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

    /// 命中分类（剪辑 v2 片段流）：缩放段把手/段体、接缝把手（含首尾裁切缝）、背景。
    enum Hit: Equatable {
        case background
        case leadingHandle(index: Int)
        case trailingHandle(index: Int)
        case segment(index: Int)
        case seamHandle(index: Int)
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

    /// 命中（缩放段层 + 接缝把手）：缩放段块优先，接缝把手其次（接缝竖线 ± 把手宽
    /// 热区），背景兜底。
    /// 接缝热区半宽（4pt——比把手窄；热区过宽会在短 clip 密集时盖满整条时间线，
    /// 波纹删除武装不起来——2026-11-21 用户反馈根因）。
    static let seamHitHalfWidth: CGFloat = 4

    /// 命中（缩放段层 + 接缝把手）：缩放段块优先；接缝取**最近**一条且 ≤4pt
    ///（多接缝拥挤时先到先得会武断吞掉相邻热区）。
    static func hit(at point: CGPoint, zoomBlocks: [Block],
                    seamPositions: [CGFloat], height: CGFloat) -> Hit {
        let zoomHit = hit(at: point, in: zoomBlocks)
        if zoomHit != .background { return zoomHit }
        var nearestIndex: Int?
        var nearestDistance = seamHitHalfWidth
        for (index, x) in seamPositions.enumerated() {
            let distance = abs(point.x - x)
            if distance <= nearestDistance {
                nearestIndex = index
                nearestDistance = distance
            }
        }
        if let nearestIndex { return .seamHandle(index: nearestIndex) }
        _ = height
        return .background
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
            /// 接缝拖动（seamIndex ∈ 0...clips.count；baseSourceTime = 接缝当前源时间）。
            case seamHandle(seamIndex: Int, baseSourceTime: TimeInterval)
            /// 空白处波纹删除拖选（锚 = 成品时间）。
            case rippleDelete(anchor: TimeInterval)
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

    private func currentBlocks(scale: CGFloat) -> [ZoomTimelineGeometry.Block] {
        ZoomTimelineGeometry.blocks(
            ranges: currentRanges(), scale: scale, height: bounds.height,
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

        // 轨道缩略图 filmstrip（剪映对齐·批次 3+4a）：槽位网格锚定**源时间**，成品轴
        // 定位经 outputTime 映射（波纹删除后缩略图随接缝重排——被删源区间的槽位无映射
        // 即跳过）；槽宽按所在 clip 速度折算。未就绪/无视频轨 → 空过。
        if let strip = model.filmstrip, scale > 0 {
            let lastSlot = Int(model.sourceDuration / strip.interval)
            if lastSlot >= 0 {
                let viewLeft = offset
                let viewRight = offset + Double(bounds.width) / max(scale, 0.001)
                for slot in 0...max(lastSlot, 0) {
                    let sourceTime = TimeInterval(slot) * strip.interval
                    guard let outputTime = model.clipsDocument.outputTime(forSourceTime: sourceTime),
                          outputTime >= viewLeft - strip.interval,
                          outputTime <= viewRight + strip.interval else { continue } // 被删/可视外槽位
                    guard let image = strip.images[sourceTime] else { continue }
                    let speed = model.clipsDocument.speed(atSourceTime: sourceTime) ?? 1
                    let slotWidth = max(CGFloat(strip.interval / speed) * scale, 2)
                    let x = ZoomTimelineGeometry.timeToX(outputTime, pxPerSec: scale, offset: offset)
                    drawAspectFill(image, in: CGRect(x: x, y: 0, width: slotWidth, height: bounds.height))
                }
            }
        }

        // 片段流：接缝竖线（白 1pt）+ 选中 clip 高亮（蓝 1pt 描边）；缩略图/波形经
        // 成品→源映射逐列查采样。接缝位置数组供命中热区。
        var seamPositions: [CGFloat] = []
        if !model.clips.isEmpty {
            var cursor: TimeInterval = 0
            NSColor.white.withAlphaComponent(0.6).setFill()
            for clip in model.clips {
                cursor += clip.displayDuration
                let x = ZoomTimelineGeometry.timeToX(cursor, pxPerSec: scale, offset: offset)
                seamPositions.append(x)
                NSBezierPath(rect: CGRect(x: x - 0.5, y: 0, width: 1, height: bounds.height)).fill()
            }
            if let selected = model.selectedClipIndex, model.clips.indices.contains(selected) {
                var startCursor: TimeInterval = 0
                for (index, clip) in model.clips.enumerated() {
                    let clipStart = startCursor
                    let clipEnd = startCursor + clip.displayDuration
                    startCursor = clipEnd
                    guard index == selected else { continue }
                    let x0 = ZoomTimelineGeometry.timeToX(clipStart, pxPerSec: scale, offset: offset)
                    let x1 = ZoomTimelineGeometry.timeToX(clipEnd, pxPerSec: scale, offset: offset)
                    NSColor.systemBlue.withAlphaComponent(0.9).setStroke()
                    NSBezierPath(rect: CGRect(x: x0 + 0.5, y: 0.5, width: max(x1 - x0 - 1, 1), height: bounds.height - 1)).stroke()
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
                // 成品时间 → 源时间（波纹删除后列与源桶的对应经映射；裁掉列跳过）
                let outputT0 = offset + Double(column) / scale
                let outputT1 = outputT0 + 1 / scale
                guard let sourceT0 = model.clipsDocument.sourceTime(forOutputTime: outputT0),
                      let sourceT1 = model.clipsDocument.sourceTime(forOutputTime: min(outputT1, model.outputDuration)) else { continue }
                let sourceSpeed = model.clipsDocument.speed(atSourceTime: sourceT0) ?? 1
                var index0 = max(0, Int(sourceT0 / bucketSeconds))
                var index1 = min(waveform.count - 1, Int(sourceT1 / bucketSeconds))
                if index1 < index0 { swap(&index0, &index1) }
                guard index0 <= index1 else { continue } // 静音列
                var minimum = Float(1)
                var maximum = Float(-1)
                for index in index0...index1 {
                    minimum = min(minimum, waveform[index].minimum)
                    maximum = max(maximum, waveform[index].maximum)
                }
                guard maximum > minimum else { continue }
                let x = CGFloat(column)
                let top = bandTop - CGFloat(maximum) * bandHeight / 2
                let bottom = bandTop - CGFloat(minimum) * bandHeight / 2
                NSBezierPath(rect: CGRect(x: x, y: bottom, width: 1, height: max(top - bottom, 1))).fill()
            }
        }

        // 剪除段块（下层、全高、红）：把手视觉与缩放段同款白 0.75。
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

        // 波纹删除拖选红罩预览（成品区间，盖段块之上——松手即删除接合）。
        if let preview = model.ripplePreview {
            let x0 = ZoomTimelineGeometry.timeToX(preview.0, pxPerSec: scale, offset: offset)
            let x1 = ZoomTimelineGeometry.timeToX(preview.1, pxPerSec: scale, offset: offset)
            NSColor.systemRed.withAlphaComponent(0.35).setFill()
            NSBezierPath(rect: CGRect(x: x0, y: 0, width: max(x1 - x0, 1), height: bounds.height)).fill()
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
        let zoomBlocks = currentBlocks(scale: scale)
        switch ZoomTimelineGeometry.hit(at: point, zoomBlocks: zoomBlocks,
                                        seamPositions: seamPositions(), height: bounds.height) {
        case .leadingHandle(let index):
            beginZoomDrag(index: index, isLeading: true, startX: point.x, model: model)
        case .trailingHandle(let index):
            beginZoomDrag(index: index, isLeading: false, startX: point.x, model: model)
        case .segment(let index):
            model.selectedIndex = index
        case .seamHandle(let seamIndex):
            // 接缝把手：base = 接缝当前源时间（输出边界 → 源时间）
            let boundaryOutput = model.clips.prefix(seamIndex).reduce(0) { $0 + $1.displayDuration }
            let baseSource = model.clipsDocument.sourceTime(forOutputTime: boundaryOutput)
                ?? model.clipsDocument.sourceTime(forOutputTime: max(boundaryOutput - 0.01, 0))
                ?? 0
            dragSession = DragSession(
                kind: .seamHandle(seamIndex: seamIndex, baseSourceTime: baseSource),
                startX: point.x, lastSnappedTime: baseSource)
        case .background:
            let rawTime = ZoomTimelineGeometry.xToTime(point.x, pxPerSec: scale, offset: offset)
            if event.modifierFlags.contains(.command), let clipIndex = model.clipIndex(atOutputTime: rawTime) {
                // ⌘+点击 = 选中 clip（速度面板）
                model.selectedClipIndex = model.selectedClipIndex == clipIndex ? nil : clipIndex
                return
            }
            // 空白按下：波纹删除拖选武装（拖出 ≥4px 成红罩预览）；松手未拖 = 点击跳播。
            // 锚点参与磁吸（吸缝边）。
            let snapped = ZoomTimelineGeometry.magnetSnap(
                proposed: rawTime, previous: nil, activeSnap: nil,
                candidates: magnetCandidates(model: model), toleranceSeconds: snapTolerance(pxPerSec: scale))
            let anchor = snapped?.time ?? rawTime
            activeSnapIndicator = snapped != nil ? anchor : nil
            dragSession = DragSession(
                kind: .rippleDelete(anchor: anchor), startX: point.x, lastSnappedTime: anchor)
        }
    }

    /// 接缝位置（成品坐标，绘制/命中共用）。
    private func seamPositions() -> [CGFloat] {
        guard let model else { return [] }
        var positions: [CGFloat] = []
        var cursor: TimeInterval = 0
        let scale = pxPerSec(model: model)
        for clip in model.clips {
            cursor += clip.displayDuration
            positions.append(ZoomTimelineGeometry.timeToX(cursor, pxPerSec: scale, offset: model.timelineOffset))
        }
        return positions
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

    /// 磁点容差（吸附剪映对齐）：把手宽度换算秒（1.25×——磁吸窗略宽于把手，配合粘滞）。
    private func snapTolerance(pxPerSec: CGFloat) -> TimeInterval {
        TimeInterval(ZoomTimelineGeometry.handleWidth / max(pxPerSec, 0.001)) * 1.25
    }

    /// 磁点收集（剪映对齐）：0 / 源时长 / 播放头 / 各剪除段与缩放段端点（排除集由调用方过滤）。
    private func magnetCandidates(model: ZoomEditorModel, excludingCut cutIndex: Int? = nil,
                                  excludingZoom zoomIndex: Int? = nil) -> [TimeInterval] {
        var candidates: [TimeInterval] = [0, model.sourceDuration, model.playhead]
        for (index, clip) in model.clips.enumerated() where index != cutIndex {
            candidates.append(contentsOf: [clip.sourceStart, clip.sourceEnd])
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
            let start = isLeading ? originalStart + delta : originalStart
            let end = isLeading ? originalEnd : originalEnd + delta
            model.dragPreview = ZoomEditorModel.DragPreview(index: index, start: start, end: end)
            // 拖动扫查：预览跟随被拖端点（输出坐标）
            model.scrub(to: isLeading ? start : end)
        case .seamHandle(let seamIndex, let baseSourceTime):
            // 接缝拖动：光标成品位移 → 源位移（× 邻接 clip 速度——取右 clip，越界回左）
            let currentTime = ZoomTimelineGeometry.xToTime(point.x, pxPerSec: scale, offset: offset)
            let outputDelta = currentTime - session.lastSnappedTime
            let neighbourSpeed = model.clips.indices.contains(seamIndex)
                ? model.clips[seamIndex].speed
                : (model.clips.last?.speed ?? 1)
            let sourceTarget = baseSourceTime + outputDelta * neighbourSpeed
            model.moveSeam(at: seamIndex, toSourceTime: sourceTarget)
            model.scrub(to: currentTime)
        case .rippleDelete(let anchor):
            // 波纹删除拖选：红罩预览（含磁吸/穿越）；扫查跟随光标（原始成品坐标）。
            guard abs(point.x - session.startX) >= 4 else { return }
            let previous = session.lastSnappedTime
            let raw = ZoomTimelineGeometry.xToTime(point.x, pxPerSec: scale, offset: offset)
            let snappedTime = magnet(raw, previous: previous, model: model, scale: scale)
            model.ripplePreview = (min(anchor, snappedTime), max(anchor, snappedTime))
            model.scrub(to: snappedTime)
            dragSession?.lastSnappedTime = snappedTime
        }
    }
    override func mouseUp(with event: NSEvent) {
        defer {
            dragSession = nil
            activeSnapIndicator = nil // 磁吸指示线松手即清
            model?.ripplePreview = nil
            if model?.dragPreview != nil { model?.dragPreview = nil }
        }
        guard let session = dragSession, let model else { return }
        switch session.kind {
        case .zoomHandle(let index, _, _, _):
            if let preview = model.dragPreview {
                model.commitDrag(index: index, start: preview.start, end: preview.end)
            }
        case .seamHandle:
            break // moveSeam 已逐拖拽事件提交（统一闸+撤销栈逐事件快照）
        case .rippleDelete(let anchor):
            if let preview = model.ripplePreview {
                model.cutOutputRange(lower: preview.0, upper: preview.1)
                model.settlePlayhead()
                _ = anchor
            } else {
                model.seek(to: session.lastSnappedTime) // 点击背景跳播
            }
        }
    }

    /// 右键（含 Control+左键）：缩放段块 → 先选中再弹「删除分段」菜单；接缝/背景无菜单。
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let model else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let scale = pxPerSec(model: model)
        switch ZoomTimelineGeometry.hit(at: point, zoomBlocks: currentBlocks(scale: scale),
                                        seamPositions: seamPositions(), height: bounds.height) {
        case .leadingHandle(let hitIndex), .trailingHandle(let hitIndex), .segment(let hitIndex):
            guard model.segments.indices.contains(hitIndex) else { return nil }
            model.selectedIndex = hitIndex
            return ZoomEditorMenus.deleteSegment(at: hitIndex, model: model)
        case .seamHandle:
            return nil // 接缝无右键菜单（修剪=拖动；删除=拖选+撤销）
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

}
