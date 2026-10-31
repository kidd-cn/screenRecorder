import AVFoundation
import XCTest

@testable import ScreenRecorder

/// SCStreamRecorder 暂停/恢复生命周期边界（Task 10）。不启动真实采集（SCStream 需要
/// 屏幕录制权限，无头不可用），只验证「未开始录制」的边界语义；暂停门控/平移/单调
/// 护栏的状态机行为由 PauseMediaClockTests 覆盖。
final class SCStreamRecorderPauseTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SCStreamRecorderPauseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        directory = nil
    }

    private func makeRecorder() -> SCStreamRecorder {
        SCStreamRecorder(config: RecordingConfiguration(
            mode: .display(1),
            captureSystemAudio: true,
            captureMicrophone: true,
            includeCamera: false,
            fps: 30,
            codec: .h264,
            outputURL: directory.appendingPathComponent("录屏_pause.mp4"),
            clickHighlightEnabled: false
        ))
    }

    /// 生命周期边界（Task 10 报告裁定）：录制未开始时 pause/resume 为 no-op——
    /// 不抛错、不置位（上层浮条无需跟踪录制生命周期状态）。
    func testPauseResumeBeforeStartAreNoOps() {
        let recorder = makeRecorder()

        XCTAssertFalse(recorder.isPaused)
        recorder.pause()
        XCTAssertFalse(recorder.isPaused, "录制未开始时 pause 必须 no-op")
        recorder.resume()
        XCTAssertFalse(recorder.isPaused, "录制未开始时 resume 必须 no-op")
    }

    /// 重复 pause/resume 幂等且边界外调用无副作用。
    func testRepeatedCallsStayNoOps() {
        let recorder = makeRecorder()

        recorder.pause()
        recorder.pause()
        XCTAssertFalse(recorder.isPaused)
        recorder.resume()
        recorder.resume()
        XCTAssertFalse(recorder.isPaused)
    }

    /// 修复轮 2：暂停丢弃计数快照在 stop 后仍可读——stop 复位 mediaClock 不得清零
    /// 诊断读数（T11 成片时长归因在收尾之后读）。internal 快照字段注入模拟真实录制
    /// 产生的活动计数（生产路径仅 stop/start 失败回滚临界区写入）；重复 stop 亦不清零。
    func testPausedDropCountersSurviveStop() async {
        let recorder = makeRecorder()
        recorder.finalPausedDroppedVideoFrameCount = 3
        recorder.finalPausedDroppedAudioPacketCount = 5
        XCTAssertEqual(recorder.pausedDroppedVideoFrameCount, 3)
        XCTAssertEqual(recorder.pausedDroppedAudioPacketCount, 5)

        await recorder.stop()
        XCTAssertEqual(recorder.pausedDroppedVideoFrameCount, 3, "stop 后快照读数必须保留")
        XCTAssertEqual(recorder.pausedDroppedAudioPacketCount, 5, "stop 后快照读数必须保留")

        await recorder.stop()
        XCTAssertEqual(recorder.pausedDroppedVideoFrameCount, 3, "重复 stop 不得覆盖快照")
        XCTAssertEqual(recorder.pausedDroppedAudioPacketCount, 5, "重复 stop 不得覆盖快照")
    }
}

// MARK: - P7a 仅声音录制：audioOnly 音轨装配的 writer 层钉测（无头）

extension SCStreamRecorderPauseTests {
    /// audioOnly 会话的音轨装配形状（生产 = SCStreamRecorder 仅音频分支在首个混音包上
    /// 装配）：writer 会话以 .m4a 输出 URL + 纯音轨（无 addVideoInput）走
    /// addAudioInput → startWriting → appendAudio → finish，产物可读且**恰为一条 AAC
    /// 音轨、零视频轨**（.m4a 纯音轨容器契约；QuickLook 原生可播的前提）。
    /// 与 AssetWriterSessionTests 的音画双轨钉测互补：此处钉「无视频 input 也能收尾成片」。
    func testAudioOnlyWriterProducesPureAudioM4a() async throws {
        let outputURL = directory.appendingPathComponent("录屏_audio_only.m4a")
        let config = RecordingConfiguration(
            mode: .audioOnly,
            captureSystemAudio: true,
            captureMicrophone: false,
            includeCamera: false,
            fps: 30,
            codec: .h264,
            outputURL: outputURL,
            clickHighlightEnabled: false
        )
        // audioOnly 无视频画布：pixelSize 仅占位（纯音轨会话永不 addVideoInput）。
        let session = try AssetWriterSession(config: config, pixelSize: .zero)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        try session.addAudioInput(with: format)
        session.startWriting()

        // 8 段 × 1024 帧 @48k（~0.17s）恒幅 0.25，PTS 从 1s 起。
        for chunk in 0..<8 {
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) else {
                return XCTFail("AVAudioPCMBuffer 创建失败")
            }
            pcm.frameLength = 1024
            for index in 0..<1024 {
                pcm.floatChannelData![0][index] = 0.25
                pcm.floatChannelData![1][index] = -0.25
            }
            var descriptionOut: CMFormatDescription?
            var asbd = format.streamDescription.pointee
            let status = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &descriptionOut)
            XCTAssertEqual(status, noErr)
            let description = try XCTUnwrap(descriptionOut, "CMFormatDescription 创建失败")
            let sample = try XCTUnwrap(
                AudioSampleBridge.makeSampleBuffer(
                    pcm: pcm,
                    skipFrames: 0,
                    pts: CMTime(value: CMTimeValue(48_000 + chunk * 1024), timescale: 48_000),
                    formatDescription: description),
                "CMSampleBuffer 打包失败")
            try session.appendAudio(sample)
        }

        let finishedURL = try await session.finish()
        XCTAssertEqual(finishedURL, outputURL, "成片 URL 即 .m4a 输出 URL")

        let asset = AVURLAsset(url: finishedURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1, ".m4a 成片恰含一条音轨")
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertTrue(videoTracks.isEmpty, "纯音轨成片不得含视频轨")
        let descriptions = try await audioTracks[0].load(.formatDescriptions)
        for description in descriptions {
            XCTAssertEqual(
                CMFormatDescriptionGetMediaSubType(description),
                FourCharCode(kAudioFormatMPEG4AAC),
                "音轨编码必须是 AAC")
        }
    }
}
