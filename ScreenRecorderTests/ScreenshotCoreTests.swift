import CoreGraphics
import XCTest

@testable import ScreenRecorder

/// `ScreenshotCore` 无头钉测（Q1）：合成位图（CGContext 画纯色），断言裁剪尺寸与 PNG
/// 魔数。裁剪契约钉定（审查轮 1 修正，规格 §Q1「与区域录制同一套换算」优先）：region
/// 已是**左上原点 / y 向下**显示器全局 points（`RegionSelectorMath` 产出口径，与区域
/// 录制 `SCStreamConfiguration.sourceRect` 同一坐标系）；scale = image 宽 /
/// displayPointSize 宽；局部 points = region − displayOrigin，local.minY 即**距屏顶
/// 距离**，CGImage 首行 = 屏顶 → 像素窗 y 无翻转：pixelY = localY·scale。退化/越界
///（含部分重叠）→ nil。
final class ScreenshotCoreTests: XCTestCase {
    // MARK: 夹具

    /// 位图上下文同款 deviceRGB 空间（填充色必须在此空间构造：`CGColor(red:green:blue:)`
    /// 走 generic RGB 校准空间，渲染进 device 上下文会被色彩匹配改值——实测灰 0.5→146、
    /// 红→(255,38,0)，纯色断言必须逐字节相等故绕开）。
    private static let deviceRGB = CGColorSpaceCreateDeviceRGB()
    private static let grayFill = CGColor(colorSpace: deviceRGB, components: [0.5, 0.5, 0.5, 1])!
    private static let redFill = CGColor(colorSpace: deviceRGB, components: [1, 0, 0, 1])!

    /// 合成位图：RGBA8 位图上下文作画后出 CGImage（绘制语义 bottom-left 原点）。
    private func makeImage(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: Self.deviceRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(context)
        return context.makeImage()!
    }

    /// 采样裁剪结果的三个位置（缓冲首字节 / 中心 / 末字节）的 RGB。方向钉死测试的期望
    /// 是**均匀单色**（整窗落在同色区），三采样与行序无关地等价——刻意规避
    /// CGBitmapContext「内存首行对应画布哪一端」的方向陷阱：均匀红换不换算都读出红，
    /// 窗口落错半区则整窗读出灰，同样判得掉。
    private func sampledRGB(of image: CGImage) -> [(red: UInt8, green: UInt8, blue: UInt8)] {
        let width = image.width
        let height = image.height
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: Self.deviceRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let buffer = context.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let pixelCount = width * height
        return [0, pixelCount / 2, pixelCount - 1].map { index in
            let offset = index * 4
            return (buffer[offset], buffer[offset + 1], buffer[offset + 2])
        }
    }

    private func assertAllPixels(
        _ image: CGImage,
        red: UInt8, green: UInt8, blue: UInt8,
        _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let samples = sampledRGB(of: image)
        for sample in samples {
            XCTAssertEqual(sample.red, red, "\(message)（R 通道）", file: file, line: line)
            XCTAssertEqual(sample.green, green, "\(message)（G 通道）", file: file, line: line)
            XCTAssertEqual(sample.blue, blue, "\(message)（B 通道）", file: file, line: line)
        }
    }

    // MARK: 裁剪（brief Step 1 场景逐条）

    /// display 20×10 pts，image 40×20 px，region 全屏(0,0,20,10) → 裁出 40×20。
    func testCropFullDisplayAtScale2() {
        let image = makeImage(width: 40, height: 20) { context in
            context.setFillColor(Self.grayFill)
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        }
        let cropped = ScreenshotCore.crop(
            image,
            displayOrigin: .zero,
            displayPointSize: CGSize(width: 20, height: 10),
            regionInGlobalPoints: CGRect(x: 0, y: 0, width: 20, height: 10))
        XCTAssertEqual(cropped?.width, 40, "全屏 region → 整幅像素尺寸（brief 钉定 40×20）")
        XCTAssertEqual(cropped?.height, 20)
    }

