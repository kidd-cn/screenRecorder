import CoreGraphics
import CoreImage
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import ScreenCaptureKit

// MARK: - PiPFrame（简报 Produces 逐字）

/// 一帧合成里 PiP 小窗在捕获像素空间的位置与外观。坐标系契约见 `PiPCaptureGeometry`。
struct PiPFrame {
    /// 捕获像素空间 rect（左上原点、y 向下——与 SCStream 输出缓冲的行序一致）。
    var rectInCapturePixels: CGRect
    /// 圆角半径（捕获像素）；简报钉死默认 12。
    var cornerRadius: CGFloat = 12
}

// MARK: - PiPCaptureGeometry（屏坐标 → 捕获像素空间换算的纯函数载体）

/// 一次录制的捕获几何：PiP 浮窗（屏坐标 points）换算进捕获像素空间所需的全量参数。
/// 坐标系推导（与 T13 已验收的 `RegionSelectorMath` 同口径，读数实测自 CGDisplayBounds）：
///
/// - **屏坐标（Cocoa 全局）**：主屏左下原点、y 向上，points——浮窗 NSPanel.frame 所在系。
/// - **CG 全局（points）**：主屏左上原点、y 向下——`CGDisplayBounds` / `sourceRect` 所在系。
/// - **捕获像素空间**：SCStream 输出缓冲，左上原点、y 向下，单位物理像素。显示器模式下
///   = 显示器物理像素（Retina ×scale），region/window 模式 = 采样 rect 的 points 尺寸按 1x
///   计（T7 台账：区域/窗口 1x 采样，`streamConfig.width/height` 直接取 points 尺寸）。
///
/// 换算链：Cocoa rect →（`RegionSelectorMath.cgRect`，浮窗所在屏锚定）→ CG 全局 rect
/// → 减采集区原点、乘 scale → 捕获像素 rect。Y 轴翻转已由 Cocoa→CG 一步完成，捕获像素
/// 空间与 CG 全局同向（缓冲第 0 行 = 采集区顶边），故此处不再翻 Y。
struct PiPCaptureGeometry {
    /// 采集区左上角在 CG 全局系（points）的位置：显示器模式 = `CGDisplayBounds.origin`；
    /// region 模式 = region rect 原点；window 模式 = 录制窗口 frame 原点（SCWindow.frame 同 CG 全局）；
    /// windowRegion（P3b）= 窗口 frame 原点 + 窗口相对 rect 原点偏移。
    let captureOriginInCGPoints: CGPoint
    /// 捕获像素 / 屏幕点：显示器模式 = 物理像素宽 / 点宽（Retina 2x）；region/window = 1。
    let scale: CGFloat
    /// 捕获输出像素尺寸（= writer 输入尺寸，`SCStreamConfiguration.width/height` 同源）。
    let capturePixelSize: CGSize

    /// CG 全局 rect（points）→ 捕获像素 rect。空矩形返回 nil（合成侧按无 PiP 直通）；
    /// 越界不裁——可见性（与采集区求交）由 `PiPCompositor` 按相交关系决定，本层只做纯换算。
    func pipFrame(fromCGRect cgRect: CGRect) -> PiPFrame? {
        guard cgRect.width > 0, cgRect.height > 0, scale > 0, scale.isFinite else { return nil }
        return PiPFrame(rectInCapturePixels: CGRect(
            x: (cgRect.minX - captureOriginInCGPoints.x) * scale,
            y: (cgRect.minY - captureOriginInCGPoints.y) * scale,
            width: cgRect.width * scale,
            height: cgRect.height * scale))
    }

