import AppKit
import SwiftUI

/// 文件列表原生表格（交互层修复）：SwiftUI `Table` + `contextMenu(forSelectionType:)`
/// 在本库手建 `NSWindow + NSHostingView` 窗口里整层不响应（macOS 26 实测：手势/菜单/
/// 双击全灭，仅控件激活存活——2026-11-13 探针取证），故行列表改用原生 `NSTableView`：
/// 选中、双击播放、右键菜单全部走 AppKit 原生事件与 NSMenu（同轮探针实证可用）。
/// 右键未选中行时先选中该行（对齐 `contextMenu(forSelectionType:)` 语义）；空白区
/// 右键清空选择后弹全灰菜单（对齐旧行为——菜单条目规则见 `RecordingListMenuSpec`）。
struct RecordingListTable: NSViewRepresentable {
    let items: [RecordingFileMetadata]
    /// 当前选择集 → 菜单（空选择返回全灰菜单）。
    let menuProvider: (Set<RecordingFileMetadata>) -> NSMenu
    /// 双击行（已选中行上的双击；空白区双击无动作）。
    let onDoubleClick: (RecordingFileMetadata) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let table = RowMenuTableView()
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.headerView = nil // 旧 SwiftUI Table 表头无排序交互（纯展示），原生等价简化为无表头
        table.usesAlternatingRowBackgroundColors = false // Omi 卡面：白卡行 + 绿柔光选中（OmiTableRowView）
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsEmptySelection = true
        table.usesAutomaticRowHeights = false
        table.rowHeight = 28
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClick(_:))
        for column in Self.makeColumns() {
            table.addTableColumn(column)
        }
        let coordinator = context.coordinator
        coordinator.table = table
        table.menuBridge = coordinator
        scrollView.documentView = table
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.items != items {
            coordinator.items = items
            coordinator.table?.reloadData()
        }
        coordinator.menuProvider = menuProvider
        coordinator.onDoubleClick = onDoubleClick
    }

    /// 列定义：名称（弹性）/ 大小 / 时长 / 创建时间——与原 SwiftUI Table 四列对齐。
    private static func makeColumns() -> [NSTableColumn] {
        let specs: [(id: String, title: String, width: CGFloat)] = [
            ("name", "名称", 260),
            ("size", "大小", 100),
            ("duration", "时长", 80),
            ("createdAt", "创建时间", 200)
        ]
        return specs.map { spec in
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            column.title = spec.title
            column.width = spec.width // 窗宽变化由表级 .lastColumnOnlyAutoresizingStyle 吸收（表头隐藏，无手动拖列）
            return column
        }
    }

    // MARK: - Coordinator（数据源/代理/双击；@MainActor——AppKit 子类全隔离是本库
    // 惯例（CameraPiPWindow/FloatingControlBar 同款），且 SDK 对 viewFor:row: 等代理
    // 方法带 NS_SWIFT_UI_ACTOR 标注）

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var items: [RecordingFileMetadata] = []
        var menuProvider: (Set<RecordingFileMetadata>) -> NSMenu
        var onDoubleClick: (RecordingFileMetadata) -> Void
        weak var table: NSTableView?

        init(_ parent: RecordingListTable) {
            self.items = parent.items
            self.menuProvider = parent.menuProvider
            self.onDoubleClick = parent.onDoubleClick
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            items.count
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            OmiTableRowView() // Omi 化：绿柔光圆角选中
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < items.count else { return nil }
            let item = items[row]
            let cell = tableView.makeView(
                withIdentifier: NSUserInterfaceItemIdentifier("cell-\(tableColumn?.identifier.rawValue ?? "")"),
                owner: nil
            ) as? NSTableCellView ?? Self.makeCell()
            cell.identifier = NSUserInterfaceItemIdentifier("cell-\(tableColumn?.identifier.rawValue ?? "")")
            cell.textField?.stringValue = Self.text(for: item, column: tableColumn?.identifier.rawValue)
            return cell
        }

        @objc func doubleClick(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0, row < items.count else { return }
            onDoubleClick(items[row])
        }

        /// 当前选中行 → 条目（右键菜单按选中集出菜单）。
        func selectedItems() -> [RecordingFileMetadata] {
            guard let table else { return [] }
            return table.selectedRowIndexes
                .compactMap { Int($0) < items.count ? items[Int($0)] : nil }
        }

        private static func makeCell() -> NSTableCellView {
            let cell = NSTableCellView()
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                field.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }

        private static func text(for item: RecordingFileMetadata, column: String?) -> String {
            switch column {
            case "size":
                return ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file)
            case "duration":
                return RecordingListFormat.durationText(item.duration)
            case "createdAt":
                return RecordingListFormat.createdAtText(item.createdAt)
            default:
                return item.name
            }
        }
    }
}

/// 原生表格子类：右键 → 行定位（未选中先选中/空白清空）→ 经 Coordinator 出菜单。
/// `menu(for:)` 由 AppKit 在右键时自动调用并就地呈现返回的 NSMenu（无 SwiftUI 参与）。
/// @MainActor：本库 AppKit 子类惯例，menu(for:) 覆盖与菜单组装调用全主 actor 一致。
@MainActor
final class RowMenuTableView: NSTableView {
    weak var menuBridge: RecordingListTable.Coordinator?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0 {
            if !isRowSelected(row) {
                selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        } else {
            deselectAll(nil)
        }
        guard let bridge = menuBridge else { return nil }
        return bridge.menuProvider(Set(bridge.selectedItems()))
    }
}

/// 展示格式（原 RecordingListView 私有工具迁出，原生单元格共用）。
enum RecordingListFormat {
    static func durationText(_ duration: TimeInterval?) -> String {
        guard let duration, duration.isFinite, duration >= 0 else { return "—" }
        let total = Int(duration.rounded())
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func createdAtText(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
