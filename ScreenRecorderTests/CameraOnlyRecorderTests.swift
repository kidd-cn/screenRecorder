import AVFoundation
import CoreMedia
import CoreVideo
import XCTest

@testable import ScreenRecorder

/// CameraOnlyRecorder（P7b 仅摄像头录制）无头钉测：真 writer 会话 + 假帧源（照
/// AssetWriterSessionTests / CameraPiPTests 的假源惯例，参考 T13
/// testAudioOnlyWriterProducesPureAudioM4a 的深钉形状）。真实摄像头链路（授权/设备解析/
/// 会话启动/preset 谈判）无头不可确定性驱动，归批量真机轮验收；此处钉：writer 装配与
/// O_EXCL claim 排他纪律、暂停时间轴语义（PauseMediaClock 同款断言，受控暂停时钟注入）、
/// makeConfiguration 的 cameraOnly 效果门与标记入口共享判定、采集装配纯逻辑缝。
///
/// 夹具故障注释：CVPixelBuffer/FormatDescription/SampleBuffer 创建失败是测试基础设施故障，
/// 必须 XCTUnwrap 表现为失败，不得表现为 skipped（AssetWriterSessionTests 同纪律）。
final class CameraOnlyRecorderTests: XCTestCase {
    private var directory: URL!
    private let fileManager = FileManager.default
    /// writer 画布尺寸（假帧源按此交付，与挂载尺寸一致的机制前提）。
    private let frameSize = CGSize(width: 64, height: 64)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraOnlyRecorderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        directory = nil
    }

    // MARK: - Helpers

    private func makeRecorder(outputName: String = "录屏_camera_only.mp4") -> CameraOnlyRecorder {
        CameraOnlyRecorder(config: RecordingConfiguration(
            mode: .cameraOnly,
            captureSystemAudio: false,
            captureMicrophone: false,
            includeCamera: false,
            fps: 30,
            codec: .h264,
            outputURL: directory.appendingPathComponent(outputName),
            clickHighlightEnabled: false
        ))
    }

    /// 假帧源样本（CameraPiPTests 夹具同款：BGRA 像素缓冲 → CMVideoFormatDescription →
    /// CMSampleBufferCreateForImageBuffer）。
    private func makeFrameSample(pts: CMTime) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, Int(frameSize.width), Int(frameSize.height),
            kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        let buffer = try XCTUnwrap(pixelBuffer, "夹具 CVPixelBuffer 创建失败（status=\(status)）")
        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &formatDescription)
        let description = try XCTUnwrap(formatDescription, "夹具 CMVideoFormatDescription 创建失败")
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: description,
            sampleTiming: &timing, sampleBufferOut: &sampleBuffer)
        return try XCTUnwrap(sampleBuffer, "夹具 CMSampleBuffer 创建失败")
    }

    // MARK: - Tests


    /// brief Step 1：假源帧 → finish 后 URL 存在；装配期 claim 在位、收尾后摘除（复用
    /// AssetWriterSession 预检 + O_EXCL claim 排他纪律）。产物恰一条 H.264 视频轨、零音轨
    ///（无混音器装配的 cameraOnly 会话 = 纯视频 MP4）。
    func testStartWritesVideoTrackWithClaim() async throws {
        let recorder = makeRecorder()
        let outputURL = directory.appendingPathComponent("录屏_camera_only.mp4")
        recorder.onStreamFailure = { error in XCTFail("正常帧流不得触发失败通道：\(error)") }
        try recorder.mountWriterSession(pixelSize: frameSize)

        XCTAssertTrue(
            fileManager.fileExists(atPath: outputURL.path + ".claim"),
            "writer 挂载即 claim 占位（排他纪律：占用输出 URL 至收尾）")

        // 5 帧 @30fps，PTS 从 1000s 起（假帧源直接驱动采集收敛点；首帧装配 writer ——
        // addVideoInput + startWriting 同步置 .writing 后即刻 append，与生产同一路径）。
        let base = CMTime(value: 30_000, timescale: 30)
        for frame in 0..<5 {
            recorder.handleVideoSample(try makeFrameSample(
                pts: CMTimeAdd(base, CMTime(value: CMTimeValue(frame), timescale: 30))))
        }

        let finishedURL = await recorder.finish()
        XCTAssertEqual(finishedURL, outputURL, "有内容会话必须产出成片")
        XCTAssertTrue(fileManager.fileExists(atPath: outputURL.path), "成片本体存在")
        XCTAssertFalse(fileManager.fileExists(atPath: outputURL.path + ".claim"), "收尾后 claim 摘除")
        XCTAssertNil(recorder.lastError)

        let asset = AVURLAsset(url: outputURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1, "成片恰含一条视频轨")
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audioTracks.isEmpty, "无混音器装配不得产出音轨")
        let descriptions = try await videoTracks[0].load(.formatDescriptions)
        for description in descriptions {
            XCTAssertEqual(
                CMFormatDescriptionGetMediaSubType(description),
                kCMVideoCodecType_H264,
                "视频编码必须是 H.264（config.codec = .h264）")
        }
    }

    /// brief Step 1：PauseMediaClock 同款断言——受控暂停时钟注入 30s 暂停窗（pause 记 40s、
    /// resume 记 70s）：暂停中的帧整帧丢弃（10.066/10.1 不入 writer、不补帧，计数 2），
    /// 恢复后 PTS 统一平移去除暂停段（70.033 → 40.033，容器级判别断言见断言处注释；
    /// 平移数学本身由 PauseMediaClockTests 逐值钉死，本测钉 recorder 决策路径）。
    func testPauseResumeShiftsTimestamps() async throws {
        let recorder = makeRecorder()
        // 受控暂停时钟（生产 = host clock 内联值；测试钉死时点，与帧 PTS 同 mach 时基约定由生产闭包保持）。
        let clockTimes: [CMTime] = [
            CMTime(value: 40, timescale: 1),
            CMTime(value: 70, timescale: 1),
        ]
        var clockIndex = 0
        recorder.pauseClock = {
            defer { clockIndex += 1 }
            return clockTimes[min(clockIndex, clockTimes.count - 1)]
        }
        recorder.onStreamFailure = { error in XCTFail("正常帧流不得触发失败通道：\(error)") }
        try recorder.mountWriterSession(pixelSize: frameSize)

        let t: (Double) -> CMTime = { CMTime(seconds: $0, preferredTimescale: 600) }
        recorder.handleVideoSample(try makeFrameSample(pts: t(10.0))) // 锚
        recorder.handleVideoSample(try makeFrameSample(pts: t(10.033)))
        recorder.pause()
        XCTAssertTrue(recorder.isPaused)
        recorder.handleVideoSample(try makeFrameSample(pts: t(10.066))) // 暂停中：丢弃
        recorder.handleVideoSample(try makeFrameSample(pts: t(10.1)))   // 暂停中：丢弃
        recorder.resume()
        XCTAssertFalse(recorder.isPaused)
        recorder.handleVideoSample(try makeFrameSample(pts: t(70.033))) // 恢复后：平移 → 40.033

        XCTAssertEqual(
            recorder.pausedDroppedVideoFrameCount, 2,
            "暂停中的两帧必须计入暂停丢弃（SCStreamRecorder 同款诊断读数）")

        let maybeFinishedURL = await recorder.finish()
        let finishedURL = try XCTUnwrap(maybeFinishedURL, "有内容会话必须产出成片")
        XCTAssertEqual(finishedURL, directory.appendingPathComponent("录屏_camera_only.mp4"))
        let asset = AVURLAsset(url: finishedURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1)
        // 容器级判别（逐帧 PTS 已由 PauseMediaClockTests 在时钟层钉死；H.264 编码器对
        // .invalid 样本时长按前一样本间隔外推尾帧时长，30s 合成暂停间隔使容器报告时长
        // 翻倍——macOS 27 实测恒 60.032）：平移正确 → ≈60.03；「未平移」回归 → ≈120；
        // 「未门控」（暂停 2 帧入轨、间隔链更长）→ ≈150。三态可判别即本断言充分。
        let range = try await videoTracks[0].load(.timeRange)
        XCTAssertEqual(range.start.seconds, 0, accuracy: 0.1, "锚帧折算成片 0 起")
        XCTAssertEqual(
            range.duration.seconds, 60.032, accuracy: 0.5,
            "恢复帧平移（40.032 − 锚 10.0 剔除 30s 暂停段）+ 尾帧时长外推的容器时长必须落在 ~60s 档"
                + "（未平移 ~120s / 未门控 ~150s 均判失败）")
    }

    /// 采集装配纯逻辑缝：预设与 writer 画布成对定格（HD 可用 → 720p 档；不可用 → VGA 档
    /// ——CameraPiPController 既有惯例档），两档尺寸恒定是「writer pixelSize 与交付档一致」
    /// 的机制前提；帧率就近支持档钳制边界。
    func testCapturePlanPairsPresetWithPixelSizeAndClampsFPS() {
        let hd = CameraOnlyRecorder.capturePlan(supportsHD: true)
        XCTAssertEqual(hd.preset, .hd1280x720)
        XCTAssertEqual(hd.pixelSize, CGSize(width: 1280, height: 720))
        let vga = CameraOnlyRecorder.capturePlan(supportsHD: false)
        XCTAssertEqual(vga.preset, .vga640x480)
        XCTAssertEqual(vga.pixelSize, CGSize(width: 640, height: 480))

        XCTAssertEqual(CameraOnlyRecorder.clampedFPS(60, deviceMin: 24, deviceMax: 30), 30, "请求 60 高于设备上限 → 取上限")
        XCTAssertEqual(CameraOnlyRecorder.clampedFPS(15, deviceMin: 24, deviceMax: 60), 24, "请求 15 低于设备下限 → 取下限")
        XCTAssertEqual(CameraOnlyRecorder.clampedFPS(30, deviceMin: 24, deviceMax: 60), 30, "档间原样")
        XCTAssertEqual(CameraOnlyRecorder.clampedFPS(90, deviceMin: 30, deviceMax: 60), 60, "远超上限 → 取上限")
        XCTAssertEqual(CameraOnlyRecorder.clampedFPS(60, deviceMin: 60, deviceMax: 60), 60, "单档设备")
        XCTAssertEqual(CameraOnlyRecorder.clampedFPS(0, deviceMin: 24, deviceMax: 60), 24, "野值防御（≥1 后落钳制区间）")
    }
}