    /// CG 全局点（points）→ 捕获像素点。与 `pipFrame(fromCGRect:)` 同一平移链：减采集区
    /// 原点、乘 scale。越界不 clamp（T16 裁定：界外点击合成出画、CI 自然裁剪）——单点恒可换算。
    func capturePixelPoint(fromCGPoint cgPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: (cgPoint.x - captureOriginInCGPoints.x) * scale,
            y: (cgPoint.y - captureOriginInCGPoints.y) * scale)
    }

    /// 按捕获模式解析几何（录制 begin 时一次性调用；解析失败返回 nil = 本场录制纯屏幕）。
    /// 系统读数（CGDisplayBounds / CGDisplayCopyDisplayMode / SCShareableContent）无头不可测，
    /// 纯换算部分由 `pipFrame(fromCGRect:)` 钉死。
    static func resolve(for mode: CaptureMode) async -> PiPCaptureGeometry? {
        switch mode {
        case .display(let displayID):
            let bounds = CGDisplayBounds(displayID)
            guard bounds.width > 1, bounds.height > 1,
                  let displayMode = CGDisplayCopyDisplayMode(displayID) else { return nil }
            let scale = CGFloat(displayMode.pixelWidth) / bounds.width
            guard scale > 0, scale.isFinite else { return nil }
            return PiPCaptureGeometry(
                captureOriginInCGPoints: bounds.origin,
                scale: scale,
                capturePixelSize: CGSize(width: displayMode.pixelWidth, height: displayMode.pixelHeight))
        case .region(let rect, _):
            guard rect.width > 1, rect.height > 1 else { return nil }
            // region 采样按 points 1x 计（T7 台账：streamConfig 直接取 rect 尺寸）
            return PiPCaptureGeometry(captureOriginInCGPoints: rect.origin, scale: 1, capturePixelSize: rect.size)
        case .window(let windowID):
            // 录制窗口的 CG 全局 frame 原点（SCWindow.frame 同 CG 全局口径）；流输出 = frame 尺寸 1x。
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
            return PiPCaptureGeometry(
                captureOriginInCGPoints: window.frame.origin,
                scale: 1,
                capturePixelSize: window.frame.size)
        case .app(let bundleID):
            // P3a：画布 = 该 App 全部可录窗口的 union 包围盒（与 SCStreamRecorder 的 filter
            // 构造同一收集函数与同一 SCWindow→快照映射）；枚举失败/零窗口返回 nil = 本场纯屏幕。
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return nil }
            let selected = WindowPicker.appWindows(
                ofBundleID: bundleID,
                from: WindowPicker.shareableSnapshots(from: content.windows))
            guard !selected.isEmpty else { return nil }
            let canvas = selected.reduce(CGRect.null) { $0.union($1.frame) }
            return PiPCaptureGeometry(
                captureOriginInCGPoints: canvas.origin,
                scale: 1,
                capturePixelSize: canvas.size)
        case .windowRegion(let windowID, let rect):
            // P3b：画布 = 窗口内采样子集的绝对位置 = 窗口 frame 原点 + 窗口相对 rect 原点
            //（SCWindow.frame 与窗口模式同 CG 全局口径，平移即得采样区左上角；Y 向已在
            // 同一全局系内，不再翻转）。rect 在开录时已钳制于窗口（SCStreamRecorder），此处
            // 沿用同值不再重钳——录制中窗口缩小与一期 window/region 模式同为「几何按现场
            // 解析、流不重配置」语义。枚举失败/窗口已关返回 nil = 本场纯屏幕。
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
            return PiPCaptureGeometry(
                captureOriginInCGPoints: CGPoint(
                    x: window.frame.origin.x + rect.minX,
                    y: window.frame.origin.y + rect.minY),
                scale: 1,
                capturePixelSize: rect.size)
        }
    }
}

// MARK: - PiPCompositor（简报 Produces：逐帧合成器）

/// 逐帧合成器（T15/T16）：屏幕帧为底，PiP 摄像头帧按 `PiPFrame` 贴入捕获像素空间（CI 连续
/// 圆角 mask），点击高亮按 `ClickOverlayState` 画黄描边半透明圆（CI 椭圆 mask + alpha 衰减）。热路径纪律：
/// - `CIContext` 单实例复用（`useSoftwareRenderer: false` 走 GPU，简报钉死）；
/// - 输出缓冲取自 `CVPixelBufferPool`（避免逐帧 ~24MB 级大分配；池按 screenFrame 实测尺寸
///   建立与重建，耗尽兜底直建）；
/// - 画布尺寸以逐帧实测的 `screenFrame` 尺寸为准（修复轮 Minor #2：`init(pixelSize:)` 的
///   尺寸只是提示，消除「缓冲实际尺寸 == init 假设」前提）；
/// - 无 PiP（pip / pipFrame 为 nil）或完全不相交时 PiP 路**零渲染**；无点击态或圈不可得时
///   点击路**零渲染**；笔画快照空/nil 时笔画路**零渲染**（未在画的常态帧掩图缓存直取，
///   零栅格化）；缩放仿射 nil 时缩放步恒等跳过；键帽快照 nil/文本空时键帽路**零渲染**
///   （文本不变的常态帧键帽位图缓存直取，零栅格化零 CoreText 排版）；多路皆空时**直返原 buffer**；
/// - 合成不触碰 PTS（`at pts` 原样透传由调用方 append）；只在任一效果缝在位时被调用
///   （调用方门控：`SCStreamRecorder` 按注入缝在位与否装配合成器）。
/// 线程模型：全部方法在 SCStream video 队列（样本回调队列）串行执行，池与四处缓存（圆角
/// mask / 点击环 mask / 笔画位图单槽 / 键帽位图单槽）无需加锁。
final class PiPCompositor {
    /// 单实例复用的渲染上下文（简报钉死：useSoftwareRenderer: false）。
    let context = CIContext(options: [.useSoftwareRenderer: false])

