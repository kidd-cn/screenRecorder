import Combine
import XCTest

@testable import ScreenRecorder

@MainActor
final class RecordingListViewModelTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingListViewModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    private func writeFakeRecordings() throws {
        try Data().write(to: directory.appendingPathComponent("录屏_2026-10-25_09-00-00.mp4"))
        try Data().write(to: directory.appendingPathComponent("录屏_2026-10-25_10-00-00.mp4"))
    }

    private func makeViewModel() -> RecordingListViewModel {
        RecordingListViewModel(
            store: RecordingFileStore(baseDirectory: directory),
            durationProvider: { _ in 42.0 }
        )
    }

    func testRefreshPopulatesItemsWithInjectedDurations() async throws {
        try writeFakeRecordings()
        let vm = makeViewModel()
        XCTAssertEqual(vm.items, [])

        await vm.refresh()

        XCTAssertEqual(vm.items.count, 2)
        XCTAssertEqual(vm.items.map(\.duration), [42.0, 42.0])
    }

    func testDeleteRemovesItemFromContents() async throws {
        try writeFakeRecordings()
        let vm = makeViewModel()
        await vm.refresh()
        XCTAssertEqual(vm.items.count, 2)

        vm.delete(vm.items[0])

        XCTAssertEqual(vm.items.count, 1)
    }

    func testDeleteReflectsInStoreContents() async throws {
        try writeFakeRecordings()
        let store = RecordingFileStore(baseDirectory: directory)
        let vm = RecordingListViewModel(store: store, durationProvider: { _ in 42.0 })
        await vm.refresh()

        vm.delete(vm.items[0])

        XCTAssertEqual(store.contents().count, 1)
    }

    // MARK: - T17 审查发现修复（T18 落实）：store 取数缝在 refresh/delete 时刻读当前 store

    /// 固定 store 拷贝会在「偏好设置换输出目录」后静默读旧目录——模型必须经
    /// `storeProvider` 缝在每次 refresh/delete 时取装配层当前 store。
    func testStoreProviderIsReadAtRefreshTimeTracksDirectoryChange() async throws {
        let dirA = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingListViewModelTests-A-\(UUID().uuidString)", isDirectory: true)
        let dirB = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingListViewModelTests-B-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }
        try Data().write(to: dirA.appendingPathComponent("录屏_2026-10-25_09-00-00.mp4"))
        try Data().write(to: dirB.appendingPathComponent("录屏_2026-10-26_10-00-00.mp4"))
        try Data().write(to: dirB.appendingPathComponent("录屏_2026-10-26_11-00-00.mp4"))

        let box = StoreBox(store: RecordingFileStore(baseDirectory: dirA))
        let vm = RecordingListViewModel(
            storeProvider: { [box] in box.store },
            durationProvider: { _ in 1.0 })
        await vm.refresh()
        XCTAssertEqual(vm.items.count, 1, "初始 provider 指向 A：只见 A 目录文件")

        box.store = RecordingFileStore(baseDirectory: dirB) // 装配层换装输出目录
        await vm.refresh()
        XCTAssertEqual(vm.items.count, 2, "换目录后 refresh 必须读新目录（固定拷贝会静默读旧）")

        vm.delete(vm.items[0])
        XCTAssertEqual(RecordingFileStore(baseDirectory: dirB).contents().count, 1, "delete 同样作用于当前 store")
        XCTAssertEqual(RecordingFileStore(baseDirectory: dirA).contents().count, 1, "旧目录不得被误删")
    }

    /// 审查修复轮 1 #4：rename 抛错（重名/权限等）时错误照抛（视图层据此告警），但列表
    /// 仍以 refresh 复核磁盘——失败路径不吞掉磁盘现状。
    func testRenameFailureStillRefreshesItemsFromDisk() async throws {
        try writeFakeRecordings()
        let store = RecordingFileStore(baseDirectory: directory)
        let vm = RecordingListViewModel(store: store, durationProvider: { _ in 1.0 })
        await vm.refresh()
        XCTAssertEqual(vm.items.count, 2)
        // 刷新后磁盘上多出的新文件：列表此刻尚不可见
        try Data().write(to: directory.appendingPathComponent("录屏_2026-10-25_11-00-00.mp4"))

        // 重名冲突：items[1]（09-00-00）改名为已存在的 10-00-00 → fileWriteFileExists
        do {
            try await vm.rename(vm.items[1], to: "录屏_2026-10-25_10-00-00.mp4")
            XCTFail("重名重命名应抛错")
        } catch {
            XCTAssertTrue(error is CocoaError, "重名冲突应为 CocoaError：\(error)")
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteFileExists)
        }

        XCTAssertEqual(vm.items.count, 3, "失败后 refresh 复核磁盘：新文件应出现在列表")
        XCTAssertEqual(vm.items.first?.name, "录屏_2026-10-25_11-00-00.mp4")
    }

    /// 可换装的 store 容器（模拟装配层 updateOutputDirectory 换装点）。
    private final class StoreBox: @unchecked Sendable {
        var store: RecordingFileStore
        init(store: RecordingFileStore) { self.store = store }
    }

    // MARK: - P8 导出编排（T16）：ExportServing/ExportNotifying 缝无头直达

    /// 可注入导出缝与通知缝的模型构造（既有 makeViewModel 保持缺省缝零改动）。
    private func makeViewModel(
        exportService: ExportServing,
        notifier: ExportNotifying?
    ) -> RecordingListViewModel {
        RecordingListViewModel(
            store: RecordingFileStore(baseDirectory: directory),
            durationProvider: { _ in 42.0 },
            exportService: exportService,
            notifier: notifier)
    }

    private func makeItem(named name: String) -> RecordingFileMetadata {
        RecordingFileMetadata(
            id: directory.appendingPathComponent(name),
            url: directory.appendingPathComponent(name),
            name: name,
            sizeBytes: 0,
            createdAt: nil,
            duration: nil)
    }

    /// T15 契约「进度回调主线程外调用」→ 模型转发必须 @MainActor hop。判别面：`@Published`
    /// 的 Combine sink 在写入线程同步触发——全部非 nil 投递必须带 `Thread.isMainThread`。
    func testExportProgressHopsToMain() async throws {
        let vm = makeViewModel(exportService: OffMainProgressExporter(), notifier: nil)

        var deliveries: [(value: Double, onMain: Bool)] = []
        let offMainValueDelivered = expectation(description: "假缝主线程外推送的 0.42 送达主线程")
        let cancellable = vm.$exportProgress.sink { value in
            guard let value else { return } // 完成复位(nil)不计
            deliveries.append((value, Thread.isMainThread))
            if value == 0.42 { offMainValueDelivered.fulfill() }
        }
        defer { cancellable.cancel() }

        await vm.exportGIF(makeItem(named: "录屏_2026-10-25_09-00-00.mp4"), options: GIFExportOptions())
        await fulfillment(of: [offMainValueDelivered], timeout: 5)

        XCTAssertEqual(deliveries.map(\.value), [0.0, 0.42], "进度序列：模型置 0 + 假缝主线程外推送的 0.42")
        XCTAssertTrue(
            deliveries.allSatisfy(\.onMain),
            "全部进度投递必须发生在主线程（T15 主线程外回调 → VM hop 契约）：\(deliveries)")
        XCTAssertNil(vm.exportProgress, "导出完成后进度复位空闲")
    }

    /// 假缝抛错（T15 ExportError 文案族）→ 失败必须以通知呈现（errorDescription 原样
    /// 透传），不发完成通知，进度复位空闲。
    func testExportFailureSurfacesNotification() async throws {
        let spy = SpyExportNotifier()
        let vm = makeViewModel(
            exportService: ThrowingExporter(error: ExportError.gifEncodingFailed),
            notifier: spy)
        let item = makeItem(named: "录屏_2026-10-25_09-00-00.mp4")

        await vm.exportGIF(item, options: GIFExportOptions())

        XCTAssertEqual(
            spy.failureMessages,
            ["导出失败：GIF 编码失败，请重试"],
            "失败必须以通知呈现（ExportError errorDescription 原样透传）")
        XCTAssertTrue(spy.completedURLs.isEmpty, "失败路径不得发完成通知")
        XCTAssertNil(vm.exportProgress, "失败后进度复位空闲")
    }

    /// 建议输出名（小窗预填）：`<原名>_gif.gif` 形（brief 钉定）；冲突沿用扩展名前
    /// " (n)" 自 2 递增惯例（复用 ExportCore 命名助手——单一事实源）；压缩为
    /// `<原名>_压缩.mp4`。
    func testExportSuggestedDestinationName() async throws {
        let vm = makeViewModel()
        let item = makeItem(named: "录屏_2026-10-25_09-00-00.mp4")

        XCTAssertEqual(vm.suggestedGIFDestinationName(for: item), "录屏_2026-10-25_09-00-00_gif.gif")

        try Data().write(to: directory.appendingPathComponent("录屏_2026-10-25_09-00-00_gif.gif"))
        XCTAssertEqual(
            vm.suggestedGIFDestinationName(for: item),
            "录屏_2026-10-25_09-00-00_gif (2).gif",
            "冲突沿用 \" (n)\" 惯例")

        XCTAssertEqual(
            vm.suggestedCompressedDestinationName(for: item),
            "录屏_2026-10-25_09-00-00_压缩.mp4")
    }
}

