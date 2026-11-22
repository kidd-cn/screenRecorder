import AVFoundation
import AVKit
import SwiftUI

// MARK: - 纯逻辑缝（无头钉测面：ZoomEditorLogicTests 消费）

/// 编辑器纯逻辑（P9/T18）：分段修改统一闸、拖端点邻居钳制、九宫格映射、预估大小。
/// 不持有任何 UI/IO 状态——SwiftUI 模型（ZoomEditorModel）与测试共用同一执行点。
enum ZoomEditorLogic {
    /// 新增段最短时长（秒）：拖端点/新增的 UI 级下限（validate 硬约束是 `start < end`，
    /// 此下限只为交互可用性——过短段不可拖拽操作）。
    static let minimumSegmentDuration: TimeInterval = 0.1

    /// 分段修改统一闸（T18 钉测 testSegmentEditGoesThroughValidate）：编辑器的**所有**
    /// 修改路径（增/调档/九宫格/拖端点/删）经此处 → `ZoomSegment.validate`（排序/钳制/
    /// 去重叠保留先者）后才允许落库/存草稿/进渲染——「先 validate 再存/再用」的单一
    /// 执行点（缩放渲染编排边界另有一道幂等闸）。
    static func applyEdit(_ current: [ZoomSegment],
                          edit: (inout [ZoomSegment]) -> Void) -> [ZoomSegment] {
        var next = current
        edit(&next)
        return ZoomSegment.validate(next)
    }

    /// 默认新增段跨度（半 span）：引用 `AutoZoomState.holdDuration`（保持时长 1.0s）
    /// 作交互缺省——不另造魔法数（编辑器 UX 缺省与实时缩放的保持段同尺度）。
    static func defaultSegmentSpan(around time: TimeInterval,
                                   sourceDuration: TimeInterval) -> (start: TimeInterval, end: TimeInterval) {
        var start = max(0, time - AutoZoomState.holdDuration)
        var end = time + AutoZoomState.holdDuration
        if sourceDuration.isFinite, sourceDuration > 0 {
            end = min(end, sourceDuration)
            start = min(start, max(0, end - minimumSegmentDuration))
        }
        return (start, end)
    }

    /// 拖端点提案钳制（UI 交互层；validate 是硬闸，本函数保证编辑段在去重叠后存活）：
    /// 入点 ≥ max(0, 前段 end)、出点 ≤ 后段 start（半开相邻合法——`validate` 首尾相接
    /// 不算重叠），再收敛最短段长；邻居间隙不足最短段长时占满间隙（间隙 ≤ 0 的退化
    /// 段由 validate 丢弃）。`validate` 去重叠保留先者——跨界拖拽若不钳会被当重叠丢弃
    ///（交互语义是钳制不是静默删除）。
    static func clampedDrag(proposedStart: TimeInterval, proposedEnd: TimeInterval,
                            previousEnd: TimeInterval?,
                            nextStart: TimeInterval?) -> (start: TimeInterval, end: TimeInterval) {
        let lower = max(0, previousEnd ?? 0)
        let upper = nextStart ?? .infinity
        var start = min(max(proposedStart, lower), upper)
        var end = min(max(proposedEnd, start), upper)
        if end - start < minimumSegmentDuration {
            if upper - lower >= minimumSegmentDuration {
                end = min(max(end, start + minimumSegmentDuration), upper)
                start = end - minimumSegmentDuration // 上限约束优先：出点贴界、入点回压
            } else {
                start = lower
                end = upper
            }
        }
        return (start, end)
    }

    /// 九宫格 → 归一化缩放中心。`row` 0 = **视觉顶行**；`column` 0 = 左列。`ZoomSegment.center`
    /// 为 CI 画布 y 向上口径（实时点击喂入同一翻转：y = 1 − 屏幕比例，y = 1 是画面顶，
    /// `CaptureController.feedZoomClick` 同款）——视觉顶行映射 y = 5/6，底行 y = 1/6。
    static func ninePatchCenter(row: Int, column: Int) -> CGPoint {
        let clampedRow = min(max(row, 0), 2)
        let clampedColumn = min(max(column, 0), 2)
        return CGPoint(
            x: (2 * CGFloat(clampedColumn) + 1) / 6,
            y: (2 * CGFloat(2 - clampedRow) + 1) / 6)
    }

    /// `ninePatchCenter` 逆映射（九宫格当前格高亮）：取 center 所属格（越界钳到角格）。
    static func ninePatchCell(for center: CGPoint) -> (row: Int, column: Int) {
        let column = min(2, max(0, Int((center.x * 3).rounded(.down))))
        let row = min(2, max(0, Int(((1 - center.y) * 3).rounded(.down))))
        return (row, column)
    }

    /// 预估导出大小（字节，近似值——UI 标注「预估」）：源码率 × 有效时长 × 编码系数。
    /// - 源码率 = sizeBytes / sourceDuration（brief 公式字面形态：size ÷ 源时长）；
    /// - 有效时长 = 源时长——缩放分段**不改时间线**（OfflineZoomRenderer 类注释
    ///   「音画时间线不动」：分段只改画面、输出时长与源逐帧一致，Task 17 真实渲染
    ///   夹具钉测时长一致），故无「分段裁剪后时长」可扣；
    /// - 编码系数：h264 = 1.0（同族重编码、同分辨率帧率，均值码率近似持平的基准档）；
    ///   hevc = 0.65（等观感质量下 HEVC 较 H.264 省 30–40% 码率的行业经验中值）。
    ///   fps/maxHeight 档的降尺寸效应不入模（预估面无源分辨率探针；输出恒标注「预估」）。
    /// 退化输入（size ≤ 0 / 时长非正或非有限）→ 0（UI 显示 —）。
    static func estimatedExportBytes(sourceSizeBytes: Int64,
                                     sourceDuration: TimeInterval,
                                     codec: VideoCodec) -> Int64 {
        guard sourceSizeBytes > 0, sourceDuration.isFinite, sourceDuration > 0 else { return 0 }
        let sourceBitrate = Double(sourceSizeBytes) / sourceDuration
        let codecFactor: Double = codec == .hevc ? 0.65 : 1.0
        return Int64((sourceBitrate * sourceDuration * codecFactor).rounded())
    }
}

// MARK: - 编辑器模型（时间线窗状态真源）

/// 时间线窗状态（P9/T18）：源片 AVPlayer 预览 + 播放头 + 分段表（全部修改经
/// `ZoomEditorLogic.applyEdit` 统一闸后落库并即时存草稿）+ 导出参数档位。
/// 播放器/时长探针只在主 actor 触达；草稿持久化经列表模型（`loadDraft`/`saveDraft`，
/// 两侧各过一道 validate）。
@MainActor
final class ZoomEditorModel: ObservableObject {
    /// 编辑的成片（预估大小取其 sizeBytes；播放/草稿/导出均挂其 URL）。
    let item: RecordingFileMetadata
    /// 源片播放器（AVPlayer 预览真源——播放头在**成品时间轴**，periodic 观察器每拍
    /// 校正：成品时间 → 源时间映射，播放器实际位置偏离映射源时间 > 0.15s 即校正——
    /// clip 接缝处的源跳变由此实现，时间线无空洞、播放天然连续）。
    let player: AVPlayer
    private let listViewModel: RecordingListViewModel
    private var timeObserver: Any?

    /// 分段表（已过 validate：有序、档位/中心合法、无重叠）——唯一写入口是 `applyEdit`。
    @Published private(set) var segments: [ZoomSegment] = []
    /// 片段流（剪辑 v2 剪映同构：时间线即成品轨，波纹删除/接缝/变速作用于此）——
    /// 唯一写入口是 `applyClipEdit` 统一闸。
    @Published private(set) var clips: [EditClip] = []
    /// 原声音量（0…1；批次 4b 音轨）。
    @Published var sourceVolume: Double = 1
    /// 配乐轨（nil = 未导入）。
    @Published var backgroundMusic: EditMusicTrack?
    /// 音量关键帧（成品时间轴；空 = 自动首尾淡入淡出；批次 4c-2）。
    @Published private(set) var keyframes: [EditKeyframe] = []
    /// 接缝转场（键 = 接缝下标；批次 4c-2）。
    @Published private(set) var transitions: [Int: EditTransition] = [:]
    /// 画面变换（缩放/位置/旋转/圆角；剪映 02.png 画面面板）。
    @Published private(set) var transform: EditTransform = .identity
    /// 画面调整（亮度/对比度/饱和度；剪映 02.png 调整面板）。
    @Published private(set) var adjust: EditAdjust = .identity
    /// 视频自然尺寸（比例显示/预览变换基准；loadMediaInfo 补齐）。
    @Published private(set) var videoSize: CGSize = .zero
    /// 选中的 clip 下标（⌘+点击选中 → 速度面板；validate 重排后按值回找）。
    @Published var selectedClipIndex: Int?
    /// 选中段下标（行点击/时间线点击选中；validate 重排后按编辑后段值回找）。
    @Published var selectedIndex: Int?
    /// 播放头（**成品时间轴**秒；periodic 观察器 0.25s 步进；播放中按映射校正源位置）。
    @Published private(set) var playhead: TimeInterval = 0
    @Published private(set) var isPlaying = false
    /// 源时长（`.task` 异步补齐；0 = 未就绪——时间线比例尺/预估大小就绪前显示占位）。
    @Published private(set) var sourceDuration: TimeInterval = 0
    /// 拖端点期间的实时预览（未落库；`onEnded` 才经统一闸 commit——拖拽中不逐 tick 写盘）。
    @Published var dragPreview: DragPreview?
    /// 波纹删除拖选预览（成品时间区间；画布绘制红罩，松手提交 cutOutputRange）。
    @Published var ripplePreview: (TimeInterval, TimeInterval)?

