import AVFoundation
import CoreMedia
import CoreVideo
import XCTest

@testable import ScreenRecorder

// MARK: - CameraPiPController（可诊断错误 + 锁保护 latestPixelBuffer 语义）

final class CameraPiPControllerTests: XCTestCase {
    /// 授权拒绝（denied）→ 可诊断错误，且不触碰设备解析/会话装配。
    func testDeniedAuthorizationThrowsDiagnosableError() {
        let controller = CameraPiPController()
        controller.authorizationStatus = { _ in .denied }
        controller.frontCameraProvider = { XCTFail("未授权时不得触碰设备解析"); return nil }

        XCTAssertThrowsError(try controller.start()) { error in
            guard let pipError = error as? CameraPiPController.CameraPiPError else {
                return XCTFail("应抛 CameraPiPError，实际：\(error)")
            }
            XCTAssertNotNil(pipError.errorDescription, "错误文案必须可诊断（装配层日志/通知直接展示）")
        }
        XCTAssertNil(controller.latestPixelBuffer)
    }

    /// 首次未决定（notDetermined）→ 代为发起授权请求 + 本次降级（可诊断错误），不阻塞。
    func testNotDeterminedRequestsAccessAndDegrades() {
        let controller = CameraPiPController()
        controller.authorizationStatus = { _ in .notDetermined }
        var requested = false
        controller.requestCameraAccess = { _, completion in
            requested = true
            completion(true)
        }
        controller.frontCameraProvider = { XCTFail("未决定时不得触碰设备解析"); return nil }

        XCTAssertThrowsError(try controller.start()) { error in
            XCTAssertTrue(error is CameraPiPController.CameraPiPError)
        }
        XCTAssertTrue(requested, "notDetermined 时必须已代为发起授权请求（重录生效）")
    }

    /// 授权就绪但无前置摄像头 → cameraNotFound 可诊断错误。
    func testMissingFrontCameraThrowsDiagnosableError() {
        let controller = CameraPiPController()
        controller.authorizationStatus = { _ in .authorized }
        controller.frontCameraProvider = { nil }

        XCTAssertThrowsError(try controller.start()) { error in
            guard let pipError = error as? CameraPiPController.CameraPiPError else {
                return XCTFail("应抛 CameraPiPError，实际：\(error)")
            }
            XCTAssertNotNil(pipError.errorDescription)
        }
    }

    /// 锁保护 latestPixelBuffer：经样本回调写入后可读出同一实例（retain 语义）。
    func testLatestPixelBufferTracksLastDeliveredFrame() throws {
        let controller = CameraPiPController()
        XCTAssertNil(controller.latestPixelBuffer, "启动前必须为 nil")

        let first = try XCTUnwrap(makeColorBuffer(width: 16, height: 16, blue: 1, green: 2, red: 3, alpha: 4), "夹具缓冲创建失败")
        controller.recordFrameIfNeeded(try XCTUnwrap(makeSampleBuffer(first)))
        XCTAssertTrue(controller.latestPixelBuffer === first, "应保留最近一帧（同一实例）")

        let second = try XCTUnwrap(makeColorBuffer(width: 16, height: 16, blue: 5, green: 6, red: 7, alpha: 8))
        controller.recordFrameIfNeeded(try XCTUnwrap(makeSampleBuffer(second)))
        XCTAssertTrue(controller.latestPixelBuffer === second, "新帧到达必须覆盖旧帧")
    }

