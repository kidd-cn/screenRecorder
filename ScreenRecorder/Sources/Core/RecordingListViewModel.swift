import AppKit
import AVFoundation
import Foundation

/// 导出服务缝（P8/T16，编排层注入面）：ExportCore 为 enum 静态函数面不可替换——VM
/// 编排经此缝注入假实现做无头测试（进度 hop / 失败通知 / 建议名三钉点直达）。生产默认
/// 实现 `ExportCoreService` 原样转发 T15 静态函数；消费契约（ExportCore 钉定）：进度
/// 0…1 单调不减、终值恰一次、主线程外调用（UI 侧自行 hop），输出命名冲突惯例在
/// ExportCore 命名助手内。
protocol ExportServing {
    func exportGIF(
        from url: URL, options: GIFExportOptions, progress: @escaping (Double) -> Void
    ) async throws -> URL

    func compress(
        from url: URL, preset: CompressionPreset, progress: @escaping (Double) -> Void
    ) async throws -> URL
}

/// 缩放渲染缝（P9/T18）：OfflineZoomRenderer 为 enum 静态函数面不可替换——编辑器编排
/// 经此缝注入假实现做无头测试（ExportServing 同纪律）。消费契约（T17 钉定）：进度
/// 0…1 严格递增、终值恰一次、主线程外调用（UI/编排侧自行 hop）。
protocol ZoomRendering {
    func render(
        sourceURL: URL, segments: [ZoomSegment], options: ExportVideoOptions,
        progress: @escaping (Double) -> Void
    ) async throws -> URL
}

/// `ZoomRendering` 生产实现：直调 OfflineZoomRenderer 静态函数（T17 消费契约零损耗转发）。
struct OfflineZoomRendererService: ZoomRendering {
    func render(
        sourceURL: URL, segments: [ZoomSegment], options: ExportVideoOptions,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        try await OfflineZoomRenderer.render(
            sourceURL: sourceURL, segments: segments, options: options, progress: progress)
    }
}

/// `ExportServing` 生产实现：直调 ExportCore 静态函数（T15 消费契约零损耗转发）。
struct ExportCoreService: ExportServing {
    func exportGIF(
        from url: URL, options: GIFExportOptions, progress: @escaping (Double) -> Void
    ) async throws -> URL {
        try await ExportCore.exportGIF(from: url, options: options, progress: progress)
    }

    func compress(
        from url: URL, preset: CompressionPreset, progress: @escaping (Double) -> Void
    ) async throws -> URL {
        try await ExportCore.compress(from: url, preset: preset, progress: progress)
    }
}

/// 导出通知缝（P8/T16）：完成/失败通知出口。生产实现接 `UNRecordingNotifier`（App 层
/// extension，T11 新通知类型进 notifier 先例）；测试注入 spy——UNUserNotificationCenter
/// 在无头测试进程不可用，必须可替换（同 `RecordingNotifying` 缝纪律）。通知是尽力而为
/// 的副通道，成片落盘才是主契约。
@MainActor
protocol ExportNotifying: AnyObject {
    func notifyExportCompleted(fileURL: URL)
    func notifyExportFailed(message: String)
}

/// 文件列表窗口（Task 18）消费的列表模型：refresh 拉取目录 + 异步补齐时长，delete/rename
/// 同步磁盘与 items；P8 起承载导出编排（调 ExportCore、进度转发主线程、错误以通知呈现）。
///
/// store 取数缝（T17 审查发现修复，本任务落实）：视图模型不持有 store 结构体固定拷贝——
/// 偏好设置换输出目录后装配层整只换装 `fileStore`（`updateOutputDirectory`）并同步换入
/// 控制器，固定拷贝会静默读旧目录。refresh/delete/rename 时刻经 `storeProvider` 取
/// 当前 store，列表与装配层永远一致。
@MainActor
final class RecordingListViewModel: ObservableObject {
    @Published var items: [RecordingFileMetadata] = []

    /// 进行中导出的进度（P8，GIF/压缩小窗进度条消费）：nil = 空闲；0…1 = 进行中。
    /// ExportCore 回调在主线程外（T15 契约）——写路径一律经 `runExport` 的 @MainActor hop。
    @Published private(set) var exportProgress: Double?

