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
    /// 源片播放器（AVPlayer 预览真源——时间线播放头由其 periodic 观察器驱动）。
    let player: AVPlayer
    private let listViewModel: RecordingListViewModel
    private var timeObserver: Any?

    /// 分段表（已过 validate：有序、档位/中心合法、无重叠）——唯一写入口是 `applyEdit`。
    @Published private(set) var segments: [ZoomSegment] = []
    /// 选中段下标（行点击/时间线点击选中；validate 重排后按编辑后段值回找）。
    @Published var selectedIndex: Int?
    /// 播放头（成片时间轴秒；periodic 观察器 0.25s 步进）。
    @Published private(set) var playhead: TimeInterval = 0
    @Published private(set) var isPlaying = false
    /// 源时长（`.task` 异步补齐；0 = 未就绪——时间线比例尺/预估大小就绪前显示占位）。
    @Published private(set) var sourceDuration: TimeInterval = 0
    /// 拖端点期间的实时预览（未落库；`onEnded` 才经统一闸 commit——拖拽中不逐 tick 写盘）。
    @Published var dragPreview: DragPreview?

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
        segments = listViewModel.loadDraft(for: item) // 开窗即续上次草稿（无草稿 = 空表新编辑）
        mountTimeObserver()
    }

    /// 源时长补齐（视图 `.task` 调用）：时间线比例尺 + 预估大小 + 新增段贴界的数据面。
    func loadMediaInfo() async {
        let seconds = try? await AVURLAsset(url: item.url).load(.duration).seconds
        guard let seconds, seconds.isFinite, seconds > 0 else { return }
        sourceDuration = seconds
    }

    /// 关窗清理（窗口 opener 的 willClose 通知调用）：停播 + 摘除 periodic 观察器
    ///（草稿已随每次编辑即时落盘，关窗无额外持久化动作）。
    func prepareForClose() {
        player.pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    // MARK: 播放控制

    func togglePlay() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func seek(to time: TimeInterval) {
        let clamped = sourceDuration > 0 ? min(max(0, time), sourceDuration) : max(0, time)
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        playhead = clamped // seek 完成前的即时反馈（观察器随后校准）
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

    /// 时间线上第 `index` 段的显示区间（拖拽预览优先——预览未落库，仅供绘制）。
    func displayedRange(at index: Int) -> (start: TimeInterval, end: TimeInterval) {
        guard segments.indices.contains(index) else { return (0, 0) }
        if let preview = dragPreview, preview.index == index {
            return (preview.start, preview.end)
        }
        return (segments[index].start, segments[index].end)
    }

    /// 预估导出大小展示文案（源码率 × 源时长 × 编码系数；未就绪/退化 → 「—」）。
    var estimatedSizeText: String {
        let bytes = ZoomEditorLogic.estimatedExportBytes(
            sourceSizeBytes: item.sizeBytes, sourceDuration: sourceDuration, codec: codec)
        guard bytes > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var exportOptions: ExportVideoOptions {
        ExportVideoOptions(fps: fpsChoice.fps, maxHeight: heightChoice.maxHeight, codec: codec)
    }

    /// 开始导出（编辑器「开始导出」按钮）：编排经列表模型（单飞门/进度 hop/通知/入列
    /// 在 `renderZoom`）；窗口保持开启，进度条展示渲染进度。
    func export() {
        Task { await listViewModel.renderZoom(item, segments: segments, options: exportOptions) }
    }

    /// 统一闸执行点：修改 → validate → 落库 → 草稿即时存盘（try? 尽力而为——草稿是
    /// 便利持久化，写失败不阻断编辑，失败形态归真机验收观察）。
    private func applyEdit(_ edit: (inout [ZoomSegment]) -> Void) {
        segments = ZoomEditorLogic.applyEdit(segments, edit: edit)
        try? listViewModel.saveDraft(segments, for: item)
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
                self.playhead = time.seconds
                self.isPlaying = self.player.timeControlStatus == .playing
            }
        }
    }
}

// MARK: - 时间线窗视图（P9/T18）