    // MARK: 时间线缩放/平移（2026-11-21 剪映专业版对齐·批次 1；视图态寄模型——画布经
    // objectWillChange 订阅重绘，SwiftUI 控件直绑）

    /// 缩放倍率（1 = 全程适配；上限 200 —— 48s 片 @200 → 1 帧 ≈ 46pt，帧级精剪）。
    @Published var timelineZoom: Double = 1 {
        didSet { clampTimelineOffset() }
    }
    /// 左缘时间（秒，钳制随 zoom）。
    @Published var timelineOffset: TimeInterval = 0

    /// 时间线可视时长（**成品轴**——剪掉素材后时间线 = 成片时长；未就绪回退源时长）。
    /// 比例尺/平移钳制必须用它：曾误用源时长致放大后可滚出内容尽头（2026-11-22 用户反馈）。
    var timelineDuration: TimeInterval { outputDuration > 0 ? outputDuration : sourceDuration }

    /// 平移钳制（zoom/时长/内容变化后统一调用）。
    func clampTimelineOffset() {
        timelineOffset = ZoomTimelineGeometry.clampedOffset(
            timelineOffset, sourceDuration: timelineDuration, zoom: timelineZoom)
    }

    // MARK: 音频波形（剪映对齐·批次 2：看波形找停顿点下刀）

    /// 波形桶（0.02s/桶采样真源在 OfflineZoomRenderer.sampleWaveform；空 = 无音轨/解码失败）。
    @Published private(set) var waveform: [OfflineZoomRenderer.WaveformBucket] = []
    /// 波形进程级缓存（同片重开编辑器零解码；主线程读写——loadWaveform hop 回主线程入库）。
    nonisolated(unsafe) private static var waveformCache: [URL: [OfflineZoomRenderer.WaveformBucket]] = [:]
    /// 波形加载去重（同实例重复 .task 防御）。
    private var waveformLoaded = false

    // MARK: 轨道缩略图（剪映对齐·批次 3：filmstrip 随缩放重排）

    /// 抽帧产物（槽位网格锚定源时间；nil = 生成中/无视频轨）。
    @Published private(set) var filmstrip: OfflineZoomRenderer.Filmstrip?
    /// 进程级缓存（同波形）。
    nonisolated(unsafe) private static var filmstripCache: [URL: OfflineZoomRenderer.Filmstrip] = [:]
    private var filmstripLoaded = false

    /// 后台抽帧（时长就绪后调用；进程缓存命中即用）。
    func loadFilmstrip() {
        guard !filmstripLoaded else { return }
        filmstripLoaded = true
        let url = item.url
        if let cached = Self.filmstripCache[url] {
            filmstrip = cached
            return
        }
        let interval = OfflineZoomRenderer.filmstripInterval(forDuration: sourceDuration)
        let maxSize = CGSize(width: 128, height: 72) // 显示 64×36 槽位的 2x 余量
        Task.detached(priority: .utility) { [weak self] in
            let strip = await OfflineZoomRenderer.sampleFilmstrip(
                sourceURL: url, interval: interval, maxSize: maxSize)
            await MainActor.run {
                if let strip {
                    Self.filmstripCache[url] = strip
                    self?.filmstrip = strip
                }
            }
        }
    }

    /// 后台加载波形（解码不占主线程；完成回主线程入库+发布；进程缓存命中即用）。
    func loadWaveform() {
        guard !waveformLoaded else { return }
        waveformLoaded = true
        let url = item.url
        if let cached = Self.waveformCache[url] {
            waveform = cached
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            let buckets = await OfflineZoomRenderer.sampleWaveform(sourceURL: url)
            await MainActor.run {
                Self.waveformCache[url] = buckets
                self?.waveform = buckets
            }
        }
    }

    struct DragPreview {
        let index: Int
        let start: TimeInterval
        let end: TimeInterval
    }

    // 导出参数档位（Picker 直绑档位集合，UI 不另造档——GIF/压缩小窗同纪律）
    @Published var fpsChoice: FPSChoice = .source
    @Published var heightChoice: HeightChoice = .source
    @Published var codec: VideoCodec = .hevc

    /// 帧率档位：`ExportVideoOptions.fps` 集合 {nil(沿用源), 24, 30, 60} 的 Pickable 映射。
    enum FPSChoice: Hashable {
        case source, fps24, fps30, fps60

        var fps: Int? {
            switch self {
            case .source: return nil
            case .fps24: return 24
            case .fps30: return 30
            case .fps60: return 60
            }
        }
    }

    /// 分辨率档位：`ExportVideoOptions.maxHeight` 集合 {nil(源), 1080, 720} 的 Pickable
    /// 映射（渲染侧只降不升——CompressionSheet 同档位族）。
    enum HeightChoice: Hashable {
        case source, h1080, h720

        var maxHeight: Int? {
            switch self {
            case .source: return nil
            case .h1080: return 1080
            case .h720: return 720
            }
        }
    }

    init(item: RecordingFileMetadata, listViewModel: RecordingListViewModel) {
        self.item = item
        self.listViewModel = listViewModel
        self.player = AVPlayer(url: item.url)
        let document = listViewModel.loadDraft(for: item, sourceDuration: 0) // 时长就绪后补初始 clip
        segments = document.zoomSegments
        clips = document.clips
        mountTimeObserver()
    }

