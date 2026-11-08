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

/// 已移出列表条目的持久化记账（Q4，记账不删文件）：read/write 两个缝闭包注入——
/// 生产接 UserDefaults（`key` 下存 `[String]` 路径集），测试接内存盒。`remove` 是
/// 读-改-写的唯一入口；集合的过滤与自愈语义在 `RecordingFileStore.contents()`
///（单一列表过滤点），本类型只做账本的存取薄壳。
struct RemovedListStore {
    /// UserDefaults 存储键（存 `[String]`——已移出条目的绝对路径集）。
    static let key = "removedFromListPaths"

    /// 取当前已移出集合（contents() 过滤/自愈消费）。
    let read: () -> Set<String>
    /// 写回集合（`remove` 记账与自愈收窄集回持久层共用；「仅集合有变化时写」由
    /// 调用方保证）。
    let write: (Set<String>) -> Void

    init(read: @escaping () -> Set<String>, write: @escaping (Set<String>) -> Void) {
        self.read = read
        self.write = write
    }

    /// 记账一条移出（读-改-写）。
    func remove(_ path: String) {
        var updated = read()
        updated.insert(path)
        write(updated)
    }
}

/// 输出目录内录像文件的存取：目录创建、文件名分配、列表、删除、重命名。
struct RecordingFileStore {
    let baseDirectory: URL
    /// 已移出条目记账缝（Q4）：contents() 过滤与自愈消费；缺省空集 + write no-op
    ///——既有调用方零改动（生产装配注入 UserDefaults 缝实现）。
    private let removedList: RemovedListStore

    init(
        baseDirectory: URL,
        removedList: RemovedListStore = RemovedListStore(read: { [] }, write: { _ in })
    ) {
        self.baseDirectory = baseDirectory
        self.removedList = removedList
    }

    /// 全代码库唯一的输出目录创建点（SettingsStore 不做任何文件系统副作用）。
    func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    /// 固定格式 `<prefix>_yyyy-MM-dd_HH-mm-ss.<ext>`，本地时区/日历下与 DateComponents
    /// 构造可往返。`prefix` 缺省「录屏」（既有调用方零改动）；截图（Q1）传「截图」产出
    /// `截图_….png` 名。
    static func fileName(for date: Date, extension ext: String = "mp4", prefix: String = "录屏") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = .current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "\(prefix)_\(formatter.string(from: date)).\(ext)"
    }

    /// 返回当前不存在的文件 URL；同名冲突时追加 " (2)" 并递增（后缀保持参数扩展名）。
    /// 不创建目录或文件。`extension` 缺省 "mp4"（既有调用方零改动）；仅声音录制（P7a）
    /// 传 "m4a" 产出 `.m4a` 名。`prefix` 缺省「录屏」（Q1）：截图传「截图」产出
    /// `截图_….png` 名，同名冲突同样 " (2)" 递增。
    func nextFileURL(now: Date = Date(), extension ext: String = "mp4", prefix: String = "录屏") -> URL {
        let baseName = Self.fileName(for: now, extension: ext, prefix: prefix)
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

    /// 列出目录内录像成片（新在前，只列 `.mp4` / `.m4a`——P7a 起仅声音成片同为成片），
    /// 目录不存在或读失败时返回空数组。
    /// 终审 F7：过滤器收窄为成片扩展名——异常退出残留的 `.claim` 占位与无关文件不进列表
    ///（此前只滤目录与隐藏文件，`.claim` 会以 0 字节条目混入文件列表）。
    /// Q4 移出记账：列表语义钉定为 **目录扫描 ∩ {mp4, m4a} − 已移出集合**——记账不删
    /// 文件，磁盘文件原地保留；自愈——集合中文件已不存在的路径剔除并写回（仅集合有
    /// 变化时写；目录读失败的早退分支不动集合，读失败 ≠ 文件不存在）。记账按绝对路径，
    /// 改名后的新路径不在集合 → 条目重现。
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

        // Q4 自愈：剔除账本里文件已删的路径并写回收窄集（成功扫描之后才自愈——上面的
        // 早退分支目录不可读，不据此断定「文件已不存在」而清账）。
        let removed = removedList.read()
        let healed = removed.filter { FileManager.default.fileExists(atPath: $0) }
        if healed != removed {
            removedList.write(healed)
        }

        // Q4 已移出过滤：账本入账侧是调用方 URL 的路径拼写，扫描侧是目录枚举拼写——
        // 两者可能不一致（如临时目录 /var/... vs 枚举返回的 /private/var/...，符号链接
        // 已解析），故按符号链接解析后的规范拼写比对（fileExists 双拼写通吃，无需归一）。
        let removedPaths = Set(removed.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        return fileURLs
            .filter { !$0.hasDirectoryPath && ["mp4", "m4a"].contains($0.pathExtension.lowercased()) }
            .filter { !removedPaths.contains($0.resolvingSymlinksInPath().path) }
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
