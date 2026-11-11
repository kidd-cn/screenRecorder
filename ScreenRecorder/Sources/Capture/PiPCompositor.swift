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
        case .audioOnly:
            // P7a：仅声音无视频画布——nil = 无采集几何，点击高亮/缩放/标记各取数缝整体
            // 不装配（composite 直通语义的上游；audioOnly 会话本无视频帧，composite 永不
            // 触及，此 nil 是穷尽性表态 + 视效链路的双保险）。
            return nil
        case .cameraOnly:
            // P7b：仅摄像头无屏幕画布（有视频但源是摄像头）——nil = 无采集几何，语义与
            // audioOnly 同形：cameraOnly 会话的 PiP/高亮/缩放/标记链在 makeConfiguration
            // 已强制全关且协调器装配 CameraOnlyRecorder（无屏幕合成链），resolve 不应被
            // 触达；此 nil 是穷尽性表态 + 视效链路的双保险。
            return nil
        }
    }
}

// MARK: - SwappedLayout（对调布局 contain 几何纯函数载体）

/// 对调布局纯函数（spec §3.2）：摄像头 contain 进画布——缩放比取宽高比**小者**，
/// 居中，余处为黑边（合成侧铺纯黑底）。坐标系：捕获像素空间（左上原点、y 向下）。
enum SwappedLayout {
    /// 非法输入（任一边 ≤ 0 / 非有限）返回 nil = 本帧不合成摄像头主画面。
    /// 取整纪律同 ScreenshotCore 裁剪：origin .rounded(.down)、size .rounded(.up)。
    static func cameraContainRect(canvasSize: CGSize, cameraSize: CGSize) -> CGRect? {
        guard canvasSize.width > 0, canvasSize.height > 0,
              cameraSize.width > 0, cameraSize.height > 0,
              canvasSize.width.isFinite, canvasSize.height.isFinite,
              cameraSize.width.isFinite, cameraSize.height.isFinite else { return nil }
        let scale = min(canvasSize.width / cameraSize.width,
                        canvasSize.height / cameraSize.height)
        let width = (cameraSize.width * scale).rounded(.up)
        let height = (cameraSize.height * scale).rounded(.up)
        let x = ((canvasSize.width - width) / 2).rounded(.down)
        let y = ((canvasSize.height - height) / 2).rounded(.down)
        return CGRect(x: x, y: y, width: width, height: height)
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
///   （文本不变的常态帧键帽位图缓存直取，零栅格化零 CoreText 排版）；多路皆空时**直返原
///   buffer**（unswapped；`layoutSwapped` 在位恒合成——对调态全源缺省 = 诚实黑画布，T2）；
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

    /// 逐帧合成（Task 9 终态签名；T2 增 `layoutSwapped`，位于 `keyboardOverlay` 与 `at`
    /// 之间、`at` 之后仍无参——终态纪律延续，缺省 false 与今日逐字节一致）。screen 为底；
    /// unswapped 且全效果缺省直返 screen（零渲染直返原 buffer，与一期逐字节一致）。单效果
    /// 缺省时该路零渲染跳过，另路照常。
    ///
    /// 次序终态（unswapped，Task 9 钉定）：底帧 → 点击环 → **标记笔画**（两者皆内容锚定层）
    /// → **统一施加缩放** → **键帽**（底部居中，视口锚定层）→ PiP（视口锚定层最上——PiP 撞
    /// 键帽时 PiP 胜出）。笔画与环同在缩放之下——笔画随内容一起缩放（content-anchored）；
    /// 键帽与 PiP 在缩放之上（viewport-anchored）。
    ///
    /// 对调态（`layoutSwapped`，spec §3.2，T2）：环/笔画/缩放仍施加于屏幕层之后，布局对调——
    /// **黑底画布** → **摄像头 contain 主画面**（`SwappedLayout.cameraContainRect` 等比居中、
    /// 直角无裁剪无圆角）→ **屏幕层**（环/笔画/缩放已施加）aspect-fill 缩进小图（圆角）→
    /// **键帽**（视口锚定画布底部居中，分支内最上）。对调帧全源缺省不直返：guard 含
    /// `layoutSwapped`，恒合成诚实黑画布（不透传上一帧屏幕画面）。
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
                   layoutSwapped: Bool = false,
                   at pts: CMTime,
                   into context: CIContext) -> CVPixelBuffer {
        guard pip != nil || layoutSwapped || clickOverlay != nil || strokes != nil || zoomTransform != nil || keyboardOverlay != nil else { return screenFrame } // 全缺省：零开销直返原 buffer（layoutSwapped 在位恒合成——对调态全源缺省 = 诚实黑画布）
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
        if layoutSwapped {
            // 对调态（T2，spec §3.2）：屏幕层（环/笔画/缩放已施加）先存，画布铺纯黑底，
            // 摄像头 contain 主画面（直角）与小图（圆角）按对调布局摆放，键帽分支内最后
            //（视口锚定最上）。任一路失败保下层直通（黑画布/主画面不被吞）。
            let screenWithEffects = composed ?? base
            composed = CIImage(color: .black).cropped(to: bounds) // 黑边底色纯黑
            if let pip, let withCamera = placeCameraMain(pip, in: bounds, over: composed ?? base) {
                composed = withCamera // 摄像头路失败（源异常）：保黑画布，本帧不合成摄像头
            }
            if let pipFrame, let withInset = placeScreenInset(screenWithEffects, pipFrame: pipFrame, in: bounds, over: composed ?? base) {
                composed = withInset // 小图路失败（rect 空/不相交）：保下层，本帧不合成小图
            }
            // 键帽（视口锚定层）：画布底部居中不受对调影响，置于小图之后（分支最上）。
            if let keyboardOverlay, let keycap = placeKeyboardOverlay(keyboardOverlay, in: bounds) {
                composed = keycap.composited(over: composed ?? base)
            }
        } else {
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
        }

        guard let composed, let output = dequeueOutputBuffer(size: bounds.size) else {
            return screenFrame
        }
        context.render(composed, to: output)
        return output
    }