// MARK: - P8 导出编排测试替身（T16）：ExportCore 为 enum 静态面不可替换，经缝注入假实现

/// 主线程外推送进度的假导出服务：模拟 T15 契约「进度回调在主线程外」；返回前自身
/// hop 主线程一次——VM 续体晚于进度 hop 入队（主队列 FIFO），hop 必先执行，断言不受
/// 「晚到 hop 被代际校验丢弃」竞态干扰。
private final class OffMainProgressExporter: ExportServing {
    func exportGIF(
        from url: URL, options: GIFExportOptions, progress: @escaping (Double) -> Void
    ) async throws -> URL {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                progress(0.42)
                continuation.resume()
            }
        }
        await MainActor.run {}
        return url
    }

    func compress(
        from url: URL, preset: CompressionPreset, progress: @escaping (Double) -> Void
    ) async throws -> URL {
        url
    }
}

/// 恒抛错的假导出服务：失败路径无头直达。
private struct ThrowingExporter: ExportServing {
    let error: Error

    func exportGIF(
        from url: URL, options: GIFExportOptions, progress: @escaping (Double) -> Void
    ) async throws -> URL {
        throw error
    }

    func compress(
        from url: URL, preset: CompressionPreset, progress: @escaping (Double) -> Void
    ) async throws -> URL {
        throw error
    }
}

/// ExportNotifying spy：收集导出完成/失败通知供断言（同 CaptureControllerTests SpyNotifier 纪律）。
@MainActor
private final class SpyExportNotifier: ExportNotifying {
    var completedURLs: [URL] = []
    var failureMessages: [String] = []

    func notifyExportCompleted(fileURL: URL) { completedURLs.append(fileURL) }
    func notifyExportFailed(message: String) { failureMessages.append(message) }
}