    /// 并发冒烟：采集队列连写 + 任意队列连读——读数恒为 nil 或已交付的帧之一，不崩。
    func testConcurrentFrameAccessStaysConsistent() throws {
        let controller = CameraPiPController()
        let frames = try (0..<4).map { index in
            try XCTUnwrap(makeColorBuffer(width: 8, height: 8, blue: UInt8(index), green: 0, red: 0, alpha: 255))
        }
        let samples = try frames.map { try XCTUnwrap(makeSampleBuffer($0)) }

        let producer = DispatchQueue(label: "pipc.producer")
        let consumer = DispatchQueue(label: "pipc.consumer")
        let expectation = expectation(description: "hammer")
        producer.async {
            for i in 0..<300 {
                controller.recordFrameIfNeeded(samples[i % samples.count])
            }
        }
        consumer.async {
            for _ in 0..<300 {
                let latest = controller.latestPixelBuffer
                XCTAssertTrue(latest == nil || frames.contains { $0 === latest })
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10)
    }

    // MARK: 夹具（无摄像头/无会话的样本缓冲）

    private func makeColorBuffer(width: Int, height: Int, blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer
        ) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            for row in 0..<height {
                let rowBase = base.advanced(by: row * bytesPerRow)
                for column in 0..<width {
                    let pixel = rowBase.advanced(by: column * 4).assumingMemoryBound(to: UInt8.self)
                    pixel[0] = blue
                    pixel[1] = green
                    pixel[2] = red
                    pixel[3] = alpha
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func makeSampleBuffer(_ pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sampleBuffer)
        return sampleBuffer
    }
}

// MARK: - CameraPiPWindowController（生命周期 + 拖动锚点）

@MainActor
final class CameraPiPWindowControllerTests: XCTestCase {
    private let geometry = PiPCaptureGeometry(
        captureOriginInCGPoints: .zero,
        scale: 2,
        capturePixelSize: CGSize(width: 2880, height: 1800))

    private var started = false
    private var stopped = false

    private func makeController() -> CameraPiPWindowController {
        started = false
        stopped = false
        return CameraPiPWindowController(
            windowFactory: { CameraPiPWindow.makeDefault() },
            startCamera: { _ in self.started = true },
            stopCamera: { _ in self.stopped = true })
    }

    /// begin：几何就绪 + 摄像头启动成功 → 浮窗可见、拖动锚点已发布（成片里可见 PiP）。
    func testBeginRecordingShowsWindowAndPublishesFrame() {
        let controller = makeController()
        controller.beginRecording(geometry: geometry)

        XCTAssertTrue(started)
        XCTAssertTrue(controller.isWindowVisible)
        XCTAssertNotNil(controller.currentPiPFrame(), "浮窗 frame 必须已进换算链（合成器逐帧可读）")
    }

    /// 摄像头启动失败（授权/无设备）→ 降级纯屏幕：不显示浮窗、锚点不发布、不阻断（不抛）。
    func testBeginRecordingDegradesWhenCameraStartFails() {
        let controller = CameraPiPWindowController(
            windowFactory: { CameraPiPWindow.makeDefault() },
            startCamera: { _ in throw CameraPiPController.CameraPiPError.cameraNotFound },
            stopCamera: { _ in })
        controller.beginRecording(geometry: geometry)

        XCTAssertFalse(controller.isWindowVisible)
        XCTAssertNil(controller.currentPiPFrame())
    }

    /// 几何不可解析（如窗口模式的枚举失败）→ 同样降级，且不得启动摄像头。
    func testBeginRecordingWithoutGeometrySkipsCameraEntirely() {
        let controller = makeController()
        controller.beginRecording(geometry: nil)

        XCTAssertFalse(started, "几何缺位时不得启动摄像头（启动了也进不了成片）")
        XCTAssertFalse(controller.isWindowVisible)
    }

    /// end：浮窗收起 + 停摄像头 + 锚点清空（幂等路径，begin 失败回滚同走此路）。
    func testEndRecordingTearsDownAndClearsAnchor() {
        let controller = makeController()
        controller.beginRecording(geometry: geometry)
        controller.endRecording()

        XCTAssertTrue(stopped)
        XCTAssertFalse(controller.isWindowVisible)
        XCTAssertNil(controller.currentPiPFrame())
    }

    /// 拖动锚点：浮窗 frame 变化（拖动中连发）实时进换算链——成片位置实时跟随的机制钉测。
    func testWindowMoveUpdatesPipFrame() throws {
        let controller = makeController()
        controller.beginRecording(geometry: geometry)
        let before = try XCTUnwrap(controller.currentPiPFrame()).rectInCapturePixels

        controller.moveWindowForTesting(to: CGRect(x: 300, y: 200, width: 160, height: 120))
        let after = try XCTUnwrap(controller.currentPiPFrame()).rectInCapturePixels

        XCTAssertNotEqual(after, before, "拖动后换算结果必须变化")
        // 屏幕锚点与窗口同屏（测试宿主主屏）：换算结果 = RegionSelectorMath.cgRect × scale
        let screen = NSScreen.main!
        let cgRect = RegionSelectorMath.cgRect(
            fromCocoaRect: CGRect(x: 300, y: 200, width: 160, height: 120),
            screenFrame: screen.frame,
            cgDisplayOrigin: RegionSelector.cgDisplayOrigin(of: screen))
        let expected = CGRect(
            x: cgRect.minX * 2, y: cgRect.minY * 2,
            width: cgRect.width * 2, height: cgRect.height * 2)
        XCTAssertEqual(after, expected, "拖动后的换算必须与纯函数口径一致（Retina ×2）")
    }

    /// latestPixelBuffer 直通摄像头控制器（合成器逐帧取数的通道）。
    func testPixelBufferProviderPassesThroughToCamera() {
        let controller = makeController()
        XCTAssertNil(controller.latestPixelBuffer())
    }
}

// MARK: - PiPLacementAnchor（浮条避让的初始拖动锚点）

final class PiPLacementAnchorTests: XCTestCase {
    private let pipSize = CGSize(width: 160, height: 120)
    private let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

    /// 无浮条信息：锚在可视区右上角（留边 12）。
    func testDefaultAnchorsTopRightWithoutBar() {
        let frame = PiPLacementAnchor.defaultFrame(visibleFrame: visibleFrame, controlBarFrame: nil)
        XCTAssertEqual(frame, CGRect(x: 1440 - 160 - 12, y: 900 - 120 - 12, width: 160, height: 120))
    }

    /// 浮条在顶部居中、与右上角不重叠：不避让。
    func testNoNudgeWhenBarDoesNotOverlap() {
        let bar = CGRect(x: 570, y: 900 - 50, width: 300, height: 40) // 顶部居中的浮条
        let frame = PiPLacementAnchor.defaultFrame(visibleFrame: visibleFrame, controlBarFrame: bar)
        XCTAssertEqual(frame.origin.x, 1440 - 160 - 12)
        XCTAssertEqual(frame.origin.y, 900 - 120 - 12)
    }

    /// 可视区窄到浮条伸进 PiP 区：PiP 下移到浮条下方（不遮浮条、仍完整可见）。
    func testNudgesBelowBarWhenOverlapping() {
        let narrow = CGRect(x: 0, y: 0, width: 400, height: 900)
        let bar = CGRect(x: 50, y: 860, width: 300, height: 40)
        let frame = PiPLacementAnchor.defaultFrame(visibleFrame: narrow, controlBarFrame: bar)
        XCTAssertTrue(frame.maxX <= narrow.maxX + 0.5, "避让后不得越出可视区右缘")
        XCTAssertFalse(frame.intersects(bar), "避让后不得与浮条重叠")
        XCTAssertEqual(frame.origin.y, bar.minY - 120 - 12)
    }
}
