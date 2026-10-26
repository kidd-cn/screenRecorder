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
}
