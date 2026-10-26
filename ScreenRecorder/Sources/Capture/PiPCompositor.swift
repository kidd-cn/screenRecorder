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

/// 逐帧合成器（T15）：屏幕帧为底，PiP 摄像头帧按 `PiPFrame` 贴入捕获像素空间，CI 连续
/// 圆角 mask。热路径纪律：
/// - `CIContext` 单实例复用（`useSoftwareRenderer: false` 走 GPU，简报钉死）；
/// - 输出缓冲取自 `CVPixelBufferPool`（避免逐帧 ~24MB 级大分配；池按 screenFrame 实测尺寸
///   建立与重建，耗尽兜底直建）；
/// - 画布尺寸以逐帧实测的 `screenFrame` 尺寸为准（修复轮 Minor #2：`init(pixelSize:)` 的
///   尺寸只是提示，消除「缓冲实际尺寸 == init 假设」前提）；
/// - 无 PiP（pip / pipFrame 为 nil）或完全不相交时**零渲染直返原 buffer**；
/// - 合成不触碰 PTS（`at pts` 原样透传由调用方 append，本参数为 Task 16 点击高亮的
///   时间轴预留）；只在 PiP 或点击高亮开启时被调用（调用方门控）。
/// 线程模型：全部方法在 SCStream video 队列（样本回调队列）串行执行，池与 mask 缓存无需加锁。
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

    /// - Parameter pixelSize: 期望输出尺寸（提示值，简报签名逐字）；实际画布以逐帧实测的
    ///   screenFrame 尺寸为准，缓冲池延迟到首帧按实测尺寸建立。
    init(pixelSize: CGSize) {
        self.pixelSize = pixelSize
    }

    /// 逐帧合成（简报 Produces 签名逐字）。screen 为底；pip/pipFrame 任一缺省直返 screen。
    @discardableResult
    func composite(screenFrame: CVPixelBuffer,
                   pip: CVPixelBuffer?,
                   pipFrame: PiPFrame?,
                   at pts: CMTime,
                   into context: CIContext) -> CVPixelBuffer {
        guard let pip, let pipFrame else { return screenFrame } // 无 PiP：零开销直返原 buffer
        // 画布尺寸以 screenFrame 实测为准（修复轮 Minor #2）：与 init pixelSize 失配时按
        // 实测求交、换算与出图——不得误判越界直通，也不得输出错误尺寸。
        let bounds = CGRect(
            x: 0, y: 0,
            width: CVPixelBufferGetWidth(screenFrame),
            height: CVPixelBufferGetHeight(screenFrame))
        let targetRect = pipFrame.rectInCapturePixels
        guard !targetRect.isEmpty, bounds.intersection(targetRect) != .null else { return screenFrame }
        let pipImage = CIImage(cvPixelBuffer: pip)
        guard pipImage.extent.width > 0, pipImage.extent.height > 0, targetRect.width > 0 else {
            return screenFrame
        }
        guard let output = dequeueOutputBuffer(size: bounds.size) else { return screenFrame } // 缓冲不可得：丢 PiP 不丢帧

        // 摄像头帧等比缩放到目标 rect（源为 .vga640x480，窗口同 4:3，等比即完整覆盖）
        let scale = targetRect.width / pipImage.extent.width
        var placedPip = pipImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        placedPip = applyRoundedCornerMask(to: placedPip, radius: pipFrame.cornerRadius)
        // CI 坐标系 y 向上；目标 rect 是缓冲区坐标（左上原点）。换算平移量：CI y = 画布高 - rect 底。
        let ciOrigin = CGPoint(x: targetRect.minX, y: bounds.height - targetRect.maxY)
        placedPip = placedPip.transformed(by: CGAffineTransform(translationX: ciOrigin.x, y: ciOrigin.y))

        // sourceOver：PiP 在上（self=placedPip），屏幕帧为底。屏幕帧全不透明，参数顺序
        // 反了会把 PiP 完全盖住（本用例已由测试钉死）。
        let composed = placedPip.composited(over: CIImage(cvPixelBuffer: screenFrame))
        context.render(composed, to: output)
        return output
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
