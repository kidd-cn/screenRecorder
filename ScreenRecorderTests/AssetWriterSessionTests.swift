import AVFoundation
import XCTest

@testable import ScreenRecorder

/// AssetWriterSession 无头回归：真实 AVFoundation，不依赖 SCStream / 权限。
/// 焦点是「绝不覆盖既有录像」的预检 + claim 双保险与 macOS 27 writer 拒写已存在文件的适配。
final class AssetWriterSessionTests: XCTestCase {
    /// 错误类型嵌套在会话类内，测试里用短别名。
    private typealias WriterError = AssetWriterSession.AssetWriterSessionError

    private var directory: URL!
    private let pixelSize = CGSize(width: 64, height: 64)
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssetWriterSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        directory = nil
    }

    // MARK: - Helpers

    private func makeConfig(outputURL: URL) -> RecordingConfiguration {
        RecordingConfiguration(
            mode: .display(1), // writer 会话不解析 mode，取值无意义
            captureSystemAudio: false,
            captureMicrophone: false,
            includeCamera: false,
            fps: 30,
            codec: .h264,
            outputURL: outputURL,
            clickHighlightEnabled: false
        )
    }

    private func makeSession(named name: String) throws -> AssetWriterSession {
        try AssetWriterSession(
            config: makeConfig(outputURL: directory.appendingPathComponent(name)),
            pixelSize: pixelSize
        )
    }

    /// 轮询等待 writer 状态离开 .unknown（startWriting 后状态迁移有界等待）。
    private func waitForNonUnknownStatus(_ session: AssetWriterSession, timeout: TimeInterval = 2) async -> AVAssetWriter.Status {
        var status = session.writerStatus
        let deadline = Date().addingTimeInterval(timeout)
        while status == .unknown && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
            status = session.writerStatus
        }
        return status
    }

    private func waitForFile(_ path: String, timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !fileManager.fileExists(atPath: path) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return fileManager.fileExists(atPath: path)
    }

    // MARK: - Tests

    /// 本缺陷的回归测试（修复轮 1）：macOS 27 的 writer 拒写已存在文件——旧的「占位真实路径」
    /// 方案会让 startWriting 滑向 .failed(-11823)。claim 方案下 writer 必须稳定进入 .writing
    /// 并自行创建输出文件，claim 同步就位。
    func testStartWritingEntersWritingState() async throws {
        let session = try makeSession(named: "录屏_test_a.mp4")
        let url = session.outputURL

        try session.addVideoInput(with: nil)
        session.startWriting()

        XCTAssertTrue(fileManager.fileExists(atPath: url.path + ".claim"), "装配期 claim 必须在位")
        let status = await waitForNonUnknownStatus(session)
        XCTAssertEqual(status, .writing, "writer 未能进入 .writing：\(String(describing: session.writerError))")
        let outputCreated = await waitForFile(url.path)
        XCTAssertTrue(outputCreated, "writer 未创建输出文件")
    }

    /// 同 URL 二次 init：writer 已创建本体后，第二个会话必须被预检拦下（绝不覆盖既有录像）。
    func testSecondSessionOnSameURLThrowsOutputAlreadyExists() async throws {
        let first = try makeSession(named: "录屏_test_b.mp4")
        try first.addVideoInput(with: nil)
        first.startWriting()
        let url = first.outputURL
        guard await waitForFile(url.path) else {
            return XCTFail("writer 未在 2s 内创建输出文件，无法构造本体已存在场景")
        }

        XCTAssertThrowsError(try makeSession(named: "录屏_test_b.mp4")) { error in
            guard case WriterError.outputAlreadyExists(let existing) = error else {
                return XCTFail("期望 outputAlreadyExists，得到 \(error)")
            }
            XCTAssertEqual(existing, url)
        }
    }

    /// claim 冲突：首个会话只装配（占 claim，writer 尚未建本体）时，同 URL 的第二个会话
    /// 必须抛 outputBusy 而不是静默并写。首个会话须持活（deinit 会摘 claim）。
    func testClaimConflictThrowsOutputBusy() throws {
        let holder = try makeSession(named: "录屏_test_c.mp4") // 仅 init：claim 在位，本体未创建
        XCTAssertTrue(fileManager.fileExists(atPath: holder.outputURL.path + ".claim"))

        XCTAssertThrowsError(try makeSession(named: "录屏_test_c.mp4")) { error in
            guard case WriterError.outputBusy = error else {
                return XCTFail("期望 outputBusy，得到 \(error)")
            }
        }
    }

    /// 零内容路径不留空壳：discard（startWriting 前）与 nothingWritten finish
    ///（startWriting 后零样本）都必须同时清掉本体与 claim。
    func testZeroContentPathsCleanOutputAndClaim() async throws {
        // discard 路径
        let discardSession = try makeSession(named: "录屏_test_d1.mp4")
        let discardURL = discardSession.outputURL
        discardSession.discardIfNoContent()
        XCTAssertFalse(fileManager.fileExists(atPath: discardURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: discardURL.path + ".claim"))

        // nothingWritten 路径
        let finishSession = try makeSession(named: "录屏_test_d2.mp4")
        let finishURL = finishSession.outputURL
        try finishSession.addVideoInput(with: nil)
        finishSession.startWriting()
        do {
            _ = try await finishSession.finish()
            XCTFail("零样本 finish 应抛 nothingWritten")
        } catch let error as WriterError {
            guard case .nothingWritten = error else {
                return XCTFail("期望 nothingWritten，得到 \(error)")
            }
        }
        XCTAssertFalse(fileManager.fileExists(atPath: finishURL.path), "nothingWritten 路径未清理本体")
        XCTAssertFalse(fileManager.fileExists(atPath: finishURL.path + ".claim"), "nothingWritten 路径未清理 claim")
    }
}