    /// displayOrigin(100,50)，region(110,55,10,5)，scale2 → 裁出 20×10。region 按左上
    /// 原点/y 向下口径：local(10,5) 即距屏顶 5pts → 像素窗顶行 = 5·scale = 10（图像
    /// 下半区）。加像素颜色断言钉 Y 向：涂红**右下半区**（绘制系 bottom-left rect
    /// (20,0,20,10) = 视觉下半），换算出的像素窗应恰落在红区——落错半区整窗灰，尺寸
    /// 断言察觉不了。
    func testCropWithDisplayOriginOffsetAndYFlip() {
        let image = makeImage(width: 40, height: 20) { context in
            context.setFillColor(Self.grayFill)
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
            context.setFillColor(Self.redFill)
            context.fill(CGRect(x: 20, y: 0, width: 20, height: 10))
        }
        let cropped = ScreenshotCore.crop(
            image,
            displayOrigin: CGPoint(x: 100, y: 50),
            displayPointSize: CGSize(width: 20, height: 10),
            regionInGlobalPoints: CGRect(x: 110, y: 55, width: 10, height: 5))
        XCTAssertEqual(cropped?.width, 20, "平移换算后的像素窗尺寸（brief 钉定 20×10）")
        XCTAssertEqual(cropped?.height, 10)
        assertAllPixels(cropped!, red: 255, green: 0, blue: 0, "region（距屏顶 5-10pts）应恰裁出涂红的右下半区")
    }

    /// 零宽/零高退化与全越界 → nil。
    func testCropDegenerateRectReturnsNil() {
        let image = makeImage(width: 40, height: 20) { context in
            context.setFillColor(Self.grayFill)
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        }
        XCTAssertNil(
            ScreenshotCore.crop(
                image,
                displayOrigin: .zero,
                displayPointSize: CGSize(width: 20, height: 10),
                regionInGlobalPoints: CGRect(x: 0, y: 0, width: 0, height: 10)),
            "零宽退化 → nil")
        XCTAssertNil(
            ScreenshotCore.crop(
                image,
                displayOrigin: .zero,
                displayPointSize: CGSize(width: 20, height: 10),
                regionInGlobalPoints: CGRect(x: 0, y: 0, width: 20, height: 0)),
            "零高退化 → nil")
        XCTAssertNil(
            ScreenshotCore.crop(
                image,
                displayOrigin: .zero,
                displayPointSize: CGSize(width: 20, height: 10),
                regionInGlobalPoints: CGRect(x: 25, y: 0, width: 5, height: 5)),
            "全越界（整体落在屏外）→ nil")
    }

    /// 审查 Minor#1：部分重叠（rect 与屏相交但不完整落在屏内）同样 → nil——严格
    /// contain 守卫钉死，不做 clamp/截断（RegionSelector 产出已钳制单屏，此为装配层
    /// 输入防线；安全侧失败）。
    func testCropPartiallyOutOfBoundsRectReturnsNil() {
        let image = makeImage(width: 40, height: 20) { context in
            context.setFillColor(Self.grayFill)
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        }
        XCTAssertNil(
            ScreenshotCore.crop(
                image,
                displayOrigin: .zero,
                displayPointSize: CGSize(width: 20, height: 10),
                regionInGlobalPoints: CGRect(x: 10, y: 0, width: 20, height: 10)),
            "部分重叠（maxX 越界）→ nil")
    }

    // MARK: PNG 编码

    /// data 前两字节 [0x89, 0x50]（PNG signature 首二位）。
    func testPngDataHasPngMagic() throws {
        let image = makeImage(width: 4, height: 4) { context in
            context.setFillColor(Self.grayFill)
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let data = try XCTUnwrap(ScreenshotCore.pngData(image), "PNG 编码应成功出非 nil Data")
        XCTAssertGreaterThan(data.count, 0)
        XCTAssertEqual([UInt8](data.prefix(2)), [0x89, 0x50], "PNG 魔数")
    }
}
