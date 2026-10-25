import XCTest

@testable import ScreenRecorder

final class RecordingFileStoreTests: XCTestCase {
    private var directory: URL!
    private var store: RecordingFileStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingFileStoreTests-\(UUID().uuidString)", isDirectory: true)
        store = RecordingFileStore(baseDirectory: directory)
    }

    override func tearDownWithError() throws {
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        directory = nil
        store = nil
    }

    /// 2026-10-25 14:30:05，按当前日历/时区构造
    private static var fixedDate: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = 25
        components.hour = 14
        components.minute = 30
        components.second = 5
        return Calendar.current.date(from: components)!
    }

    func testFileNameForFixedDate() {
        XCTAssertEqual(
            RecordingFileStore.fileName(for: Self.fixedDate),
            "录屏_2026-10-25_14-30-05.mp4"
        )
    }

    func testNextFileURLTwiceDoesNotConflict() throws {
        try store.ensureDirectory()
        let first = store.nextFileURL(now: Self.fixedDate)
        XCTAssertEqual(first.lastPathComponent, "录屏_2026-10-25_14-30-05.mp4")
        try Data().write(to: first)

        let second = store.nextFileURL(now: Self.fixedDate)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second.lastPathComponent, "录屏_2026-10-25_14-30-05 (2).mp4")
    }

    func testEnsureDirectoryCreatesDirectory() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        try store.ensureDirectory()

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
        XCTAssertTrue(exists)
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testRenameReflectsInContents() throws {
        try store.ensureDirectory()
        let url = store.nextFileURL(now: Self.fixedDate)
        try Data("x".utf8).write(to: url)

        try store.rename(url, toName: "重命名.mp4")

        let names = store.contents().map(\.name)
        XCTAssertEqual(names, ["重命名.mp4"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
