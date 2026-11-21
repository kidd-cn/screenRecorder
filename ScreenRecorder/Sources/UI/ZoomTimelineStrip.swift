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

    // MARK: 时间线缩放/平移（2026-11-21 剪映专业版对齐·批次 1）

    /// 有效像素率 = 条宽 ÷ 可视时长（可视时长 = 源时长 ÷ 缩放倍率）。zoom ≥ 1（1 = 全程
    /// 适配，与旧版恒等）。
    static func pxPerSec(width: CGFloat, sourceDuration: TimeInterval, zoom: Double) -> CGFloat {
        guard sourceDuration.isFinite, sourceDuration > 0 else { return width / 0.001 }
        let span = max(sourceDuration / max(zoom, 1), 0.001)
        return width / span
    }

    /// 平移钳制：左缘时间 ∈ [0, 源时长 − 可视时长]（zoom = 1 时恒 0）。
    static func clampedOffset(_ offset: TimeInterval, sourceDuration: TimeInterval, zoom: Double) -> TimeInterval {
        guard sourceDuration.isFinite, sourceDuration > 0 else { return 0 }
        let span = sourceDuration / max(zoom, 1)
        return min(max(0, offset), max(0, sourceDuration - span))
    }

    /// 时间 → 视图 x（pxPerSec 已含缩放；offset = 左缘时间）。
    static func timeToX(_ t: TimeInterval, pxPerSec: CGFloat, offset: TimeInterval) -> CGFloat {
        CGFloat(t - offset) * pxPerSec
    }

    /// 视图 x → 时间（钳制归调用方——钳制范围依赖当前 zoom）。
    static func xToTime(_ x: CGFloat, pxPerSec: CGFloat, offset: TimeInterval) -> TimeInterval {
        offset + x / max(pxPerSec, 0.001)
    }

    /// 吸附（剪映对齐）：提案时间落在任一磁点 ± 容差内 → 吸到最近磁点，否则原值。
    /// 磁点由调用方收集（0/时长/各剪除段端点/播放头；被拖段自身端点须排除）。
    static func snapped(_ proposed: TimeInterval,
                        candidates: [TimeInterval],
                        toleranceSeconds: TimeInterval) -> TimeInterval {
        guard toleranceSeconds > 0 else { return proposed }
        var best = proposed
        var bestDistance = toleranceSeconds
        for candidate in candidates {
            let distance = abs(candidate - proposed)
            if distance < bestDistance {
                best = candidate
                bestDistance = distance
            }
        }
        return best
    }

    /// 磁吸主逻辑（剪映对齐·带粘滞与穿越检测）：
    /// 1. **粘滞**——上一吸附点仍在 1.5× 容差内 → 保持吸附（磁点「咬住」手感，防抖动
    ///    交替吸脱）；
    /// 2. **邻近**——proposed 容差内有磁点 → 吸最近；
    /// 3. **穿越**——previous → proposed 光标路径跨越磁点即吸（鼠标事件合并使快速拖动
    ///    单格跳 10-20px、直接越过容差窗——只做邻近检测磁吸会「体感不存在」的根因），
    ///    取被穿越者中距 proposed 最近者；
    /// 4. 均未命中 → nil（调用方清指示线、用原值）。
    static func magnetSnap(proposed: TimeInterval,
                           previous: TimeInterval?,
                           activeSnap: TimeInterval?,
                           candidates: [TimeInterval],
                           toleranceSeconds: TimeInterval) -> (time: TimeInterval, snapped: Bool)? {
        guard toleranceSeconds > 0, !candidates.isEmpty else { return nil }
        if let active = activeSnap, abs(proposed - active) <= toleranceSeconds * 1.5 {
            return (active, true) // 粘滞
        }
        var nearest: TimeInterval?
        var nearestDistance = toleranceSeconds
        for candidate in candidates {
            let distance = abs(candidate - proposed)
            if distance < nearestDistance {
                nearest = candidate
                nearestDistance = distance
            }
        }
        if let nearest { return (nearest, true) } // 邻近
        if let previous {
            let lo = min(previous, proposed)
            let hi = max(previous, proposed)
            var crossed: TimeInterval?
            var crossedDistance = TimeInterval.greatestFiniteMagnitude
            for candidate in candidates where lo < candidate && candidate < hi {
                let distance = abs(candidate - proposed)
                if distance < crossedDistance {
                    crossed = candidate
                    crossedDistance = distance
                }
            }
            if let crossed { return (crossed, true) } // 穿越
        }
        return nil
    }

    /// 时间码（剪映同款 HH:MM:SS:FF，帧率缺省 30）：totalFrames = round(seconds × fps)
    /// ——0.999s @30 → 00:00:00:30（帧位 30 属上溢？不：30 帧 @30fps = 1.0s 边界，
    /// round 后恰进位到秒位，故 ff 恒 < fps）。fps ≤ 0 → "—"。
    static func timecode(_ seconds: TimeInterval, fps: Double = 30) -> String {
        guard seconds.isFinite, seconds >= 0, fps > 0 else { return "—" }
        let totalFrames = Int((seconds * fps).rounded())
        let framesPerSecond = Int(fps.rounded())
        let ff = totalFrames % max(framesPerSecond, 1)
        let totalSeconds = totalFrames / max(framesPerSecond, 1)
        return String(format: "%02d:%02d:%02d:%02d", totalSeconds / 3600, (totalSeconds % 3600) / 60, totalSeconds % 60, ff)
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

    /// 段块矩形（画布坐标）：x = timeToX(start)（含平移），宽 = max((end − start) × scale,
    /// 2)，纵向 [verticalInset, height − verticalInset]。
    static func blocks(ranges: [(index: Int, start: TimeInterval, end: TimeInterval)],
                       scale: CGFloat, height: CGFloat,
                       offset: TimeInterval = 0) -> [Block] {
        let blockHeight = max(height - 2 * verticalInset, 1)
        return ranges.map { range in
            let x = max(timeToX(range.start, pxPerSec: scale, offset: offset), 0)
            let width = max((range.end - range.start) * scale, minimumBlockWidth)
            return Block(
                index: range.index,
                rect: CGRect(x: x, y: verticalInset, width: width, height: blockHeight))
        }
    }

    /// 剪除段块矩形（剪辑 v1）：全高 [0, height]——与缩放段块（内缩 4pt）同 x 口径，
    /// 纵向铺满以视觉区分「剪除 = 整条时间轴上抹掉」。
    static func cutBlocks(ranges: [(index: Int, start: TimeInterval, end: TimeInterval)],
                          scale: CGFloat, height: CGFloat,
                          offset: TimeInterval = 0) -> [Block] {
        ranges.map { range in
            let x = max(timeToX(range.start, pxPerSec: scale, offset: offset), 0)
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

    /// 播放头横坐标（含平移；钳在 [−playheadWidth, width − playheadWidth]——zoom 后
    /// 播放头可在视图左缘之外）。
    static func playheadX(playhead: TimeInterval, scale: CGFloat, width: CGFloat,
                          offset: TimeInterval = 0) -> CGFloat {
        min(max(timeToX(playhead, pxPerSec: scale, offset: offset), -playheadWidth),
            max(width - playheadWidth, 0))
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
        /// 上一事件的光标/被拖端点时间（磁吸穿越检测基准；逐 mouseDragged 更新）。
        var lastSnappedTime: TimeInterval
    }

    private var dragSession: DragSession?
    /// 当前激活的磁吸点（拖拽中画黄色指示线；松手/脱吸清除）。
    private var activeSnapIndicator: TimeInterval?

    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: 滚轮/捏合（剪映对齐·时间线缩放平移）：⌘+滚轮 或 捏合 = 光标处缩放；
    // 普通滚轮（横向或纵向）= 平移。

    override func scrollWheel(with event: NSEvent) {
        guard let model, model.sourceDuration > 0, bounds.width > 0 else {
            return super.scrollWheel(with: event)
        }
        let scale = pxPerSec(model: model)
        let point = convert(event.locationInWindow, from: nil)
        let cursorTime = ZoomTimelineGeometry.xToTime(point.x, pxPerSec: scale, offset: model.timelineOffset)
        if event.modifierFlags.contains(.command) {
            // 缩放（光标锚定：缩放前后光标下时间不变）：自然方向 = 向上滚放大。
            let factor = exp(-Double(event.scrollingDeltaY) * 0.01)
            model.timelineZoom = min(max(model.timelineZoom * factor, 1), 200)
            let newScale = pxPerSec(model: model)
            model.timelineOffset = ZoomTimelineGeometry.clampedOffset(
                cursorTime - point.x / max(newScale, 0.001),
                sourceDuration: model.sourceDuration, zoom: model.timelineZoom)
        } else {
            // 平移：横向分量优先（触控板横扫），否则纵向分量（鼠标滚轮）。
            let delta = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
            guard delta != 0 else { return }
            model.timelineOffset = ZoomTimelineGeometry.clampedOffset(
                model.timelineOffset + TimeInterval(delta / max(scale, 0.001)),
                sourceDuration: model.sourceDuration, zoom: model.timelineZoom)
        }
    }

    /// 触控板捏合缩放（光标锚定）。
    override func magnify(with event: NSEvent) {
        guard let model, model.sourceDuration > 0, bounds.width > 0 else { return }
        let scale = pxPerSec(model: model)
        let point = convert(event.locationInWindow, from: nil)
        let cursorTime = ZoomTimelineGeometry.xToTime(point.x, pxPerSec: scale, offset: model.timelineOffset)
        let factor = 1 + Double(event.magnification)
        model.timelineZoom = min(max(model.timelineZoom * factor, 1), 200)
        let newScale = pxPerSec(model: model)
        model.timelineOffset = ZoomTimelineGeometry.clampedOffset(
            cursorTime - point.x / max(newScale, 0.001),
            sourceDuration: model.sourceDuration, zoom: model.timelineZoom)
    }

    /// 尺寸变化即重绘（比例尺依赖条宽；macOS NSView 无 needsDisplayOnBoundsChange）。
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    // MARK: 布局

    /// 有效像素率与平移（模型持有缩放态；画布经订阅重绘）。
    private func pxPerSec(model: ZoomEditorModel) -> CGFloat {
        ZoomTimelineGeometry.pxPerSec(
            width: bounds.width, sourceDuration: model.sourceDuration, zoom: model.timelineZoom)
    }

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
        ZoomTimelineGeometry.blocks(
            ranges: currentRanges(), scale: scale, height: bounds.height,
            offset: model?.timelineOffset ?? 0)
    }

    private func currentCutBlocks(scale: CGFloat) -> [ZoomTimelineGeometry.Block] {
        ZoomTimelineGeometry.cutBlocks(
            ranges: currentCutRanges(), scale: scale, height: bounds.height,
            offset: model?.timelineOffset ?? 0)
    }

    // MARK: 绘制（旧版视觉逐项对齐：背景 .quaternary 近似 / 段块选中 0.55、未选 0.3 /
    // 缓入出白端帽 0.35 / 端点把手白 0.75 / 播放头 accent 1.5pt；剪辑 v1 追加：剪除段
    // 红块全高 0.35 + 白把手，先画（下层），缩放段块后画（上层）盖过重叠区）

    override func draw(_ dirtyRect: NSRect) {
        guard let model else { return }
        let scale = pxPerSec(model: model)
        let offset = model.timelineOffset

        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(rect: bounds).fill()

        // 轨道缩略图 filmstrip（剪映对齐·批次 3）：槽位网格锚定源时间（每槽 = 1 个
        // 抽帧间隔），宽度随缩放重排；aspect-fill 铺满条高。在波形/红块之下——剪除区
        // 缩略图被红罩压暗可见。未就绪/无视频轨 → 空过。
        if let strip = model.filmstrip, scale > 0 {
            let slotWidth = CGFloat(strip.interval) * scale
            if slotWidth >= 2 { // 亚 2pt 槽不画（缩太小看不清，省绘制）
                let firstSlot = max(0, Int(offset / strip.interval))
                let lastSlot = min(Int(model.sourceDuration / strip.interval),
                                   Int((offset + Double(bounds.width) / scale) / strip.interval))
                for slot in firstSlot...max(lastSlot, firstSlot) {
                    guard let image = strip.images[TimeInterval(slot) * strip.interval] else { continue }
                    let x = ZoomTimelineGeometry.timeToX(
                        TimeInterval(slot) * strip.interval, pxPerSec: scale, offset: offset)
                    let rect = CGRect(x: x, y: 0, width: slotWidth, height: bounds.height)
                    drawAspectFill(image, in: rect)
                }
            }
        }

        // 音频波形带（剪映对齐·批次 2）：可见范围逐像素列聚合桶 min/max，中线对称
        // 画在 [0.25h, 0.75h] 带（蓝色半透明；在红块之下——剪除区音频被红罩压暗可见）。
        // 波形数据未就绪/无音轨 → 空过（条带保持背景）。
        let waveform = model.waveform
        if !waveform.isEmpty, scale > 0 {
            let bucketSeconds = 0.02
            let bandTop = bounds.height * 0.75
            let bandHeight = bounds.height * 0.5
            NSColor.systemBlue.withAlphaComponent(0.45).setFill()
            let columns = Int(bounds.width)
            for column in 0..<max(columns, 0) {
                let t0 = offset + Double(column) / scale
                let t1 = t0 + 1 / scale
                var index0 = max(0, Int(t0 / bucketSeconds))
                var index1 = min(waveform.count - 1, Int(t1 / bucketSeconds))
                if index1 < index0 { swap(&index0, &index1) }
                guard index0 <= index1 else { continue } // 列在波形时间轴之外
                var minimum = Float(1)
                var maximum = Float(-1)
                for index in index0...index1 {
                    minimum = min(minimum, waveform[index].minimum)
                    maximum = max(maximum, waveform[index].maximum)
                }
                guard maximum > minimum else { continue } // 静音列
                let x = CGFloat(column)
                let top = bandTop - CGFloat(maximum) * bandHeight / 2
                let bottom = bandTop - CGFloat(minimum) * bandHeight / 2
                NSBezierPath(rect: CGRect(x: x, y: bottom, width: 1, height: max(top - bottom, 1))).fill()
            }
        }

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

        // 磁吸指示线（剪映对齐·黄色竖线：拖拽中吸附生效的可视反馈，盖段块之上）。
        if let snapTime = activeSnapIndicator, dragSession != nil {
            let snapX = ZoomTimelineGeometry.timeToX(
                snapTime, pxPerSec: scale, offset: offset)
            NSColor.systemYellow.setFill()
            NSBezierPath(rect: CGRect(x: snapX - 0.5, y: 0, width: 1, height: bounds.height)).fill()
        }

        // 播放头竖线。
        let playheadX = ZoomTimelineGeometry.playheadX(
            playhead: model.playhead, scale: scale, width: bounds.width, offset: offset)
        NSColor.systemGreen.setFill()
        NSBezierPath(rect: CGRect(
            x: playheadX, y: 0,
            width: ZoomTimelineGeometry.playheadWidth, height: bounds.height)).fill()
    }

    /// aspect-fill 绘制（裁切铺满目标矩形——缩略图槽位同款裁切语义）。
    private func drawAspectFill(_ image: CGImage, in rect: CGRect) {
        let imageAspect = CGFloat(image.width) / CGFloat(image.height)
        let rectAspect = rect.width / max(rect.height, 1)
        var drawRect = rect
        if imageAspect > rectAspect {
            let width = rect.height * imageAspect
            drawRect = CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: rect.height)
        } else {
            let height = rect.width / imageAspect
            drawRect = CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.clip(to: rect)
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)).draw(in: drawRect)
        context.restoreGState()
    }

    // MARK: 鼠标事件（原生通道）

    override func mouseDown(with event: NSEvent) {
        guard let model else { return }
        let point = convert(event.locationInWindow, from: nil)
        let scale = pxPerSec(model: model)
        let offset = model.timelineOffset
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
            // = 点击背景跳播（旧语义）。锚点即参与磁吸（剪映同款——按下即吸边）。
            let rawAnchor = ZoomTimelineGeometry.xToTime(point.x, pxPerSec: scale, offset: offset)
            let snapped = ZoomTimelineGeometry.magnetSnap(
                proposed: rawAnchor, previous: nil, activeSnap: nil,
                candidates: magnetCandidates(model: model), toleranceSeconds: snapTolerance(pxPerSec: scale))
            let anchor = snapped?.time ?? rawAnchor
            activeSnapIndicator = snapped != nil ? anchor : nil
            dragSession = DragSession(
                kind: .cutCreate(anchor: anchor), startX: point.x,
                lastSnappedTime: anchor)
        }
    }

    private func beginZoomDrag(index: Int, isLeading: Bool, startX: CGFloat, model: ZoomEditorModel) {
        guard model.segments.indices.contains(index) else { return }
        let segment = model.segments[index]
        let origin = isLeading ? segment.start : segment.end
        dragSession = DragSession(
            kind: .zoomHandle(index: index, isLeading: isLeading,
                              originalStart: segment.start, originalEnd: segment.end),
            startX: startX, lastSnappedTime: origin)
    }

    private func beginCutDrag(index: Int, isLeading: Bool, startX: CGFloat, model: ZoomEditorModel) {
        guard model.cuts.indices.contains(index) else { return }
        let cut = model.cuts[index]
        let origin = isLeading ? cut.start : cut.end
        dragSession = DragSession(
            kind: .cutHandle(index: index, isLeading: isLeading,
                             originalStart: cut.start, originalEnd: cut.end),
            startX: startX, lastSnappedTime: origin)
    }

    /// 磁点容差（吸附剪映对齐）：把手宽度换算秒（1.25×——磁吸窗略宽于把手，配合粘滞）。
    private func snapTolerance(pxPerSec: CGFloat) -> TimeInterval {
        TimeInterval(ZoomTimelineGeometry.handleWidth / max(pxPerSec, 0.001)) * 1.25
    }

    /// 磁点收集（剪映对齐）：0 / 源时长 / 播放头 / 各剪除段与缩放段端点（排除集由调用方过滤）。
    private func magnetCandidates(model: ZoomEditorModel, excludingCut cutIndex: Int? = nil,
                                  excludingZoom zoomIndex: Int? = nil) -> [TimeInterval] {
        var candidates: [TimeInterval] = [0, model.sourceDuration, model.playhead]
        for (index, cut) in model.cuts.enumerated() where index != cutIndex {
            candidates.append(contentsOf: [cut.start, cut.end])
        }
        for (index, segment) in model.segments.enumerated() where index != zoomIndex {
            candidates.append(contentsOf: [segment.start, segment.end])
        }
        return candidates
    }

    /// 磁吸一步（邻近/粘滞/穿越 + 指示线维护）：返回生效时间；nil = 不吸附（清线用原值）。
    private func magnet(_ proposed: TimeInterval, previous: TimeInterval,
                        model: ZoomEditorModel, scale: CGFloat,
                        excludingCut cutIndex: Int? = nil, excludingZoom zoomIndex: Int? = nil) -> TimeInterval {
        let result = ZoomTimelineGeometry.magnetSnap(
            proposed: proposed, previous: previous, activeSnap: activeSnapIndicator,
            candidates: magnetCandidates(model: model, excludingCut: cutIndex, excludingZoom: zoomIndex),
            toleranceSeconds: snapTolerance(pxPerSec: scale))
        if let result {
            activeSnapIndicator = result.time
            return result.time
        }
        activeSnapIndicator = nil
        return proposed
    }

    override func mouseDragged(with event: NSEvent) {
        guard let session = dragSession, let model else { return }
        let point = convert(event.locationInWindow, from: nil)
        let scale = pxPerSec(model: model)
        let offset = model.timelineOffset
        let delta = (point.x - session.startX) / scale
        switch session.kind {
        case .zoomHandle(let index, let isLeading, let originalStart, let originalEnd):
            let previous = session.lastSnappedTime
            let raw = isLeading ? originalStart + delta : originalEnd + delta
            let snappedEnd = magnet(raw, previous: previous, model: model, scale: scale,
                                    excludingZoom: index)
            let start = isLeading ? snappedEnd : originalStart
            let end = isLeading ? originalEnd : snappedEnd
            model.dragPreview = ZoomEditorModel.DragPreview(index: index, start: start, end: end)
            model.scrub(to: snappedEnd) // 拖动扫查：预览跟随被拖端点
            dragSession?.lastSnappedTime = snappedEnd
        case .cutHandle(let index, let isLeading, let originalStart, let originalEnd):
            let previous = session.lastSnappedTime
            let raw = isLeading ? originalStart + delta : originalEnd + delta
            let snappedEnd = magnet(raw, previous: previous, model: model, scale: scale,
                                    excludingCut: index)
            let start = isLeading ? snappedEnd : originalStart
            let end = isLeading ? originalEnd : snappedEnd
            model.cutDragPreview = ZoomEditorModel.CutDragPreview(index: index, start: start, end: end)
            model.scrub(to: snappedEnd) // 拖动扫查：预览跟随被拖端点
            dragSession?.lastSnappedTime = snappedEnd
        case .cutCreate(let anchor):
            // 拖出 ≥4px 才成预览（亚拖动 = 点击，松手跳播）；拖动扫查：预览跟随光标
            //（scrub 原始跳转——光标在既有剪除段内也照实显示，扫查 ≠ 播放语义）。
            guard abs(point.x - session.startX) >= 4 else { return }
            let previous = session.lastSnappedTime
            let raw = ZoomTimelineGeometry.xToTime(point.x, pxPerSec: scale, offset: offset)
            let snappedTime = magnet(raw, previous: previous, model: model, scale: scale)
            model.cutDragPreview = ZoomEditorModel.CutDragPreview(
                index: nil,
                start: min(anchor, snappedTime),
                end: max(anchor, snappedTime))
            model.scrub(to: snappedTime)
            dragSession?.lastSnappedTime = snappedTime
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragSession = nil
            activeSnapIndicator = nil // 磁吸指示线松手即清
            if model?.cutDragPreview != nil { model?.cutDragPreview = nil }
            if model?.dragPreview != nil { model?.dragPreview = nil }
        }
        guard let session = dragSession, let model else { return }
        let scale = pxPerSec(model: model)
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
                model.seek(to: ZoomTimelineGeometry.xToTime(
                    session.startX, pxPerSec: scale, offset: model.timelineOffset)) // 点击背景跳播（旧语义）
            }
        }
    }

    /// 右键（含 Control+左键）：缩放段块 → 先选中再弹「删除分段」；剪除段块 → 弹
    /// 「删除剪除段」；背景右键无菜单（旧版同款）。
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let model else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let scale = pxPerSec(model: model)
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
