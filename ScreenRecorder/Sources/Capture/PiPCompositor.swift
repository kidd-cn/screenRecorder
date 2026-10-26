import CoreGraphics
import CoreImage
import CoreMedia
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
    /// region 模式 = region rect 原点；window 模式 = 录制窗口 frame 原点（SCWindow.frame 同 CG 全局）。
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
///   点击路**零渲染**；两路皆空时**直返原 buffer**；
/// - 合成不触碰 PTS（`at pts` 原样透传由调用方 append）；只在 PiP 或点击高亮开启时被调用
///   （调用方门控：`SCStreamRecorder` 按注入缝在位与否装配合成器）。
/// 线程模型：全部方法在 SCStream video 队列（样本回调队列）串行执行，池与两处 mask 缓存无需加锁。
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

    /// - Parameter pixelSize: 期望输出尺寸（提示值，简报签名逐字）；实际画布以逐帧实测的
    ///   screenFrame 尺寸为准，缓冲池延迟到首帧按实测尺寸建立。
    init(pixelSize: CGSize) {
        self.pixelSize = pixelSize
    }

    /// 逐帧合成（简报 Produces 签名逐字，T16 增 clickOverlay）。screen 为底；PiP 与点击高亮
    /// 双缺省直返 screen（零渲染直返原 buffer）。单效果缺省时该路零渲染跳过，另一路照常。
    @discardableResult
    func composite(screenFrame: CVPixelBuffer,
                   pip: CVPixelBuffer?,
                   pipFrame: PiPFrame?,
                   clickOverlay: ClickOverlayState? = nil,
                   at pts: CMTime,
                   into context: CIContext) -> CVPixelBuffer {
        guard pip != nil || clickOverlay != nil else { return screenFrame } // 双缺省：零开销直返原 buffer
        // 画布尺寸以 screenFrame 实测为准（修复轮 Minor #2）：与 init pixelSize 失配时按
        // 实测求交、换算与出图——不得误判越界直通，也不得输出错误尺寸。
        let bounds = CGRect(
            x: 0, y: 0,
            width: CVPixelBufferGetWidth(screenFrame),
            height: CVPixelBufferGetHeight(screenFrame))
        let base = CIImage(cvPixelBuffer: screenFrame)
        var composed: CIImage?

        // PiP（T15 管线原样搬移）：rect 空 / 不相交 / 源异常任一失败即本路零渲染直通。
        if let pip, let pipFrame {
            composed = placePip(pip, pipFrame: pipFrame, in: bounds, over: base)
        }
        // 点击高亮（T16）：出画由 CI 自然裁剪；圈不可得（半径/alpha 非法）本路直通不丢帧。
        if let clickOverlay, let overlayImage = placeClickOverlay(clickOverlay, in: bounds) {
            composed = overlayImage.composited(over: composed ?? base)
        }

        guard let composed, let output = dequeueOutputBuffer(size: bounds.size) else { return screenFrame }
        context.render(composed, to: output)
        return output
    }

    /// PiP 摆放（原 composite 主体逐行搬移）：返回合成后的整幅图像；nil = 本帧不合成 PiP。
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