    /// 源时长补齐（视图 `.task` 调用）：时间线比例尺 + 预估大小 + 新增段贴界的数据面。
    /// 片段流（v2）：空文档（含 v1 草稿迁移场景——迁移需要时长）在时长就绪后重读草稿
    /// 或置单 clip 全程。
    func loadMediaInfo() async {
        let asset = AVURLAsset(url: item.url)
        let seconds = try? await asset.load(.duration).seconds
        guard let seconds, seconds.isFinite, seconds > 0 else { return }
        sourceDuration = seconds
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize) {
            videoSize = size
        }
        if clips.isEmpty {
            let document = listViewModel.loadDraft(for: item, sourceDuration: seconds)
            if document.clips.isEmpty {
                clips = EditDocument.initial(duration: seconds).clips
            } else {
                clips = document.clips
                segments = document.zoomSegments
            }
            sourceVolume = document.sourceVolume
            backgroundMusic = document.backgroundMusic
            keyframes = document.keyframes
            transitions = document.transitions
            transform = document.transform
            adjust = document.adjust
            clampTimelineOffset()
            saveDocument()
        }
    }

    /// 关窗清理（窗口 opener 的 willClose 通知调用）：停播 + 摘除 periodic/边界观察器
    ///（草稿已随每次编辑即时落盘，关窗无额外持久化动作）。
    func prepareForClose() {
        player.pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    /// 选中下标钳制（clips/segments 数量变化——波纹删除/validate 丢弃——后，过期下标
    /// 会让 SwiftUI Binding 差分评估越界崩溃，2026-11-22 崩溃报告实锤：右键触发更新时
    /// selectedClipSection 的 Binding get 用旧下标访问已缩短的数组）。
    private func clampSelections() {
        if let selected = selectedClipIndex, !clips.indices.contains(selected) {
            selectedClipIndex = nil
        }
        if let selected = selectedIndex, !segments.indices.contains(selected) {
            selectedIndex = nil
        }
    }

    // MARK: 播放控制

    func togglePlay() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            settlePlayhead() // 起播落位：播放头落在剪除段内则先跳到段尾
            player.play()
            isPlaying = true
        }
    }

    func seek(to outputTime: TimeInterval) {
        let clamped = outputDuration > 0 ? min(max(0, outputTime), outputDuration) : max(0, outputTime)
        // 成品时间 → 源时间 seek（预览「所见即导出所得」——时间线即成品轨）。
        if let source = clipsDocument.sourceTime(forOutputTime: clamped) {
            player.seek(to: CMTime(seconds: source, preferredTimescale: 600))
        }
        playhead = clamped
    }

    /// 原始跳转（片段流下与 seek 同义——时间线无空洞；保留名号供画布拖拽扫查）。
    func scrub(to outputTime: TimeInterval) {
        seek(to: outputTime)
    }

    /// 播放头落位（片段流下恒等钳制；保留名号供拖拽提交）。
    func settlePlayhead() {
        seek(to: playhead)
    }

    /// 当前 clips 的文档面（映射/编辑操作真源；画布接缝换算只读访问）。
    var clipsDocument: EditDocument {
        // ⚠️ 新增文档字段必须在此携带——applyClipEdit/applyEdit 从本面读改写回，
        // 漏带 = 该字段的所有编辑互相抹除（transitions 曾犯，keyframes 同前科）
        EditDocument(clips: clips, zoomSegments: segments,
                     sourceVolume: sourceVolume, backgroundMusic: backgroundMusic,
                     keyframes: keyframes, transitions: transitions,
                     transform: transform, adjust: adjust)
    }

    // MARK: 分段编辑（唯一写入口：全部经 ZoomEditorLogic.applyEdit 统一闸）

    /// 在播放头处新增段（±hold 窗、默认档位 1.6、中心画面正中）；新增段即选中；
    /// 与既有段重叠被 validate 丢弃时保持原选中（段表不变）。
    func addSegment(at time: TimeInterval) {
        let span = ZoomEditorLogic.defaultSegmentSpan(around: time, sourceDuration: sourceDuration)
        let segment = ZoomSegment(
            start: span.start, end: span.end,
            level: ZoomSegment.levels[1], center: CGPoint(x: 0.5, y: 0.5))
        applyEdit { $0.append(segment) }
        if let index = segments.firstIndex(of: segment) {
            selectedIndex = index
        }
    }

    /// 调档位（野档位由 validate 就近钳合法档）。
    func setLevel(at index: Int, level: Double) {
        updateSegment(at: index) { $0.level = level }
    }

    /// 九宫格设中心（视觉顶行 row 0；映射与钳制在 ZoomEditorLogic/validate）。
    func setCenter(atIndex index: Int, ninePatchRow row: Int, column: Int) {
        updateSegment(at: index) {
            $0.center = ZoomEditorLogic.ninePatchCenter(row: row, column: column)
        }
    }

    /// 拖端点提交：先钳邻居边界（保先者语义下跨界拖拽不得被丢——交互语义是钳制），
    /// 再走统一闸落库。`start`/`end` 为拖拽预览的原始提案。
    func commitDrag(index: Int, start: TimeInterval, end: TimeInterval) {
        guard segments.indices.contains(index) else { return }
        let clamped = ZoomEditorLogic.clampedDrag(
            proposedStart: start, proposedEnd: end,
            previousEnd: index > 0 ? segments[index - 1].end : nil,
            nextStart: index + 1 < segments.count ? segments[index + 1].start : nil)
        updateSegment(at: index) { $0.start = clamped.start; $0.end = clamped.end }
    }

    func removeSegment(at index: Int) {
        guard segments.indices.contains(index) else { return }
        applyEdit { $0.remove(at: index) }
        selectedIndex = nil
    }

    // MARK: 片段流编辑（剪辑 v2 剪映同构；唯一写入口：applyClipEdit 统一闸）

    /// 波纹删除（成品时间轴 [lower, upper)）：跨接处 clip 拆/缩/消，其余接合。
    func cutOutputRange(lower: TimeInterval, upper: TimeInterval) {
        applyClipEdit { $0 = $0.removingOutputRange(lower: lower, upper: upper) }
    }

    /// 接缝移动（seamIndex ∈ 0...clips.count；toSourceTime 为目标源时间）。
    func moveSeam(at seamIndex: Int, toSourceTime source: TimeInterval) {
        applyClipEdit { $0 = $0.movingSeam(at: seamIndex, toSourceTime: source) ?? $0 }
    }

    /// 选中 clip 调速（野速度由 validate 钳合法区间）。
    func setClipSpeed(at index: Int, speed: Double) {
        updateClip(at: index) { $0.speed = speed }
    }

    // MARK: 音轨（批次 4b：原声音量 + 配乐）

    func setSourceVolume(_ volume: Double) {
        sourceVolume = min(max(volume, 0), 1)
        saveDocument()
    }

    /// 导入配乐（NSOpenPanel；沙盒 security-scoped bookmark 锚定）。
    func importMusic() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if #available(macOS 14.0, *) {
            panel.allowedContentTypes = [.audio]
        } else {
            panel.allowedFileTypes = ["m4a", "mp3", "wav", "aac", "flac"]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? url.bookmarkData() else {
            NSLog("Editor: 配乐书签创建失败（%@）", url.path)
            return
        }
        applyClipEdit { $0.backgroundMusic = EditMusicTrack(
            bookmark: bookmark, name: url.lastPathComponent, volume: 0.5) }
    }

    func removeMusic() {
        applyClipEdit { $0.backgroundMusic = nil }
    }

    func setMusicVolume(_ volume: Double) {
        applyClipEdit { $0.backgroundMusic?.volume = min(max(volume, 0), 1) }
    }

    // MARK: 音量关键帧（批次 4c-2：成品时间轴锚定，双击音频道添加）

    func addKeyframe(at outputTime: TimeInterval, volume: Double) {
        applyClipEdit { $0.keyframes = EditKeyframe.validate(
            $0.keyframes + [EditKeyframe(outputTime: outputTime, volume: min(max(volume, 0), 1))]) }
    }

    /// 拖动关键帧（按**拖动起始时间**寻址——validate 重排后下标漂移）。
    /// 拖动关键帧（按**拖动起始时间**寻址——validate 重排后下标漂移；时间/音量越邻帧
    /// 界由 validate 排序/去重收口）。
    func moveKeyframe(fromOriginalTime original: TimeInterval, to outputTime: TimeInterval, volume: Double) {
        applyClipEdit { document in
            guard let index = document.keyframes.firstIndex(
                where: { abs($0.outputTime - original) < 1e-6 }) else { return }
            var keyframe = document.keyframes[index]
            keyframe.outputTime = max(0, outputTime)
            keyframe.volume = min(max(volume, 0), 1)
            document.keyframes[index] = keyframe
            document.keyframes = EditKeyframe.validate(document.keyframes)
        }
    }

    func removeKeyframe(at index: Int) {
        guard keyframes.indices.contains(index) else { return }
        applyClipEdit { $0.keyframes.remove(at: index) }
    }

    // MARK: 接缝转场（批次 4c-2：右键接缝添加/删除）

    func addTransition(at seam: Int, kind: EditTransition.Kind) {
        applyClipEdit { $0.transitions[seam] = EditTransition(kind: kind) }
    }

    /// 播放头最近的**内部**接缝下标（seam ∈ 1..<clips.count；片尾缝无转场键不参与；
    /// 无内部接缝 → nil）。
    func nearestSeam(toOutputTime t: TimeInterval) -> Int? {
        guard clips.count >= 2 else { return nil }
        let boundaries = Array(clipsDocument.seamBoundaries(of: clips).dropLast())
        var best: (seam: Int, distance: TimeInterval)?
        for (index, boundary) in boundaries.enumerated() {
            let distance = abs(boundary - t)
            if best == nil || distance < best!.distance {
                best = (index + 1, distance)
            }
        }
        return best?.seam
    }

    /// 循环切换播放头最近接缝的转场（无 → 黑场 → 溶解 → 无）；返回切换后的种类
    ///（nil = 该缝已无转场）。键盘 ⇧⌘T 与播放行按钮共用。
    @discardableResult
    func cycleTransitionNearPlayhead() -> EditTransition.Kind? {
        guard let seam = nearestSeam(toOutputTime: playhead) else { return nil }
        let current = transitions[seam]?.kind
        let next: EditTransition.Kind? = {
            switch current {
            case nil: return .black
            case .black: return .crossfade
            case .crossfade: return nil
            }
        }()
        if let next {
            addTransition(at: seam, kind: next)
        } else {
            removeTransition(at: seam)
        }
        return next
    }

    /// 播放头最近接缝的转场显示名（无 clip → nil；无转场 → 「无」）。
    var transitionLabelAtPlayhead: String? {
        guard let seam = nearestSeam(toOutputTime: playhead) else { return nil }
        switch transitions[seam]?.kind {
        case .black: return NSLocalizedString("黑场", comment: "Transition kind")
        case .crossfade: return NSLocalizedString("溶解", comment: "Transition kind")
        case nil: return NSLocalizedString("无", comment: "No transition")
        }
    }

    func removeTransition(at seam: Int) {
        applyClipEdit { $0.transitions[seam] = nil }
    }

    /// 改转场时长（EditTransition init 内钳 0.2…2s）。
    func setTransitionDuration(at seam: Int, duration: TimeInterval) {
        applyClipEdit { $0.transitions[seam]?.duration = duration }
    }

    // MARK: 画面变换（剪映 02.png 右侧「画面」面板）

    /// 应用画面变换（滑杆实时；经统一闸 → 撤销栈/草稿）。
    func setTransform(_ newTransform: EditTransform) {
        applyClipEdit { $0.transform = newTransform.validated }
    }

    func resetTransform() {
        applyClipEdit { $0.transform = .identity }
    }

    /// 对齐预设（剪映 02.png 六向对齐）：按当前缩放把内容贴到画布边。
    func alignTransform(horizontal: Int, vertical: Int) {
        // horizontal: -1 左 / 0 中 / 1 右；vertical: -1 下 / 0 中 / 1 上（CI y 向上）
        var next = transform
        let margin = max((1 - next.scale) / 2, 0)
        next.offsetX = Double(horizontal) * margin
        next.offsetY = Double(vertical) * margin
        setTransform(next)
    }

    // MARK: 画面调整（亮度/对比度/饱和度）

    func setAdjust(_ newAdjust: EditAdjust) {
        applyClipEdit { $0.adjust = newAdjust.validated }
    }

    func resetAdjust() {
        applyClipEdit { $0.adjust = .identity }
    }

    // MARK: 分割 / 删除（剪映 02.png 顶部工具栏）

    /// 在播放头处分割当前 clip：成品时间处把所在 clip 一分为二（共享源切点）。
    func splitAtPlayhead() {
        let t = playhead
        guard t > 0.05, t < outputDuration - 0.05 else { return }
        var cursor: TimeInterval = 0
        for (index, clip) in clips.enumerated() {
            let start = cursor
            let end = cursor + clip.displayDuration
            cursor = end
            guard t > start + 0.05, t < end - 0.05 else { continue }
            let sourceCut = clip.sourceStart + (t - start) * clip.speed
            guard sourceCut - clip.sourceStart >= EditDocument.minimumClipSourceDuration,
                  clip.sourceEnd - sourceCut >= EditDocument.minimumClipSourceDuration else { return }
            applyClipEdit { document in
                var before = document.clips[index]
                var after = document.clips[index]
                before.sourceEnd = sourceCut
                after.sourceStart = sourceCut
                document.clips[index] = before
                document.clips.insert(after, at: index + 1)
            }
            return
        }
    }

    /// 播放头所在 clip 的（下标，源时间）——裁剪/分割共用寻址。
    private func clipAddress(atOutputTime t: TimeInterval) -> (index: Int, sourceTime: TimeInterval)? {
        guard !clips.isEmpty else { return nil }
        var cursor: TimeInterval = 0
        for (index, clip) in clips.enumerated() {
            let start = cursor
            let end = cursor + clip.displayDuration
            cursor = end
            if t >= start, t < end {
                return (index, clip.sourceStart + (t - start) * clip.speed)
            }
        }
        return nil
    }

    /// 向左裁剪（剪映 01.png 工具栏）：裁掉播放头所在片段的左半——入点移到播放头。
    func trimLeftAtPlayhead() {
        guard let address = clipAddress(atOutputTime: playhead) else { return }
        applyClipEdit { document in
            guard document.clips.indices.contains(address.index) else { return }
            var clip = document.clips[address.index]
            guard address.sourceTime - clip.sourceStart >= EditDocument.minimumClipSourceDuration else { return }
            clip.sourceStart = address.sourceTime
            document.clips[address.index] = clip
        }
        selectedClipIndex = nil
    }

    /// 向右裁剪（剪映 01.png 工具栏）：裁掉播放头所在片段的右半——出点移到播放头。
    func trimRightAtPlayhead() {
        guard let address = clipAddress(atOutputTime: playhead) else { return }
        applyClipEdit { document in
            guard document.clips.indices.contains(address.index) else { return }
            var clip = document.clips[address.index]
            guard clip.sourceEnd - address.sourceTime >= EditDocument.minimumClipSourceDuration else { return }
            clip.sourceEnd = address.sourceTime
            document.clips[address.index] = clip
        }
        selectedClipIndex = nil
    }

    /// 删除选中 clip（整段波纹删除）；未选中 → 删除播放头所在 clip。
    func deleteSelectedClip() {
        guard !clips.isEmpty else { return }
        let index = selectedClipIndex
            ?? clipIndex(atOutputTime: min(playhead, max(outputDuration - 0.01, 0)))
        guard let index, clips.indices.contains(index) else { return }
        var cursor: TimeInterval = 0
        for clip in clips.prefix(index) { cursor += clip.displayDuration }
        cutOutputRange(lower: cursor, upper: cursor + clips[index].displayDuration)
        selectedClipIndex = nil
    }

    /// 配乐 URL 解析（书签 → 可访问 URL；渲染/混音期间保持访问，由调用方 stop）。
    func resolveMusicAccess() -> (url: URL, stop: () -> Void)? {
        guard let music = backgroundMusic else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: music.bookmark,
                                 options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            NSLog("Editor: 配乐书签解析失败（%@）", music.name)
            return nil
        }
        let scoped = url.startAccessingSecurityScopedResource()
        return (url, { if scoped { url.stopAccessingSecurityScopedResource() } })
    }

    /// 成片总时长（摘要行/比例尺面——时间线即成品轨）。
    var outputDuration: TimeInterval { clipsDocument.outputDuration }

    /// 源裁切总量（源时长 − clips 覆盖源长；摘要行展示）。
    var totalCutSeconds: TimeInterval {
        max(sourceDuration - clips.reduce(0) { $0 + ($1.sourceEnd - $1.sourceStart) }, 0)
    }

    /// 导出时长（= 成片时长）。
    var exportDuration: TimeInterval { outputDuration }

    /// 是否含剪辑痕迹（导出名分流）。
    var hasEdits: Bool { clipsDocument.hasEdits(sourceDuration: sourceDuration) }

    /// 缩放段映射到成品时间轴（画布铺排用）。
    var mappedZoomSegments: [ZoomSegment] { clipsDocument.mappedZoomSegments() }

    /// 抓播放头当前帧存为封面（剪映 01.png「封面」按钮复刻）：
    /// 源时间取成品→源映射，PNG 落成片同目录 `<原名>_封面.png`。
    func saveCoverFrame() {
        let source = clipsDocument.sourceTime(forOutputTime: playhead)
            ?? clipsDocument.sourceTime(forOutputTime: min(playhead, outputDuration))
        guard let source else { return }
        let url = item.url
        Task.detached(priority: .utility) { [weak self] in
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            guard let result = try? await generator.image(
                at: CMTime(seconds: source, preferredTimescale: 600)).image else { return }
            let coverURL = url.deletingLastPathComponent()
                .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "_封面.png")
            let bitmap = NSBitmapImageRep(cgImage: result)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
            try? FileManager.default.removeItem(at: coverURL)
            try? png.write(to: coverURL)
            NSLog("Editor: 封面已存 %@", coverURL.lastPathComponent)
        }
    }

    /// 播放头所在/成品时间所在 clip 的下标（选中面板兜底）。
    func clipIndex(atOutputTime t: TimeInterval) -> Int? {
        var cursor: TimeInterval = 0
        for (index, clip) in clips.enumerated() {
            let span = clip.displayDuration
            if t < cursor + span { return index }
            cursor += span
        }
        return nil
    }


    /// 时间线上第 `index` 段的显示区间（拖拽预览优先——预览未落库，仅供绘制）。
    func displayedRange(at index: Int) -> (start: TimeInterval, end: TimeInterval) {
        guard segments.indices.contains(index) else { return (0, 0) }
        if let preview = dragPreview, preview.index == index {
            return (preview.start, preview.end)
        }
        return (segments[index].start, segments[index].end)
    }

    /// 预估导出大小展示文案（源码率 × 剪除后时长 × 编码系数；未就绪/退化 → 「—」）。
    var estimatedSizeText: String {
        let bytes = ZoomEditorLogic.estimatedExportBytes(
            sourceSizeBytes: item.sizeBytes, sourceDuration: exportDuration, codec: codec)
        guard bytes > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var exportOptions: ExportVideoOptions {
        ExportVideoOptions(fps: fpsChoice.fps, maxHeight: heightChoice.maxHeight, codec: codec)
    }

    /// 开始导出（编辑器「开始导出」按钮）：编排经列表模型（单飞门/进度 hop/通知/入列
    /// 在 `renderZoom`）；窗口保持开启，进度条展示渲染进度。剪除段随编排传入（渲染侧
    /// 折叠时间线 + 命名分流 `_剪辑.mp4`）。
    func export() {
        let document = currentDocument()
        let hasEditsFlag = hasEdits
        let itemRef = item
        Task { @MainActor in
            let rendered = await listViewModel.renderZoom(
                itemRef, segments: document.zoomSegments, clips: document.clips,
                keyframes: document.keyframes, transitions: document.transitions,
                transform: document.transform, adjust: document.adjust,
                options: exportOptions)
            // 配乐混音（批次 4b）：渲染成功且有配乐 → AVMutableComposition 双音轨混音，
            // 原地替换成片（tmp 导出后替换）。
            guard let music = document.backgroundMusic, music.volume > 0.01, let rendered else { return }
            guard let access = resolveMusicAccess() else { return }
            defer { access.stop() }
            do {
                let tmpURL = rendered.deletingLastPathComponent().appendingPathComponent(
                    ".mux_\(UUID().uuidString).mp4")
                try await OfflineZoomRenderer.muxBackgroundMusic(
                    editedURL: rendered, musicURL: access.url,
                    volume: Float(music.volume), outputURL: tmpURL)
                _ = try FileManager.default.replaceItemAt(rendered, withItemAt: tmpURL)
                NSLog("Editor: 配乐混音完成（%@ × %.2f）", music.name, music.volume)
            } catch {
                NSLog("Editor: 配乐混音失败（保留无配乐成片）：\(error)")
            }
            _ = hasEditsFlag
        }
    }

    /// 统一闸执行点：修改 → validate → 落库 → 草稿即时存盘（try? 尽力而为——草稿是
    /// 便利持久化，写失败不阻断编辑，失败形态归真机验收观察）。
    private func applyEdit(_ edit: (inout [ZoomSegment]) -> Void) {
        pushUndo()
        var document = clipsDocument
        edit(&document.zoomSegments)
        let validated = EditDocument.validate(document)
        segments = validated.zoomSegments
        clips = validated.clips
        sourceVolume = validated.sourceVolume
        backgroundMusic = validated.backgroundMusic
        keyframes = validated.keyframes
        transitions = validated.transitions
        transform = validated.transform
        adjust = validated.adjust
        saveDocument()
    }

    /// 剪除段统一闸：修改 → `CutSegment.validate` → 落库 → 草稿即时存盘（同 applyEdit 纪律）
    /// → 边界观察器重挂（播放跳剪主通道跟随最新剪除段）。
    // MARK: 撤销/重做（快照栈——EditDocument 值语义；⌘Z / ⇧⌘Z + 工具行按钮）

    private var undoStack: [EditDocument] = []
    private var redoStack: [EditDocument] = []
    /// 栈深上限（防长会话无界增长；超限弃最旧）。
    private static let undoLimit = 100
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    /// 变更前快照（applyEdit/applyClipEdit 入口调用；清 redo 分支）。
    private func pushUndo() {
        undoStack.append(currentDocument())
        if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
        syncUndoFlags()
    }

    private func currentDocument() -> EditDocument {
        EditDocument(clips: clips, zoomSegments: segments,
                     sourceVolume: sourceVolume, backgroundMusic: backgroundMusic,
                     keyframes: keyframes, transitions: transitions, transform: transform,
                     adjust: adjust)
    }

    private func applyDocument(_ document: EditDocument) {
        segments = document.zoomSegments
        clips = document.clips
        sourceVolume = document.sourceVolume
        backgroundMusic = document.backgroundMusic
        keyframes = document.keyframes
        transitions = document.transitions
        transform = document.transform
        adjust = document.adjust
        clampTimelineOffset()
        selectedClipIndex = nil
        selectedIndex = nil
        saveDocument()
        selectedIndex = nil
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(currentDocument())
        applyDocument(previous)
        syncUndoFlags()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(currentDocument())
        applyDocument(next)
        syncUndoFlags()
    }

    private func syncUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: 键盘工作流（空格/←→/Home/End 路由在 opener；步进动作在此）

    /// 逐帧步进（缺省帧率 1/30s）。
    func stepFrames(_ count: Int) {
        scrub(to: playhead + TimeInterval(count) / 30.0)
    }

    func stepSeconds(_ seconds: TimeInterval) {
        scrub(to: playhead + seconds)
    }

    /// 播放头时间码（剪映同款 HH:MM:SS:FF @30）。
    var playheadTimecode: String { ZoomTimelineGeometry.timecode(playhead) }
    /// 成片时长时间码。
    var durationTimecode: String { ZoomTimelineGeometry.timecode(outputDuration) }

    private func applyClipEdit(_ edit: (inout EditDocument) -> Void) {
        pushUndo()
        var document = clipsDocument
        edit(&document)
        let validated = EditDocument.validate(document)
        clips = validated.clips
        segments = validated.zoomSegments
        sourceVolume = validated.sourceVolume
        backgroundMusic = validated.backgroundMusic
        keyframes = validated.keyframes
        transitions = validated.transitions
        transform = validated.transform
        adjust = validated.adjust
        clampTimelineOffset() // 时长可能变短（波纹删除）——平移不得越界
        clampSelections() // 过期选中下标置 nil（防 SwiftUI Binding 越界）
        saveDocument()
    }

    /// 草稿落盘（两段表合一文档；尽力而为）。
    private func saveDocument() {
        try? listViewModel.saveDraft(currentDocument(), for: item)
    }

    /// 定点修改：对旧段拷贝先算出**编辑后期望值**，validate 后按期望值回找选中下标
    ///（validate 可能重排——按值回找使选中跟随段走；编辑段被丢弃（重叠）时回找失败
    /// → 保持原下标不变，UI 层提示段表已规整）。
    private func updateSegment(at index: Int, mutate: (inout ZoomSegment) -> Void) {
        guard segments.indices.contains(index) else { return }
        var expected = segments[index]
        mutate(&expected)
        applyEdit { mutate(&$0[index]) }
        if let newIndex = segments.firstIndex(of: expected) {
            selectedIndex = newIndex
        }
    }

    /// 剪除段定点修改（剪除段无选中概念，仅统一闸 + 防越界）。
    /// 片段定点修改（validate 后按值回找选中下标）。
    private func updateClip(at index: Int, mutate: (inout EditClip) -> Void) {
        guard clips.indices.contains(index) else { return }
        var expected = clips[index]
        mutate(&expected)
        applyClipEdit { mutate(&$0.clips[index]) }
        if let newIndex = clips.firstIndex(of: expected) {
            selectedClipIndex = newIndex
        }
    }

    /// 播放跟随（放大时）：播放头逼近/越过右缘 → 视窗左移，播放头保持距左缘 8%
    ///（剪映同款滚动跟随）。zoom = 1 全程可见无需跟随。
    private func followPlayheadIfNeeded() {
        guard isPlaying, timelineZoom > 1.001, timelineDuration > 0 else { return }
        let span = timelineDuration / timelineZoom
        let rightEdge = timelineOffset + span
        if playhead > rightEdge - span * 0.08 || playhead < timelineOffset {
            timelineOffset = ZoomTimelineGeometry.clampedOffset(
                playhead - span * 0.08,
                sourceDuration: timelineDuration, zoom: timelineZoom)
        }
    }

    /// 播放头驱动：主队列 periodic 观察器（0.25s 步进）。回调为 AVFoundation @Sendable
    /// 缝（主队列投递）——写回经 `Task { @MainActor }` hop（willSet sink 裁定同款纪律：
    /// 异步缝闭包不直写主 actor 状态）。
    private func mountTimeObserver() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                // 成品轴播放头：播放中把播放器实际位置校正到「成品时间映射的源时间」
                //（clip 接缝处源跳变由此实现——映射连续、时间线无空洞）。
                var seconds = time.seconds
                if self.player.timeControlStatus == .playing,
                   seconds <= self.outputDuration,
                   let mappedSource = self.clipsDocument.sourceTime(forOutputTime: seconds) {
                    let actual = self.player.currentTime().seconds
                    if actual.isFinite, abs(actual - mappedSource) > 0.15 {
                        self.player.seek(to: CMTime(seconds: mappedSource, preferredTimescale: 600))
                    }
                }
                self.playhead = seconds
                self.isPlaying = self.player.timeControlStatus == .playing
                self.followPlayheadIfNeeded()
            }
        }
    }
}

