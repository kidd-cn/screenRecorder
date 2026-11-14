import Foundation

/// 输出目录安全作用域访问（2026-11-14 沙盒适配）：App Store 要求 App Sandbox——
/// 沙盒内只能读写用户经 `NSOpenPanel` 显式选择的目录。做法：
/// 1. 选择目录时创建 security-scoped bookmark（`com.apple.security.files.bookmarks.app-scope`）；
/// 2. 启动时解析书签并对 URL `startAccessingSecurityScopedResource()`，访问权保持到进程退出
///   （会话级；不在运行中反复 start/stop 以规避计数歧义）；
/// 3. 书签缺失/失效（目录被移动、删除或来自上个安装）→ 返回 nil，由装配层引导重新选择。
/// 非沙盒构建下同一 API 兼容（无作用域时 start 返回 false 但访问本就开放）。
///
/// 存储：UserDefaults（`outputDirectoryBookmark`，Data）。目录路径仍由 SettingsStore
/// 落库（展示用）；访问权真源是本类型解析出的 URL。
enum OutputDirectoryAccess {
    static let bookmarkKey = "outputDirectoryBookmark"
    private static let lock = NSLock()
    private static var activeURLs: [URL] = []

    /// 选择目录后登记书签（失败抛错由调用方提示；不影响既有目录继续使用）。
    static func storeBookmark(for url: URL, defaults: UserDefaults = .standard) throws {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
        defaults.set(data, forKey: bookmarkKey)
        beginAccess(url)
    }

    /// 解析书签并取得访问权；nil = 无书签或已失效。
    static func resolve(defaults: UserDefaults = .standard) -> URL? {
        guard let data = defaults.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale)
        else { return nil }
        if stale {
            // 书签过期（目录移动等）：以当前解析结果刷新（尽力而为；失败保留旧值待重选）。
            try? storeBookmark(for: url, defaults: defaults)
        }
        beginAccess(url)
        return url
    }

    /// 清理（用户重新选择目录时调用；仅清存储，访问权随进程退出释放）。
    static func clearBookmark(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: bookmarkKey)
    }

    private static func beginAccess(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        guard !activeURLs.contains(url) else { return }
        if url.startAccessingSecurityScopedResource() {
            activeURLs.append(url)
        }
    }
}
