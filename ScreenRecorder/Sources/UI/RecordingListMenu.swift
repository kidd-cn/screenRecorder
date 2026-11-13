import AppKit

/// 文件列表右键菜单规格（纯逻辑，无头钉测 `entries`）：条目/顺序/置灰规则与原
/// SwiftUI `contextMenu(forSelectionType:)` 菜单及 brief 行操作逐字一致；NSMenu 组装
/// 为薄层（`menu(...)`）。承载方式见 `RecordingListView` 头注（交互层修复）。
enum RecordingListMenuSpec {
    /// 操作标识（allCases 顺序即菜单顺序）。
    enum Action: String, CaseIterable, Equatable {
        case play, reveal, rename, edit, exportGIF, compress, removeFromList, delete
    }

    struct Entry: Equatable {
        let title: String
        let action: Action
        let isEnabled: Bool
        let isDestructive: Bool
    }

    /// 单条目标题（与 brief 逐字一致）。
    static func title(for action: Action) -> String {
        switch action {
        case .play: return "播放"
        case .reveal: return "在 Finder 中显示"
        case .rename: return "重命名…"
        case .edit: return "编辑…"
        case .exportGIF: return "导出 GIF…"
        case .compress: return "压缩…"
        case .removeFromList: return "移出列表"
        case .delete: return "删除…"
        }
    }

    /// 置灰规则：播放/Finder 显示/移出列表/删除 非空选择即可；重命名/导出 GIF/压缩 仅
    /// 单选；编辑 仅单选且非纯声音成片（.m4a 无视频画布，视频轨编排不适用）。
    static func isEnabled(_ action: Action, selectionCount: Int, firstIsAudioOnly: Bool) -> Bool {
        switch action {
        case .play, .reveal, .removeFromList, .delete:
            return selectionCount > 0
        case .rename, .exportGIF, .compress:
            return selectionCount == 1
        case .edit:
            return selectionCount == 1 && !firstIsAudioOnly
        }
    }

    static func entries(selectionCount: Int, firstIsAudioOnly: Bool) -> [Entry] {
        Action.allCases.map { action in
            Entry(
                title: title(for: action),
                action: action,
                isEnabled: isEnabled(action, selectionCount: selectionCount, firstIsAudioOnly: firstIsAudioOnly),
                isDestructive: action == .delete)
        }
    }

    // MARK: - NSMenu 组装（薄层）

    /// 行为闭包集（由视图侧对接 sheet/告警/模型流）。
    struct Handlers {
        let play: () -> Void
        let reveal: () -> Void
        let rename: () -> Void
        let edit: () -> Void
        let exportGIF: () -> Void
        let compress: () -> Void
        let removeFromList: () -> Void
        let delete: () -> Void

        func handler(for action: Action) -> () -> Void {
            switch action {
            case .play: return play
            case .reveal: return reveal
            case .rename: return rename
            case .edit: return edit
            case .exportGIF: return exportGIF
            case .compress: return compress
            case .removeFromList: return removeFromList
            case .delete: return delete
            }
        }
    }

    /// 组装 NSMenu：`autoenablesItems = false`（置灰完全由规格决定）；点击经
    /// `MenuActionProxy` 分发——NSMenuItem.target 为弱引用，代理数组由菜单子类
    /// 强持有，随菜单销毁释放。
    static func menu(selectionCount: Int, firstIsAudioOnly: Bool, handlers: Handlers) -> NSMenu {
        let menu = RetainingMenu()
        menu.autoenablesItems = false
        var proxies: [MenuActionProxy] = []
        for entry in entries(selectionCount: selectionCount, firstIsAudioOnly: firstIsAudioOnly) {
            let proxy = MenuActionProxy(action: handlers.handler(for: entry.action))
            let item = NSMenuItem(
                title: entry.title,
                action: #selector(MenuActionProxy.picked),
                keyEquivalent: "")
            item.target = proxy
            item.isEnabled = entry.isEnabled
            if entry.isDestructive { // 「删除…」红字（对齐原 role: .destructive；NSMenuItem 无 isDestructive，走标题属性）
                item.attributedTitle = NSAttributedString(string: entry.title, attributes: [
                    .font: NSFont.menuFont(ofSize: 0),
                    .foregroundColor: NSColor.systemRed
                ])
            }
            menu.addItem(item)
            proxies.append(proxy)
        }
        menu.retainedProxies = proxies
        return menu
    }
}

/// NSMenu 子类：强持有点击代理（NSMenuItem.target 弱引用，代理须与菜单同寿命）。
final class RetainingMenu: NSMenu {
    var retainedProxies: [MenuActionProxy] = []
}

/// NSMenu 点击分发代理（存活期 = 菜单存活期）。
final class MenuActionProxy: NSObject {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        super.init()
    }

    @objc func picked() {
        action()
    }
}