// MARK: - 时间线窗视图（P9/T18）

/// 时间线窗（brief Produces）：AVPlayer 预览 + 播放/时间行 + 时间线条（分段块、拖入出点、
/// 播放头、点击跳播）+ 分段列表（增/选/调档位/删）+ 九宫格中心 + 导出参数（fps/分辨率/
/// 编码）+ 预估大小 + 渲染进度。
///
/// 交互通道（2026-11-13 同列表窗修复）：本窗为手建 `NSWindow + NSHostingView`，
/// SwiftUI 手势/菜单层整层不响应（见 RecordingListView 头注）——分段列表与时间线条的
/// 选中/右键菜单/拖端点全走 AppKit 原生通道：列表 = 原生 `NSTableView`
///（`ZoomSegmentTable`），时间线条 = 自绘 `NSView`（`ZoomTimelineStrip`）。控件
///（Button/Picker/下拉）激活通道本就存活，维持 SwiftUI。
///
/// 预览实现裁定（2026-11-13 修订）：改用原生 `AVPlayerView`（NSViewRepresentable）。
/// 原 `AVKit.VideoPlayer` 在本环境打不开编辑器——`_AVKit_SwiftUI` 被链接而 AVKit.framework
/// 本体未进加载列表，`VideoPlayerView` 初始化时父类 `AVPlayerView` 元数据缺失，进程
/// SIGABRT（`failed to demangle superclass ... 'So12AVPlayerViewC'`，崩溃报告实证）；
/// 且 VideoPlayer 的传输控件本是 SwiftUI 层（本窗口族内不可交互）。AVPlayerView 为
/// AppKit 控件：强制 AVKit 链接消除崩溃，传输控件（悬浮样式）原生可用。裁切（裁剪/
/// 拼接/多轨）不做（spec §5 P9 非目标）。
struct ZoomEditorView: View {
    @ObservedObject var model: ZoomEditorModel
    @ObservedObject var viewModel: RecordingListViewModel