    /// 对调态成片缩影（spec §3.3 修订版，替代原屏幕内容缩略图缝）：完整对调布局的
    /// 实时缩略预览——黑底画布 + 摄像头 contain 主画面 + 屏幕小图同位角标，整幅按
    /// `s = min(1, maxEdgeLength / max(canvasW, canvasH))` 缩为 mini 画布（canvas×s）。
    /// 合成次序同 composite 对调分支（减键帽减特效）：小图特效（点击环/笔画瞬态）与键帽
    ///（视口内容）不入缩影——瞬态/视口内容经 ≤0.5s 采样会失真频闪，缩影表达布局不是
    /// 特效（spec §3.3 修订裁定）；摄像头不镜像（成片语义，镜像属预览特权）、小图圆角
    /// 同成片（radius×s）。渲染纪律：`self.context` 单实例 createCGImage 出图（mini 域
    /// 裁剪保证出图尺寸 = mini 画布）。guard：screen 零尺寸/非有限 或 maxEdgeLength 非法
    /// → nil（诚实不产）；camera nil → 黑主画面 + 小图照常（断源窗口期缩影 = 成片真实
    /// 内容）；pipFrame nil → 摄像头 + 纯黑（无小图）。video 队列串行调用（≤0.5s 节流在
    /// 调用方 SCStreamRecorder），与池/缓存同无锁纪律。
    func makeSwappedPreview(camera: CVPixelBuffer?, screen: CVPixelBuffer,
                            pipFrame: PiPFrame?, maxEdgeLength: CGFloat = 320) -> CGImage? {
        let canvasWidth = CGFloat(CVPixelBufferGetWidth(screen))
        let canvasHeight = CGFloat(CVPixelBufferGetHeight(screen))
        guard canvasWidth > 0, canvasHeight > 0, canvasWidth.isFinite, canvasHeight.isFinite,
              maxEdgeLength > 0, maxEdgeLength.isFinite else { return nil }
        let scale = min(CGFloat(1), maxEdgeLength / max(canvasWidth, canvasHeight))
        guard scale > 0, scale.isFinite else { return nil }
        let miniSize = CGSize(width: canvasWidth * scale, height: canvasHeight * scale)
        let miniBounds = CGRect(origin: .zero, size: miniSize)
        // 黑底画布（黑边底色纯黑，与 composite 对调分支同底）。
        var composed = CIImage(color: .black).cropped(to: miniBounds)
        // 摄像头 contain 主画面：rect 复用 SwappedLayout.cameraContainRect 纯函数在**全画布**
        // 求出，rect×s 落进 mini 画布；放置纪律同 placeCameraMain（clamped(to: extent) →
        // scale（contain 比×s）→ 平移（ciY = miniH − rect.maxY）→ cropped(to: rect)——源
        // 先钳位到自身 extent（边缘延伸堵双线性读出源域外的透明黑掺入），输出再裁回 rect，
        // 黑边保纯黑）。rect 非法/源异常本路直通不丢层（保下层黑画布或既有主画面）。
        if let camera,
           let containRect = SwappedLayout.cameraContainRect(
                canvasSize: CGSize(width: canvasWidth, height: canvasHeight),
                cameraSize: CGSize(width: CVPixelBufferGetWidth(camera),
                                   height: CVPixelBufferGetHeight(camera))) {
            let miniRect = CGRect(
                x: containRect.minX * scale, y: containRect.minY * scale,
                width: containRect.width * scale, height: containRect.height * scale)
            let rawCamera = CIImage(cvPixelBuffer: camera)
            if rawCamera.extent.width > 0, rawCamera.extent.height > 0,
               miniRect.width > 0, miniRect.height > 0 {
                let cameraScale = min(miniRect.width / rawCamera.extent.width,
                                      miniRect.height / rawCamera.extent.height)
                if cameraScale > 0, cameraScale.isFinite {
                    let ciRect = CGRect(x: miniRect.minX, y: miniSize.height - miniRect.maxY,
                                        width: miniRect.width, height: miniRect.height)
                    let placed = rawCamera
                        .clamped(to: rawCamera.extent)
                        .transformed(by: CGAffineTransform(scaleX: cameraScale, y: cameraScale))
                        .transformed(by: CGAffineTransform(
                            translationX: miniRect.minX,
                            y: miniSize.height - miniRect.maxY))
                        .cropped(to: ciRect)
                    composed = placed.composited(over: composed)
                }
            }
        }
        // 屏幕小图同位角标：screen **原始层**（不施加特效——Ruling 20① 同口径）aspect-fill
        //（scale 取宽高比大者 + 中心裁剪）进 pipFrame.rectInCapturePixels×s，
        // `applyRoundedCornerMask(radius: pipFrame.cornerRadius × s)`（圆角同成片），平移
        // 到位（placeScreenInset 同数学同坐标换算，ciY = miniH − rect.maxY）。rect 空/
        // 不相交/源异常本路直通（无小图，主画面不被吞）。
        if let pipFrame {
            let fullRect = pipFrame.rectInCapturePixels
            let targetRect = CGRect(
                x: fullRect.minX * scale, y: fullRect.minY * scale,
                width: fullRect.width * scale, height: fullRect.height * scale)
            let screenLayer = CIImage(cvPixelBuffer: screen)
            if !targetRect.isEmpty,
               miniBounds.intersection(targetRect) != .null,
               screenLayer.extent.width > 0, screenLayer.extent.height > 0,
               targetRect.width > 0, targetRect.height > 0 {
                let fillScale = max(targetRect.width / screenLayer.extent.width,
                                    targetRect.height / screenLayer.extent.height)
                if fillScale > 0, fillScale.isFinite {
                    let scaled = screenLayer.transformed(by: CGAffineTransform(scaleX: fillScale, y: fillScale))
                    // 中心裁剪到 rect 尺寸：origin 归零后打圆角（圆角 mask 与图像须同
                    // origin-0 对齐），最后统一平移到摆放位（placeScreenInset 逐行同构）。
                    let cropOrigin = CGPoint(
                        x: scaled.extent.midX - targetRect.width / 2,
                        y: scaled.extent.midY - targetRect.height / 2)
                    var placedInset = scaled
                        .cropped(to: CGRect(origin: cropOrigin, size: targetRect.size))
                        .transformed(by: CGAffineTransform(translationX: -cropOrigin.x, y: -cropOrigin.y))
                    placedInset = applyRoundedCornerMask(to: placedInset, radius: pipFrame.cornerRadius * scale)
                    let ciOrigin = CGPoint(x: targetRect.minX, y: miniSize.height - targetRect.maxY)
                    placedInset = placedInset.transformed(by: CGAffineTransform(translationX: ciOrigin.x, y: ciOrigin.y))
                    composed = placedInset.composited(over: composed)
                }
            }
        }
        return context.createCGImage(composed, from: miniBounds)
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

        // 摄像头帧 aspect-fill 到目标 rect（scale 取宽高比大者 + 中心裁剪）：设备实际交付
        // 帧宽高比随机型/系统变化（验收机交付 16:9，`.vga640x480` 的 4:3 假设未被遵循），
        // 按宽等比缩放会在 rect 顶部留空档透出下层画面（验收缺陷：顶条原画面）。fill 与
        // 预览层 `.resizeAspectFill` 同语义——窗内所见即成片所得。
        let scale = max(targetRect.width / pipImage.extent.width,
                        targetRect.height / pipImage.extent.height)
        let scaled = pipImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // 中心裁剪到 rect 尺寸：origin 归零后打圆角（圆角 mask 与图像须同 origin-0 对齐），
        // 最后统一平移到摆放位。等比失配时裁掉溢出侧，恰好匹配时裁剪/平移皆为零（原行为）。
        let cropOrigin = CGPoint(
            x: scaled.extent.midX - targetRect.width / 2,
            y: scaled.extent.midY - targetRect.height / 2)
        var placedPip = scaled
            .cropped(to: CGRect(origin: cropOrigin, size: targetRect.size))
            .transformed(by: CGAffineTransform(translationX: -cropOrigin.x, y: -cropOrigin.y))
        placedPip = applyRoundedCornerMask(to: placedPip, radius: pipFrame.cornerRadius)
        // CI 坐标系 y 向上；目标 rect 是缓冲区坐标（左上原点）。换算平移量：CI y = 画布高 - rect 底。
        let ciOrigin = CGPoint(x: targetRect.minX, y: bounds.height - targetRect.maxY)
        placedPip = placedPip.transformed(by: CGAffineTransform(translationX: ciOrigin.x, y: ciOrigin.y))

        // sourceOver：PiP 在上（self=placedPip），屏幕帧为底。屏幕帧全不透明，参数顺序
        // 反了会把 PiP 完全盖住（本用例已由测试钉死）。
        return placedPip.composited(over: base)
    }