    /// 进行中缩放渲染的进度（T18，编辑器小窗进度条消费）：nil = 空闲；0…1 = 进行中。
    /// OfflineZoomRenderer 回调在主线程外（T17 契约）——写路径一律经 `renderZoom`
    /// 的 @MainActor hop。与 `exportProgress` 相互独立（GIF/压缩与缩放渲染是两条编排）。
    @Published private(set) var zoomRenderProgress: Double?

    /// 当前 store 取数缝（装配层提供）。
    private let storeProvider: () -> RecordingFileStore
    private let durationProvider: (URL) async throws -> TimeInterval?
    private let exportService: ExportServing
    private let zoomRenderer: ZoomRendering
    private let notifier: ExportNotifying?

    /// 进行中导出代际（非 Published，主 actor 独占）：0 = 空闲，>0 = 单飞进行中；
    /// 同时作进度 hop 的代际校验（见 `runExport`）。
    private var exportRunID = 0

    /// 缩放渲染运行代数（T18，主 actor 独占）：**单调递增、不复用**——只作进度 hop 的
    /// 代际校验（本代结束后晚到的 hop 被丢弃）；T16 `exportRunID` 归位回收形态的已知
    /// 停放缺陷（相邻代语义不成立）在此不复制（controller 对 T18 运行态的立法形态）。
    private var zoomRenderRunID = 0

    /// 缩放渲染单飞忙布尔（T18）：进行中判定只看本布尔，与代数解耦（不复用 0/1 回收）。
    private var zoomRenderInFlight = false

    /// 默认实现放闭包便于测试注入（真实实现仅在生产使用，测试注入假 .mp4 也能拿到时长）。
    /// 参数为 throwing：AVAsset.load(.duration) 可抛（损坏/不可读文件），refresh 侧以 try? 归一为 nil。
    /// 导出/通知/渲染缝缺省生产实现与 nil——既有测试零改动；生产装配显式传 `UNRecordingNotifier`。
    init(
        storeProvider: @escaping () -> RecordingFileStore,
        durationProvider: @escaping (URL) async throws -> TimeInterval? = { try await AVURLAsset(url: $0).load(.duration).seconds },
        exportService: ExportServing = ExportCoreService(),
        notifier: ExportNotifying? = nil,
        zoomRenderer: ZoomRendering = OfflineZoomRendererService()
    ) {
        self.storeProvider = storeProvider
        self.durationProvider = durationProvider
        self.exportService = exportService
        self.notifier = notifier
        self.zoomRenderer = zoomRenderer
    }

    /// 固定 store 便捷构造（既有测试与一次性场景）：取数缝恒返回该 store。
    convenience init(
        store: RecordingFileStore,
        durationProvider: @escaping (URL) async throws -> TimeInterval? = { try await AVURLAsset(url: $0).load(.duration).seconds },
        exportService: ExportServing = ExportCoreService(),
        notifier: ExportNotifying? = nil,
        zoomRenderer: ZoomRendering = OfflineZoomRendererService()
    ) {
        self.init(
            storeProvider: { store }, durationProvider: durationProvider,
            exportService: exportService, notifier: notifier, zoomRenderer: zoomRenderer)
    }

    /// 重新扫描目录并补齐每条时长；读取失败按 nil 处理。store 在调用时刻经缝取当前值
    ///（换输出目录后刷新即见新目录）。
    func refresh() async {
        var current = storeProvider().contents()
        for index in current.indices {
            current[index].duration = try? await durationProvider(current[index].url)
        }
        items = current
    }

    /// 删除磁盘文件并同步移除列表项；删除失败以 refresh 复核。作用于当前 store。
    /// T18：缩放分段草稿（`<成片>.zoomdraft.json`）随成片一并删除——草稿是成片的
    /// 派生物，不留孤儿草稿。
    func delete(_ item: RecordingFileMetadata) {
        storeProvider().delete(item.url)
        try? FileManager.default.removeItem(at: Self.draftURL(for: item.url))
        items.removeAll { $0.id == item.id }
    }