    /// 右侧检查器页签（剪映 02.png：画面/变速/动画/音频）。
    enum InspectorTab: String, CaseIterable, Identifiable {
        case video, adjust, speed, animation, audio
        var id: String { rawValue }
        var title: String {
            switch self {
            case .video: return NSLocalizedString("画面", comment: "Inspector tab")
            case .adjust: return NSLocalizedString("调整", comment: "Inspector tab")
            case .speed: return NSLocalizedString("变速", comment: "Inspector tab")
            case .animation: return NSLocalizedString("动画", comment: "Inspector tab")
            case .audio: return NSLocalizedString("音频", comment: "Inspector tab")
            }
        }
    }

    @State private var inspectorTab: InspectorTab = .video

    private var panelBackground: Color { Color(nsColor: .controlBackgroundColor) }
    private var dividerColor: Color { Color(nsColor: .separatorColor) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().overlay(dividerColor)
            HStack(spacing: 0) {
                sideBar.frame(width: 196)
                Divider().overlay(dividerColor)
                centerPane
                Divider().overlay(dividerColor)
                inspector.frame(width: 256)
            }
            Divider().overlay(dividerColor)
            timelinePane
        }
        .frame(minWidth: 1180, minHeight: 760)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await model.loadMediaInfo(); model.loadFilmstrip() }
        .task { model.loadWaveform() }
    }

    // MARK: 顶部栏（剪映 02.png：编辑工具在底部时间线栏，顶栏只放分享/导出）

    private var topBar: some View {
        HStack(spacing: 12) {
            Text(model.item.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Spacer()
            Button {
                // 分享：剪映为发布到平台/生成链接；本应用离线，占位提示
            } label: {
                Label("分享", systemImage: "square.and.arrow.up.on.square")
            }
            .disabled(true)
            .help("分享：暂未实现（离线应用，可先用导出）")
            Button { model.export() } label: {
                Label("导出", systemImage: "square.and.arrow.up")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(OmiStyle.accent))
                    .foregroundStyle(.white)
            }
            .disabled(viewModel.zoomRenderProgress != nil)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(panelBackground)
    }

    // MARK: 左侧素材栏

    private var sideBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("素材").font(.subheadline.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    sourceCard
                    Divider().overlay(dividerColor)
                    Text("音频").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if let music = model.backgroundMusic {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(music.name, systemImage: "music.note")
                                .font(.caption).lineLimit(1)
                            Text("配乐 · \(Int((music.volume * 100).rounded()))%")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    } else {
                        Button {
                            model.importMusic()
                        } label: {
                            Label("导入音频…", systemImage: "plus.circle")
                                .font(.caption)
                        }
                    }
                }
            }
            Spacer()
            Text("录音本身为素材；导入音频进配乐轨")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(panelBackground)
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.black.opacity(0.35))
                if let thumbnail = representativeThumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: "film")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 74)
            .clipped()
            Text(model.item.name)
                .font(.caption)
                .lineLimit(1)
            Text(model.durationTimecode)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var representativeThumbnail: NSImage? {
        guard let strip = model.filmstrip,
              let first = strip.images.min(by: { $0.key < $1.key })?.value else { return nil }
        return NSImage(cgImage: first, size: NSSize(width: first.width, height: first.height))
    }

    // MARK: 中间播放器（变换实时预览）

    private var centerPane: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                PlayerPreview(player: model.player)
                    .scaleEffect(model.transform.scale)
                    .rotationEffect(.degrees(model.transform.rotationDegrees))
                    .offset(
                        x: model.transform.offsetX * geo.size.width,
                        y: -model.transform.offsetY * geo.size.height)
                    .clipShape(RoundedRectangle(
                        cornerRadius: CGFloat(model.transform.cornerRadius) * min(geo.size.width, geo.size.height)))
                    .brightness(model.adjust.brightness)
                    .contrast(model.adjust.contrast)
                    .saturation(model.adjust.saturation)
            }
            .frame(maxHeight: .infinity)
            transportRow
        }
        .padding(10)
    }

    private var transportRow: some View {
        HStack(spacing: 12) {
            Text("\(model.playheadTimecode) / \(model.durationTimecode)")
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Button { model.stepFrames(-1) } label: { Image(systemName: "backward.frame") }
                .help("上一帧（←）")
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
            }.help("播放/暂停（空格）")
            Button { model.stepFrames(1) } label: { Image(systemName: "forward.frame") }
                .help("下一帧（→）")
            Spacer()
            Button("画面") { inspectorTab = .video }
            Button("缩放") { inspectorTab = .video }
            Text("比例 \(aspectText)").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .font(.callout)
    }

    private var aspectText: String {
        let size = model.videoSize
        guard size.width > 0, size.height > 0 else { return "—" }
        let ratio = size.width / size.height
        if abs(ratio - 16.0 / 9.0) < 0.01 { return "16:9" }
        if abs(ratio - 4.0 / 3.0) < 0.01 { return "4:3" }
        if abs(ratio - 9.0 / 16.0) < 0.01 { return "9:16" }
        if abs(ratio - 1) < 0.01 { return "1:1" }
        return String(format: "%.2f:1", ratio)
    }

    // MARK: 右侧检查器

    private var inspector: some View {
        VStack(spacing: 0) {
            Picker("", selection: $inspectorTab) {
                ForEach(InspectorTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    inspectorContent
                }
                .padding(10)
            }
        }
        .background(panelBackground)
    }

    @ViewBuilder
    private var inspectorContent: some View {
        switch inspectorTab {
        case .video:
            transformPanel
        case .adjust:
            adjustPanel
        case .speed:
            speedPanel
        case .animation:
            segmentSection
            selectedSegmentSection
        case .audio:
            audioTracksSection
        }
    }

    // MARK: 画面变换面板（缩放/位置/旋转/圆角）

    private var transformPanel: some View {
        let current = model.transform
        return VStack(alignment: .leading, spacing: 12) {
            // 子页签（剪映 02.png：基础/抠像/蒙版/美颜媒体——仅基础已实现，其余置灰占位）
            HStack(spacing: 6) {
                Text("基础")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(OmiStyle.accent.opacity(0.2)))
                ForEach(["抠像", "蒙版", "美颜媒体"], id: \.self) { title in
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.secondary.opacity(0.1)))
                        .help("\(title)：暂未实现")
                }
                Spacer()
                Button("重置") { model.resetTransform() }
                    .disabled(current.isIdentity)
                    .font(.caption)
            }
            // 六向对齐（剪映 02.png 对齐按钮组）
            HStack(spacing: 6) {
                ForEach(Array([(-1, 1), (0, 1), (1, 1), (-1, 0), (1, -1), (0, -1)].enumerated()),
                        id: \.offset) { _, pair in
                    Button {
                        model.alignTransform(horizontal: pair.0, vertical: pair.1)
                    } label: {
                        Image(systemName: alignmentSymbol(horizontal: pair.0, vertical: pair.1))
                            .font(.caption)
                    }
                    .help("对齐")
                }
            }
            transformSlider("缩放",
                            value: current.scale * 100, range: 10...400, suffix: "%") {
                var next = current; next.scale = $0 / 100; model.setTransform(next)
            }
            transformSlider("位置 X",
                            value: current.offsetX * 100, range: -100...100, suffix: "%") {
                var next = current; next.offsetX = $0 / 100; model.setTransform(next)
            }
            transformSlider("位置 Y",
                            value: current.offsetY * 100, range: -100...100, suffix: "%") {
                var next = current; next.offsetY = $0 / 100; model.setTransform(next)
            }
            transformSlider("旋转",
                            value: current.rotationDegrees, range: -180...180, suffix: "°") {
                var next = current; next.rotationDegrees = $0; model.setTransform(next)
            }
            transformSlider("圆角",
                            value: current.cornerRadius * 100, range: 0...50, suffix: "%") {
                var next = current; next.cornerRadius = $0 / 100; model.setTransform(next)
            }
            Text("位置单位为画布比例；圆角为短边比例。导出时按此应用。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func transformSlider(_ title: String, value: Double,
                                 range: ClosedRange<Double>, suffix: String,
                                 onChange: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(String(format: "%.0f%@", value, suffix))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { value }, set: onChange), in: range)
        }
    }

    // MARK: 调整面板（亮度/对比度/饱和度）

    private var adjustPanel: some View {
        let current = model.adjust
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("调整").font(.subheadline.weight(.semibold))
                Spacer()
                Button("重置") { model.resetAdjust() }
                    .disabled(current.isIdentity)
                    .font(.caption)
            }
            transformSlider("亮度",
                            value: current.brightness * 200, range: -100...100, suffix: "") {
                var next = current; next.brightness = $0 / 200; model.setAdjust(next)
            }
            transformSlider("对比度",
                            value: (current.contrast - 1) * 200, range: -100...100, suffix: "") {
                var next = current; next.contrast = 1 + $0 / 200; model.setAdjust(next)
            }
            transformSlider("饱和度",
                            value: (current.saturation - 1) * 100, range: -100...100, suffix: "") {
                var next = current; next.saturation = 1 + $0 / 100; model.setAdjust(next)
            }
            Text("调整作用于整条成片，导出时应用。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func alignmentSymbol(horizontal: Int, vertical: Int) -> String {
        switch (horizontal, vertical) {
        case (-1, 0): return "arrow.left.to.line"
        case (1, 0): return "arrow.right.to.line"
        case (0, 1): return "arrow.up.to.line"
        case (0, -1): return "arrow.down.to.line"
        default: return "dot.squareshape.split.2x2"
        }
    }

    // MARK: 变速面板

    @ViewBuilder
    private var speedPanel: some View {
        if let index = model.selectedClipIndex, model.clips.indices.contains(index) {
            let clip = model.clips[index]
            VStack(alignment: .leading, spacing: 8) {
                Text("片段 \(index + 1)").font(.subheadline.weight(.semibold))
                Picker("速度", selection: Binding(
                    get: { clip.speed },
                    set: { model.setClipSpeed(at: index, speed: $0) })) {
                    Text("0.5×").tag(0.5)
                    Text("1×").tag(1.0)
                    Text("1.25×").tag(1.25)
                    Text("1.5×").tag(1.5)
                    Text("2×").tag(2.0)
                    Text("3×").tag(3.0)
                }
                Text("时长 \(String(format: "%.1f", clip.displayDuration))s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("⌘+点击时间线选中片段后调速（0.5–3×，音高保持）")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 底部时间线

    private var timelinePane: some View {
        VStack(alignment: .leading, spacing: 4) {
            timelineToolbar
            HStack(alignment: .top, spacing: 4) {
                // 封面（剪映 02.png：轨道左缘的小按钮）
                Button {
                    model.saveCoverFrame()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "pencil.and.scribble")
                            .font(.caption)
                        Text("封面").font(.caption2)
                    }
                    .frame(width: 44, height: 52)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor)))
                }
                .buttonStyle(.plain)
                .help("抓播放头当前帧存为封面 PNG")
                ZoomTimelineStrip(model: model)
                    .frame(height: 120)
            }
            Text("空白拖选=波纹删除 · 拖白线=修剪接缝 · ⌘+点击=选段调速 · 双击音频道=音量关键帧 · 接缝右键/⇧⌘T=转场 · 空格播放 ←→ 逐帧 · ⌘B 分割")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(8)
        .background(panelBackground)
    }

    /// 时间线编辑工具栏（剪映 02.png 底部那一排：撤销/重做/分割/删除/裁剪/转场）。
    private var timelineToolbar: some View {
        HStack(spacing: 10) {
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo).help("撤销（⌘Z）")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo).help("重做（⇧⌘Z）")
            Divider().frame(height: 16)
            Button { model.splitAtPlayhead() } label: {
                Label("分割", systemImage: "rectangle.split.2x1")
            }
            .help("在播放头处分割片段（⌘B）")
            Button { model.deleteSelectedClip() } label: { Image(systemName: "trash") }
                .help("删除选中片段")
            Button { model.trimLeftAtPlayhead() } label: { Image(systemName: "arrow.left.to.line") }
                .help("向左裁剪（裁掉播放头左侧）")
            Button { model.trimRightAtPlayhead() } label: { Image(systemName: "arrow.right.to.line") }
                .help("向右裁剪（裁掉播放头右侧）")
            Button { _ = model.cycleTransitionNearPlayhead() } label: { Image(systemName: "square.on.square.dashed") }
                .disabled(model.clips.count < 2)
                .help("循环最近接缝转场（⇧⌘T）")
            Spacer()
            Text("共 \(model.clips.count) 段 · 源裁切 \(String(format: "%.1f", model.totalCutSeconds))s · 成片 ≈ \(String(format: "%.1f", model.exportDuration))s")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(get: { model.timelineZoom }, set: { model.timelineZoom = $0 }),
                in: 1...200)
                .frame(width: 90)
                .help("时间线缩放（⌘+滚轮）")
            Button("适应") {
                model.timelineZoom = 1
                model.timelineOffset = 0
            }
            .font(.caption2)
            .disabled(model.timelineZoom <= 1 && model.timelineOffset <= 0)
        }
        .buttonStyle(.plain)
        .font(.callout)
    }

    // MARK: 播放行

    private var playControlRow: some View {
        HStack(spacing: 12) {
            Button {
                model.togglePlay()
            } label: {
                Label(model.isPlaying ? "暂停" : "播放",
                      systemImage: model.isPlaying ? "pause.fill" : "play.fill")
            }
            // 时间码（剪映同款 HH:MM:SS:FF @30）。
            Text("\(model.playheadTimecode) / \(model.durationTimecode)")
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(OmiStyle.subtleText)
            Spacer()
            // 撤销/重做（剪映对齐·⌘Z / ⇧⌘Z）。
            Button {
                model.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!model.canUndo)
            .help("撤销（⌘Z）")
            Button {
                model.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!model.canRedo)
            .help("重做（⇧⌘Z）")
            // 封面（剪映 01.png 左侧按钮复刻）：抓播放头当前帧存 PNG
            Button {
                model.saveCoverFrame()
            } label: {
                Label("封面", systemImage: "photo.on.rectangle.angled")
            }
            .help("抓取播放头当前帧存为封面图（PNG）")
            // 转场循环按钮（剪映对齐·无鼠标通道）：对播放头最近接缝 无→黑场→溶解→无
            Button {
                _ = model.cycleTransitionNearPlayhead()
            } label: {
                Text(model.transitionLabelAtPlayhead.map { "转场：\($0)" } ?? "转场")
                    .font(.callout)
            }
            .disabled(model.clips.count < 2)
            .help("循环切换播放头最近接缝的转场：无 → 黑场 → 溶解（⇧⌘T）")
            Button("在播放头添加分段") {
                model.addSegment(at: model.playhead)
            }
        }
    }

    // MARK: 分段列表（增/选/调档位/删；原生 NSTableView——SwiftUI 手势/菜单层不可用）

    @ViewBuilder
    private var segmentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("缩放分段").font(.headline)
                Text("\(model.segments.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OmiStyle.subtleText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.14)))
            }
            if model.segments.isEmpty {
                Text("暂无分段——播放到目标位置后点「在播放头添加分段」，或在时间线上拖段块两端调整入出点。")
                    .font(.footnote)
                    .foregroundStyle(OmiStyle.subtleText)
            } else {
                ZoomSegmentTable(model: model)
                    .frame(height: CGFloat(model.segments.count) * ZoomSegmentTable.rowHeight)
            }
        }
    }

    // MARK: 选中段细节（九宫格中心）

    @ViewBuilder
    private var selectedSegmentSection: some View {
        if let index = model.selectedIndex, model.segments.indices.contains(index) {
            OmiCard {
                HStack(alignment: .top, spacing: 16) {
                NinePatchGrid(currentCenter: model.segments[index].center) { row, column in
                    model.setCenter(atIndex: index, ninePatchRow: row, column: column)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("缩放中心（九宫格）").font(.subheadline)
                    Text("点选九宫格设定「段 \(index + 1)」的缩放中心；与点击自动缩放同一画面口径（格中心 ±1/6 归一化）。")
                        .font(.footnote)
                        .foregroundStyle(OmiStyle.subtleText)
                }
                Spacer()
                }
            }
        }
    }

    // MARK: 选中 clip 速度面板（剪映对齐·⌘+点击选中）

    @ViewBuilder
    private var selectedClipSection: some View {
        if let index = model.selectedClipIndex, model.clips.indices.contains(index) {
            OmiCard {
                HStack(spacing: 16) {
                    Text("片段 \(index + 1)")
                        .font(.subheadline.weight(.semibold))
                    // Binding get 防御过期下标（差分更新可能在 body 守卫重评前触达）
                    Picker("速度", selection: Binding(
                        get: { model.clips.indices.contains(index) ? model.clips[index].speed : 1.0 },
                        set: { model.setClipSpeed(at: index, speed: $0) })) {
                        Text("0.5×").tag(0.5)
                        Text("1×").tag(1.0)
                        Text("1.25×").tag(1.25)
                        Text("1.5×").tag(1.5)
                        Text("2×").tag(2.0)
                        Text("3×").tag(3.0)
                    }
                    .frame(width: 120)
                    Text("时长 \(model.clips.indices.contains(index) ? String(format: "%.1f", model.clips[index].displayDuration) : "—")s")
                        .font(.footnote)
                        .foregroundStyle(OmiStyle.subtleText)
                    Spacer()
                    Button("取消选中") { model.selectedClipIndex = nil }
                        .buttonStyle(.plain)
                        .font(.footnote)
                }
            }
        }
    }

    // MARK: 音轨卡（批次 4b：原声音量 + 配乐）

    private var audioTracksSection: some View {
        OmiCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("音轨").font(.headline)
                HStack(spacing: 8) {
                    Text("原声").frame(width: 44, alignment: .leading)
                        .font(.callout)
                    Slider(value: Binding(
                        get: { model.sourceVolume },
                        set: { model.setSourceVolume($0) }), in: 0...1)
                    Text("\(Int((model.sourceVolume * 100).rounded()))%")
                        .font(.system(.footnote, design: .monospaced))
                        .frame(width: 44, alignment: .trailing)
                }
                HStack(spacing: 8) {
                    Text("配乐").frame(width: 44, alignment: .leading)
                        .font(.callout)
                    if let music = model.backgroundMusic {
                        Slider(value: Binding(
                            get: { music.volume },
                            set: { model.setMusicVolume($0) }), in: 0...1)
                        Text(music.name)
                            .font(.caption)
                            .lineLimit(1)
                            .frame(maxWidth: 110, alignment: .leading)
                        Button {
                            model.removeMusic()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("移除配乐")
                    } else {
                        Button("导入音频…") { model.importMusic() }
                        Text("循环铺满成片，导出时混音")
                            .font(.caption)
                            .foregroundStyle(OmiStyle.faintText)
                    }
                }
                Text("配乐音量建议 ≤50%——盖过人声是常见事故。")
                    .font(.caption2)
                    .foregroundStyle(OmiStyle.faintText)
            }
        }
    }

    // MARK: 导出参数 + 预估 + 进度

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("导出").font(.headline)
            Text("输出：\(viewModel.suggestedEditedDestinationName(for: model.item, hasEdits: model.hasEdits))（与源同目录）")
                .font(.footnote)
                .foregroundStyle(OmiStyle.subtleText)
            HStack(spacing: 16) {
                Picker("帧率", selection: $model.fpsChoice) {
                    Text("沿用源").tag(ZoomEditorModel.FPSChoice.source)
                    Text("24 fps").tag(ZoomEditorModel.FPSChoice.fps24)
                    Text("30 fps").tag(ZoomEditorModel.FPSChoice.fps30)
                    Text("60 fps").tag(ZoomEditorModel.FPSChoice.fps60)
                }
                .frame(width: 130)
                Picker("分辨率", selection: $model.heightChoice) {
                    Text("源分辨率").tag(ZoomEditorModel.HeightChoice.source)
                    Text("1080p").tag(ZoomEditorModel.HeightChoice.h1080)
                    Text("720p").tag(ZoomEditorModel.HeightChoice.h720)
                }
                .frame(width: 130)
                Picker("编码", selection: $model.codec) {
                    Text("H.264").tag(VideoCodec.h264)
                    Text("HEVC").tag(VideoCodec.hevc)
                }
                .frame(width: 110)
                Spacer()
                Text("预估大小：\(model.estimatedSizeText)（近似值）")
                    .font(.footnote)
                    .foregroundStyle(OmiStyle.subtleText)
            }
            progressArea
            HStack {
                Spacer()
                Button {
                    model.export()
                } label: {
                    Label("开始导出", systemImage: "square.and.arrow.up")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(OmiStyle.accent))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.zoomRenderProgress != nil)
            }
        }
    }

    @ViewBuilder
    private var progressArea: some View {
        if let progress = viewModel.zoomRenderProgress {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress)
                Text("正在渲染成片…\(Int((progress * 100).rounded()))%")
                    .font(.footnote)
                    .foregroundStyle(OmiStyle.subtleText)
            }
        }
    }
}

