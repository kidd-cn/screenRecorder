import CoreImage
import CoreMedia
import CoreVideo
import XCTest

@testable import ScreenRecorder

// MARK: - 像素缓冲夹具（32BGRA 纯色填充 + 采样）

/// BGRA 四通道颜色（tuple 不可下标，用结构体承载采样循环）。
private struct BGRAColor {
    var blue: UInt8
    var green: UInt8
    var red: UInt8
    var alpha: UInt8

    subscript(channel: Int) -> UInt8 {
        switch channel {
        case 0: return blue
        case 1: return green
        case 2: return red
        default: return alpha
        }
    }
}

/// 无头合成测试夹具：CVPixelBuffer 按 BGRA 字节序填纯色、按坐标采样。
/// 颜色容差 ±3：CI 软渲染的色彩管理往返对纯色主分量是恒等的，边沿抗锯齿带除外。
private let colorTolerance = 3

private func makeColorBuffer(width: Int, height: Int, color: BGRAColor) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    guard CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer
    ) == kCVReturnSuccess, let buffer else { return nil }
    fillBuffer(buffer, with: color)
    return buffer
}

private func fillBuffer(_ buffer: CVPixelBuffer, with color: BGRAColor) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    for row in 0..<CVPixelBufferGetHeight(buffer) {
        let rowBase = base.advanced(by: row * bytesPerRow)
        for column in 0..<CVPixelBufferGetWidth(buffer) {
            let pixel = rowBase.advanced(by: column * 4).assumingMemoryBound(to: UInt8.self)
            pixel[0] = color.blue
            pixel[1] = color.green
            pixel[2] = color.red
            pixel[3] = color.alpha
        }
    }
}

/// 采样 (x, y)（缓冲区像素坐标，左上原点、y 向下）处的 BGRA 四元组。
private func samplePixel(_ buffer: CVPixelBuffer, x: Int, y: Int) -> BGRAColor {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return BGRAColor(blue: 0, green: 0, red: 0, alpha: 0) }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    let pixel = base.advanced(by: y * bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
    return BGRAColor(blue: pixel[0], green: pixel[1], red: pixel[2], alpha: pixel[3])
}

private func assertColor(
    _ actual: BGRAColor,
    equals expected: BGRAColor,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let channelNames = ["B", "G", "R", "A"]
    for channel in 0..<4 {
        XCTAssertTrue(
            abs(Int(actual[channel]) - Int(expected[channel])) <= colorTolerance,
            "\(message)（通道 \(channelNames[channel]) 偏差过大：\(actual[channel]) vs \(expected[channel])）",
            file: file, line: line)
    }
}

// MARK: - PiPFrame（简报 Produces 逐字钉测）

final class PiPFrameTests: XCTestCase {
    func testDefaultCornerRadiusIsTwelvePixels() {
        let frame = PiPFrame(rectInCapturePixels: CGRect(x: 1, y: 2, width: 3, height: 4))
        XCTAssertEqual(frame.cornerRadius, 12, "简报钉死默认圆角 12（捕获像素）")
    }
}

// MARK: - PiPCaptureGeometry（屏坐标 → 捕获像素空间的换算纯函数）

final class PiPCaptureGeometryTests: XCTestCase {
    /// 显示器模式夹具：1512×982 点、2x Retina（3024×1964 物理像素），CG 全局原点 (0, 0)。
    /// 换算走 CG 全局 points（左上原点、y 向下）——与 RegionSelectorMath.cgRect 的口径一致。
    private var displayGeometry: PiPCaptureGeometry {
        PiPCaptureGeometry(
            captureOriginInCGPoints: CGPoint(x: 0, y: 0),
            scale: 2,
            capturePixelSize: CGSize(width: 3024, height: 1964))
    }