    /// 同目录内重命名并刷新列表；失败（重名/权限等）时错误照抛给视图层做告警，但列表
    /// 同样以 refresh 复核磁盘现状（审查修复轮 1 #4：失败后列表仍与磁盘一致）。作用于
    /// 当前 store。T18：缩放分段草稿随成片更名（成片改名后旧名草稿会成孤儿，永无随删
    /// 机会——移动为尽力而为，移动失败不阻断重命名主流程）。
    func rename(_ item: RecordingFileMetadata, to: String) async throws {
        let oldDraftURL = Self.draftURL(for: item.url)
        do {
            try storeProvider().rename(item.url, toName: to)
        } catch {
            await refresh()
            throw error
        }
        let newDraftURL = Self.draftURL(
            for: storeProvider().baseDirectory.appendingPathComponent(to))
        if FileManager.default.fileExists(atPath: oldDraftURL.path) {
            try? FileManager.default.moveItem(at: oldDraftURL, to: newDraftURL)
        }
        await refresh()
    }

    /// 在 Finder 中定位并选中该文件。
    func revealInFinder(_ item: RecordingFileMetadata) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: - 导出编排（P8）

    /// 建议 GIF 输出名（小窗预填）：`<原名>_gif.gif`；冲突 " (n)" 惯例在 ExportCore
    /// 命名助手（单一事实源，含对真实目录的存在性探测）。
    func suggestedGIFDestinationName(for item: RecordingFileMetadata) -> String {
        ExportCore.gifDestinationURL(for: item.url).lastPathComponent
    }

    /// 建议压缩输出名（小窗预填）：`<原名>_压缩.mp4`（同上单一事实源）。
    func suggestedCompressedDestinationName(for item: RecordingFileMetadata) -> String {
        ExportCore.compressedDestinationURL(for: item.url).lastPathComponent
    }

    /// 导出 GIF（参数档位即 `GIFExportOptions`，UI Picker 只出档位集合不另造档）。
    func exportGIF(_ item: RecordingFileMetadata, options: GIFExportOptions) async {
        await runExport(.gif(url: item.url, options: options))
    }

    /// 压缩导出（参数档位即 `CompressionPreset`）。
    func compress(_ item: RecordingFileMetadata, preset: CompressionPreset) async {
        await runExport(.compress(url: item.url, preset: preset))
    }

    /// 导出计划（编排层私有）：源 + 参数的枚举，`run(_:)` 经缝调 ExportCore 对应入口。
    private enum ExportPlan {
        case gif(url: URL, options: GIFExportOptions)
        case compress(url: URL, preset: CompressionPreset)

        func run(_ service: ExportServing, progress: @escaping (Double) -> Void) async throws -> URL {
            switch self {
            case .gif(let url, let options):
                return try await service.exportGIF(from: url, options: options, progress: progress)
            case .compress(let url, let preset):
                return try await service.compress(from: url, preset: preset, progress: progress)
            }
        }
    }