/// 源片预览（原生 AVPlayerView 桥接）：悬浮传输控件（悬停出现，近似原 VideoPlayer
/// 交互）+ aspect-fit 视频；播放/跳播真源仍是 `ZoomEditorModel` 的 AVPlayer。
private struct PlayerPreview: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }
}

/// 九宫格中心选择（3×3；当前中心所在格高亮，`ZoomEditorLogic.ninePatchCell` 逆映射）。
private struct NinePatchGrid: View {
    let currentCenter: CGPoint
    let onSelect: (_ row: Int, _ column: Int) -> Void

    var body: some View {
        let current = ZoomEditorLogic.ninePatchCell(for: currentCenter)
        VStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { column in
                        Button {
                            onSelect(row, column)
                        } label: {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(current.row == row && current.column == column
                                      ? OmiStyle.accent
                                      : Color.secondary.opacity(0.25))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .help("缩放中心：\(row == 0 ? "上" : row == 1 ? "中" : "下")\(column == 0 ? "左" : column == 1 ? "中" : "右")")
                    }
                }
            }
        }
    }
}

// MARK: - 编辑器窗口管理（AppKit 面缺口：SwiftUI 行菜单开独立 NSWindow）

/// 编辑器窗打开器（P9/T18）：文件列表行菜单「编辑…」入口。按成片 URL 键控单实例
///（重复「编辑…」前置既有窗，不叠开第二个编辑器编辑同片）；关闭仅隐藏内容释放语义
///（`isReleasedWhenClosed = false` 复用窗口惯例），willClose 时停播/摘观察器并摘出
/// 登记表——再开即全新模型（草稿已即时落盘，无状态丢失）。LSUIElement 激活前置同
/// 文件列表窗（`openRecordingList`）惯例。
@MainActor
enum ZoomEditorWindowOpener {
    private static var controllers: [URL: NSWindowController] = [:]
    private static var closeObservers: [URL: NSObjectProtocol] = [:]

