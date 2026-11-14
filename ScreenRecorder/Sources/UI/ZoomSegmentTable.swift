import AppKit
import SwiftUI

/// 分段列表原生表格（交互层修复）：行选中、右键「删除分段」全走 AppKit 原生通道；
/// 行内档位下拉（NSPopUpButton）与删除按钮（NSButton）为原生控件——控件激活通道本来
/// 就存活，仅 SwiftUI 手势/菜单层在该窗口族内不响应（见 RecordingListView 头注）。
/// 行布局与旧 SwiftUI 行逐项对齐：段号 40 / 区间 128（等宽数字）/ 档位 96 / 尾随删除按钮。
struct ZoomSegmentTable: NSViewRepresentable {
    let model: ZoomEditorModel

    /// 行高（旧 SwiftUI 行 padding 3×2 + 控件 ~22）。
    static let rowHeight: CGFloat = 28

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let table = SegmentTableView()
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.rowHeight = Self.rowHeight
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("segment"))
        column.width = 600
        table.addTableColumn(column)
        context.coordinator.table = table
        table.menuBridge = context.coordinator
        scrollView.documentView = table
        context.coordinator.sync(model: model)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.sync(model: model)
    }

    // MARK: - Coordinator（数据源/代理/选中回写/删段菜单）

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private(set) var model: ZoomEditorModel
        private var segments: [ZoomSegment] = []
        weak var table: SegmentTableView?

        private static let cellID = NSUserInterfaceItemIdentifier("segment-row")

        init(model: ZoomEditorModel) {
            self.model = model
        }

        /// 视图更新入口：段表变化 → reload；选中变化 → 同步表格高亮（模型为真源，
        /// 时间线点击/新增段/validate 重排都可能改选中）。
        func sync(model: ZoomEditorModel) {
            self.model = model
            guard let table else { return }
            if segments != model.segments {
                segments = model.segments
                table.reloadData()
            }
            let desired = model.selectedIndex.map { IndexSet(integer: $0) } ?? IndexSet()
            if table.selectedRowIndexes != desired {
                table.selectRowIndexes(desired, byExtendingSelection: false)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            segments.count
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            OmiTableRowView() // Omi 化：绿柔光圆角选中
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard segments.indices.contains(row) else { return nil }
            let cell = tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? SegmentRowCell
                ?? SegmentRowCell()
            cell.identifier = Self.cellID
            cell.configure(segment: segments[row], row: row, model: model)
            return cell
        }

        /// 行选中 → 模型选中（用户点击/键盘切换走此路）。
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table else { return }
            let newIndex = table.selectedRow >= 0 ? table.selectedRow : nil
            if model.selectedIndex != newIndex {
                model.selectedIndex = newIndex
            }
        }

        /// 右键菜单（行内任意位置）：先选中该行（对齐列表窗语义），再出「删除分段」。
        func menu(forRow row: Int) -> NSMenu {
            let menu = RetainingMenu()
            let proxy = MenuActionProxy { [weak self] in
                Task { @MainActor in self?.model.removeSegment(at: row) } // NSMenu 动作投递在主线程，显式 hop 与库惯例一致
            }
            let item = NSMenuItem(
                title: "删除分段", action: #selector(MenuActionProxy.picked), keyEquivalent: "")
            item.target = proxy
            menu.addItem(item)
            menu.retainedProxies = [proxy]
            return menu
        }
    }
}

/// 原生表格子类：右键 → 行定位（未选中先选中）→ 「删除分段」菜单。
@MainActor
final class SegmentTableView: NSTableView {
    weak var menuBridge: ZoomSegmentTable.Coordinator?

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let bridge = menuBridge else { return nil }
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        if !isRowSelected(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return bridge.menu(forRow: row)
    }
}

/// 分段行单元格（原生控件）：段号 / 区间（等宽数字）/ 档位下拉 / 删除按钮。
@MainActor
final class SegmentRowCell: NSTableCellView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let rangeLabel = NSTextField(labelWithString: "")
    private let levelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let trashButton = NSButton()

    private var onLevelChange: ((Double) -> Void)?
    private var onDelete: (() -> Void)?

    init() {
        super.init(frame: .zero)
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 不支持（代码构建视图）")
    }

    /// 绑定当前行数据与行为（复用单元格每次取用时重新绑定——行号不跨刷新存活）。
    func configure(segment: ZoomSegment, row: Int, model: ZoomEditorModel) {
        nameLabel.stringValue = "段 \(row + 1)"
        rangeLabel.stringValue = String(format: "%.2fs – %.2fs", segment.start, segment.end)
        levelPopup.selectItem(withTitle: String(format: "%.2fx", segment.level))
        onLevelChange = { [weak model] level in
            model?.setLevel(at: row, level: level)
        }
        onDelete = { [weak model] in
            model?.removeSegment(at: row)
        }
    }

    private func buildLayout() {
        nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        rangeLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        for label in [nameLabel, rangeLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }

        for level in ZoomSegment.levels {
            levelPopup.addItem(withTitle: String(format: "%.2fx", level))
        }
        levelPopup.translatesAutoresizingMaskIntoConstraints = false
        levelPopup.target = self
        levelPopup.action = #selector(levelChanged(_:))
        addSubview(levelPopup)

        trashButton.isBordered = false
        trashButton.imagePosition = .imageOnly
        trashButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "删除分段")
        trashButton.contentTintColor = .secondaryLabelColor
        trashButton.toolTip = "删除分段"
        trashButton.translatesAutoresizingMaskIntoConstraints = false
        trashButton.target = self
        trashButton.action = #selector(trashClicked(_:))
        addSubview(trashButton)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.widthAnchor.constraint(equalToConstant: 40),
            rangeLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 12),
            rangeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            rangeLabel.widthAnchor.constraint(equalToConstant: 128),
            levelPopup.leadingAnchor.constraint(equalTo: rangeLabel.trailingAnchor, constant: 12),
            levelPopup.centerYAnchor.constraint(equalTo: centerYAnchor),
            levelPopup.widthAnchor.constraint(equalToConstant: 96),
            trashButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            trashButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            trashButton.widthAnchor.constraint(equalToConstant: 20),
            trashButton.heightAnchor.constraint(equalToConstant: 20),
            levelPopup.trailingAnchor.constraint(lessThanOrEqualTo: trashButton.leadingAnchor, constant: -8)
        ])
    }

    @objc private func levelChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard ZoomSegment.levels.indices.contains(index) else { return }
        onLevelChange?(ZoomSegment.levels[index])
    }

    @objc private func trashClicked(_ sender: Any?) {
        onDelete?()
    }
}
