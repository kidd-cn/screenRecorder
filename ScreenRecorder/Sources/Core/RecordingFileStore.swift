import Foundation

/// 文件列表中的一条录像元数据。
/// Equatable/Hashable 为合成实现（全可哈希成员）：供测试、UI 比对与 `Table` 行选中集
///（`contextMenu(forSelectionType:)` 的 selection 元素要求 Hashable）。
struct RecordingFileMetadata: Identifiable, Equatable, Hashable {
    /// 以文件 URL 作为稳定标识。
    let id: URL
    let url: URL
    let name: String
    let sizeBytes: Int64
    let createdAt: Date?
    /// 由 RecordingListViewModel 通过 durationProvider 异步填充；store 列目录时为 nil。
    var duration: TimeInterval?
}

/// 输出目录内录像文件的存取：目录创建、文件名分配、列表、删除、重命名。
struct RecordingFileStore {
    let baseDirectory: URL

    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    /// 全代码库唯一的输出目录创建点（SettingsStore 不做任何文件系统副作用）。
    func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    /// 固定格式 `录屏_yyyy-MM-dd_HH-mm-ss.<ext>`，本地时区/日历下与 DateComponents 构造可往返。
    static func fileName(for date: Date, extension ext: String = "mp4") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = .current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "录屏_\(formatter.string(from: date)).\(ext)"
    }

    /// 返回当前不存在的文件 URL；同名冲突时追加 " (2)" 并递增。不创建目录或文件。
    func nextFileURL(now: Date = Date()) -> URL {
        let baseName = Self.fileName(for: now)
        let stem = (baseName as NSString).deletingPathExtension
        let ext = (baseName as NSString).pathExtension

        var candidate = baseDirectory.appendingPathComponent(baseName)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = baseDirectory.appendingPathComponent("\(stem) (\(counter)).\(ext)")
            counter += 1
        }
        return candidate
    }

    /// 列出目录内文件（新在前），目录不存在或读失败时返回空数组。
    func contents() -> [RecordingFileMetadata] {
        let fileURLs: [URL]
        do {
            fileURLs = try FileManager.default.contentsOfDirectory(
                at: baseDirectory,
                includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return []
        }

        return fileURLs
            .filter { !$0.hasDirectoryPath }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { url in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
                return RecordingFileMetadata(
                    id: url,
                    url: url,
                    name: url.lastPathComponent,
                    sizeBytes: Int64(values?.fileSize ?? 0),
                    createdAt: values?.creationDate,
                    duration: nil
                )
            }
    }

    /// 删除失败时静默忽略（签名不抛出）；调用方以 contents()/refresh() 复核结果。
    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// 同目录内重命名。
    func rename(_ url: URL, toName: String) throws {
        let destination = url.deletingLastPathComponent().appendingPathComponent(toName)
        try FileManager.default.moveItem(at: url, to: destination)
    }
}