    /// Retina 显示器模式：点坐标 ×2 进捕获像素；浮窗在屏右上角 → 成片右上角。
    func testDisplayModeScalesPointsToPixels() {
        let frame = displayGeometry.pipFrame(fromCGRect: CGRect(x: 1300, y: 100, width: 160, height: 120))
        XCTAssertEqual(frame?.rectInCapturePixels, CGRect(x: 2600, y: 200, width: 320, height: 240))
        XCTAssertEqual(frame?.cornerRadius, 12)
    }

    /// Y 轴方向钉死：Cocoa 屏坐标越靠下（y 大）→ 捕获像素空间越靠下（y 大，缓冲区顶部为 0）。
    /// 浮窗贴屏幕底边时其像素 rect 必须贴近捕获区底边（1964 - 240 = 1724）。
    func testDisplayModeYAxisFollowsBufferTopLeftOrigin() {
        let nearBottom = displayGeometry.pipFrame(fromCGRect: CGRect(x: 100, y: 822, width: 160, height: 120))
        XCTAssertEqual(nearBottom?.rectInCapturePixels, CGRect(x: 200, y: 1644, width: 320, height: 240))
    }

    /// 副屏偏移不丢：显示器 CG 原点非零时先减采集区原点再乘缩放（相对坐标，不是全局坐标）。
    func testDisplayModeOffsetsByCaptureOrigin() {
        let geometry = PiPCaptureGeometry(
            captureOriginInCGPoints: CGPoint(x: 1440, y: -380),
            scale: 2,
            capturePixelSize: CGSize(width: 3840, height: 2160))
        let frame = geometry.pipFrame(fromCGRect: CGRect(x: 1500, y: -300, width: 100, height: 50))
        XCTAssertEqual(frame?.rectInCapturePixels, CGRect(x: 120, y: 160, width: 200, height: 100))
    }

    /// 区域模式：scale 1（T7 台账：区域/窗口 1x 采样），采集区原点 = region rect 原点。
    func testRegionModeUsesUnitScaleAndRectOrigin() {
        let geometry = PiPCaptureGeometry(
            captureOriginInCGPoints: CGPoint(x: 500, y: 300),
            scale: 1,
            capturePixelSize: CGSize(width: 800, height: 600))
        let frame = geometry.pipFrame(fromCGRect: CGRect(x: 1200, y: 340, width: 160, height: 120))
        XCTAssertEqual(frame?.rectInCapturePixels, CGRect(x: 700, y: 40, width: 160, height: 120))
    }

    /// 空矩形无效（浮窗收起等）→ nil，合成侧按无 PiP 直通。
    func testEmptyRectYieldsNil() {
        XCTAssertNil(displayGeometry.pipFrame(fromCGRect: .zero))
        XCTAssertNil(displayGeometry.pipFrame(fromCGRect: CGRect(x: 0, y: 0, width: 0, height: 10)))
    }

    /// 完全在采集区外的浮窗（如拖到了未录制的副屏）仍是有效换算——裁剪与否由合成器
    /// 按相交关系决定（几何层只做纯换算，不承担可见性）。
    func testOutsideCaptureAreaStillConverts() {
        let frame = displayGeometry.pipFrame(fromCGRect: CGRect(x: 5000, y: 0, width: 160, height: 120))
        XCTAssertEqual(frame?.rectInCapturePixels, CGRect(x: 10000, y: 0, width: 320, height: 240))
    }
}

// MARK: - PiPFrameStore（主线程写 / video 队列读的锁保护桥）

final class PiPFrameStoreTests: XCTestCase {
    private let geometry = PiPCaptureGeometry(
        captureOriginInCGPoints: .zero,
        scale: 2,
        capturePixelSize: CGSize(width: 2880, height: 1800))

    /// 主屏夹具（与 RegionSelectorMathTests 同推导）：Cocoa 全局 (0,0,1440,900)、CG 原点 (0,0)。
    private let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let cgOrigin = CGPoint(x: 0, y: 0)

