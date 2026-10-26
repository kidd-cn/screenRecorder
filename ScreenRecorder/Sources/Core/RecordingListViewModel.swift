import AppKit
import AVFoundation
import Foundation

/// 文件列表窗口（Task 18）消费的列表模型：refresh 拉取目录 + 异步补齐时长，delete/rename
/// 同步磁盘与 items。
///
/// store 取数缝（T17 审查发现修复，本任务落实）：视图模型不持有 store 结构体固定拷贝——
/// 偏好设置换输出目录后装配层整只换装 `fileStore`（`updateOutputDirectory`）并同步换入
/// 控制器，固定拷贝会静默读旧目录。refresh/delete/rename 时刻经 `storeProvider` 取
/// 当前 store，列表与装配层永远一致。
@MainActor
final class RecordingListViewModel: ObservableObject {
    @Published var items: [RecordingFileMetadata] = []

    /// 当前 store 取数缝（装配层提供）。
    private let storeProvider: () -> RecordingFileStore
    private let durationProvider: (URL) async throws -> TimeInterval?

    /// 默认实现放闭包便于测试注入（真实实现仅在生产使用，测试注入假 .mp4 也能拿到时长）。
    /// 参数为 throwing：AVAsset.load(.duration) 可抛（损坏/不可读文件），refresh 侧以 try? 归一为 nil。
    init(
        storeProvider: @escaping () -> RecordingFileStore,
        durationProvider: @escaping (URL) async throws -> TimeInterval? = { try await AVURLAsset(url: $0).load(.duration).seconds }
    ) {
        self.storeProvider = storeProvider
        self.durationProvider = durationProvider
    }

    /// 固定 store 便捷构造（既有测试与一次性场景）：取数缝恒返回该 store。
    convenience init(
        store: RecordingFileStore,
        durationProvider: @escaping (URL) async throws -> TimeInterval? = { try await AVURLAsset(url: $0).load(.duration).seconds }
    ) {
        self.init(storeProvider: { store }, durationProvider: durationProvider)
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
    func delete(_ item: RecordingFileMetadata) {
        storeProvider().delete(item.url)
        items.removeAll { $0.id == item.id }
    }

    /// 同目录内重命名并刷新列表。作用于当前 store。
    func rename(_ item: RecordingFileMetadata, to: String) async throws {
        try storeProvider().rename(item.url, toName: to)
        await refresh()
    }

    /// 在 Finder 中定位并选中该文件。
    func revealInFinder(_ item: RecordingFileMetadata) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }
}
