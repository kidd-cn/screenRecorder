import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
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

// MARK: - 帧驱动 harness 夹具（T4）：32BGRA 纯色填充/采样 + 视频样本打包 + 成片回读

/// BGRA 四通道颜色（tuple 不可下标，用结构体承载采样循环；与 PiPCompositorTests 夹具同构）。
private struct BGRAColor {
    var blue: UInt8
    var green: UInt8
    var red: UInt8
    var alpha: UInt8
}

private func makeColorBuffer(width: Int, height: Int, color: BGRAColor) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    guard CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer
    ) == kCVReturnSuccess, let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    for row in 0..<height {
        let rowBase = base.advanced(by: row * bytesPerRow)
        for column in 0..<width {
            let pixel = rowBase.advanced(by: column * 4).assumingMemoryBound(to: UInt8.self)
            pixel[0] = color.blue
            pixel[1] = color.green
            pixel[2] = color.red
            pixel[3] = color.alpha
        }
    }
    return buffer
}

/// 采样 (x, y)（缓冲区像素坐标，左上原点、y 向下）处的 BGRA 四元组。
private func samplePixel(_ buffer: CVPixelBuffer, x: Int, y: Int) -> BGRAColor {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else {
        return BGRAColor(blue: 0, green: 0, red: 0, alpha: 0)
    }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    let pixel = base.advanced(by: y * bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
    return BGRAColor(blue: pixel[0], green: pixel[1], red: pixel[2], alpha: pixel[3])
}

/// 把像素缓冲打包成带 PTS 的视频 CMSampleBuffer（与 CameraPiPTests 夹具同构，PTS 显式
/// 传入——时钟层单调护栏拒收平帧/回跳帧）。
private func makeVideoSampleBuffer(_ pixelBuffer: CVPixelBuffer, pts: CMTime) -> CMSampleBuffer? {
    var format: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
    guard let format else { return nil }
    var timing = CMSampleTimingInfo(
        duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
    var sampleBuffer: CMSampleBuffer?
    CMSampleBufferCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true,
        makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
        sampleTiming: &timing, sampleBufferOut: &sampleBuffer)
    return sampleBuffer
}

/// H264 有损回读的颜色带断言（编码往返逐字节不可保，带内即语义成立）：
/// 黑 = 三通道全 ≤ 40；蓝 = B ≥ 200 且 R/G ≤ 60；红 = R ≥ 200 且 B/G ≤ 60。
private func assertBlack(
    _ pixel: BGRAColor, _ message: String,
    file: StaticString = #filePath, line: UInt = #line
) {
    let dominant = max(Int(pixel.blue), Int(pixel.green), Int(pixel.red))
    XCTAssertLessThanOrEqual(
        dominant, 40, "\(message)（实得 B=\(pixel.blue) G=\(pixel.green) R=\(pixel.red)）",
        file: file, line: line)
}

private func assertBlue(
    _ pixel: BGRAColor, _ message: String,
    file: StaticString = #filePath, line: UInt = #line
) {
    let isBlue = Int(pixel.blue) >= 200 && Int(pixel.red) <= 60 && Int(pixel.green) <= 60
    XCTAssertTrue(
        isBlue, "\(message)（实得 B=\(pixel.blue) G=\(pixel.green) R=\(pixel.red)）",
        file: file, line: line)
}

private func assertRed(
    _ pixel: BGRAColor, _ message: String,
    file: StaticString = #filePath, line: UInt = #line
) {
    let isRed = Int(pixel.red) >= 200 && Int(pixel.blue) <= 60 && Int(pixel.green) <= 60
    XCTAssertTrue(
        isRed, "\(message)（实得 B=\(pixel.blue) G=\(pixel.green) R=\(pixel.red)）",
        file: file, line: line)
}

// MARK: - T4 对调/缩略图取数缝：帧驱动钉测（真实 AssetWriterSession 落临时目录）

/// 帧驱动 harness（T4）：不经 start()（SCStream 构造依赖 SCContentFilter / TCC 枚举，
/// 无头不可用），经 `armForTesting` 装配真实 AssetWriterSession + 按需合成器，再以
/// `deliverVideoFrameForTesting`（= `stream(_:didOutputSampleBuffer:of:)` 的 `.screen`
/// 分支同一条 handleVideoSample 路）逐帧驱动，成片经 AVAssetReader 回读像素带断言。
/// 夹具与 PiPCompositorSwappedTests 同一套几何：画布 64×40 纯蓝、摄像头 32×32 纯红、
/// 小图位 (40,24,20,12) 圆角 3——contain rect = (12,0,40,40)（左右黑边各 12px）。
final class SCStreamRecorderSwapSeamTests: XCTestCase {
    private var directory: URL!

    private let canvasSize = CGSize(width: 64, height: 40)
    private let insetFrame = PiPFrame(
        rectInCapturePixels: CGRect(x: 40, y: 24, width: 20, height: 12), cornerRadius: 3)
    private let screenBlue = BGRAColor(blue: 255, green: 0, red: 0, alpha: 255)
    private let cameraRed = BGRAColor(blue: 0, green: 0, red: 255, alpha: 255)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SCStreamRecorderSwapSeamTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        directory = nil
    }

    // MARK: 夹具装配

    /// 对调夹具 recorder：includeCamera + PiP 双取数缝在位（合成器必装配）；swapped /
    /// 缩略图消费 / 节拍时钟缝按参注入，真实 writer 会话（64×40 画布）经装配缝落位。
    private func makeHarness(
        swapped: (() -> Bool)?,
        outputName: String,
        thumbnailConsumer: ((CGImage) -> Void)? = nil,
        clock: (() -> TimeInterval)? = nil
    ) throws -> SCStreamRecorder {
        let config = RecordingConfiguration(
            mode: .display(1),
            captureSystemAudio: false,
            captureMicrophone: false,
            includeCamera: true,
            fps: 30,
            codec: .h264,
            outputURL: directory.appendingPathComponent(outputName),
            clickHighlightEnabled: false
        )
        let recorder = SCStreamRecorder(config: config)
        let camera = makeColorBuffer(width: 32, height: 32, color: cameraRed)!
        recorder.pipPixelBufferProvider = { camera }
        recorder.pipFrameProvider = { [insetFrame] in insetFrame }
        if let swapped { recorder.layoutSwappedProvider = swapped }
        recorder.screenThumbnailConsumer = thumbnailConsumer
        if let clock { recorder.thumbnailNow = clock }
        let session = try AssetWriterSession(config: config, pixelSize: canvasSize)
        recorder.armForTesting(writerSession: session, pixelSize: canvasSize)
        return recorder
    }

    /// 连喂 count 帧纯蓝 64×40（PTS 严格递增 @30fps——时钟层单调护栏拒收平帧/回跳帧，
    /// `ptsStartIndex` 供同会话多批投喂续接序号）；`clock` 逐帧回调先于投喂执行（节拍
    /// 时钟步进钩子）。
    private func deliverFrames(
        _ recorder: SCStreamRecorder, count: Int, ptsStartIndex: Int = 0,
        clock: ((Int) -> Void)? = nil
    ) throws {
        for index in 0..<count {
            clock?(index)
            let frame = try XCTUnwrap(makeColorBuffer(width: 64, height: 40, color: screenBlue))
            let sample = try XCTUnwrap(
                makeVideoSampleBuffer(
                    frame,
                    pts: CMTime(value: CMTimeValue(ptsStartIndex + index), timescale: 30)),
                "视频样本打包失败")
            recorder.deliverVideoFrameForTesting(sample)
        }
    }

    /// 成片首帧回读（AVAssetReader 32BGRA）；无视频轨/读不出首帧 = 基础设施失败。
    private func loadFirstVideoFrame(_ url: URL) async throws -> CVPixelBuffer {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first, "成片无视频轨")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        XCTAssertTrue(
            reader.startReading(),
            "AVAssetReader 启动失败：\(String(describing: reader.error))")
        let sample = try XCTUnwrap(output.copyNextSampleBuffer(), "成片读不出首帧")
        return try XCTUnwrap(CMSampleBufferGetImageBuffer(sample), "首帧无像素缓冲")
    }

    // MARK: 钉测

    /// T4 主钉测：`layoutSwappedProvider` 真实进入 composite——swapped true 的成片为对调
    /// 布局（画布边缘纯黑黑边、contain 内摄像头红、小图位屏幕蓝），swapped false 的成片为
    /// 原样布局（边缘蓝铺满、PiP 位红）。有损编码按颜色带断言（夹具纯色，带内即语义成立）。
    func testSwappedProviderPlumbsIntoComposite() async throws {
        // 对调态：contain rect = (12,0,40,40) → 左右黑边各 12px；小图位 (40,24,20,12)。
        let swappedRecorder = try makeHarness(swapped: { true }, outputName: "录屏_swapped.mp4")
        try deliverFrames(swappedRecorder, count: 6)
        await swappedRecorder.stop()
        let swappedURL = try XCTUnwrap(swappedRecorder.finishedFileURL, "对调态帧必须真实成片")
        let swappedFrame = try await loadFirstVideoFrame(swappedURL)
        assertBlack(samplePixel(swappedFrame, x: 0, y: 0), "左上角纯黑（黑边，对调布局生效）")
        assertBlack(samplePixel(swappedFrame, x: 63, y: 39), "右下角纯黑（黑边）")
        assertBlack(samplePixel(swappedFrame, x: 0, y: 20), "左边缘纯黑（黑边）")
        assertBlack(samplePixel(swappedFrame, x: 63, y: 20), "右边缘纯黑（黑边）")
        assertRed(samplePixel(swappedFrame, x: 30, y: 20), "contain 主画面内为摄像头红")
        assertBlue(samplePixel(swappedFrame, x: 50, y: 30), "小图位为屏幕蓝（缩进小图画在摄像头之上）")

        // 原样态（false）：屏幕铺满画布（边缘全蓝），PiP 位红（原样布局在场）。
        let plainRecorder = try makeHarness(swapped: { false }, outputName: "录屏_plain.mp4")
        try deliverFrames(plainRecorder, count: 6)
        await plainRecorder.stop()
        let plainURL = try XCTUnwrap(plainRecorder.finishedFileURL, "原样帧必须真实成片")
        let plainFrame = try await loadFirstVideoFrame(plainURL)
        assertBlue(samplePixel(plainFrame, x: 0, y: 0), "左上角蓝（屏幕铺满，原样）")
        assertBlue(samplePixel(plainFrame, x: 63, y: 39), "右下角蓝（原样）")
        assertBlue(samplePixel(plainFrame, x: 0, y: 20), "左边缘蓝（原样）")
        assertBlue(samplePixel(plainFrame, x: 30, y: 20), "画布中部蓝（PiP 位之外）")
        assertRed(samplePixel(plainFrame, x: 50, y: 30), "PiP 位为摄像头红（原样布局在场）")
    }

    /// 节流派发钉测：`thumbnailNow` 手控时钟——同帧率连喂 4 帧（时钟步进 0.1s）consumer
    /// 恰 1 次（首拍打点后 0.1–0.3s 全被 0.5s 节流窗挡住）；时钟推进 0.6s 再喂第 2 次。
    func testThumbnailConsumerThrottlesToHalfSecond() async throws {
        var clock: TimeInterval = 100.0
        var thumbnails: [CGImage] = []
        let recorder = try makeHarness(
            swapped: { true },
            outputName: "录屏_throttle.mp4",
            thumbnailConsumer: { thumbnails.append($0) },
            clock: { clock })
        try deliverFrames(recorder, count: 4) { clock = 100.0 + Double($0) * 0.1 }
        XCTAssertEqual(thumbnails.count, 1, "首拍打点后 0.1s 步进的 4 帧恰产 1 张缩略图")
        clock += 0.6 // 100.3 → 100.9：越过 0.5s 节流窗
        try deliverFrames(recorder, count: 1, ptsStartIndex: 4)
        XCTAssertEqual(thumbnails.count, 2, "时钟推进 0.6s 后下一帧必须再产第 2 张")
        XCTAssertEqual(thumbnails[0].width, 64, "64×40 屏幕帧 ≤ 320 上限：原尺寸直出")
        XCTAssertEqual(thumbnails[0].height, 40, "64×40 屏幕帧 ≤ 320 上限：原尺寸直出")
        await recorder.stop()
        XCTAssertNotNil(recorder.finishedFileURL, "帧须真实成片（断言非空转）")
    }

    /// 零渲染纪律：不对调态连缩略图都不产——provider false 与 nil（T5 接线前生产常态：
    /// 缝在位而装配层未接 = 恒屏幕为主）两种取数态下，大幅跨过节流窗的多帧喂入 consumer
    /// 恒 0 次；同场帧须真实成片（断言非空转）。
    func testThumbnailOnlyConsumedWhenSwapped() async throws {
        var clock: TimeInterval = 100.0
        var consumed = 0
        let falseRecorder = try makeHarness(
            swapped: { false },
            outputName: "录屏_not_swapped.mp4",
            thumbnailConsumer: { _ in consumed += 1 },
            clock: { clock })
        try deliverFrames(falseRecorder, count: 5) { clock = 100.0 + Double($0) * 10 }
        XCTAssertEqual(consumed, 0, "不对调态零渲染：缩略图一次都不产")

        let nilProviderRecorder = try makeHarness(
            swapped: nil,
            outputName: "录屏_nil_provider.mp4",
            thumbnailConsumer: { _ in consumed += 1 },
            clock: { clock })
        try deliverFrames(nilProviderRecorder, count: 5) { clock = 200.0 + Double($0) * 10 }
        XCTAssertEqual(consumed, 0, "provider nil 同缝：恒屏幕为主，缩略图不产")

        await falseRecorder.stop()
        await nilProviderRecorder.stop()
        XCTAssertNotNil(falseRecorder.finishedFileURL, "false 场帧须真实成片（断言非空转）")
        XCTAssertNotNil(nilProviderRecorder.finishedFileURL, "nil 场帧须真实成片（断言非空转）")
    }
}