    func testScreenRectConvertsToCapturePixelsThroughCGSpace() {
        let store = PiPFrameStore()
        store.setGeometry(geometry)
        store.setScreenRect(CGRect(x: 1200, y: 660, width: 160, height: 120),
                            screenFrame: screenFrame, cgDisplayOrigin: cgOrigin)
        // Cocoa (1200,660,160,120) → CG (1200, 900-780=120) → ×2 = (2400,240,320,240)
        XCTAssertEqual(store.currentPiPFrame()?.rectInCapturePixels, CGRect(x: 2400, y: 240, width: 320, height: 240))
    }

    /// 几何与浮窗 frame 任一缺位 → nil（录制未装配 / 浮窗未显示 / 收尾后）。
    func testMissingGeometryOrRectYieldsNil() {
        let store = PiPFrameStore()
        store.setGeometry(geometry)
        XCTAssertNil(store.currentPiPFrame(), "无浮窗 frame 时必须 nil（纯屏幕直通）")

        store.setGeometry(nil)
        store.setScreenRect(CGRect(x: 0, y: 0, width: 160, height: 120),
                            screenFrame: screenFrame, cgDisplayOrigin: cgOrigin)
        XCTAssertNil(store.currentPiPFrame(), "无几何时必须 nil（纯屏幕直通）")
    }

    /// 收尾清空（endRecording 语义）：先清 frame 再清几何，之后读取恒 nil。
    func testClearAfterRecordingYieldsNil() {
        let store = PiPFrameStore()
        store.setGeometry(geometry)
        store.setScreenRect(CGRect(x: 10, y: 10, width: 160, height: 120),
                            screenFrame: screenFrame, cgDisplayOrigin: cgOrigin)
        XCTAssertNotNil(store.currentPiPFrame())
        store.setScreenRect(nil, screenFrame: screenFrame, cgDisplayOrigin: cgOrigin)
        store.setGeometry(nil)
        XCTAssertNil(store.currentPiPFrame())
    }

    /// 并发冒烟：主线程连写 + 后台队列连读不崩、读数要么 nil 要么合法（锁保护语义）。
    func testConcurrentReadWriteStaysConsistent() {
        let store = PiPFrameStore()
        store.setGeometry(geometry)
        let writer = DispatchQueue(label: "pipframestore.writer")
        let reader = DispatchQueue(label: "pipframestore.reader")
        let expectation = expectation(description: "hammer")
        var readResults: [CGRect?] = []
        let resultsLock = NSLock()
        reader.async {
            for _ in 0..<500 {
                resultsLock.lock()
                readResults.append(store.currentPiPFrame()?.rectInCapturePixels)
                resultsLock.unlock()
            }
            expectation.fulfill()
        }
        writer.async {
            for i in 0..<500 {
                let x = CGFloat(i % 1000)
                store.setScreenRect(CGRect(x: x, y: 100, width: 160, height: 120),
                                    screenFrame: self.screenFrame, cgDisplayOrigin: self.cgOrigin)
            }
        }
        wait(for: [expectation], timeout: 10)
        resultsLock.lock()
        defer { resultsLock.unlock() }
        for result in readResults {
            if let rect = result {
                XCTAssertTrue(rect.width == 320 && rect.height == 240, "并发读取只能得到完整换算结果或 nil")
            }
        }
    }
}

// MARK: - PiPCompositor（合成几何 / 圆角 mask / 无 PiP 直返）

final class PiPCompositorTests: XCTestCase {
    /// 软渲染上下文：无头环境确定性出图（生产用 compositor 自带的 GPU context）。
    private lazy var softwareContext = CIContext(options: [.useSoftwareRenderer: true])

    private let captureSize = CGSize(width: 320, height: 240)
    private let screenColor = BGRAColor(blue: 0, green: 255, red: 0, alpha: 255) // 纯绿
    private let pipColor = BGRAColor(blue: 255, green: 0, red: 0, alpha: 255)    // 纯蓝

