import AppKit
import Combine
import SwiftUI

/// 时间线条几何（纯逻辑，无头钉测面）：时间 → 像素映射与命中测试。
/// 与旧 SwiftUI 版布局常量逐一对应：段块上下内缩 4pt（offset y:4 + height-8）、
/// 端点把手宽 8pt、段块最小可见宽 2pt。画布用 NSView 默认非翻转坐标（y 向上）；
/// 条带上下对称内缩，两套 y 向不影响命中结果。
enum ZoomTimelineGeometry {
    /// 端点把手宽度（旧 SwiftUI 拖拽把手 8pt）。
    static let handleWidth: CGFloat = 8
    /// 段块上下内缩（旧 offset y:4 + height-8）。
    static let verticalInset: CGFloat = 4
    /// 段块最小可见宽度（旧 `max(width, 2)`）。
    static let minimumBlockWidth: CGFloat = 2
    /// 播放头线宽（旧 1.5pt）。
    static let playheadWidth: CGFloat = 1.5

    /// 比例尺 = 条宽 / max(源时长, 0.001)（源时长未就绪前的退化口径，与旧版一致）。
    static func scale(width: CGFloat, sourceDuration: TimeInterval) -> CGFloat {
        width / max(sourceDuration, 0.001)
    }

    struct Block: Equatable {
        let index: Int
        let rect: CGRect
    }

    /// 命中分类：缩放段把手/段体优先（视觉上层），剪除段其次（剪辑 v1：红块全高、
    /// 视觉在下层），背景兜底。剪除段把手与段体的窄段把手重叠裁决与缩放段同款。
    enum Hit: Equatable {
        case background
        case leadingHandle(index: Int)
        case trailingHandle(index: Int)
        case segment(index: Int)
        case cutLeadingHandle(index: Int)
        case cutTrailingHandle(index: Int)
        case cutBlock(index: Int)
    }

    /// 段块矩形（画布坐标）：x = max(start × scale, 0)，宽 = max((end − start) × scale,
    /// 2)，纵向 [verticalInset, height − verticalInset]。
    static func blocks(ranges: [(index: Int, start: TimeInterval, end: TimeInterval)],
                       scale: CGFloat, height: CGFloat) -> [Block] {
        let blockHeight = max(height - 2 * verticalInset, 1)
        return ranges.map { range in
            let x = max(range.start * scale, 0)
            let width = max((range.end - range.start) * scale, minimumBlockWidth)
            return Block(
                index: range.index,
                rect: CGRect(x: x, y: verticalInset, width: width, height: blockHeight))
        }
    }

    /// 剪除段块矩形（剪辑 v1）：全高 [0, height]——与缩放段块（内缩 4pt）同 x 口径，
    /// 纵向铺满以视觉区分「剪除 = 整条时间轴上抹掉」。
    static func cutBlocks(ranges: [(index: Int, start: TimeInterval, end: TimeInterval)],
                          scale: CGFloat, height: CGFloat) -> [Block] {
        ranges.map { range in
            let x = max(range.start * scale, 0)
            let width = max((range.end - range.start) * scale, minimumBlockWidth)
            return Block(
                index: range.index,
                rect: CGRect(x: x, y: 0, width: width, height: height))
        }
    }

    /// 双层命中：先缩放段层（视觉上层），后剪除段层；都未命中 → 背景。
    static func hit(at point: CGPoint, zoomBlocks: [Block], cutBlocks: [Block]) -> Hit {
        switch hit(at: point, in: zoomBlocks) {
        case .background: break
        case let hit: return hit
        }
        switch hit(at: point, in: cutBlocks) {
        case .background: return .background
        case .leadingHandle(let index): return .cutLeadingHandle(index: index)
        case .trailingHandle(let index): return .cutTrailingHandle(index: index)
        case .segment(let index): return .cutBlock(index: index)
        default: return .background
        }
    }

    static func hit(at point: CGPoint, in blocks: [Block]) -> Hit {
        for block in blocks.reversed() { // 后绘制者在视觉上层，优先命中
            let rect = block.rect
            guard rect.contains(point) else { continue }
            let handle = min(handleWidth, rect.width)
            if point.x <= rect.minX + handle {
                return .leadingHandle(index: block.index)
            }
            if point.x >= rect.maxX - handle {
                return .trailingHandle(index: block.index)
            }
            return .segment(index: block.index)
        }
        return .background
    }

