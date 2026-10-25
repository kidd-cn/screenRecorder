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
}