// MARK: - P7b：makeConfiguration 的 cameraOnly 效果门 + 标记入口共享判定

/// brief Step 1：cameraOnly 经 makeConfiguration 强制关断的效果族（规格钉定「效果不可用」），
/// 外加标记入口「无视频画布」共享谓词的布尔矩阵（覆盖层/工具条/画笔按钮/源丢失监视同一真源）。
@MainActor
final class CameraOnlyConfigurationTests: XCTestCase {
    private static let suiteName = "test.cameraOnly.configuration"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)
        defaults.removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.suiteName)
        defaults = nil
        super.tearDown()
    }

    func testEffectsUnavailableInCameraOnly() {
        let settings = SettingsStore(userDefaults: defaults)
        settings.captureSystemAudio = true
        settings.captureMicrophone = true
        settings.pipEnabled = true
        settings.autoZoomEnabled = true
        settings.clickHighlightEnabled = true
        settings.clickSoundEnabled = true

        let config = AppAssembly.makeConfiguration(
            settings: settings,
            mode: .cameraOnly,
            outputURL: URL(fileURLWithPath: "/tmp/camera_only.mp4"))

        XCTAssertEqual(config.mode, .cameraOnly)
        XCTAssertFalse(config.includeCamera, "画中画叠加摄像头必须强制关（录制源摄像头不经此字段）")
        XCTAssertFalse(config.autoZoomEnabled, "缩放必须强制关（规格钉定：cameraOnly 效果不可用）")
        XCTAssertFalse(config.clickHighlightEnabled, "点击高亮必须强制关")
        XCTAssertFalse(config.clickSoundEnabled, "点击音效必须强制关（骑点击高亮同一点击源的效果族）")
        XCTAssertFalse(config.captureSystemAudio, "系统声必须强制关（唯一采集通道是 SCStream，cameraOnly 不建流）")
        XCTAssertTrue(config.captureMicrophone, "麦克风照常（用户偏好透传，经 mixer 可混）")

        // 标记入口共享判定：「无视频画布」谓词布尔矩阵（cameraOnly 与 audioOnly 同侧）。
        XCTAssertFalse(CaptureMode.cameraOnly.hasVideoCanvas)
        XCTAssertFalse(CaptureMode.audioOnly.hasVideoCanvas)
        XCTAssertTrue(CaptureMode.display(1).hasVideoCanvas)
        XCTAssertTrue(CaptureMode.window(1).hasVideoCanvas)
        XCTAssertTrue(
            CaptureMode.region(rect: CGRect(x: 0, y: 0, width: 8, height: 8), displayID: 1).hasVideoCanvas)
        XCTAssertTrue(CaptureMode.app(bundleID: "com.example.app").hasVideoCanvas)
        XCTAssertTrue(
            CaptureMode.windowRegion(window: 1, rect: CGRect(x: 0, y: 0, width: 8, height: 8)).hasVideoCanvas)
    }
}
