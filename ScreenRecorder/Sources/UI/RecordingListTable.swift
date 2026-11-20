import AppKit
import AVFoundation
import SwiftUI

/// 文件列表原生表格（交互层修复）：SwiftUI `Table` + `contextMenu(forSelectionType:)`
/// 在本库手建 `NSWindow + NSHostingView` 窗口里整层不响应（macOS 26 实测：手势/菜单/
/// 双击全灭，仅控件激活存活——2026-11-13 探针取证），故行列表改用原生 `NSTableView`。
/// 2026-11-20 按 Omi 47.png 像素级复刻：六列（名字/时长/文件大小/类型/创建时间/操作）、
/// 名字列带视频首帧缩略图、操作列为三个圆形按钮（播放 / 在 Finder 中显示 / 编辑）、
/// 56pt 行高、表头竖分隔线、行横分隔线。
struct RecordingListTable: NSViewRepresentable {
    let items: [RecordingFileMetadata]
    /// 当前选择集 → 菜单（空选择返回全灰菜单）。
    let menuProvider: (Set<RecordingFileMetadata>) -> NSMenu
    /// 双击行（已选中行上的双击；空白区双击无动作）。
    let onDoubleClick: (RecordingFileMetadata) -> Void
    /// 行内操作按钮（Omi 操作列）：播放 / 在 Finder 中显示 / 编辑。
    let onRowAction: (RecordingFileMetadata, RowAction) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let table = RowMenuTableView()
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.headerView = OmiTableHeaderView()
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .clear
        table.gridStyleMask = [.solidHorizontalGridLineMask]
        table.gridColor = NSColor.white.withAlphaComponent(0.08)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsEmptySelection = true
        table.usesAutomaticRowHeights = false
        table.rowHeight = 64
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClick(_:))
        context.coordinator.table = table
        for column in Self.makeColumns() {
            table.addTableColumn(column)
        }
        table.menuBridge = context.coordinator
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
        coordinator.onRowAction = onRowAction
    }

    /// 列定义（Omi 47.png 六列）：名字（弹性）/ 时长 / 文件大小 / 类型 / 创建时间 / 操作。
    private static func makeColumns() -> [NSTableColumn] {
        let specs: [(id: String, title: String, width: CGFloat,
                     minWidth: CGFloat)] = [
            ("name", NSLocalizedString("名字", comment: "Column name"), 300, 180),
            ("duration", NSLocalizedString("时长", comment: "Column duration"), 90, 70),
            ("size", NSLocalizedString("文件大小", comment: "Column size"), 100, 80),
            ("kind", NSLocalizedString("类型", comment: "Column kind"), 90, 70),
            ("createdAt", NSLocalizedString("创建时间", comment: "Column created"), 200, 150),
            ("actions", NSLocalizedString("操作", comment: "Column actions"), 140, 120),
        ]
        return specs.map { spec in
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            column.title = spec.title
            column.width = spec.width
            column.minWidth = spec.minWidth
            column.headerCell.alignment = .left
            return column
        }
    }

    // MARK: - Coordinator（数据源/代理/双击；@MainActor——AppKit 子类全隔离是本库惯例）

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var items: [RecordingFileMetadata] = []
        var menuProvider: (Set<RecordingFileMetadata>) -> NSMenu
        var onDoubleClick: (RecordingFileMetadata) -> Void
        var onRowAction: (RecordingFileMetadata, RowAction) -> Void
        weak var table: NSTableView?

        init(_ parent: RecordingListTable) {
            self.items = parent.items
            self.menuProvider = parent.menuProvider
            self.onDoubleClick = parent.onDoubleClick
            self.onRowAction = parent.onRowAction
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            items.count
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            OmiTableRowView()
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < items.count else { return nil }
            let item = items[row]
            let columnID = tableColumn?.identifier.rawValue ?? ""
            switch columnID {
            case "name":
                let identifier = NSUserInterfaceItemIdentifier("cell-name")
                let cell = tableView.makeView(withIdentifier: identifier, owner: nil)
                    as? RecordingNameCell ?? RecordingNameCell()
                cell.identifier = identifier
                cell.configure(with: item)
                return cell
            case "actions":
                let identifier = NSUserInterfaceItemIdentifier("cell-actions")
                let cell = tableView.makeView(withIdentifier: identifier, owner: nil)
                    as? RecordingActionCell ?? RecordingActionCell()
                cell.identifier = identifier
                cell.configure(item: item) { [weak self] action in
                    self?.onRowAction(item, action)
                }
                return cell
            default:
                let identifier = NSUserInterfaceItemIdentifier("cell-\(columnID)")
                let cell = tableView.makeView(withIdentifier: identifier, owner: nil)
                    as? ListRowCell ?? ListRowCell()
                cell.identifier = identifier
                cell.label.stringValue = Self.text(for: item, column: columnID)
                cell.label.alignment = .left
                return cell
            }
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

        private static func text(for item: RecordingFileMetadata, column: String) -> String {
            switch column {
            case "size":
                return ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file)
            case "duration":
                return RecordingListFormat.durationText(item.duration)
            case "kind":
                return RecordingListFormat.kindText(for: item)
            case "createdAt":
                return RecordingListFormat.createdAtText(item.createdAt)
            default:
                return item.name
            }
        }
    }
}