    /// 播放头横坐标（钳在 [0, width − playheadWidth]；宽度不足时落 0）。
    static func playheadX(playhead: TimeInterval, scale: CGFloat, width: CGFloat) -> CGFloat {
        min(max(playhead * scale, 0), max(width - playheadWidth, 0))
    }
}

/// 时间线条（AppKit 原生绘制与事件）：点击背景跳播、点段选中、右键删段、拖端点把手
/// 调入出点。替代旧 SwiftUI `DragGesture`/`onTapGesture`/`contextMenu`——该窗口族
/// （手建 `NSWindow + NSHostingView`）内 SwiftUI 手势/菜单层整层不响应（macOS 26
/// 实测，见 RecordingListView 头注；列表窗同轮修复已证 AppKit 通道可用）。
struct ZoomTimelineStrip: NSViewRepresentable {
    let model: ZoomEditorModel

    func makeNSView(context: Context) -> ZoomTimelineCanvas {
        let canvas = ZoomTimelineCanvas()
        canvas.model = model
        // 圆角由画布自身 layer 裁切（圆角贴合卡面；SwiftUI .clipShape 不用——见类内
        // 订阅注释：本窗口族 SwiftUI 桥半残，能少依赖就少依赖）。
        canvas.wantsLayer = true
        canvas.layer?.cornerRadius = 8
        canvas.layer?.masksToBounds = true
        return canvas
    }

    func updateNSView(_ canvas: ZoomTimelineCanvas, context: Context) {
        canvas.model = model // didSet 重挂订阅；本通道在本窗口族只走一次（探针实证）
        canvas.needsDisplay = true
        canvas.displayIfNeeded()
    }
}

@MainActor
final class ZoomTimelineCanvas: NSView {
    weak var model: ZoomEditorModel? {
        didSet { observeModel() }
    }

    /// 模型变化 → 重绘订阅（2026-11-21「红块不可见」根因修复）：本窗口族（手建
    /// `NSWindow + NSHostingView`）的 SwiftUI→NSViewRepresentable 更新通道实测**只走
    /// 一次**（探针实证：updateNSView 恰一次且 pre-layout，后续模型变化不再抵达——
    /// 同窗口族手势/菜单层死文档化的病理族）。画布自持 objectWillChange 订阅驱动重绘
    ///（FloatingControlBarPanel `$state` 订阅同款纪律），绕过宿主桥。
    private var changeObservation: AnyCancellable?