/// 时间线窗（brief Produces）：AVPlayer 预览 + 播放/时间行 + 时间线条（分段块、拖入出点、
/// 播放头、点击跳播）+ 分段列表（增/选/调档位/删）+ 九宫格中心 + 导出参数（fps/分辨率/
/// 编码）+ 预估大小 + 渲染进度。SwiftUI 工具链限制沿用一期教训（Table/toolbar 不可用
/// ——contextMenu/safeAreaInset 惯例），列表用手写行不用 Table。
///
/// 预览实现裁定：`AVKit.VideoPlayer`（SwiftUI 原生、macOS 12+，本 floor 13 直接可用），
/// 不用 NSViewRepresentable 包 `AVPlayerView`——一期教训的坑都集中在 AppKit↔SwiftUI
/// 桥接边界（Table 泛型推断/toolbar 不渲染）；且 AVPlayerView 自带传输控件与时间线窗
/// 自带的播放控制/播放头重复，Representable 还需额外 delegate/清理面。裁切（裁剪/拼接/
/// 多轨）不做（spec §5 P9 非目标）。
struct ZoomEditorView: View {
    @ObservedObject var model: ZoomEditorModel
    @ObservedObject var viewModel: RecordingListViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VideoPlayer(player: model.player)
                .frame(minHeight: 220, maxHeight: 300)
                .frame(maxWidth: .infinity)
            playControlRow
            TimelineStrip(model: model)
            segmentSection
            selectedSegmentSection
            Divider()
            exportSection
        }
        .padding(16)
        .frame(width: 720)
        .task { await model.loadMediaInfo() }
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
            Text("\(model.playhead, specifier: "%.1f")s / \(model.sourceDuration, specifier: "%.1f")s")
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Button("在播放头添加分段") {
                model.addSegment(at: model.playhead)
            }
        }
    }

    // MARK: 分段列表（增/选/调档位/删；Table 不可用——手写行 + contextMenu）

    @ViewBuilder
    private var segmentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("缩放分段").font(.headline)
            if model.segments.isEmpty {
                Text("暂无分段——播放到目标位置后点「在播放头添加分段」，或在时间线上拖段块两端调整入出点。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 4) {
                    ForEach(model.segments.indices, id: \.self) { index in
                        segmentRow(index: index)
                    }
                }
            }
        }
    }

    private func segmentRow(index: Int) -> some View {
        let segment = model.segments[index]
        return HStack(spacing: 12) {
            Text("段 \(index + 1)")
                .frame(width: 40, alignment: .leading)
            Text(String(format: "%.2fs – %.2fs", segment.start, segment.end))
                .font(.system(.body, design: .monospaced))
                .frame(width: 128, alignment: .leading)
            Picker("档位", selection: levelBinding(index: index)) {
                ForEach(ZoomSegment.levels, id: \.self) { level in
                    Text(String(format: "%.2fx", level)).tag(level)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 96)
            Spacer()
            Button {
                model.removeSegment(at: index)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除分段")
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(
            (index == model.selectedIndex ? Color.accentColor.opacity(0.15) : Color.clear)
                .cornerRadius(4))
        .contentShape(Rectangle())
        .onTapGesture { model.selectedIndex = index }
        .contextMenu {
            Button("删除分段") {
                model.removeSegment(at: index)
            }
        }
    }

    /// 档位绑定：读当前值、写经统一闸（`setLevel` → applyEdit）——直绑段值会绕过 validate。
    private func levelBinding(index: Int) -> Binding<Double> {
        Binding(
            get: { model.segments.indices.contains(index) ? model.segments[index].level : ZoomSegment.levels[1] },
            set: { model.setLevel(at: index, level: $0) })
    }

    // MARK: 选中段细节（九宫格中心）

    @ViewBuilder
    private var selectedSegmentSection: some View {
        if let index = model.selectedIndex, model.segments.indices.contains(index) {
            HStack(alignment: .top, spacing: 16) {
                NinePatchGrid(currentCenter: model.segments[index].center) { row, column in
                    model.setCenter(atIndex: index, ninePatchRow: row, column: column)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("缩放中心（九宫格）").font(.subheadline)
                    Text("点选九宫格设定「段 \(index + 1)」的缩放中心；与点击自动缩放同一画面口径（格中心 ±1/6 归一化）。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    // MARK: 导出参数 + 预估 + 进度

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("导出").font(.headline)
            Text("输出：\(viewModel.suggestedZoomedDestinationName(for: model.item))（与源同目录）")
                .font(.footnote)
                .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
            }
            progressArea
            HStack {
                Spacer()
                Button("开始导出") {
                    model.export()
                }
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
                Text("正在渲染缩放成片…\(Int((progress * 100).rounded()))%")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
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
                                      ? Color.accentColor
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

/// 时间线条（比例尺 = 条宽 / 源时长；源时长未就绪前退化为最小比例尺）：
/// 分段块（选中高亮 + 缓入/缓出窗口淡色端帽——窗口常量引用 `OfflineZoomRenderer`
/// 单一真源，短段不画端帽的收敛语义真源在 `zoomProgress`，此处仅为视觉近似）；
/// 段块两端白色把手拖入出点（拖拽中实时预览、松手经统一闸 commit）；背景点击跳播；
/// 播放头竖线。
private struct TimelineStrip: View {
    @ObservedObject var model: ZoomEditorModel

    var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / max(model.sourceDuration, 0.001)
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.quaternary)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                        model.seek(to: value.location.x / scale)
                    })
                ForEach(model.segments.indices, id: \.self) { index in
                    segmentView(index: index, scale: scale, height: geometry.size.height)
                }
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 1.5, height: geometry.size.height)
                    .offset(x: min(max(model.playhead * scale, 0), geometry.size.width - 1.5))
            }
        }
        .frame(height: 64)
    }

    @ViewBuilder
    private func segmentView(index: Int, scale: CGFloat, height: CGFloat) -> some View {
        let range = model.displayedRange(at: index)
        let x = max(range.start * scale, 0)
        let width = max((range.end - range.start) * scale, 2)
        let isSelected = index == model.selectedIndex
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(isSelected ? Color.accentColor.opacity(0.55) : Color.accentColor.opacity(0.3))
            HStack(spacing: 0) {
                edgeHandle(index: index, scale: scale, isLeading: true)
                Spacer(minLength: 0)
                edgeHandle(index: index, scale: scale, isLeading: false)
            }
            easingCaps(range: range, scale: scale)
        }
        .frame(width: width, height: height - 8)
        .offset(x: x, y: 4)
        .onTapGesture { model.selectedIndex = index }
        .contextMenu {
            Button("删除分段") {
                model.removeSegment(at: index)
            }
        }
    }

    /// 缓入/缓出窗口端帽（淡色）：仅长段绘制（段长 > 缓入 + 缓出窗时窗口不收敛，
    /// 端帽语义与 `zoomProgress` 一致；短段收敛形态不画，避免在 UI 复制收敛公式）。
    @ViewBuilder
    private func easingCaps(range: (start: TimeInterval, end: TimeInterval), scale: CGFloat) -> some View {
        if range.end - range.start > OfflineZoomRenderer.easingInWindow + OfflineZoomRenderer.easingOutWindow {
            HStack(spacing: 0) {
                Rectangle().fill(Color.white.opacity(0.35))
                    .frame(width: min(OfflineZoomRenderer.easingInWindow * scale, 24))
                Spacer(minLength: 0)
                Rectangle().fill(Color.white.opacity(0.35))
                    .frame(width: min(OfflineZoomRenderer.easingOutWindow * scale, 24))
            }
        }
    }

    /// 端点把手（入点/出点拖拽）：拖拽中写 `dragPreview`（实时预览未落库），松手经
    /// `commitDrag`（钳邻居边界 + 统一闸 validate + 存草稿）。
    private func edgeHandle(index: Int, scale: CGFloat, isLeading: Bool) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.75))
            .frame(width: 8)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    guard model.segments.indices.contains(index) else { return }
                    let original = model.segments[index]
                    let delta = value.translation.width / scale
                    model.dragPreview = ZoomEditorModel.DragPreview(
                        index: index,
                        start: isLeading ? original.start + delta : original.start,
                        end: isLeading ? original.end : original.end + delta)
                }
                .onEnded { _ in
                    if let preview = model.dragPreview {
                        model.commitDrag(index: preview.index, start: preview.start, end: preview.end)
                    }
                    model.dragPreview = nil
                })
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

    static func open(for item: RecordingFileMetadata, viewModel: RecordingListViewModel) {
        if let existing = controllers[item.url] {
            NSApp.activate(ignoringOtherApps: true)
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let model = ZoomEditorModel(item: item, listViewModel: viewModel)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "编辑 — \(item.name)"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ZoomEditorView(model: model, viewModel: viewModel))
        window.center()
        let controller = NSWindowController(window: window)
        controllers[item.url] = controller
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
