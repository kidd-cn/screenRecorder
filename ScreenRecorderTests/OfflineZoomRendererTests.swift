import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import XCTest

@testable import ScreenRecorder

/// OfflineZoomRenderer（P9 离线缩放渲染引擎）无头钉测：
/// - `ZoomSegment.validate`（排序 + 钳制 + 去重叠保留先者 + 非法段丢弃）；
/// - 缓入/缓出窗口与实时时长常量同源（`AutoZoomState.attackDuration` / `.releaseDuration`
///   单一真源，离线侧零复制——Task 17 钉定）+ segment 内部进度窗口语义（入点缓入、
///   出点缓出、短段窗口各收敛到段长一半）；
/// - 真实渲染小夹具：程序生成 2s@30fps 纯色 + 运动标记源（含静音 AAC 音轨）→
///   1 个 segment 渲染 → 输出时长/尺寸一致、音轨在且同为 AAC（音画时间线不动）、
///   同一探针点在恒等帧与 hold 帧取色翻转（中心区域被放大可区分）、进度 0…1 单调
///   到顶恰一次 1.0、输出命名 `<原名>_缩放.mp4`。
///
/// 渲染/编码走真实 AVAssetReader/Writer + CI：经 `context:` 缝注入软件渲染上下文
///（headless 确定性，与 PiPCompositorTests 同纪律）；GPU 路径与长片吞吐归批次真机
/// 验收。像素探针全部取中高（y = 高/2）——底帧竖直翻转口径下取色不变（夹具标记
/// 垂直居中厚条），探针只钉水平向的放大位移。夹具装配失败是测试基础设施故障，
/// 必须 XCTUnwrap 表现为失败，不得表现为 skipped（ExportCoreTests 同纪律）。
final class OfflineZoomRendererTests: XCTestCase {
    private var directory: URL!