    /// 简报签名保留的期望画布尺寸（提示值）；实际画布一律以逐帧实测的 screenFrame 尺寸为准。
    private let pixelSize: CGSize
    /// 输出缓冲池（32BGRA @ 首帧实测尺寸，尺寸变化时按实测重建；创建失败退化为逐帧直建，
    /// 宁分配不丢帧）。只在 video 队列访问，无需加锁。
    private var bufferPool: CVPixelBufferPool?
    /// 当前池对应的实测尺寸（nil = 池未建/已弃用——错误尺寸的池化缓冲不得使用）。
    private var poolSize: CGSize?
    /// 圆角 mask 缓存：键为（宽, 高, 半径）——浮窗尺寸录制中恒定，实际 ≤ 1 项；封顶防御。
    private var maskCache: [MaskCacheKey: CIImage] = [:]

    private struct MaskCacheKey: Hashable {
        let width: Int
        let height: Int
        let radius: CGFloat
    }

    /// 点击高亮描边宽（捕获像素，T16）：描边中心恰在 `ClickOverlayState.radiusInPixels` 圆上。
    static let clickStrokeWidth: CGFloat = 4
    /// 点击高亮描边色：纯黄、基态不透明度 85%（简报「黄色描边半透明圆」；衰减由
    /// `ClickOverlayState.alpha` 逐帧再乘）。CIColor 字面量直接进 CI 工作空间，不经位图解码。
    static let clickRingColor = CIColor(red: 1, green: 1, blue: 0, alpha: 0.85)
    /// 点击圈掩图缓存：键为（位图边长, 描边宽）——半径录制中恒定，实际 ≤ 1 项；封顶防御。
    private var clickMaskCache: [ClickMaskKey: CIImage] = [:]

    private struct ClickMaskKey: Hashable {
        let side: Int
        let strokeWidth: CGFloat
        /// 修复轮 1 #1：不同 radius 可能向上取整到同一 side——键不含 radius 会互相命中、画错圈。
        let radius: CGFloat
    }

    /// 笔画彩色位图单槽缓存：键为快照值 + 画布尺寸——快照相等（未在画）时逐帧零分配直取；
    /// 续写/撤销/清空使快照不等即重栅格化（正在画的拖拽帧才付位图成本）。
    private var strokesMaskCache: (snapshot: MarkingStrokeSnapshot,
                                   canvasWidth: Int,
                                   canvasHeight: Int,
                                   image: CIImage)?

    /// 键帽位图单槽缓存（P4）：键为快照值（文本 + 样式）——键帽位图只依赖快照，画布无关
    /// （底部居中的摆放平移逐帧做，零成本仿射）。文本不变（linger 窗口内）逐帧零分配直取；
    /// 新按键/样式切换使快照不等即重排 CoreText 重栅格化。
    private var keycapLayerCache: (snapshot: KeyboardOverlaySnapshot, image: CIImage)?

