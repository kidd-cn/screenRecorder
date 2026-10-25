import AppKit
import AVFoundation
import Foundation

/// 文件列表窗口（Task 18）消费的列表模型：refresh 拉取目录 + 异步补齐时长，delete/rename 同步磁盘与 items。
@MainActor
final class RecordingListViewModel: ObservableObject {
    @Published var items: [RecordingFileMetadata] = []

    private let store: RecordingFileStore
    private let durationProvider: (URL) async throws -> TimeInterval?

    /// 默认实现放闭包便于测试注入（真实实现仅在生产使用，测试注入假 .mp4 也能拿到时长）。
    /// 参数为 throwing：AVAsset.load(.duration) 可抛（损坏/不可读文件），refresh 侧以 try? 归一为 nil。
    init(
        store: RecordingFileStore,
        durationProvider: @escaping (URL) async throws -> TimeInterval? = { try await AVURLAsset(url: $0).load(.duration).seconds }
    ) {
        self.store = store
        self.durationProvider = durationProvider
    }

    /// 重新扫描目录并补齐每条时长；读取失败按 nil 处理。
    func refresh() async {
        var current = store.contents()
        for index in current.indices {
            current[index].duration = try? await durationProvider(current[index].url)
        }
        items = current
    }

    /// 删除磁盘文件并同步移除列表项；删除失败以 refresh 复核。
    func delete(_ item: RecordingFileMetadata) {
        store.delete(item.url)
        items.removeAll { $0.id == item.id }
    }

    func rename(_ item: RecordingFileMetadata, to: String) async throws {
        try store.rename(item.url, toName: to)
        await refresh()
    }

    /// 在 Finder 中定位并选中该文件。
    func revealInFinder(_ item: RecordingFileMetadata) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }
}