    private func makeCompositor() -> PiPCompositor {
        PiPCompositor(pixelSize: captureSize)
    }

    /// 无 PiP（pip 或 pipFrame 为 nil）时逐字节直返原 buffer——同一实例、零渲染开销。
    func testNilPipReturnsOriginalBuffer() {
        let compositor = makeCompositor()
        let screen = makeColorBuffer(width: 320, height: 240, color: screenColor)!
        let pip = makeColorBuffer(width: 64, height: 48, color: pipColor)!

        XCTAssertTrue(compositor.composite(
            screenFrame: screen, pip: nil, pipFrame: PiPFrame(rectInCapturePixels: CGRect(x: 0, y: 0, width: 96, height: 72)),
            at: .zero, into: softwareContext) === screen, "无 PiP 必须直返原 buffer（=== 同实例）")

        XCTAssertTrue(compositor.composite(
            screenFrame: screen, pip: pip, pipFrame: nil,
            at: .zero, into: softwareContext) === screen, "有 PiP 无位置信息同样直返（贴右上角由浮窗摆放负责）")
    }

    /// 浮窗完全在采集区外（拖到未录制屏）→ 直返原 buffer（不渲染、不分配）。
    func testFullyOutsidePipReturnsOriginalBuffer() {
        let compositor = makeCompositor()
        let screen = makeColorBuffer(width: 320, height: 240, color: screenColor)!
        let pip = makeColorBuffer(width: 64, height: 48, color: pipColor)!
        let result = compositor.composite(
            screenFrame: screen, pip: pip,
            pipFrame: PiPFrame(rectInCapturePixels: CGRect(x: 400, y: 300, width: 96, height: 72)),
            at: .zero, into: softwareContext)
        XCTAssertTrue(result === screen, "完全不相交时必须直返原 buffer")
    }

    /// 合成主路径：输出为 pixelSize 的新 buffer；PiP 区域内是摄像头内容、区域外是屏幕内容。
    func testCompositePlacesPipInsideSpecifiedRect() {
        let compositor = makeCompositor()
        let screen = makeColorBuffer(width: 320, height: 240, color: screenColor)!
        let pip = makeColorBuffer(width: 64, height: 48, color: pipColor)!
        let frame = PiPFrame(rectInCapturePixels: CGRect(x: 200, y: 16, width: 96, height: 72)) // 右上角

        let output = compositor.composite(screenFrame: screen, pip: pip, pipFrame: frame, at: .zero, into: softwareContext)

        XCTAssertFalse(output === screen, "合成输出必须是新 buffer（不得污染采集侧缓冲）")
        XCTAssertEqual(CVPixelBufferGetWidth(output), 320)
        XCTAssertEqual(CVPixelBufferGetHeight(output), 240)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(output), kCVPixelFormatType_32BGRA)