    /// 键帽底边距（捕获像素，简报钉定）：键帽底边距画布下沿 24px，水平居中。
    static let keycapBottomMargin: CGFloat = 24
    /// 键帽配色（P4 两色单选）：主色 = 深底白字（半透明 0.65，悬浮观感不遮底内容重心），
    /// 备选色 = 浅底黑字（0.85）。取色在合成器（SettingsStore 只存布尔档位）。
    private static let keycapPrimaryFill = (CGFloat(0.1), CGFloat(0.1), CGFloat(0.1), CGFloat(0.65))
    private static let keycapPrimaryText = (CGFloat(1), CGFloat(1), CGFloat(1), CGFloat(1))
    private static let keycapAlternateFill = (CGFloat(1), CGFloat(1), CGFloat(1), CGFloat(0.85))
    private static let keycapAlternateText = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(1))

    /// 笔画彩色位图（premultiplied RGBA：笔画带各自色值、其余透明，边沿 AA）。
    /// 坐标：笔画点为底帧归一化（左上原点、y 向下 0…1），CGContext 原点左下、y 向上——
    /// 与 CI 画布同一翻转（`ciY = 画布高 − 缓冲 y`，placeClickOverlay 同口径）。
    /// 单点笔画（点击未拖）画圆头点。
    private static func makeStrokesCGImage(_ snapshot: MarkingStrokeSnapshot,
                                           canvasWidth: Int,
                                           canvasHeight: Int) -> CGImage? {
        let context = CGContext(
            data: nil, width: canvasWidth, height: canvasHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context else { return nil }
        let canvasW = CGFloat(canvasWidth)
        let canvasH = CGFloat(canvasHeight)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in snapshot.strokes {
            let lineWidth = CGFloat(stroke.width) * min(canvasW, canvasH)
            guard lineWidth > 0, lineWidth.isFinite else { continue }
            context.setStrokeColor(red: CGFloat(stroke.color.red), green: CGFloat(stroke.color.green),
                                   blue: CGFloat(stroke.color.blue), alpha: 1)
            context.setFillColor(red: CGFloat(stroke.color.red), green: CGFloat(stroke.color.green),
                                 blue: CGFloat(stroke.color.blue), alpha: 1)
            context.setLineWidth(lineWidth)
            // 归一化（y 向下）→ 位图坐标（y 向上）：x×宽、y = 高 − y×高。
            let mapped = stroke.points.map { point in
                CGPoint(x: point.x * canvasW, y: canvasH - point.y * canvasH)
            }
            guard let first = mapped.first else { continue }
            if mapped.count == 1 {
                // 单点笔画：圆头半径的实心点（描边零长线段不出墨）。
                let radius = lineWidth / 2
                context.fillEllipse(in: CGRect(x: first.x - radius, y: first.y - radius,
                                               width: lineWidth, height: lineWidth))
                continue
            }
            context.beginPath()
            context.move(to: first)
            for point in mapped.dropFirst() {
                context.addLine(to: point)
            }
            context.strokePath()
        }
        return context.makeImage()
    }

    /// - Parameter pixelSize: 期望输出尺寸（提示值，简报签名逐字）；实际画布以逐帧实测的
    ///   screenFrame 尺寸为准，缓冲池延迟到首帧按实测尺寸建立。
    init(pixelSize: CGSize) {
        self.pixelSize = pixelSize
    }

    /// 逐帧合成（Task 9 终态签名：签名增 `keyboardOverlay`，位于 `zoomTransform` 与 `at`
    /// 之间、其后无参——终态签名钉定，`at` 之后不得再加参）。screen 为底；全效果缺省直返
    /// screen（零渲染直返原 buffer，与一期逐字节一致）。单效果缺省时该路零渲染跳过，另路照常。
    ///
    /// 次序终态（Task 9 钉定，修订 Task 8 注释中「键帽在 PiP 之后」的预告）：底帧 → 点击环
    /// → **标记笔画**（两者皆内容锚定层）→ **统一施加缩放** → **键帽**（底部居中，视口锚定层）
    /// → PiP（视口锚定层最上——PiP 撞键帽时 PiP 胜出）。笔画与环同在缩放之下——笔画随内容
    /// 一起缩放（content-anchored）；键帽与 PiP 在缩放之上（viewport-anchored）。
    /// `zoomTransform` 为 CI 画布空间（y 向上，与 placeClickOverlay/placePip 的换算口径同源）
    /// 的仿射；`transformed(by:)` 是惰性 CI recipe，热路径零位图分配。
    @discardableResult
    func composite(screenFrame: CVPixelBuffer,
                   pip: CVPixelBuffer?,
                   pipFrame: PiPFrame?,
                   clickOverlay: ClickOverlayState? = nil,
                   strokes: MarkingStrokeSnapshot? = nil,
                   zoomTransform: CGAffineTransform? = nil,
                   keyboardOverlay: KeyboardOverlaySnapshot? = nil,
                   at pts: CMTime,
                   into context: CIContext) -> CVPixelBuffer {
        guard pip != nil || clickOverlay != nil || strokes != nil || zoomTransform != nil || keyboardOverlay != nil else { return screenFrame } // 全缺省：零开销直返原 buffer
        // 画布尺寸以 screenFrame 实测为准（修复轮 Minor #2）：与 init pixelSize 失配时按
        // 实测求交、换算与出图——不得误判越界直通，也不得输出错误尺寸。
        let bounds = CGRect(
            x: 0, y: 0,
            width: CVPixelBufferGetWidth(screenFrame),
            height: CVPixelBufferGetHeight(screenFrame))
        let base = CIImage(cvPixelBuffer: screenFrame)
        var composed: CIImage?

        // 点击高亮（内容锚定层，v2）：先画在底帧上，置于缩放之下。出画由 CI 自然裁剪；
        // 圈不可得（半径/alpha 非法）本路直通不丢帧。
        if let clickOverlay, let overlayImage = placeClickOverlay(clickOverlay, in: bounds) {
            composed = overlayImage.composited(over: composed ?? base)
        }
        // 标记笔画（内容锚定层，P2）：画在环之上、缩放之下。快照空/掩图失败本路直通不丢帧；
        // 掩图单槽缓存使「未在画」的常态帧零栅格化（与点击环的掩图缓存同一热路径纪律）。
        if let strokes, let strokesImage = placeStrokes(strokes, in: bounds) {
            composed = strokesImage.composited(over: composed ?? base)
        }
        // 统一缩放（v2）：对已含环与笔画的画面施加 zoomTransform（nil = 恒等跳过）。
        if let zoomTransform {
            composed = (composed ?? base).transformed(by: zoomTransform)
        }
        // 键帽层（P4，视口锚定层）：底部居中圆角键帽，缩放之上、PiP 之下。快照 nil/文本空/
        // 位图失败本路直通；文本不变逐帧直取位图单槽缓存（零栅格化零排版）。
        if let keyboardOverlay, let keycap = placeKeyboardOverlay(keyboardOverlay, in: bounds) {
            composed = keycap.composited(over: composed ?? base)
        }
        // PiP（视口锚定层最上，v2）：键帽后的画面为底。rect 空 / 不相交 / 源异常任一失败即
        // 本路零渲染直通。
        if let pip, let pipFrame {
            composed = placePip(pip, pipFrame: pipFrame, in: bounds, over: composed ?? base)
        }

        guard let composed, let output = dequeueOutputBuffer(size: bounds.size) else { return screenFrame }
        context.render(composed, to: output)
        return output
    }

    /// 标记笔画层（P2）：全部笔画栅格化为一张**彩色** RGBA 位图——每笔画自带
    /// `MarkingColor`（黑/红），掩图方案（灰度形状 + 单色 CIBlendWithMask）装不下
    /// 逐笔画颜色，直接把色值烘进位图再 sourceOver 合成（一次栅格化、零滤镜链）。
    /// 缓存：快照值 + 画布尺寸作单槽键——`MarkingStrokeSnapshot` 为 Equatable 值类型，
    /// 未在画时逐帧相等直取缓存（零分配）。
    /// 线宽按底帧**短边**归一换算像素（`width × min(w, h)`，简报钉定），圆头圆角连接。
    private func placeStrokes(_ snapshot: MarkingStrokeSnapshot, in bounds: CGRect) -> CIImage? {
        guard !snapshot.strokes.isEmpty else { return nil }
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        guard width > 0, height > 0 else { return nil }
        if let cache = strokesMaskCache,
           cache.snapshot == snapshot, cache.canvasWidth == width, cache.canvasHeight == height {
            return cache.image
        }
        guard let layerCG = Self.makeStrokesCGImage(snapshot, canvasWidth: width, canvasHeight: height) else {
            return nil
        }
        let layer = CIImage(cgImage: layerCG).cropped(to: bounds)
        strokesMaskCache = (snapshot, width, height, layer) // 单槽缓存（快照变更即整体换装）
        return layer
    }

    /// 键帽摆放（P4）：圆角键帽位图贴画布**底部居中**（底边距 24px，简报钉定），出画由
    /// `cropped(to:)` 自然裁剪。文本空 / 位图生成失败返回 nil = 本帧不合成（直通不丢帧）。
    /// 位图单槽缓存：文本 + 样式不变逐帧直取（零栅格化零 CoreText 排版）；摆放只是平移
    /// 仿射（CI 惰性 recipe，逐帧零成本），故缓存与画布尺寸无关。
    private func placeKeyboardOverlay(_ overlay: KeyboardOverlaySnapshot, in bounds: CGRect) -> CIImage? {
        guard !overlay.text.isEmpty else { return nil }
        let keycap: CIImage
        if let cache = keycapLayerCache, cache.snapshot == overlay {
            keycap = cache.image
        } else {
            guard let cg = Self.makeKeycapCGImage(for: overlay) else { return nil }
            keycap = CIImage(cgImage: cg)
            keycapLayerCache = (overlay, keycap) // 单槽缓存（快照变更即整体换装）
        }
        let extent = keycap.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else {
            return nil
        }
        // 缓冲坐标（左上原点）→ CI 坐标（左下原点）同 placePip 口径（ciY = 画布高 − 缓冲 y）：
        // 键帽缓冲底边 = 画布高 − 24 → CI 原点 y = 画布高 − (画布高 − 24) = 24，恰为底边距。
        let ciOrigin = CGPoint(x: bounds.midX - extent.width / 2, y: Self.keycapBottomMargin)
        return keycap.transformed(by: CGAffineTransform(translationX: ciOrigin.x, y: ciOrigin.y))
            .cropped(to: bounds)
    }

    /// 键帽位图（圆角矩形底 + CoreText 文字，文字渲染沿用合成器位图生成惯例）：系统字体
    /// 字号字面直用（SettingsStore 档位 12/14/18 即捕获像素，与 ClickOverlayState
    /// radiusInPixels 同口径，栅格化时按 1x 捕获像素取值）；两色单选在此外观定值。
    /// 布局：水平内边距 0.7×字号、垂直 0.45×字号、圆角 0.28×键帽高，文字基线贴下缘内边距。
    private static func makeKeycapCGImage(for overlay: KeyboardOverlaySnapshot) -> CGImage? {
        let fontSize = CGFloat(overlay.style.fontSize)
        guard fontSize > 0, fontSize.isFinite else { return nil }
        let (fill, text) = overlay.style.colorAlternate
            ? (keycapAlternateFill, keycapAlternateText)
            : (keycapPrimaryFill, keycapPrimaryText)
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
        guard let font else { return nil } // 字体创建失败：无键帽直通（不丢帧）
        let attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(
                red: text.0, green: text.1, blue: text.2, alpha: text.3),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: overlay.text, attributes: attributes))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let textHeight = ascent + descent
        guard textWidth > 0, textWidth.isFinite, textHeight > 0, textHeight.isFinite else { return nil }

        let padX = fontSize * 0.7
        let padY = fontSize * 0.45
        let width = max(1, Int((textWidth + padX * 2).rounded(.up)))
        let height = max(1, Int((textHeight + padY * 2).rounded(.up)))
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context else { return nil }
        // 圆角底（位图坐标 y 向上，与 CI 画布同向，无翻转）。
        let radius = CGFloat(height) * 0.28
        let capRect = CGRect(x: 0, y: 0, width: width, height: height)
        context.addPath(CGPath(roundedRect: capRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(CGColor(red: fill.0, green: fill.1, blue: fill.2, alpha: fill.3))
        context.fillPath()
        // CoreText 文字：基线贴下缘内边距（位图不翻 CTM，CoreText 直绘即正立）。
        context.textPosition = CGPoint(x: padX, y: padY)
        CTLineDraw(line, context)
        return context.makeImage()
    }

    /// PiP 摆放（原 composite 主体逐行搬移；`base` 形参名保留，v2 下传入的底图是
    /// 缩放后的画面）：返回合成后的整幅图像；nil = 本帧不合成 PiP。
    private func placePip(_ pip: CVPixelBuffer, pipFrame: PiPFrame, in bounds: CGRect, over base: CIImage) -> CIImage? {
        let targetRect = pipFrame.rectInCapturePixels
        guard !targetRect.isEmpty, bounds.intersection(targetRect) != .null else { return nil }
        let pipImage = CIImage(cvPixelBuffer: pip)
        guard pipImage.extent.width > 0, pipImage.extent.height > 0, targetRect.width > 0 else { return nil }

        // 摄像头帧等比缩放到目标 rect（源为 .vga640x480，窗口同 4:3，等比即完整覆盖）
        let scale = targetRect.width / pipImage.extent.width
        var placedPip = pipImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        placedPip = applyRoundedCornerMask(to: placedPip, radius: pipFrame.cornerRadius)
        // CI 坐标系 y 向上；目标 rect 是缓冲区坐标（左上原点）。换算平移量：CI y = 画布高 - rect 底。
        let ciOrigin = CGPoint(x: targetRect.minX, y: bounds.height - targetRect.maxY)
        placedPip = placedPip.transformed(by: CGAffineTransform(translationX: ciOrigin.x, y: ciOrigin.y))

        // sourceOver：PiP 在上（self=placedPip），屏幕帧为底。屏幕帧全不透明，参数顺序
        // 反了会把 PiP 完全盖住（本用例已由测试钉死）。
        return placedPip.composited(over: base)
    }

    /// 点击高亮圈（T16）：黄描边半透明圆，描边中心恰在 `radiusInPixels`，整体不透明度按
    /// `overlay.alpha` 衰减（tracker 交付态已按 600ms 窗口回填；合成器不读钟，逐帧确定）。
    /// 缓冲区坐标 → CI 坐标同 PiP 约定（ciY = 画布高 − 缓冲 y；圆无方向性，仅换算圆心）。
    /// 圈 mask 按（位图边长, 描边宽）生成一次并缓存——录制中恒定，实际 ≤ 1 项。返回 nil =
    /// 本帧不合成（半径/alpha 非法或 mask 生成失败，直通不丢帧）。
    private func placeClickOverlay(_ overlay: ClickOverlayState, in bounds: CGRect) -> CIImage? {
        let radius = overlay.radiusInPixels
        let alpha = overlay.alpha
        guard radius > 0, radius.isFinite, alpha > 0, alpha.isFinite, alpha <= 1.001 else { return nil }
        guard let ringMask = clickRingMask(radius: radius, strokeWidth: Self.clickStrokeWidth) else { return nil }

        let center = CGPoint(x: overlay.point.x, y: bounds.height - overlay.point.y)
        // 裁剪域取描边外沿（半径 + 描边半宽 + AA 余量）：裁到圆心线圆界会把描边外半截剪掉，
        // 四个切线区的采样点恰好落在被剪的边界上（修复自 RED 后首跑：环带缺右/下弧段）。
        let outer = radius + Self.clickStrokeWidth / 2 + 1
        let outerRect = CGRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2)
        let maskExtent = ringMask.extent
        let placedMask = ringMask.transformed(by: CGAffineTransform(
            translationX: center.x - maskExtent.midX,
            y: center.y - maskExtent.midY))
        // CI 椭圆 mask：黄色描边层按环带亮度掩图取形（mask 白 255=全取 / 黑 0=透明，二元
        // 灰阶——不引入中灰，避免 CI 工作色彩空间解码往返的中间值漂移）。
        guard let blend = CIFilter(name: "CIBlendWithMask") else { return nil }
        blend.setValue(CIImage(color: Self.clickRingColor).cropped(to: outerRect), forKey: kCIInputImageKey)
        blend.setValue(CIImage(color: .clear).cropped(to: outerRect), forKey: kCIInputBackgroundImageKey)
        blend.setValue(placedMask, forKey: kCIInputMaskImageKey)
        guard let ring = blend.outputImage else { return nil }
        // 淡出不透明度：整体 alpha 缩放（CIColorMatrix alpha 通道）。
        guard let fade = CIFilter(name: "CIColorMatrix") else { return nil }
        fade.setValue(ring, forKey: kCIInputImageKey)
        fade.setValue(CIVector(x: 0, y: 0, z: 0, w: alpha), forKey: "inputAVector")
        return fade.outputImage
    }

    /// 环带亮度掩图（8bit 灰度：描边带白 255、其余黑 0，边沿 AA），按（边长, 描边宽）缓存。
    private func clickRingMask(radius: CGFloat, strokeWidth: CGFloat) -> CIImage? {
        // 位图盖住描边外沿 + 1px AA 余量；圆心置于位图正中（竖直对称，翻转方向不影响结果）。
        let side = Int(((radius + strokeWidth / 2 + 1) * 2).rounded(.up))
        guard side > 1 else { return nil }
        let key = ClickMaskKey(side: side, strokeWidth: strokeWidth, radius: radius)
        if let cached = clickMaskCache[key] { return cached }
        guard let cg = Self.makeRingMaskCGImage(side: side, radius: radius, strokeWidth: strokeWidth) else {
            return nil
        }
        let mask = CIImage(cgImage: cg)
        if clickMaskCache.count < 4 {
            clickMaskCache[key] = mask // 封顶缓存（尺寸恒定，实际远低于上限）
        }
        return mask
    }

    /// 环带掩图位图：描边中心恰在半径 `radius` 的圆上（CGContext 描边椭圆）。
    private static func makeRingMaskCGImage(side: Int, radius: CGFloat, strokeWidth: CGFloat) -> CGImage? {
        let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        guard let context else { return nil }
        let c = CGFloat(side) / 2
        context.setStrokeColor(gray: 1, alpha: 1)
        context.setLineWidth(strokeWidth)
        context.strokeEllipse(in: CGRect(x: c - radius, y: c - radius, width: radius * 2, height: radius * 2))
        return context.makeImage()
    }

    /// 圆角 mask（最终尺寸空间）：CIBlendWithMask 用圆角矩形亮度图把 PiP 圆角外抹成透明。
    private func applyRoundedCornerMask(to image: CIImage, radius: CGFloat) -> CIImage {
        let extent = image.extent
        guard radius > 0, extent.width > 2 * radius, extent.height > 2 * radius else { return image }
        let key = MaskCacheKey(width: Int(extent.width), height: Int(extent.height), radius: radius)
        if let cached = maskCache[key] { return cached }
        guard let maskCG = PiPCompositor.makeRoundedRectMaskCGImage(extent: extent, radius: radius) else {
            return image // mask 生成失败：方角降级（不丢帧）
        }
        let mask = CIImage(cgImage: maskCG)
        guard let blend = CIFilter(name: "CIBlendWithMask") else { return image }
        blend.setValue(image, forKey: kCIInputImageKey)
        blend.setValue(CIImage(color: .clear).cropped(to: extent), forKey: kCIInputBackgroundImageKey)
        blend.setValue(mask, forKey: kCIInputMaskImageKey)
        guard let masked = blend.outputImage else { return image }
        if maskCache.count < 8 {
            maskCache[key] = masked.cropped(to: extent) // 封顶缓存（尺寸恒定，实际远低于上限）
        }
        return masked.cropped(to: extent)
    }

    /// 圆角矩形亮度掩图（8bit 灰度：圆角内白 255、外黑 0，边沿 AA），CIImage(cgImage:) 直接消费。
    private static func makeRoundedRectMaskCGImage(extent: CGRect, radius: CGFloat) -> CGImage? {
        let width = Int(extent.width.rounded())
        let height = Int(extent.height.rounded())
        guard width > 0, height > 0 else { return nil }
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        context?.setFillColor(gray: 1, alpha: 1)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let path = CGPath(
            roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context?.addPath(path)
        context?.fillPath()
        return context?.makeImage()
    }

    // MARK: 测试缝（Review Focus #1 代码级钉子）

    /// 当前输出缓冲池与其尺寸（internal 只读）：PiPCompositorTests 钉「连帧命中同一池实例、
    /// 池尺寸稳定」——逐帧重建池/直建兜底即逐帧分配，测试即红。只在 video 队列/测试读，
    /// 与池字段同无锁纪律。
    var activeOutputPool: CVPixelBufferPool? { bufferPool }
    var activeOutputPoolSize: CGSize? { poolSize }

    /// 从池取输出缓冲（按 screenFrame 实测尺寸建池，尺寸变化时重建）；池不可用/耗尽时直建
    /// 兜底（罕见路径，宁分配不丢帧）。重建失败即弃池——错误尺寸的池化缓冲不得使用。
    private func dequeueOutputBuffer(size: CGSize) -> CVPixelBuffer? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0, height > 0 else { return nil }
        if poolSize != size {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
            var pool: CVPixelBufferPool?
            if CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess,
               let pool {
                bufferPool = pool
                poolSize = size
            } else {
                bufferPool = nil
                poolSize = nil
            }
        }
        if let bufferPool {
            var pooled: CVPixelBuffer?
            if CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, bufferPool, &pooled) == kCVReturnSuccess,
               let pooled {
                return pooled
            }
        }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, nil, &buffer
        ) == kCVReturnSuccess else { return nil }
        return buffer
    }
}