    /// 探针取色容差（H.264 色度抽样与编码漂移；探针点深在纯色区内部，远超此容差）。
    private let colorTolerance = 0.2
    /// 夹具背景（近黑）/标记色（亮红）——探针期望值。
    private let background = (0.10, 0.10, 0.10)
    private let marker = (0.90, 0.20, 0.10)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfflineZoomRendererTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        directory = nil
    }

    // MARK: - ZoomSegment.validate（排序 + 钳制 + 去重叠保留先者）

    func testValidateSortsClampsAndDropsOverlaps() {
        let input = [
            ZoomSegment(start: 3.0, end: 4.0, level: 2.5, center: CGPoint(x: 0.5, y: 0.5)),
            ZoomSegment(start: 1.0, end: 2.0, level: 1.6, center: CGPoint(x: 1.4, y: -0.2)),
            // 与上一条 1.0–2.0 重叠 → 丢（重叠保留先者）
            ZoomSegment(start: 1.5, end: 2.5, level: 1.6, center: CGPoint(x: 0.5, y: 0.5)),
            // start < 0 钳 0
            ZoomSegment(start: -1.0, end: 0.5, level: 1.6, center: CGPoint(x: 0.5, y: 0.5)),
            // start >= end（约束不可钳）→ 丢
            ZoomSegment(start: 5.0, end: 5.0, level: 1.6, center: CGPoint(x: 0.5, y: 0.5)),
            // level 就近钳档：2.5 → 1.9、1.7 → 1.6、0.5 → 1.35
            ZoomSegment(start: 6.0, end: 7.0, level: 1.7, center: CGPoint(x: 0.5, y: 0.5)),
            ZoomSegment(start: 8.0, end: 9.0, level: 0.5, center: CGPoint(x: 0.5, y: 0.5)),
            // 非有限字段（不可钳）→ 丢
            ZoomSegment(start: .nan, end: 10.0, level: 1.6, center: CGPoint(x: 0.5, y: 0.5)),
        ]

        XCTAssertEqual(ZoomSegment.validate(input), [
            ZoomSegment(start: 0.0, end: 0.5, level: 1.6, center: CGPoint(x: 0.5, y: 0.5)),
            ZoomSegment(start: 1.0, end: 2.0, level: 1.6, center: CGPoint(x: 1.0, y: 0.0)),
            ZoomSegment(start: 3.0, end: 4.0, level: 1.9, center: CGPoint(x: 0.5, y: 0.5)),
            ZoomSegment(start: 6.0, end: 7.0, level: 1.6, center: CGPoint(x: 0.5, y: 0.5)),
            ZoomSegment(start: 8.0, end: 9.0, level: 1.35, center: CGPoint(x: 0.5, y: 0.5)),
        ], "排序 + 钳制（start ≥ 0 / level 最近档 / center 0…1）+ 重叠丢后者 + 非法段丢弃")

        // 首尾相接不算重叠（区间半开 [start, end)）
        let adjacent = ZoomSegment.validate([
            ZoomSegment(start: 1.0, end: 2.0, level: 1.6, center: CGPoint(x: 0.5, y: 0.5)),
            ZoomSegment(start: 2.0, end: 3.0, level: 1.6, center: CGPoint(x: 0.5, y: 0.5)),
        ])
        XCTAssertEqual(adjacent.count, 2, "半开区间：前段 end == 后段 start 不算重叠")

        // 被包含段（完全落在先者内部）同样按重叠丢弃
        let contained = ZoomSegment.validate([
            ZoomSegment(start: 0.0, end: 10.0, level: 1.6, center: CGPoint(x: 0.5, y: 0.5)),
            ZoomSegment(start: 3.0, end: 4.0, level: 1.6, center: CGPoint(x: 0.5, y: 0.5)),
        ])
        XCTAssertEqual(contained.map(\.start), [0.0], "内含段丢弃，保留先者")
    }

    // MARK: - 缓入缓出窗口（实时时长常量单一真源）

    func testSegmentEasingWindowMatchesLiveConstants() {
        // 单一真源断言：离线窗口常量 = AutoZoomState 实时时长常量（离线侧零复制——
        // 常量数值本身 0.25/0.4 的钉测在 AutoZoomStateTests，此处只钉「同源」）。
        XCTAssertEqual(OfflineZoomRenderer.easingInWindow, AutoZoomState.attackDuration,
                       "离线缓入窗口必须引用实时 attack 时长真源")
        XCTAssertEqual(OfflineZoomRenderer.easingOutWindow, AutoZoomState.releaseDuration,
                       "离线缓出窗口必须引用实时 release 时长真源")
        XCTAssertEqual(AutoZoomState.attackDuration, 0.25, accuracy: 1e-12)
        XCTAssertEqual(AutoZoomState.releaseDuration, 0.4, accuracy: 1e-12)

        // segment 内部进度窗口语义：线性相位位置（easeInOut 由 contentTransform 内部
        // 施加——与实时 AutoZoomState.progress 同构），入点 0 / 出点 0 = 原始画面。
        let segment = ZoomSegment(start: 1.0, end: 3.0, level: 1.6, center: CGPoint(x: 0.5, y: 0.5))
        func progress(at time: TimeInterval) -> Double {
            OfflineZoomRenderer.zoomProgress(for: segment, at: time)
        }
        XCTAssertEqual(progress(at: 0.99), 0, "段外无缩放")
        XCTAssertEqual(progress(at: 1.0), 0, "入点 = 原始画面（与实时 attack 起点同构）")
        XCTAssertEqual(progress(at: 1.0 + AutoZoomState.attackDuration), 1,
                       "缓入窗口走满即进 hold（窗口端点恰满档位）")
        XCTAssertEqual(progress(at: 1.0 + AutoZoomState.attackDuration / 2), 0.5, accuracy: 1e-9,
                       "相位线性")
        XCTAssertEqual(progress(at: 2.0), 1, "hold 中段满档位")
        XCTAssertEqual(progress(at: 3.0 - AutoZoomState.releaseDuration), 1, accuracy: 1e-9,
                       "缓出窗口起点仍满档位（端点±1e-9：0.4 非精确二进制数，减法边界 1 ulp 抖动）")
        XCTAssertEqual(progress(at: 3.0 - AutoZoomState.releaseDuration / 2), 0.5, accuracy: 1e-9,
                       "缓出相位线性")
        XCTAssertEqual(progress(at: 3.0), 0, "出点回到原始画面（与实时时间线走完同构）")
        XCTAssertEqual(progress(at: 3.01), 0, "段外无缩放")

        // 短段（时长 < 缓入 + 缓出）：窗口各收敛到段长一半，恒不重叠
        let short = ZoomSegment(start: 0.0, end: 0.2, level: 1.6, center: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(OfflineZoomRenderer.zoomProgress(for: short, at: 0.05), 0.5, accuracy: 1e-9,
                       "短段缓入窗 = 段长一半")
        XCTAssertEqual(OfflineZoomRenderer.zoomProgress(for: short, at: 0.1), 1,
                       "短段中点恰满档位")
        XCTAssertEqual(OfflineZoomRenderer.zoomProgress(for: short, at: 0.15), 0.5, accuracy: 1e-9,
                       "短段缓出窗 = 段长一半")
    }

    // MARK: - 真实渲染小夹具（程序生成源 + 静音音轨）

    func testRenderSmallFixtureVideo() async throws {
        let sourceURL = directory.appendingPathComponent("缩放夹具源.mp4")
        try await makeFixtureVideo(at: sourceURL)

        let segments = [
            ZoomSegment(start: 0.5, end: 2.0, level: 1.9, center: CGPoint(x: 0.5, y: 0.5)),
        ]
        var progressValues: [Double] = []
        let outputURL = try await OfflineZoomRenderer.render(
            sourceURL: sourceURL,
            segments: segments,
            options: ExportVideoOptions(fps: nil, maxHeight: nil, codec: .h264),
            progress: { progressValues.append($0) },
            context: CIContext(options: [.useSoftwareRenderer: true]))

        // 命名与存在（T15 惯例：源同目录 <原名>_缩放.mp4）
        XCTAssertEqual(outputURL.lastPathComponent, "缩放夹具源_缩放.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path), "输出成片在盘")

        let output = AVURLAsset(url: outputURL)
        // 时长一致（音画时间线不动）
        let outputDuration = try await output.load(.duration).seconds
        XCTAssertEqual(outputDuration, 2.0, accuracy: 0.05, "输出时长与源一致")
        // 视频轨：尺寸沿用源（maxHeight nil 直通）
        let outputVideoTracks = try await output.loadTracks(withMediaType: .video)
        let outputVideo = try XCTUnwrap(outputVideoTracks.first, "输出应有视频轨")
        let outputSize = try await outputVideo.load(.naturalSize)
        XCTAssertEqual(outputSize, CGSize(width: 320, height: 180), "maxHeight nil → 源分辨率直通")
        let outputVideoDuration = try await outputVideo.load(.timeRange).duration.seconds
        XCTAssertEqual(outputVideoDuration, 2.0, accuracy: 0.05, "视频轨时长与源一致")
        // 音轨 passthrough：源静音 AAC 轨 → 输出音轨在、同为 AAC、时长一致
        let outputAudioTracks = try await output.loadTracks(withMediaType: .audio)
        let outputAudio = try XCTUnwrap(outputAudioTracks.first, "源静音音轨应直通到输出")
        let descriptions = try await outputAudio.load(.formatDescriptions)
        XCTAssertFalse(descriptions.isEmpty, "音轨格式描述在")
        for description in descriptions {
            XCTAssertEqual(CMFormatDescriptionGetMediaSubType(description),
                           FourCharCode(kAudioFormatMPEG4AAC), "输出音轨保持 AAC")
        }
        let outputAudioDuration = try await outputAudio.load(.timeRange).duration.seconds
        XCTAssertEqual(outputAudioDuration, 2.0, accuracy: 0.1, "音轨时间线不动")

        // 像素：恒等帧（t=3/30，段外）与 hold 帧（t=1.0，满档位）同一探针取色翻转。
        // 缩放 center (0.5, 0.5) 恒不触钳制：hold 档位 1.9 下视口 x=8px 映回底帧
        // x = 160 + (8−160)/1.9 = 80px（标记中心）；标记在恒等帧位于 x≈80px（frame 3
        // 标记中心 0.2624w）且恒等帧左侧 x=8px 为背景。
        let generator = AVAssetImageGenerator(asset: output)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let identity = try await generator.image(at: CMTime(value: 3, timescale: 30))
        let hold = try await generator.image(at: CMTime(value: 1, timescale: 1))
        try assertPixel(identity.image, x: 80, y: 90, near: marker, "恒等帧：标记在 0.25w 处")
        try assertPixel(identity.image, x: 160, y: 90, near: background, "恒等帧：中心是背景")
        try assertPixel(identity.image, x: 8, y: 90, near: background, "恒等帧：左缘是背景")
        try assertPixel(hold.image, x: 8, y: 90, near: marker, "hold 帧：0.25w 标记放大后达左缘探针")
        try assertPixel(hold.image, x: 160, y: 90, near: background, "hold 帧：中心仍为背景")
        try assertPixel(hold.image, x: 280, y: 90, near: background, "hold 帧：右缘是背景")

        // 进度契约（对齐 T15）：0…1、非空、首值 0、终值恰一次 1.0、严格递增
        XCTAssertFalse(progressValues.isEmpty, "进度回调非空")
        XCTAssertEqual(progressValues.first, 0, "首回调 0")
        XCTAssertEqual(progressValues.last, 1.0, "终值恰 1.0")
        XCTAssertTrue(progressValues.allSatisfy { $0 >= 0 && $0 <= 1 }, "全程 0…1")
        for (previous, current) in zip(progressValues, progressValues.dropFirst()) {
            XCTAssertLessThan(previous, current, "严格递增（去重后单调到顶）")
        }
    }

    // MARK: - R1 修复钉测（会话锚点 / 损坏源防线）

    func testRenderLateAudioHeadGapKeepsTimeline() async throws {
        // 音轨带头部空档的源（外部文件形态：音频首样本晚于视频首样本 0.5s，经
        // makeFixtureVideo(audioStartOffset:) 构造）。渲染器会话锚点取双轨首样本
        // 最小 PTS（R1 F1 修法）——本钉测锁该形态的时间线 passthrough 不变量：
        // 视频轨片头原位不压扁、音轨时间线与源逐项一致、容器时长为双轨并集。
        //
        // 平台实测注记（R1 F1 红测不可构造的根因，审阅已如实申报）：AVAssetWriter
        // 把音频头部空档结构化进容器（AAC 档转写为 elst 空编辑；LPCM-MOV 同形），
        // 但 AVAssetReader 音频解码对空编辑**从 0 起静音填充**——reader 层首音频
        // PTS 恒 = 0 = 视频首 PTS，「音频首样本晚于视频首样本」的 reader 级输入
        // 无法经 AVAssetWriter 或轨道合成构造（合成导出被拒 -11838）。锚点决策
        // 因此无 head 级红测（勿造重言），修法由装配期 min() + appends 兜底保证。
        let sourceURL = directory.appendingPathComponent("音晚源.mp4")
        try await makeFixtureVideo(at: sourceURL, audioStartOffset: 0.5)

        let sourceAsset = AVURLAsset(url: sourceURL)
        let sourceAudioTracks = try await sourceAsset.loadTracks(withMediaType: .audio)
        let sourceAudio = try XCTUnwrap(sourceAudioTracks.first, "夹具音轨在")
        let sourceAudioTimeRange = try await sourceAudio.load(.timeRange)

        let outputURL = try await OfflineZoomRenderer.render(
            sourceURL: sourceURL,
            segments: [],
            options: ExportVideoOptions(fps: nil, maxHeight: nil, codec: .h264),
            progress: { _ in },
            context: CIContext(options: [.useSoftwareRenderer: true]))

        let output = AVURLAsset(url: outputURL)
        let outputVideoTracks = try await output.loadTracks(withMediaType: .video)
        let outputVideo = try XCTUnwrap(outputVideoTracks.first, "输出应有视频轨")
        let videoTimeRange = try await outputVideo.load(.timeRange)
        XCTAssertEqual(videoTimeRange.start.seconds, 0, accuracy: 0.02,
                       "视频轨起点 = 视频首样本 PTS 0（片头原位，不被会话锚点钳走）")
        XCTAssertEqual(videoTimeRange.duration.seconds, 2.0, accuracy: 0.05,
                       "视频轨时长与源一致（片头不压扁）")
        let outputAudioTracks = try await output.loadTracks(withMediaType: .audio)
        let outputAudio = try XCTUnwrap(outputAudioTracks.first, "源音轨仍直通")
        let audioTimeRange = try await outputAudio.load(.timeRange)
        XCTAssertEqual(audioTimeRange.start.seconds, sourceAudioTimeRange.start.seconds,
                       accuracy: 0.02, "音轨起点与源一致")
        XCTAssertEqual(audioTimeRange.duration.seconds, sourceAudioTimeRange.duration.seconds,
                       accuracy: 0.1, "音轨时长与源一致（时间线不动）")
        let outputDuration = try await output.load(.duration).seconds
        let sourceDuration = try await sourceAsset.load(.duration).seconds
        XCTAssertEqual(outputDuration, sourceDuration, accuracy: 0.1,
                       "容器时长与源一致")
    }

    func testRenderCorruptSourceThrowsTypedErrorWithoutResidue() async throws {
        // 损坏源（视频轨在但解码配置 avcC 被腐蚀 → 零可解码帧）必须抛类型化错误且
        // 不留半截成片（R1 F3 防线：会话锚点装配后才 startWriting——双轨均无可解码
        // 样本时在 startWriting 前抛 `.noRenderableSamples`，「未 startWriting 就
        // finishWriting」的 ObjC 异常路径结构性不可达）。本钉测锁可观察契约：
        // 错误类型为 RenderError + 目标路径无残壳。
        let sourceURL = directory.appendingPathComponent("损坏源.mp4")
        try await makeFixtureVideo(at: sourceURL)
        var data = try Data(contentsOf: sourceURL)
        let range = try XCTUnwrap(data.range(of: Data("avcC".utf8)), "夹具缺 avcC（H.264 配置）")
        let start = range.upperBound + 4 // avcC 头 + SPS 长度字段 → 直达 SPS 载荷
        let corruption: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0xDE, 0xAD, 0xBE, 0xEF]
        for (index, byte) in corruption.enumerated() {
            data[start + index] = byte
        }
        try data.write(to: sourceURL)

        let expectedOutput = directory.appendingPathComponent("损坏源_缩放.mp4")
        try? FileManager.default.removeItem(at: expectedOutput)

        do {
            _ = try await OfflineZoomRenderer.render(
                sourceURL: sourceURL,
                segments: [],
                options: ExportVideoOptions(fps: nil, maxHeight: nil, codec: .h264),
                progress: { _ in },
                context: CIContext(options: [.useSoftwareRenderer: true]))
            XCTFail("损坏源必须抛类型化错误")
        } catch let error as OfflineZoomRenderer.RenderError {
            XCTAssertFalse(error.localizedDescription.isEmpty,
                           "类型化错误带可呈现文案：\(error.localizedDescription)")
        } catch {
            XCTFail("必须抛 RenderError 类型，实得：\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedOutput.path),
                       "失败路径不留半截成片")
    }

    // MARK: - Codable（持久化面）与输出命名

    func testSegmentCodableRoundtrip() throws {
        let segments = [
            ZoomSegment(start: 0.5, end: 2.0, level: 1.6, center: CGPoint(x: 0.25, y: 0.75)),
            ZoomSegment(start: 3.0, end: 4.5, level: 1.9, center: CGPoint(x: 1.0, y: 0.0)),
        ]
        let data = try JSONEncoder().encode(segments)
        let decoded = try JSONDecoder().decode([ZoomSegment].self, from: data)
        XCTAssertEqual(decoded, segments, "JSON 往返保真（P9 分析产物落库口径）")
    }

    func testZoomedDestinationNaming() throws {
        let source = directory.appendingPathComponent("录屏_2026-10-30_10-00-00.mp4")
        try Data("x".utf8).write(to: source)
        XCTAssertEqual(
            OfflineZoomRenderer.zoomedDestinationURL(for: source).lastPathComponent,
            "录屏_2026-10-30_10-00-00_缩放.mp4", "无冲突 → `<原名>_缩放.mp4`")

        try Data().write(to: directory.appendingPathComponent("录屏_2026-10-30_10-00-00_缩放.mp4"))
        XCTAssertEqual(
            OfflineZoomRenderer.zoomedDestinationURL(for: source).lastPathComponent,
            "录屏_2026-10-30_10-00-00_缩放 (2).mp4", "同名冲突 → 追加 (2)（nextFileURL 同款惯例）")
    }

    // MARK: - 夹具装配（测试基础设施，失败即测试失败）

    /// 程序生成 2s@30fps 320×180 源：近黑背景 + 亮红运动标记（x 向 sin 摆动，帧间可辨）
    /// + 静音 AAC 立体声音轨（44.1kHz）。标记为垂直居中厚条（探针中高免翻转口径），
    /// 水平中心 x = (0.25 + 0.04·sin(2π·帧/60))w——frame 3 ≈ 0.2624w、frame 30 恰 0.25w。
    /// - Parameters:
    ///   - audioStartOffset: 音轨首样本 PTS 偏移（默认 0 = 音画同起；≠ 0 时音轨相对
    ///     视频后移 0.5s 量级的外部文件形态）。平台注记：AVAssetWriter 会把该头部
    ///     空档结构化进容器（AAC 档转写为 elst 空编辑——结构在容器里，解码层从 0
    ///     静音填充），音轨 timeRange 仍自容器起点起算（空档含在内）。
    private func makeFixtureVideo(at url: URL, audioStartOffset: TimeInterval = 0) async throws {
        let width = 320
        let height = 180
        let fps = 30
        // 60 帧 = 20 音频段 × 3 帧（3 帧 @30fps = 0.1s = 每段 4410 帧 @44.1kHz）

        let writer = try AVAssetWriter(url: url, fileType: .mp4)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        // realtime 档（AssetWriterSession 同款）：非实时档 + 双轨全量先写一路会被
        // 跨轨配速饿死（isReadyForMoreMediaData 永不复位——本任务实测）；无丢帧由
        // 「同一像素缓冲追加未受理即小睡重试」保证，不靠 isReady 预判。
        videoInput.expectsMediaDataInRealTime = true
        XCTAssertTrue(writer.canAdd(videoInput), "夹具视频输入装配失败")
        writer.add(videoInput)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])

        // 音频输入（AAC）：静音 PCM 直写由 writer 编码
        let sampleRate = 44100.0
        let audioFormat = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
            "夹具音频格式创建失败")
        var asbd = audioFormat.streamDescription.pointee
        var descriptionOut: CMFormatDescription?
        XCTAssertEqual(
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                magicCookieSize: 0, magicCookie: nil, extensions: nil,
                formatDescriptionOut: &descriptionOut),
            noErr, "夹具音频格式描述创建失败")
        let audioDescription = try XCTUnwrap(descriptionOut, "夹具音频格式描述不可用")
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ])
        audioInput.expectsMediaDataInRealTime = true
        XCTAssertTrue(writer.canAdd(audioInput), "夹具音频输入装配失败")
        writer.add(audioInput)

        XCTAssertTrue(writer.startWriting(), "夹具 writer 启动失败")
        // 夹具默认音画起点均为 0：会话时间轴直接锚 0（AssetWriterSession 首样本锚定同款
        // 纪律——macOS 27 上不 startSession 追加像素缓冲直接抛 NSInternalInconsistencyException）
        writer.startSession(atSourceTime: .zero)

        // isReady 轮询到受理再追加（无丢帧）；20s 仍不受理（= 饿死）按夹具故障失败，
        // 不挂死测试。realtime 档下 isReady 仅取决于本轨编码队列，跨轨不配速。
        struct FixtureWriteFailure: Error {}
        func waitForReady(_ input: AVAssetWriterInput, what: String) throws {
            var waited = 0
            while !input.isReadyForMoreMediaData {
                guard writer.status != .failed, waited < 10_000 else {
                    XCTFail("\(what) 长期未受理（status=\(writer.status.rawValue)）：\(String(describing: writer.error))")
                    throw FixtureWriteFailure()
                }
                waited += 1
                Thread.sleep(forTimeInterval: 0.002)
            }
        }

        // 视频帧与静音段按时间线交错写（3 帧 @30fps = 0.1s = 4410 帧 @44.1kHz）。
        let framesPerChunk = 4410
        for chunk in 0..<20 {
            for frame in (chunk * 3)..<(chunk * 3 + 3) {
                let buffer = try XCTUnwrap(makePixelBuffer(width: width, height: height),
                                           "夹具像素缓冲创建失败")
                try drawFixtureFrame(index: frame, into: buffer, width: CGFloat(width), height: CGFloat(height))
                let pts = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
                try waitForReady(videoInput, what: "夹具帧 \(frame)")
                XCTAssertTrue(
                    adaptor.append(buffer, withPresentationTime: pts),
                    "夹具帧 \(frame) 写入失败：\(String(describing: writer.error))")
            }
            let pcm = try XCTUnwrap(
                AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(framesPerChunk)),
                "夹具 PCM 缓冲创建失败")
            pcm.frameLength = AVAudioFrameCount(framesPerChunk)
            for index in 0..<framesPerChunk {
                pcm.floatChannelData![0][index] = 0
                pcm.floatChannelData![1][index] = 0
            }
            let pts = CMTime(value: CMTimeValue(audioStartOffset * sampleRate) + CMTimeValue(chunk * framesPerChunk),
                             timescale: CMTimeScale(sampleRate))
            let sample = try XCTUnwrap(
                AudioSampleBridge.makeSampleBuffer(
                    pcm: pcm, skipFrames: 0, pts: pts, formatDescription: audioDescription),
                "夹具音频样本打包失败")
            try waitForReady(audioInput, what: "夹具音段 \(chunk)")
            XCTAssertTrue(audioInput.append(sample),
                          "夹具音段 \(chunk) 写入失败：\(String(describing: writer.error))")
        }
        videoInput.markAsFinished()
        audioInput.markAsFinished()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            XCTFail("夹具成片失败（status=\(writer.status.rawValue)）：\(String(describing: writer.error))")
            return
        }
    }

    private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        // XCTUnwrap 的失败即测试失败（夹具故障不得表现为 skipped）
        return try XCTUnwrap(status == kCVReturnSuccess ? buffer : nil,
                             "夹具像素缓冲创建失败（status=\(status)）")
    }

    /// 单帧绘制：背景铺满 + 标记矩形（几何口径见 makeFixtureVideo 注释）。
    /// BGRA 缓冲配 little-endian premultipliedFirst 位图（与 PiPCompositorTests 取色口径同族）。
    private func drawFixtureFrame(index: Int, into buffer: CVPixelBuffer,
                                  width: CGFloat, height: CGFloat) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = try XCTUnwrap(
            CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: CVPixelBufferGetWidth(buffer),
                height: CVPixelBufferGetHeight(buffer),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue),
            "夹具 CGContext 创建失败")
        context.setFillColor(CGColor(red: background.0, green: background.1, blue: background.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let phase = Double(index) / 60.0 * 2 * Double.pi
        let markerCenterX = (0.25 + 0.04 * sin(phase)) * width
        context.setFillColor(CGColor(red: marker.0, green: marker.1, blue: marker.2, alpha: 1))
        context.fill(CGRect(x: markerCenterX - 0.03 * width, y: 0.35 * height,
                            width: 0.06 * width, height: 0.30 * height))
    }

    // MARK: - 像素探针

    /// 读取画面 (x, y) 处像素（y 以内存行计——探针恒取中高行，竖直翻转口径下取值不变）。
    private func pixelComponents(of image: CGImage, x: Int, y: Int) throws -> (Double, Double, Double) {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            "探针 CGContext 创建失败")
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try XCTUnwrap(context.data, "探针位图数据不可用")
        let row = data.assumingMemoryBound(to: UInt8.self).advanced(by: y * context.bytesPerRow)
        let pixel = row.advanced(by: x * 4)
        return (Double(pixel[0]) / 255.0, Double(pixel[1]) / 255.0, Double(pixel[2]) / 255.0)
    }

    private func assertPixel(_ image: CGImage, x: Int, y: Int, near expected: (Double, Double, Double),
                             _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let actual = try pixelComponents(of: image, x: x, y: y)
        XCTAssertLessThanOrEqual(abs(actual.0 - expected.0), colorTolerance, "\(message)：红通道", file: file, line: line)
        XCTAssertLessThanOrEqual(abs(actual.1 - expected.1), colorTolerance, "\(message)：绿通道", file: file, line: line)
        XCTAssertLessThanOrEqual(abs(actual.2 - expected.2), colorTolerance, "\(message)：蓝通道", file: file, line: line)
    }
}