    // MARK: 键盘路由（剪映对齐·批次 1；SwiftUI 控件激活存活但键盘层不可依赖——本窗口
    // 族病理；本地 keyDown 监听按「key 窗 = 编辑器窗」路由到对应模型，文本编辑中放行）
    /// 监听器与路由表跨 actor 缝：`addLocalMonitorForEvents(matching: .keyDown)` 恒主
    /// 线程投递（文档契约），nonisolated(unsafe) 静态仅作线程契约载体；动作一律 Task hop
    /// 回主 actor 执行。键按下时同步返回 nil 吞键（异步 hop 不影响吞键决策）。
    nonisolated(unsafe) private static var keyMonitor: Any?
    nonisolated(unsafe) private static var keyTargets: [ObjectIdentifier: ZoomEditorModel] = [:]

    private static func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window = event.window, window === NSApp.keyWindow,
                  let model = keyTargets[ObjectIdentifier(window)] else { return event }
            if window.firstResponder is NSTextView { return event } // 文本编辑中不劫持
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch event.keyCode {
            case 49 where mods.isEmpty: // 空格 = 播放/暂停
                Task { @MainActor in model.togglePlay() }
                return nil
            case 123 where mods == .shift: // ⇧← = 后退 1s
                Task { @MainActor in model.stepSeconds(-1) }
                return nil
            case 123 where mods.isEmpty: // ← = 后退 1 帧
                Task { @MainActor in model.stepFrames(-1) }
                return nil
            case 124 where mods == .shift: // ⇧→ = 前进 1s
                Task { @MainActor in model.stepSeconds(1) }
                return nil
            case 124 where mods.isEmpty: // → = 前进 1 帧
                Task { @MainActor in model.stepFrames(1) }
                return nil
            case 115 where mods.isEmpty: // Home = 跳到片头
                Task { @MainActor in model.seek(to: 0) }
                return nil
            case 119 where mods.isEmpty: // End = 跳到片尾
                Task { @MainActor in model.seek(to: model.sourceDuration) }
                return nil
            case 6 where mods.contains(.command): // ⌘Z / ⇧⌘Z = 撤销/重做
                let isRedo = mods.contains(.shift)
                Task { @MainActor in isRedo ? model.redo() : model.undo() }
                return nil
            case 11 where mods == .command: // ⌘B = 播放头处分割
                Task { @MainActor in model.splitAtPlayhead() }
                return nil
            case 17 where mods == [.command, .shift]: // ⇧⌘T = 循环最近接缝转场
                Task { @MainActor in _ = model.cycleTransitionNearPlayhead() }
                return nil
            default:
                return event
            }
        }
    }

    static func open(for item: RecordingFileMetadata, viewModel: RecordingListViewModel) {
        if let existing = controllers[item.url] {
            NSApp.activate(ignoringOtherApps: true)
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let model = ZoomEditorModel(item: item, listViewModel: viewModel)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(format: NSLocalizedString("编辑 — %@", comment: "Editor window title"), item.name)
        // 剪映 02.png 复刻：整窗深色观感（面板/检查器/时间线同一色阶）
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ZoomEditorView(model: model, viewModel: viewModel))
        window.center()
        let controller = NSWindowController(window: window)
        controllers[item.url] = controller
        // 键盘路由登记 + 全局监听恰一次安装（多编辑器窗并存按 key 窗分发）。
        keyTargets[ObjectIdentifier(window)] = model
        installKeyMonitorIfNeeded()
        // 关闭登记摘除（NSWindowDelegate 的 Swift 隔离桥接在此工具链不可用——通知惯例，
        // RecordingListWindowController didBecomeKey 同款）：所有隔离状态访问都在
        // `Task { @MainActor }` 内。
        closeObservers[item.url] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak model] _ in
            Task { @MainActor in
                model?.prepareForClose()
                controllers[item.url] = nil
                keyTargets[ObjectIdentifier(window)] = nil
                if let observer = closeObservers[item.url] {
                    NotificationCenter.default.removeObserver(observer)
                    closeObservers[item.url] = nil
                }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}
