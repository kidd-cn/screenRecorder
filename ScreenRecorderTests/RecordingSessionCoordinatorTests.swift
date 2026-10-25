import XCTest

@testable import ScreenRecorder

/// 可编程假 provider（同 DiskSpaceMonitorTests 模式）：直接返回预设字节数。
private final class FakeFreeSpaceProvider: DiskFreeSpaceProviding {
    var freeBytesValue: Int64?

    func freeBytes(at url: URL) -> Int64? { freeBytesValue }
}

/// RecordingSessionCoordinator 无头可测面：begin 前置磁盘检查 / 无会话时的空操作语义。
/// begin 成功路径依赖 ScreenCaptureKit TCC（无头环境不可确定性驱动），归批量真机轮验收。
@MainActor
final class RecordingSessionCoordinatorTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingSessionCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func makeConfig() -> RecordingConfiguration {
        RecordingConfiguration(
            mode: .display(1),
            captureSystemAudio: false,
            captureMicrophone: false,
            micVolume: 1.0,
            includeCamera: false,
            fps: 30,
            codec: .h264,
            outputURL: tempDirectory.appendingPathComponent("target.mp4"),
            clickHighlightEnabled: false
        )
    }

    func testBeginThrowsInsufficientDiskSpaceBelowStopThreshold() async {
        let provider = FakeFreeSpaceProvider()
        provider.freeBytesValue = 400_000_000
        let coordinator = RecordingSessionCoordinator(
            diskProvider: provider, warnBelow: 2_000_000_000, stopBelow: 500_000_000)

        do {
            _ = try await coordinator.begin(makeConfig())
            XCTFail("低于 stop 阈值时 begin 应失败，不开录")
        } catch let error as CaptureSessionError {
            XCTAssertEqual(error, .insufficientDiskSpace(freeBytes: 400_000_000, requiredBytes: 500_000_000))
        } catch {
            XCTFail("意外错误类型：\(error)")
        }
    }

    func testFinishWithoutBeginReturnsNil() async {
        let coordinator = RecordingSessionCoordinator()

        let url = await coordinator.finish()

        XCTAssertNil(url)
    }

    func testPauseResumeWithoutSessionAreNoOps() {
        let coordinator = RecordingSessionCoordinator()

        coordinator.pause()
        coordinator.resume()
    }
}
