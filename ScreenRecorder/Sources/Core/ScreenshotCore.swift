import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 截图核心（Q1）：纯函数——位图裁剪 + PNG 编码。无 AppKit、无采集调用，无头可测；
/// 选区（RegionSelector）、取帧（CGDisplayCreateImage）、写盘与通知的编排归装配层
///（`AppAssembly.takeScreenshot`）。
enum ScreenshotCore {
    /// 位图裁剪：显示器全局 points rect → 像素 rect。region 契约（审查轮 1 修正，规格
    /// §Q1「与区域录制同一套换算」优先）：**左上原点 / y 向下**显示器全局 points
    ///（`RegionSelectorMath` 产出口径，与区域录制 `SCStreamConfiguration.sourceRect`
    /// 同一坐标系）。scale = image 宽 / displayPointSize 宽；局部 points = region −
    /// displayOrigin，local.minY 即距屏顶距离，CGImage 首行 = 屏顶 → 像素窗 y **无
    /// 翻转**：pixelY = localY·scale（原计划的自屏左下角起量前提与选择器实际产出口径
    /// 不符，翻转公式已删）。rect 退化（零宽/高）或越界（不完整落在屏内；RegionSelector
    /// 产出的 rect 已钳制单屏，此守卫兜装配层输入，安全侧失败不截断）→ nil。
    /// 亚像素边缘整像素化：原点向下取整、尺寸向上取整（覆盖 region 覆到的全部像素列/行），
    /// 再与图像边界求交收敛浮点毛刺；交后不足 1 px 视为退化 → nil。
    static func crop(
        _ image: CGImage,
        displayOrigin: CGPoint,
        displayPointSize: CGSize,
        regionInGlobalPoints: CGRect
    ) -> CGImage? {
        guard displayPointSize.width > 0, displayPointSize.height > 0 else { return nil }
        let local = CGRect(
            x: regionInGlobalPoints.minX - displayOrigin.x,
            y: regionInGlobalPoints.minY - displayOrigin.y,
            width: regionInGlobalPoints.width,
            height: regionInGlobalPoints.height)
        guard local.width > 0, local.height > 0,
              CGRect(origin: .zero, size: displayPointSize).contains(local) else { return nil }

        let scale = CGFloat(image.width) / displayPointSize.width
        let pixelRect = CGRect(
            x: (local.minX * scale).rounded(.down),
            y: (local.minY * scale).rounded(.down),
            width: (local.width * scale).rounded(.up),
            height: (local.height * scale).rounded(.up))
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard pixelRect.width >= 1, pixelRect.height >= 1 else { return nil }
        return image.cropping(to: pixelRect)
    }

    /// CGImage → PNG Data（ImageIO，PNG UTType）。编码器创建或 finalize 失败 → nil
    ///（装配层按「失败静默 NSLog」纪律处理，不通知）。
    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
