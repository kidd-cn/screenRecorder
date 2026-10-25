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

    // MARK: - Task 8：AAC 音轨与音画锚点

    private let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!

    /// 构造非交错 PCM 的 CMSampleBuffer（与 SystemAudioMixer 输出口径一致）。
    private func makeAudioSample(pcm: AVAudioPCMBuffer, pts: CMTime) throws -> CMSampleBuffer {
        var asbd = pcm.format.streamDescription.pointee
        var description: CMFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        )
        XCTAssertEqual(status, noErr)
        guard let description else { throw XCTSkip("CMFormatDescription 创建失败") }
        guard let sample = AudioSampleBridge.makeSampleBuffer(
            pcm: pcm, skipFrames: 0, pts: pts, formatDescription: description
        ) else {
            throw XCTSkip("CMSampleBuffer 打包失败")
        }
        return sample
    }

    /// 成片音轨必须是 AAC（MP4 + AAC 是规格硬要求），且音频 PTS 相对视频锚点的位置
    /// 在成片时间轴上得到尊重（音画起点同步的 writer 层验证）。
    /// 实测口径（macOS 27）：track timeRange 以成片时间 0 为基准；内容落点用 AVAssetReader
    /// 解码后的首个非静音样本时间验证。AAC priming 实测引入 ~3ms 偏移，断言窗口放宽。
    func testAudioTrackIsAACAndLateStartLandsAtItsPTS() async throws {
        let session = try makeSession(named: "录屏_test_aac.mp4")
        let url = session.outputURL
        try session.addVideoInput(with: nil)
        try session.addAudioInput(with: audioFormat)
        session.startWriting()
        let status = await waitForNonUnknownStatus(session)
        XCTAssertEqual(status, .writing, "writer 未进入 .writing：\(String(describing: session.writerError))")

        // 视频锚定 1000.0s：60 帧 @30fps（2s）
        let base = CMTime(value: 48_000_000, timescale: 48_000)
        guard let pixelBuffer = makePixelBuffer() else { return XCTFail("CVPixelBuffer 创建失败") }
        for frame in 0..<60 {
            let pts = CMTimeAdd(base, CMTime(value: CMTimeValue(frame), timescale: 30))
            try? await Task.sleep(nanoseconds: 2_000_000)
            try session.appendVideo(pixelBuffer, at: pts)
        }
        // 音频从 1000.5s 起步（晚于锚点）：12 段 × 1024 帧 @48k（0.256s），恒幅 0.25
        let audioStart = CMTimeAdd(base, CMTime(value: 24_000, timescale: 48_000))
        for chunk in 0..<12 {
            guard let pcm = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: 1024) else {
                return XCTFail("AVAudioPCMBuffer 创建失败")
            }
            pcm.frameLength = 1024
            for index in 0..<1024 {
                pcm.floatChannelData![0][index] = 0.25
                pcm.floatChannelData![1][index] = -0.25
            }
            let pts = CMTimeAdd(audioStart, CMTime(value: CMTimeValue(chunk * 1024), timescale: 48_000))
            try? await Task.sleep(nanoseconds: 2_000_000)
            try session.appendAudio(makeAudioSample(pcm: pcm, pts: pts))
        }

        let finishedURL = try await session.finish()
        XCTAssertEqual(finishedURL, url)

        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1, "成片必须有音频轨")

        let descriptions = try await audioTracks[0].load(.formatDescriptions)
        XCTAssertFalse(descriptions.isEmpty)
        for description in descriptions {
            XCTAssertEqual(
                CMFormatDescriptionGetMediaSubType(description),
                FourCharCode(kAudioFormatMPEG4AAC),
                "音轨编码必须是 AAC"
            )
        }
        let videoRange = try await videoTracks[0].load(.timeRange)
        XCTAssertEqual(videoRange.duration.seconds, 2.0, accuracy: 0.1, "视频时长 2s")
        let audioRange = try await audioTracks[0].load(.timeRange)
        // 轨道编辑从成片 0 起（头部为锚点前的静音间隙），时长 = 间隙 0.5s + 内容 0.256s
        XCTAssertEqual(audioRange.duration.seconds, 0.756, accuracy: 0.1, "音频轨道时长应覆盖 0.5s 间隙 + 0.256s 内容")

        // 内容落点：解码音轨，首个非静音样本应落在成片时间 0.5s（±0.1，AAC priming ~3ms）
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var firstLoud: Double?
        while firstLoud == nil, let sample = output.copyNextSampleBuffer() {
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0, let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
            guard let dataPointer else { continue }
            let floats = dataPointer.withMemoryRebound(to: Float.self, capacity: totalLength / 4) { $0 }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            for frame in 0..<frames where floats[frame * 2] > 0.1 {
                firstLoud = pts + Double(frame) / audioFormat.sampleRate
                break
            }
        }
        let loud = try XCTUnwrap(firstLoud, "音轨解码后无任何非静音样本")
        XCTAssertEqual(loud, 0.5, accuracy: 0.1, "音频内容应从成片时间 0.5s（其 PTS 相对锚点的位置）开始")
    }

    private func makePixelBuffer() -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, 0, CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }
}