        assertColor(samplePixel(output, x: 10, y: 10), equals: screenColor, "屏幕区域保持原样")
        assertColor(samplePixel(output, x: 248, y: 52), equals: pipColor, "PiP rect 中心应为摄像头内容")
        assertColor(samplePixel(output, x: 260, y: 20), equals: pipColor, "PiP rect 内上部应为摄像头内容")
    }

    /// Y 轴方向钉死：rect 位于缓冲区底部时内容必须落在底部（若上下颠倒本用例即红）。
    func testCompositeRespectsBufferTopLeftOrigin() {
        let compositor = makeCompositor()
        let screen = makeColorBuffer(width: 320, height: 240, color: screenColor)!
        let pip = makeColorBuffer(width: 64, height: 48, color: pipColor)!
        let frame = PiPFrame(rectInCapturePixels: CGRect(x: 16, y: 150, width: 96, height: 72)) // 底部

        let output = compositor.composite(screenFrame: screen, pip: pip, pipFrame: frame, at: .zero, into: softwareContext)

        assertColor(samplePixel(output, x: 60, y: 180), equals: pipColor, "底部 rect 中心应为摄像头内容")
        assertColor(samplePixel(output, x: 60, y: 20), equals: screenColor, "顶部仍应是屏幕内容")
    }

    /// CI 圆角 mask：rect 内四角被切（透出屏幕色），圆角内侧仍是摄像头内容。
    func testCompositeAppliesRoundedCornerMask() {
        let compositor = makeCompositor()
        let screen = makeColorBuffer(width: 320, height: 240, color: screenColor)!
        let pip = makeColorBuffer(width: 64, height: 48, color: pipColor)!
        let frame = PiPFrame(rectInCapturePixels: CGRect(x: 200, y: 16, width: 96, height: 72), cornerRadius: 12)

        let output = compositor.composite(screenFrame: screen, pip: pip, pipFrame: frame, at: .zero, into: softwareContext)

        // rect 左上角 (200,16)，圆角圆心 (212,28)、半径 12：
        // (201,17) 距圆心 ≈ 15.6 —— 圆角外 → 屏幕色；(206,22) 距圆心 ≈ 8.5 —— 圆角内 → 摄像头色。
        assertColor(samplePixel(output, x: 201, y: 17), equals: screenColor, "圆角外必须透出屏幕内容")
        assertColor(samplePixel(output, x: 206, y: 22), equals: pipColor, "圆角内必须保留摄像头内容")
    }

    /// cornerRadius = 0 → 无圆角，rect 四角实心。
    func testCompositeWithZeroRadiusKeepsSquareCorners() {
        let compositor = makeCompositor()
        let screen = makeColorBuffer(width: 320, height: 240, color: screenColor)!
        let pip = makeColorBuffer(width: 64, height: 48, color: pipColor)!
        let frame = PiPFrame(rectInCapturePixels: CGRect(x: 200, y: 16, width: 96, height: 72), cornerRadius: 0)

        let output = compositor.composite(screenFrame: screen, pip: pip, pipFrame: frame, at: .zero, into: softwareContext)
        assertColor(samplePixel(output, x: 201, y: 17), equals: pipColor, "零圆角时角点也是摄像头内容")
    }

    /// 浮窗部分越界：不崩、输出合法，越界侧被裁剪、界内内容完整。
    func testPartiallyOutsidePipIsClippedNotFatal() {
        let compositor = makeCompositor()
        let screen = makeColorBuffer(width: 320, height: 240, color: screenColor)!
        let pip = makeColorBuffer(width: 64, height: 48, color: pipColor)!
        let frame = PiPFrame(rectInCapturePixels: CGRect(x: 280, y: 100, width: 96, height: 72)) // 右缘越界

        let output = compositor.composite(screenFrame: screen, pip: pip, pipFrame: frame, at: .zero, into: softwareContext)

        XCTAssertEqual(CVPixelBufferGetWidth(output), 320)
        XCTAssertEqual(CVPixelBufferGetHeight(output), 240)
        assertColor(samplePixel(output, x: 300, y: 130), equals: pipColor, "界内半区应为摄像头内容")
        assertColor(samplePixel(output, x: 10, y: 230), equals: screenColor, "远端屏幕内容不受影响")
    }

    /// 同一 compositor 连续多帧合成（CIContext 复用 + 缓冲池复用的冒烟）。
    func testConsecutiveCompositeCallsSucceed() {
        let compositor = makeCompositor()
        let screen = makeColorBuffer(width: 320, height: 240, color: screenColor)!
        let pip = makeColorBuffer(width: 64, height: 48, color: pipColor)!
        let frame = PiPFrame(rectInCapturePixels: CGRect(x: 200, y: 16, width: 96, height: 72))
        for _ in 0..<5 {
            let output = compositor.composite(screenFrame: screen, pip: pip, pipFrame: frame, at: .zero, into: softwareContext)
            XCTAssertEqual(CVPixelBufferGetWidth(output), 320)
        }
    }
}