    private func observeModel() {
        changeObservation?.cancel()
        guard let model else { return }
        changeObservation = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { // objectWillChange 先于变更落地——hop 一拍再重绘
                guard let self else { return }
                self.needsDisplay = true
                self.displayIfNeeded()
            }
        }
    }

    /// 拖拽会话（mouseDown 建立、mouseDragged 出预览、mouseUp 经统一闸提交）：
    /// 缩放段端点（既有）/ 剪除段端点（剪辑 v1）/ 空白处新建剪除段拖选（剪辑 v1）。
    private struct DragSession {
        enum Kind {
            case zoomHandle(index: Int, isLeading: Bool, originalStart: TimeInterval, originalEnd: TimeInterval)
            case cutHandle(index: Int, isLeading: Bool, originalStart: TimeInterval, originalEnd: TimeInterval)
            case cutCreate(anchor: TimeInterval)
        }
        let kind: Kind
        let startX: CGFloat
    }

    private var dragSession: DragSession?

    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 尺寸变化即重绘（比例尺依赖条宽；macOS NSView 无 needsDisplayOnBoundsChange）。
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    // MARK: 布局

    private func currentRanges() -> [(index: Int, start: TimeInterval, end: TimeInterval)] {
        guard let model else { return [] }
        return model.segments.indices.map { index in
            let range = model.displayedRange(at: index)
            return (index, range.start, range.end)
        }
    }

    /// 剪除段显示区间（含拖拽预览；新建预览 index nil 追加在表尾）。
    private func currentCutRanges() -> [(index: Int, start: TimeInterval, end: TimeInterval)] {
        guard let model else { return [] }
        var ranges = model.cuts.indices.map { index in
            let range = model.displayedCutRange(at: index)
            return (index, range.start, range.end)
        }
        if let preview = model.cutDragPreview, preview.index == nil {
            ranges.append((Int.min, preview.start, preview.end)) // 新建预览块（命中按背景兜底——index Int.min 不入表）
        }
        return ranges
    }

    private func currentBlocks(scale: CGFloat) -> [ZoomTimelineGeometry.Block] {
        ZoomTimelineGeometry.blocks(ranges: currentRanges(), scale: scale, height: bounds.height)
    }

    private func currentCutBlocks(scale: CGFloat) -> [ZoomTimelineGeometry.Block] {
        ZoomTimelineGeometry.cutBlocks(ranges: currentCutRanges(), scale: scale, height: bounds.height)
    }

    // MARK: 绘制（旧版视觉逐项对齐：背景 .quaternary 近似 / 段块选中 0.55、未选 0.3 /
    // 缓入出白端帽 0.35 / 端点把手白 0.75 / 播放头 accent 1.5pt；剪辑 v1 追加：剪除段
    // 红块全高 0.35 + 白把手，先画（下层），缩放段块后画（上层）盖过重叠区）

    override func draw(_ dirtyRect: NSRect) {
        guard let model else { return }
        let scale = ZoomTimelineGeometry.scale(width: bounds.width, sourceDuration: model.sourceDuration)

        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(rect: bounds).fill()

        // 剪除段块（下层、全高、红）：把手视觉与缩放段同款白 0.75。
        let cutBlocks = currentCutBlocks(scale: scale)
        for block in cutBlocks {
            NSColor.systemRed.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: block.rect, xRadius: 3, yRadius: 3).fill()
            NSColor.white.withAlphaComponent(0.75).setFill()
            let handle = min(ZoomTimelineGeometry.handleWidth, block.rect.width)
            NSBezierPath(rect: CGRect(
                x: block.rect.minX, y: block.rect.minY,
                width: handle, height: block.rect.height)).fill()
            NSBezierPath(rect: CGRect(
                x: block.rect.maxX - handle, y: block.rect.minY,
                width: handle, height: block.rect.height)).fill()
        }

        let ranges = currentRanges()
        let blocks = ZoomTimelineGeometry.blocks(ranges: ranges, scale: scale, height: bounds.height)
        for (position, block) in blocks.enumerated() {
            let range = ranges[position]
            let selected = block.index == model.selectedIndex
            NSColor.systemGreen
                .withAlphaComponent(selected ? 0.55 : 0.3)
                .setFill()
            NSBezierPath(roundedRect: block.rect, xRadius: 3, yRadius: 3).fill()

            // 缓入/缓出窗口端帽：仅长段绘制（与 `zoomProgress` 收敛语义一致的视觉近似，
            // 旧版同款条件与宽度上限 24pt）。
            if range.end - range.start
                > OfflineZoomRenderer.easingInWindow + OfflineZoomRenderer.easingOutWindow
            {
                NSColor.white.withAlphaComponent(0.35).setFill()
                let inWidth = min(OfflineZoomRenderer.easingInWindow * scale, 24)
                let outWidth = min(OfflineZoomRenderer.easingOutWindow * scale, 24)
                NSBezierPath(rect: CGRect(
                    x: block.rect.minX, y: block.rect.minY,
                    width: inWidth, height: block.rect.height)).fill()
                NSBezierPath(rect: CGRect(
                    x: block.rect.maxX - outWidth, y: block.rect.minY,
                    width: outWidth, height: block.rect.height)).fill()
            }

            // 端点把手（入点/出点拖动热区与视觉同位）。
            NSColor.white.withAlphaComponent(0.75).setFill()
            let handle = min(ZoomTimelineGeometry.handleWidth, block.rect.width)
            NSBezierPath(rect: CGRect(
                x: block.rect.minX, y: block.rect.minY,
                width: handle, height: block.rect.height)).fill()
            NSBezierPath(rect: CGRect(
                x: block.rect.maxX - handle, y: block.rect.minY,
                width: handle, height: block.rect.height)).fill()
        }

        // 播放头竖线。
        let playheadX = ZoomTimelineGeometry.playheadX(
            playhead: model.playhead, scale: scale, width: bounds.width)
        NSColor.systemGreen.setFill()
        NSBezierPath(rect: CGRect(
            x: playheadX, y: 0,
            width: ZoomTimelineGeometry.playheadWidth, height: bounds.height)).fill()
    }

    // MARK: 鼠标事件（原生通道）

    override func mouseDown(with event: NSEvent) {
        guard let model else { return }
        let point = convert(event.locationInWindow, from: nil)
        let scale = ZoomTimelineGeometry.scale(width: bounds.width, sourceDuration: model.sourceDuration)
        switch ZoomTimelineGeometry.hit(at: point, zoomBlocks: currentBlocks(scale: scale),
                                        cutBlocks: currentCutBlocks(scale: scale)) {
        case .leadingHandle(let index):
            beginZoomDrag(index: index, isLeading: true, startX: point.x, model: model)
        case .trailingHandle(let index):
            beginZoomDrag(index: index, isLeading: false, startX: point.x, model: model)
        case .segment(let index):
            model.selectedIndex = index
        case .cutLeadingHandle(let index):
            beginCutDrag(index: index, isLeading: true, startX: point.x, model: model)
        case .cutTrailingHandle(let index):
            beginCutDrag(index: index, isLeading: false, startX: point.x, model: model)
        case .cutBlock(let index):
            // 双击删剪除段（v1 剪除段无选中态，块上单击无动作）。
            if event.clickCount >= 2 {
                model.removeCut(at: index)
            }
        case .background:
            // 空白按下：先按「新建剪除段拖选」武装（拖出 ≥4px 才成预览）；松手未拖
            // = 点击背景跳播（旧语义）。
            dragSession = DragSession(
                kind: .cutCreate(anchor: point.x / scale), startX: point.x)
        }
    }

    private func beginZoomDrag(index: Int, isLeading: Bool, startX: CGFloat, model: ZoomEditorModel) {
        guard model.segments.indices.contains(index) else { return }
        let segment = model.segments[index]
        dragSession = DragSession(
            kind: .zoomHandle(index: index, isLeading: isLeading,
                              originalStart: segment.start, originalEnd: segment.end),
            startX: startX)
    }

    private func beginCutDrag(index: Int, isLeading: Bool, startX: CGFloat, model: ZoomEditorModel) {
        guard model.cuts.indices.contains(index) else { return }
        let cut = model.cuts[index]
        dragSession = DragSession(
            kind: .cutHandle(index: index, isLeading: isLeading,
                             originalStart: cut.start, originalEnd: cut.end),
            startX: startX)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let session = dragSession, let model else { return }
        let point = convert(event.locationInWindow, from: nil)
        let scale = ZoomTimelineGeometry.scale(width: bounds.width, sourceDuration: model.sourceDuration)
        let delta = (point.x - session.startX) / scale
        switch session.kind {
        case .zoomHandle(let index, let isLeading, let originalStart, let originalEnd):
            let start = isLeading ? originalStart + delta : originalStart
            let end = isLeading ? originalEnd : originalEnd + delta
            model.dragPreview = ZoomEditorModel.DragPreview(index: index, start: start, end: end)
            model.scrub(to: isLeading ? start : end) // 拖动扫查：预览跟随被拖端点
        case .cutHandle(let index, let isLeading, let originalStart, let originalEnd):
            let start = isLeading ? originalStart + delta : originalStart
            let end = isLeading ? originalEnd : originalEnd + delta
            model.cutDragPreview = ZoomEditorModel.CutDragPreview(index: index, start: start, end: end)
            model.scrub(to: isLeading ? start : end) // 拖动扫查：预览跟随被拖端点
        case .cutCreate(let anchor):
            // 拖出 ≥4px 才成预览（亚拖动 = 点击，松手跳播）；拖动扫查：预览跟随光标
            //（scrub 原始跳转——光标在既有剪除段内也照实显示，扫查 ≠ 播放语义）。
            guard abs(point.x - session.startX) >= 4 else { return }
            let currentTime = point.x / scale
            model.cutDragPreview = ZoomEditorModel.CutDragPreview(
                index: nil,
                start: min(anchor, currentTime),
                end: max(anchor, currentTime))
            model.scrub(to: currentTime)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragSession = nil
            if model?.cutDragPreview != nil { model?.cutDragPreview = nil }
            if model?.dragPreview != nil { model?.dragPreview = nil }
        }
        guard let session = dragSession, let model else { return }
        let scale = ZoomTimelineGeometry.scale(width: bounds.width, sourceDuration: model.sourceDuration)
        switch session.kind {
        case .zoomHandle(let index, _, _, _):
            if let preview = model.dragPreview {
                model.commitDrag(index: index, start: preview.start, end: preview.end)
            }
        case .cutHandle(let index, _, _, _):
            if let preview = model.cutDragPreview {
                model.commitCutDrag(index: index, start: preview.start, end: preview.end)
            }
        case .cutCreate(let anchor):
            if let preview = model.cutDragPreview {
                // 拖选成段：经修剪闸提交（不足最短时长 → 静默丢弃）；提交后播放头落位
                //（落在刚建的剪除段内 → 跳到段尾）。
                model.commitCutCreation(anchor: anchor, start: preview.start, end: preview.end)
                model.settlePlayhead()
            } else {
                model.seek(to: session.startX / scale) // 点击背景跳播（旧语义）
            }
        }
    }

    /// 右键（含 Control+左键）：缩放段块 → 先选中再弹「删除分段」；剪除段块 → 弹
    /// 「删除剪除段」；背景右键无菜单（旧版同款）。
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let model else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let scale = ZoomTimelineGeometry.scale(width: bounds.width, sourceDuration: model.sourceDuration)
        switch ZoomTimelineGeometry.hit(at: point, zoomBlocks: currentBlocks(scale: scale),
                                        cutBlocks: currentCutBlocks(scale: scale)) {
        case .leadingHandle(let hitIndex), .trailingHandle(let hitIndex), .segment(let hitIndex):
            guard model.segments.indices.contains(hitIndex) else { return nil }
            model.selectedIndex = hitIndex
            return ZoomEditorMenus.deleteSegment(at: hitIndex, model: model)
        case .cutLeadingHandle(let hitIndex), .cutTrailingHandle(let hitIndex), .cutBlock(let hitIndex):
            guard model.cuts.indices.contains(hitIndex) else { return nil }
            return ZoomEditorMenus.deleteCut(at: hitIndex, model: model)
        case .background:
            return nil
        }
    }
}

