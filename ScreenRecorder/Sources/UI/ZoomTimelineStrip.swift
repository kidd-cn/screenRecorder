import AppKit
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

    /// 命中分类：把手优先于段体（窄段两端把手重叠时入点把手优先——与视觉自左向右
    /// 一致）；点不在任何段块内 → 背景。
    enum Hit: Equatable {
        case background
        case leadingHandle(index: Int)
        case trailingHandle(index: Int)
        case segment(index: Int)
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
        return canvas
    }

    func updateNSView(_ canvas: ZoomTimelineCanvas, context: Context) {
        canvas.model = model
        canvas.needsDisplay = true
    }
}

@MainActor
final class ZoomTimelineCanvas: NSView {
    weak var model: ZoomEditorModel?

    /// 端点拖拽会话（mouseDown 建立、mouseDragged 出预览、mouseUp 经统一闸提交）。
    private struct DragState {
        let index: Int
        let isLeading: Bool
        let originalStart: TimeInterval
        let originalEnd: TimeInterval
        let startX: CGFloat
    }

    private var dragState: DragState?

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

    private func currentBlocks(scale: CGFloat) -> [ZoomTimelineGeometry.Block] {
        ZoomTimelineGeometry.blocks(ranges: currentRanges(), scale: scale, height: bounds.height)
    }

    // MARK: 绘制（旧版视觉逐项对齐：背景 .quaternary 近似 / 段块选中 0.55、未选 0.3 /
    // 缓入出白端帽 0.35 / 端点把手白 0.75 / 播放头 accent 1.5pt）

    override func draw(_ dirtyRect: NSRect) {
        guard let model else { return }
        let scale = ZoomTimelineGeometry.scale(width: bounds.width, sourceDuration: model.sourceDuration)

        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(rect: bounds).fill()

        let ranges = currentRanges()
        let blocks = ZoomTimelineGeometry.blocks(ranges: ranges, scale: scale, height: bounds.height)
        for (position, block) in blocks.enumerated() {
            let range = ranges[position]
            let selected = block.index == model.selectedIndex
            NSColor.controlAccentColor
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
        NSColor.controlAccentColor.setFill()
        NSBezierPath(rect: CGRect(
            x: playheadX, y: 0,
            width: ZoomTimelineGeometry.playheadWidth, height: bounds.height)).fill()
    }

    // MARK: 鼠标事件（原生通道）

    override func mouseDown(with event: NSEvent) {
        guard let model else { return }
        let point = convert(event.locationInWindow, from: nil)
        let scale = ZoomTimelineGeometry.scale(width: bounds.width, sourceDuration: model.sourceDuration)
        switch ZoomTimelineGeometry.hit(at: point, in: currentBlocks(scale: scale)) {
        case .leadingHandle(let index):
            beginDrag(index: index, isLeading: true, startX: point.x, model: model)
        case .trailingHandle(let index):
            beginDrag(index: index, isLeading: false, startX: point.x, model: model)
        case .segment(let index):
            model.selectedIndex = index
        case .background:
            model.seek(to: point.x / scale) // 点击背景跳播（旧 DragGesture(minimumDistance: 0) 语义）
        }
    }

    private func beginDrag(index: Int, isLeading: Bool, startX: CGFloat, model: ZoomEditorModel) {
        guard model.segments.indices.contains(index) else { return }
        let segment = model.segments[index]
        dragState = DragState(
            index: index, isLeading: isLeading,
            originalStart: segment.start, originalEnd: segment.end,
            startX: startX)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let state = dragState, let model else { return }
        let point = convert(event.locationInWindow, from: nil)
        let scale = ZoomTimelineGeometry.scale(width: bounds.width, sourceDuration: model.sourceDuration)
        let delta = (point.x - state.startX) / scale // 旧版 translation.width / scale
        model.dragPreview = ZoomEditorModel.DragPreview(
            index: state.index,
            start: state.isLeading ? state.originalStart + delta : state.originalStart,
            end: state.isLeading ? state.originalEnd : state.originalEnd + delta)
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragState = nil }
        guard dragState != nil, let model else { return }
        if let preview = model.dragPreview {
            model.commitDrag(index: preview.index, start: preview.start, end: preview.end)
        }
        model.dragPreview = nil // 旧版 onEnded 同款：无论有无预览都清预览
    }

    /// 右键（含 Control+左键）落在任一段块上 → 先选中该段，再弹「删除分段」菜单；
    /// 背景右键无菜单（旧版 contextMenu 只挂在段块上）。
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let model else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let scale = ZoomTimelineGeometry.scale(width: bounds.width, sourceDuration: model.sourceDuration)
        let index: Int
        switch ZoomTimelineGeometry.hit(at: point, in: currentBlocks(scale: scale)) {
        case .leadingHandle(let hitIndex), .trailingHandle(let hitIndex), .segment(let hitIndex):
            index = hitIndex
        case .background:
            return nil
        }
        guard model.segments.indices.contains(index) else { return nil }
        model.selectedIndex = index
        return ZoomEditorMenus.deleteSegment(at: index, model: model)
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
            title: "删除分段", action: #selector(MenuActionProxy.picked), keyEquivalent: "")
        item.target = proxy
        menu.addItem(item)
        menu.retainedProxies = [proxy]
        return menu
    }
}