    /// 摄像头 contain 主画面（对调态，T2）：`SwappedLayout.cameraContainRect` 等比居中贴入
    /// 画布——直角、无裁剪、无圆角（主画面语义：人脸完整不裁）。缩放比取宽高比**小者**
    ///（与 cameraContainRect 同式，修复轮 1）：rect 尺寸含 ceil 舍入松弛（每维 ≤ +1px），
    /// 单取宽比会把松弛放大成竖比源的超高（如 101×200 → 41.58 vs rect 高 40，上端 1.58px
    /// 伸出画布被裁 = 源顶 7.6 行内容永不显示，违反「绝不裁剪」）；取小者后 scaled 两维
    /// ≤ rect，裁剪只剩舍入松弛。contain rect 非法 / 源异常返回 nil = 本帧不合成摄像头路
    ///（保下层黑画布）。CI 坐标换算与 placePip 同口径（ciY = bounds.height − 缓冲 y）。
    /// contain 恰好贴合时双线性采样会读到源 extent 外（透明黑掺入边列）——源先钳位到
    /// 自身 extent（边缘延伸），输出再裁剪到 contain rect（防钳位延伸外溢出 rect），
    /// 黑边保持纯黑。
    private func placeCameraMain(_ pip: CVPixelBuffer, in bounds: CGRect, over base: CIImage) -> CIImage? {
        let cameraSize = CGSize(width: CVPixelBufferGetWidth(pip), height: CVPixelBufferGetHeight(pip))
        guard let containRect = SwappedLayout.cameraContainRect(canvasSize: bounds.size, cameraSize: cameraSize) else {
            return nil
        }
        let rawCamera = CIImage(cvPixelBuffer: pip)
        guard rawCamera.extent.width > 0, rawCamera.extent.height > 0, containRect.width > 0, containRect.height > 0 else { return nil }
        let scale = min(containRect.width / rawCamera.extent.width,
                        containRect.height / rawCamera.extent.height)
        guard scale > 0, scale.isFinite else { return nil }
        let ciContainRect = CGRect(
            x: containRect.minX,
            y: bounds.height - containRect.maxY,
            width: containRect.width,
            height: containRect.height)
        let placed = rawCamera
            .clamped(to: rawCamera.extent)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(
                translationX: containRect.minX,
                y: bounds.height - containRect.maxY))
            .cropped(to: ciContainRect)
        return placed.composited(over: base)
    }

    /// 屏幕层缩进小图（对调态，T2）：aspect-fill（scale 取宽高比**大者** + 中心裁剪，
    /// placePip 同数学同坐标换算）→ `applyRoundedCornerMask(radius: pipFrame.cornerRadius)`
    /// → 平移到位。rect 空/不相交/源异常返回 nil = 本帧不合成小图路（拖出采集区 = 小图
    /// 消失的诚实语义）。
    private func placeScreenInset(_ screen: CIImage, pipFrame: PiPFrame, in bounds: CGRect, over base: CIImage) -> CIImage? {
        let targetRect = pipFrame.rectInCapturePixels
        guard !targetRect.isEmpty, bounds.intersection(targetRect) != .null else { return nil }
        // 屏幕层先裁回画布域：点击环/笔画的掩图层 extent 可能伸出画布（环掩图域以点击点
        // 为心外扩），union extent 会把下方中心裁剪窗口整体带偏（小图内容错位、露底色）。
        // 画布外内容在 unswapped 输出中本就不可见，裁齐后两种布局同一画布域。
        let screenLayer = screen.cropped(to: bounds)
        guard screenLayer.extent.width > 0, screenLayer.extent.height > 0, targetRect.width > 0, targetRect.height > 0 else { return nil }

        let scale = max(targetRect.width / screenLayer.extent.width,
                        targetRect.height / screenLayer.extent.height)
        guard scale > 0, scale.isFinite else { return nil }
        let scaled = screenLayer.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // 中心裁剪到 rect 尺寸：origin 归零后打圆角（圆角 mask 与图像须同 origin-0 对齐），
        // 最后统一平移到摆放位（与 placePip 逐行同构）。
        let cropOrigin = CGPoint(
            x: scaled.extent.midX - targetRect.width / 2,
            y: scaled.extent.midY - targetRect.height / 2)
        var placedInset = scaled
            .cropped(to: CGRect(origin: cropOrigin, size: targetRect.size))
            .transformed(by: CGAffineTransform(translationX: -cropOrigin.x, y: -cropOrigin.y))
        placedInset = applyRoundedCornerMask(to: placedInset, radius: pipFrame.cornerRadius)
        // CI 坐标系 y 向上；目标 rect 是缓冲区坐标（左上原点）。换算平移量：CI y = 画布高 - rect 底。
        let ciOrigin = CGPoint(x: targetRect.minX, y: bounds.height - targetRect.maxY)
        placedInset = placedInset.transformed(by: CGAffineTransform(translationX: ciOrigin.x, y: ciOrigin.y))
        return placedInset.composited(over: base)
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
    /// 缓存的是 mask 形状图（尺寸/半径录制中恒定，逐帧零生成）；混合每帧现跑——缓存合成
    /// 输出会把输出 DAG 钉在首帧缓冲上，键恒定即第二帧起命中缓存，成片 PiP 冻结在第一帧
    ///（真机验收缺陷：亮场首帧恰为合成图而「看着正常」，暗场首帧黑而「人像不见」；
    /// 钉测 testConsecutiveCompositesTrackNewPipContent）。
    private func applyRoundedCornerMask(to image: CIImage, radius: CGFloat) -> CIImage {
        let extent = image.extent
        guard radius > 0, extent.width > 2 * radius, extent.height > 2 * radius else { return image }
        let key = MaskCacheKey(width: Int(extent.width), height: Int(extent.height), radius: radius)
        let mask: CIImage
        if let cached = maskCache[key] {
            mask = cached
        } else {
            guard let maskCG = PiPCompositor.makeRoundedRectMaskCGImage(extent: extent, radius: radius) else {
                return image // mask 生成失败：方角降级（不丢帧）
            }
            mask = CIImage(cgImage: maskCG)
            if maskCache.count < 8 {
                maskCache[key] = mask // 封顶缓存（尺寸恒定，实际远低于上限）
            }
        }
        guard let blend = CIFilter(name: "CIBlendWithMask") else { return image }
        blend.setValue(image, forKey: kCIInputImageKey)
        blend.setValue(CIImage(color: .clear).cropped(to: extent), forKey: kCIInputBackgroundImageKey)
        blend.setValue(mask, forKey: kCIInputMaskImageKey)
        guard let masked = blend.outputImage else { return image }
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
