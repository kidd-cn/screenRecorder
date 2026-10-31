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

    /// 终审 F7：列表只列 `.mp4` 成片——异常退出残留的 `.claim` 占位与无关文件不进列表
    ///（扩展名比对不区分大小写）。
    func testContentsFiltersToMp4FilesOnly() throws {
        try store.ensureDirectory()
        let mp4 = directory.appendingPathComponent("录屏_2026-10-25_14-30-05.mp4")
        let claim = directory.appendingPathComponent("录屏_2026-10-25_14-30-06.mp4.claim")
        let txt = directory.appendingPathComponent("notes.txt")
        let partial = directory.appendingPathComponent("half.mp4.part")
        let upper = directory.appendingPathComponent("CAM.MP4")
        for file in [mp4, claim, txt, partial, upper] {
            try Data("x".utf8).write(to: file)
        }

        let names = store.contents().map(\.name)

        XCTAssertEqual(Set(names), ["录屏_2026-10-25_14-30-05.mp4", "CAM.MP4"],
                       "只保留 .mp4 成片（.claim/.txt/.part 均不进列表）")
        XCTAssertEqual(names.count, 2)
    }

    /// P7a：列表放宽为 mp4/m4a 双成片扩展名（五文件矩阵扩为六）——仅声音录制的
    /// `.m4a` 成片进列表；`.claim` 占位（含 audioOnly 场景的 `.m4a.claim`）、`.part`
    /// 残留与无关文件仍滤除（终审 F7 纪律不变，成片扩展名矩阵由一扩二，大小写不敏感）。
    func testContentsIncludesM4aExcludesClaimAndPart() throws {
        try store.ensureDirectory()
        let mp4 = directory.appendingPathComponent("录屏_2026-10-25_14-30-05.mp4")
        let upper = directory.appendingPathComponent("CAM.MP4")
        let m4a = directory.appendingPathComponent("录屏_2026-10-25_14-30-07.m4a")
        let m4aClaim = directory.appendingPathComponent("录屏_2026-10-25_14-30-06.m4a.claim")
        let partial = directory.appendingPathComponent("half.mp4.part")
        let txt = directory.appendingPathComponent("notes.txt")
        for file in [mp4, upper, m4a, m4aClaim, partial, txt] {
            try Data("x".utf8).write(to: file)
        }

        let names = store.contents().map(\.name)

        XCTAssertEqual(
            Set(names),
            ["录屏_2026-10-25_14-30-05.mp4", "CAM.MP4", "录屏_2026-10-25_14-30-07.m4a"],
            "mp4×2 + m4a 进列表（.m4a.claim/.part/.txt 均不进）")
        XCTAssertEqual(names.count, 3)
    }

    /// P7a：`nextFileURL` 扩展名参数——audioOnly 路径传 "m4a" 产出 .m4a 名；缺省
    /// "mp4" 既有行为不变（既有调用方零改动）。同名冲突递增后缀同样保持参数扩展名。
    func testNextFileURLExtensionParameter() throws {
        try store.ensureDirectory()
        XCTAssertEqual(
            store.nextFileURL(now: Self.fixedDate).lastPathComponent,
            "录屏_2026-10-25_14-30-05.mp4",
            "缺省扩展名不变（既有调用方零改动）")

        let m4a = store.nextFileURL(now: Self.fixedDate, extension: "m4a")
        XCTAssertEqual(m4a.lastPathComponent, "录屏_2026-10-25_14-30-05.m4a")
        try Data().write(to: m4a)

        let second = store.nextFileURL(now: Self.fixedDate, extension: "m4a")
        XCTAssertEqual(second.lastPathComponent, "录屏_2026-10-25_14-30-05 (2).m4a",
                       "冲突递增后缀保持参数扩展名")
    }
}