/// 编辑器右键菜单（NSMenu 组装薄层）：点击分发代理经 `RetainingMenu` 与菜单同寿命
///（NSMenuItem.target 弱引用），复用列表窗修复的 `MenuActionProxy`。
enum ZoomEditorMenus {
    static func deleteSegment(at index: Int, model: ZoomEditorModel) -> NSMenu {
        let menu = RetainingMenu()
        let proxy = MenuActionProxy { [weak model] in
            Task { @MainActor in model?.removeSegment(at: index) } // NSMenu 动作投递在主线程，显式 hop 与库惯例一致
        }
        let item = NSMenuItem(
            title: NSLocalizedString("删除分段", comment: "Segment menu delete"), action: #selector(MenuActionProxy.picked), keyEquivalent: "")
        item.target = proxy
        menu.addItem(item)
        menu.retainedProxies = [proxy]
        return menu
    }

    /// 剪除段右键菜单（剪辑 v1）。
    static func deleteCut(at index: Int, model: ZoomEditorModel) -> NSMenu {
        let menu = RetainingMenu()
        let proxy = MenuActionProxy { [weak model] in
            Task { @MainActor in model?.removeCut(at: index) }
        }
        let item = NSMenuItem(
            title: NSLocalizedString("删除剪除段", comment: "Cut menu delete"), action: #selector(MenuActionProxy.picked), keyEquivalent: "")
        item.target = proxy
        menu.addItem(item)
        menu.retainedProxies = [proxy]
        return menu
    }
}