/// 行内操作（Omi 操作列三个圆形按钮）。
enum RowAction {
    case play
    case reveal
    case edit
}

/// 原生表格子类：右键 → 行定位（未选中先选中/空白清空）→ 经 Coordinator 出菜单。
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

/// 表头（Omi 47.png）：深色底 + 列间竖分隔线。分隔线在 `draw(_:)` 里按可见列边界补画
/// （NSTableHeaderView 默认不画分隔线）。
@MainActor
final class OmiTableHeaderView: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let tableView else { return }
        NSColor.white.withAlphaComponent(0.10).setFill()
        var x: CGFloat = 0
        for column in tableView.tableColumns {
            x += column.width
            guard x < bounds.maxX - 1 else { break }
            NSRect(x: x - 0.5, y: 6, width: 1, height: bounds.height - 12).fill()
        }
    }
}

/// 展示格式（原生单元格共用）。
enum RecordingListFormat {
    static func durationText(_ duration: TimeInterval?) -> String {
        guard let duration, duration.isFinite, duration >= 0 else { return "—" }
        let total = Int(duration.rounded())
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    static func createdAtText(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// 录制类型（Omi「类型」列）：文件名前缀（2026-11-20 起按模式命名）优先，
    /// 历史文件按扩展名回退——m4a = 声音、png = 截图、其余 = 屏幕。
    static func kindText(for item: RecordingFileMetadata) -> String {
        let knownPrefixes: [(prefix: String, title: String)] = [
            (NSLocalizedString("窗口区域", comment: "Kind window region"),
             NSLocalizedString("窗口区域", comment: "Kind window region")),
            (NSLocalizedString("窗口", comment: "Kind window"), NSLocalizedString("窗口", comment: "Kind window")),
            (NSLocalizedString("区域", comment: "Kind region"), NSLocalizedString("区域", comment: "Kind region")),
            (NSLocalizedString("App", comment: "Kind app"), NSLocalizedString("App", comment: "Kind app")),
            (NSLocalizedString("摄像头", comment: "Kind camera"), NSLocalizedString("摄像头", comment: "Kind camera")),
            (NSLocalizedString("声音", comment: "Kind audio"), NSLocalizedString("声音", comment: "Kind audio")),
            (NSLocalizedString("屏幕", comment: "Kind screen"), NSLocalizedString("屏幕", comment: "Kind screen")),
            (NSLocalizedString("截图", comment: "Kind screenshot"), NSLocalizedString("截图", comment: "Kind screenshot")),
        ]
        for entry in knownPrefixes where item.name.hasPrefix(entry.prefix + "_") {
            return entry.title
        }
        switch item.url.pathExtension.lowercased() {
        case "m4a": return NSLocalizedString("声音", comment: "Kind audio")
        case "png", "jpg", "jpeg", "heic": return NSLocalizedString("截图", comment: "Kind screenshot")
        default: return NSLocalizedString("屏幕", comment: "Kind screen")
        }
    }
}

// MARK: - 名字列（缩略图 + 文件名）

/// 名字列单元（Omi 同款）：视频首帧缩略图 64×40 圆角 + 文件名。缩略图异步生成
///（`RecordingThumbnailProvider`），生成完成回到主线程贴图；单元复用后按 URL 比对
/// 丢弃陈旧结果。
@MainActor
final class RecordingNameCell: NSView {
    let label = NSTextField(labelWithString: "")
    private let thumb = NSImageView()
    private var currentURL: URL?

    init() {
        super.init(frame: .zero)
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 4
        thumb.layer?.masksToBounds = true
        thumb.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.translatesAutoresizingMaskIntoConstraints = false
        addSubview(thumb)
        label.font = .systemFont(ofSize: 14)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            thumb.leadingAnchor.constraint(equalTo: leadingAnchor),
            thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 72),
            thumb.heightAnchor.constraint(equalToConstant: 46),
            label.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 不支持（代码构建视图）")
    }

    func configure(with item: RecordingFileMetadata) {
        label.stringValue = item.name
        currentURL = item.url
        thumb.image = nil
        RecordingThumbnailProvider.shared.thumbnail(for: item.url) { [weak self] image in
            guard let self, self.currentURL == item.url else { return }
            self.thumb.image = image
        }
    }
}

/// 文件缩略图缓存（Omi 名字列预览）：首帧异步生成 + 内存缓存。视频用
/// `AVAssetImageGenerator`（0.1s 处抓帧），图片直接载入，音频画音符占位（无画面）。
@MainActor
final class RecordingThumbnailProvider {
    static let shared = RecordingThumbnailProvider()