    /// 导出编排共用主体：单飞门 + 进度 @MainActor hop + 完成/失败通知。
    /// - 单飞：进行中（`exportRunID > 0`）忽略新请求（UI 侧「开始导出」按钮同禁用）；
    /// - 进度 hop：T15 回调主线程外——`@Sendable` 缝闭包（不携带模型 actor 隔离）内
    ///   `Task { @MainActor }` 写 `exportProgress`；`exportRunID` 代际校验丢弃本代结束
    ///   后晚到的 hop（终值 1.0 晚于复位会卡死空闲判定），`max` 保 hop 乱序下仍单调
    ///   （T15 本就单调不减，此处仅护 hop 重排）；
    /// - 失败：ExportError 文案族 errorDescription 完整行透传通知缝（「导出失败：…」）；
    ///   非 ExportError 透出系统本地化描述（重命名失败 NSAlert 同纪律）；
    /// - 成功：完成通知（`notifySaved` 对称文案）。
    private func runExport(_ plan: ExportPlan) async {
        guard exportRunID == 0 else { return }
        exportRunID += 1
        let runID = exportRunID
        exportProgress = 0
        defer {
            exportRunID = 0
            exportProgress = nil
        }

        let forward: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor in
                guard let self, self.exportRunID == runID else { return }
                self.exportProgress = max(self.exportProgress ?? 0, value)
            }
        }
        do {
            let outputURL = try await plan.run(exportService, progress: forward)
            notifier?.notifyExportCompleted(fileURL: outputURL)
        } catch {
            notifier?.notifyExportFailed(
                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: - 缩放分段草稿持久化（P9/T18）

    /// 草稿文件 URL：`<成片>.zoomdraft.json`——**成片全名追加** `.zoomdraft.json` 后缀
    /// （含原扩展名），与成片同目录。字面读法（成片 = 含扩展名的文件）且同名不同扩展的
    /// 成片（`foo.mp4` / `foo.m4a`）草稿互不串档。
    static func draftURL(for movieURL: URL) -> URL {
        movieURL.appendingPathExtension("zoomdraft.json")
    }

    /// 读草稿：`ZoomSegment` JSON 数组；文件缺失/非 JSON 归空表（按无草稿开新编辑，不抛）；
    /// 解码成功仍过 `ZoomSegment.validate`（再**用**前的闸——手改草稿野值在进编辑器前归一）。
    func loadDraft(for item: RecordingFileMetadata) -> [ZoomSegment] {
        guard let data = try? Data(contentsOf: Self.draftURL(for: item.url)),
              let decoded = try? JSONDecoder().decode([ZoomSegment].self, from: data)
        else { return [] }
        return ZoomSegment.validate(decoded)
    }

    /// 写草稿：先过 `ZoomSegment.validate`（**存**前的闸——编辑器统一闸之后的第二道防线，
    /// 幂等）再原子落盘；磁盘失败照抛（调用方编辑器侧尽力而为 `try?`）。
    func saveDraft(_ segments: [ZoomSegment], for item: RecordingFileMetadata) throws {
        let data = try JSONEncoder().encode(ZoomSegment.validate(segments))
        try data.write(to: Self.draftURL(for: item.url), options: [.atomic])
    }

    // MARK: - 缩放渲染编排（P9/T18）

    /// 建议缩放导出名（编辑器小窗预填）：`<原名>_缩放.mp4`；冲突 " (n)" 惯例在
    /// OfflineZoomRenderer 命名助手（T17 单一事实源，含对真实目录的存在性探测）。
    func suggestedZoomedDestinationName(for item: RecordingFileMetadata) -> String {
        OfflineZoomRenderer.zoomedDestinationURL(for: item.url).lastPathComponent
    }

    /// 缩放渲染编排（编辑器「开始导出」）：单飞门 + 进度 @MainActor hop + 编排边界
    /// validate + 完成/失败通知 + 成功后自动入列。
    /// - 单飞（T18 立法形态）：进行中（`zoomRenderInFlight`）忽略新请求；代数
    ///   `zoomRenderRunID` 单调递增不复用（T16 exportRunID 回收停放缺陷不复制）；
    /// - validate：编辑器统一闸已过 validate，编排边界再过一道（幂等）——渲染缝的
    ///   「**用**」前置闸不依赖调用方自律；
    /// - 进度 hop：T17 回调主线程外且严格递增——`@Sendable` 缝闭包内 `Task { @MainActor }`
    ///   写 `zoomRenderProgress`，代际校验丢晚到 hop，`max` 护 hop 重排（runExport 同款）；
    /// - 成功：先 refresh（自动入列——按 `_压缩.mp4` 先例，T18 默认裁定）再完成通知；
    ///   失败：errorDescription 透传通知缝（runExport 同纪律）。注意 GIF/压缩编排
    ///   （`runExport`）未反向门本入口——缩放渲染与其并发无害（冲突命名 + 独立通知面），
    ///   见任务报告停放项。
    func renderZoom(_ item: RecordingFileMetadata, segments: [ZoomSegment],
                    options: ExportVideoOptions) async {
        guard !zoomRenderInFlight else { return }
        zoomRenderInFlight = true
        zoomRenderRunID += 1
        let runID = zoomRenderRunID
        zoomRenderProgress = 0
        defer {
            zoomRenderInFlight = false
            zoomRenderProgress = nil
        }

        let forward: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor in
                guard let self, self.zoomRenderRunID == runID else { return }
                self.zoomRenderProgress = max(self.zoomRenderProgress ?? 0, value)
            }
        }
        do {
            let outputURL = try await zoomRenderer.render(
                sourceURL: item.url, segments: ZoomSegment.validate(segments),
                options: options, progress: forward)
            await refresh() // 自动入列（成功产物立即可见；_压缩.mp4 先例）
            notifier?.notifyExportCompleted(fileURL: outputURL)
        } catch {
            notifier?.notifyExportFailed(
                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