    private var cache: [URL: NSImage] = [:]
    private var inFlight: Set<URL> = []
    /// 缓存上限防长列表无限增长（超出按插入序淘汰最早 32 条）。
    private static let cacheLimit = 64

    func thumbnail(for url: URL, completion: @escaping (NSImage?) -> Void) {
        if let cached = cache[url] {
            completion(cached)
            return
        }
        if inFlight.contains(url) { return } // 生成中：本轮跳过（下次刷新命中缓存）
        inFlight.insert(url)
        let ext = url.pathExtension.lowercased()
        let size = CGSize(width: 128, height: 80) // 2x 像素余量
        // 解码/抓帧在 detached 任务（主 actor 不阻塞列表滚动）；结果回主 actor 入库。
        // 局部捕获只含 URL/扩展名/尺寸（Sendable 值），不捕获 self。
        let imageTask = Task.detached(priority: .utility) { () -> NSImage? in
            if ext == "png" || ext == "jpg" || ext == "jpeg" || ext == "heic" {
                return NSImage(contentsOf: url)
            }
            if ext == "m4a" {
                return NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
            }
            return await Self.firstFrame(of: url, maxSize: size)
        }
        // 完成回调经 MainActor 回跳（Task 继承主 actor 上下文）。
        Task { @MainActor [weak self] in
            let image = await imageTask.value
            guard let self else { return }
            if let image {
                self.cache[url] = image
                if self.cache.count > Self.cacheLimit {
                    for key in self.cache.keys.prefix(32) { self.cache.removeValue(forKey: key) }
                }
            }
            self.inFlight.remove(url)
            completion(image)
        }
    }

    /// 首帧抓取（后台）：失败返回 nil（单元保持深色占位）。
    private static func firstFrame(of url: URL, maxSize: CGSize) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maxSize
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        guard let cg = try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

// MARK: - 文本列单元

/// 普通行单元（不使用 NSTableCellView——其 textField 内部缩进会与表头不对齐）：
/// 单行文本，leading 6pt 与表头标题视觉一致（2026-11-15 统一左对齐）。
@MainActor
final class ListRowCell: NSView {
    let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 不支持（代码构建视图）")
    }
}

// MARK: - 操作列（Omi 三个圆形按钮）

/// 操作列单元：播放 ▶ / 在 Finder 中显示（方框内箭头）/ 编辑 ✂——白描边圆形按钮。
/// 按钮回调按行配置（单元复用安全：configure 每次整体换闭包）。
@MainActor
final class RecordingActionCell: NSView {
    private var item: RecordingFileMetadata?
    private var onAction: ((RowAction) -> Void)?
    private let playButton = CircularGlyphButton(symbol: "play.fill", accessibility: "播放")
    private let revealButton = CircularGlyphButton(symbol: "arrow.down.forward.square", accessibility: "在 Finder 中显示")
    private let editButton = CircularGlyphButton(symbol: "scissors", accessibility: "编辑")

    init() {
        super.init(frame: .zero)
        let stack = NSStackView(views: [playButton, revealButton, editButton])
        stack.spacing = 10
        stack.orientation = .horizontal
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        playButton.target = self
        playButton.action = #selector(playTapped)
        revealButton.target = self
        revealButton.action = #selector(revealTapped)
        editButton.target = self
        editButton.action = #selector(editTapped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 不支持（代码构建视图）")
    }

    /// 按行配置：条目 + 动作闭包；音频无视频轨不可编辑（编辑按钮置灰）。
    func configure(item: RecordingFileMetadata, onAction: @escaping (RowAction) -> Void) {
        self.item = item
        self.onAction = onAction
        let isAudio = item.url.pathExtension.lowercased() == "m4a"
        editButton.isEnabled = !isAudio
        editButton.alphaValue = isAudio ? 0.35 : 1
    }

    @objc private func playTapped() { onAction?(.play) }
    @objc private func revealTapped() { onAction?(.reveal) }
    @objc private func editTapped() { onAction?(.edit) }
}

/// 白描边圆形符号按钮（Omi 操作列观感）：26pt 圆 + 1.5pt 白描边 + 白色符号。
@MainActor
final class CircularGlyphButton: NSButton {
    private static let diameter: CGFloat = 26

    init(symbol: String, accessibility: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
        isBordered = false
        bezelStyle = .regularSquare
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        contentTintColor = .white
        wantsLayer = true
        layer?.cornerRadius = Self.diameter / 2
        layer?.borderWidth = 1.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.diameter).isActive = true
        heightAnchor.constraint(equalToConstant: Self.diameter).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 不支持（代码构建视图）")
    }
}
