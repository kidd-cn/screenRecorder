import AppKit
import AVFoundation
import CoreImage
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

    // MARK: 终审 a1：前置摄像头在位校验（start 装配前拦截，拔出后不再出「无人脸死窗」）

    /// 设备不在位（拔出）→ start 在装配之前显式降级：抛 cameraNotFound，且**不得进入
    /// 装配**（不触碰设备解析、不 beginConfiguration——拔出后 session 残留上一场的
    /// inputs/outputs，若继续走 assemblyPlan 会永见非零而跳过装配，startRunning 成功
    /// 却永无帧）。装配前置拦截同时保证降级路径无半装配残留。
    func testDisconnectedFrontCameraDegradesBeforeAssembly() {
        let controller = CameraPiPController()
        controller.authorizationStatus = { _ in .authorized }
        controller.isFrontCameraConnected = { false }
        controller.frontCameraProvider = { XCTFail("设备不在位时不得进入装配（不得解析设备）"); return nil }

        XCTAssertThrowsError(try controller.start()) { error in
            guard let pipError = error as? CameraPiPController.CameraPiPError,
                  case .cameraNotFound = pipError else {
                return XCTFail("应抛 cameraNotFound，实际：\(error)")
            }
            XCTAssertNotNil(pipError.errorDescription, "降级错误必须可诊断（装配层日志直接展示）")
        }
        XCTAssertNil(controller.latestPixelBuffer, "降级路径不得产出帧")
    }

    /// 设备在位 → 通过校验照常进入装配链（provider 返回 nil 走既有 cameraNotFound 路径，
    /// 证明在位校验未误拦）。
    func testConnectedFrontCameraProceedsIntoAssembly() {
        let controller = CameraPiPController()
        controller.authorizationStatus = { _ in .authorized }
        controller.isFrontCameraConnected = { true }
        controller.frontCameraProvider = { nil }

        XCTAssertThrowsError(try controller.start()) { error in
            guard let pipError = error as? CameraPiPController.CameraPiPError,
                  case .cameraNotFound = pipError else {
                return XCTFail("应走既有 cameraNotFound 路径（装配阶段），实际：\(error)")
            }
        }
    }

    /// 授权拒绝优先于在位校验（校验排在授权之后）：权限拒绝是可行动修复（引导授权），
    /// 不得被「设备不在位」的降级文案掩盖。
    func testDeniedAuthorizationTakesPrecedenceOverDevicePresence() {
        let controller = CameraPiPController()
        controller.authorizationStatus = { _ in .denied }
        controller.isFrontCameraConnected = { false }
        controller.frontCameraProvider = { XCTFail("未授权时不得触碰设备解析"); return nil }

        XCTAssertThrowsError(try controller.start()) { error in
            guard let pipError = error as? CameraPiPController.CameraPiPError else {
                return XCTFail("应抛 CameraPiPError，实际：\(error)")
            }
            XCTAssertEqual(pipError.errorDescription,
                           CameraPiPController.CameraPiPError.cameraPermissionDenied.errorDescription,
                           "denied 场景必须报权限错（优先于在位降级）")
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

    /// 生命周期串行化契约（修复轮 Important #1）：stop() 提交后（清理在控制器专用串行
    /// lifecycle 队列完成），随后 start() 返回时该清理必已完成——跨场「先收上一场、再开
    /// 下一场」的 happens-before 由控制器自建，不依赖调用方排队。
    func testStartObservesTeardownOfPreviouslySubmittedStop() throws {
        let controller = CameraPiPController()
        controller.authorizationStatus = { _ in .authorized }
        let frame = try XCTUnwrap(makeColorBuffer(width: 8, height: 8, blue: 1, green: 2, red: 3, alpha: 4))
        controller.recordFrameIfNeeded(try XCTUnwrap(makeSampleBuffer(frame)))
        XCTAssertNotNil(controller.latestPixelBuffer)

        var observedFrameAtAssembly: CVPixelBuffer?
        controller.frontCameraProvider = {
            observedFrameAtAssembly = controller.latestPixelBuffer
            return nil
        }
        controller.stop() // 提交清理（lifecycle 队列异步完成）
        XCTAssertThrowsError(try controller.start(), "无前置摄像头应抛 cameraNotFound")
        XCTAssertNil(observedFrameAtAssembly, "start 的装配阶段必须观察到 stop 已完成的清理（串行 FIFO）")
        XCTAssertNil(controller.latestPixelBuffer, "start 返回后，此前提交的 stop 清理必已完成")
    }

    /// 跨场启停按程序序提交的串行化压测（修复轮 Important #1）：生产中 end 的 stop 与下一场
    /// begin 的 start 由主线程按程序序提交（stop 提交即返回、start 同步等待），执行收敛在
    /// lifecycle 串行队列——每轮 start 的装配阶段观察到的必须是上一 stop 清理后的状态。
    /// 注：lifecycle 队列保证的是「同线程提交序 → 执行序」；跨线程提交的到达序不在保证范围
    /// （生产不存在跨线程提交：装配层 stop 已改为主线程直接提交）。
    func testStopStartCyclesSubmittedInProgramOrderStaySerialized() throws {
        let controller = CameraPiPController()
        controller.authorizationStatus = { _ in .authorized }

        var violations = 0
        let violationsLock = NSLock()
        controller.frontCameraProvider = {
            if controller.latestPixelBuffer != nil {
                violationsLock.lock()
                violations += 1
                violationsLock.unlock()
            }
            return nil
        }

        let frame = try XCTUnwrap(makeColorBuffer(width: 8, height: 8, blue: 9, green: 0, red: 0, alpha: 255))
        let sample = try XCTUnwrap(makeSampleBuffer(frame))
        let submitter = DispatchQueue(label: "pip.hammer.submitter") // 模拟主线程程序序提交
        let roundDone = DispatchGroup()
        for _ in 0..<40 {
            controller.recordFrameIfNeeded(sample) // 交付最新帧（上一场完全收场后、本场 stop 前）
            roundDone.enter()
            submitter.async {
                controller.stop() // 提交即返回（非阻塞），执行在 lifecycle 队列排队
                _ = try? controller.start() // 同步等待：串行等在此前提交的 stop 之后
                if controller.latestPixelBuffer != nil {
                    violationsLock.lock()
                    violations += 1
                    violationsLock.unlock()
                }
                roundDone.leave()
            }
            roundDone.wait() // 与生产时序一致：上一场完全收场后才开始下一场的帧交付
        }
        XCTAssertEqual(violations, 0, "程序序提交的 stop/start 在 lifecycle 队列上串行：start 的装配必须观察到 stop 已完成")
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

    // MARK: 对调状态桥（spec §3.1：会话级 layoutSwapped 布尔，主线程写 / video 队列读）

    /// PiPFrameStore 旗标语义：初值 = 屏幕为主；set/get 往返（写读皆经既有 NSLock 串行化）。
    func testLayoutSwappedFlagRoundTripsAndResets() {
        let store = PiPFrameStore()
        XCTAssertFalse(store.isLayoutSwapped) // 初值 = 屏幕为主
        store.setLayoutSwapped(true)
        XCTAssertTrue(store.isLayoutSwapped)
        store.setLayoutSwapped(false)
        XCTAssertFalse(store.isLayoutSwapped)
    }

    /// begin 成功装配 → 旗标复位 false：每场开始屏幕为主，上一场遗留的对调态不得带进新场。
    func testBeginRecordingResetsSwappedLayout() {
        let controller = makeController()
        controller.setLayoutSwapped(true)
        controller.beginRecording(geometry: geometry)

        XCTAssertTrue(started, "夹具自检：本场须走成功装配路径（复位语义挂在成功装配段）")
        XCTAssertFalse(controller.isLayoutSwapped, "每场开始复位屏幕为主")
    }

    /// begin 后置 true，endRecording() 后复位 false（收尾幂等复位，与 begin 复位互为双保险）。
    func testEndRecordingResetsSwappedLayout() {
        let controller = makeController()
        controller.beginRecording(geometry: geometry)
        controller.setLayoutSwapped(true)
        controller.endRecording()

        XCTAssertFalse(controller.isLayoutSwapped, "收尾复位屏幕为主")
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

    // MARK: P5 预览跟背景覆盖层（验收增强）

    /// 背景场 begin：覆盖层显示（处理后帧的呈现面）+ 浮窗照常装配；end：覆盖层隐藏、
    /// 呈现面随窗收起——浮窗跨场复用不残留呈现链。
    func testPreviewOverlayFollowsBackgroundAssembly() {
        let controller = makeController()
        let processor = CameraBackgroundProcessor(
            mode: .builtin(.gradientWarm), segmenter: NoopPersonSegmenter())
        controller.beginRecording(geometry: geometry, backgroundProcessor: processor)
        XCTAssertTrue(controller.isWindowVisible)
        XCTAssertTrue(controller.isPreviewOverlayVisible, "背景场覆盖层必须显示（预览跟背景）")

        controller.endRecording()
        XCTAssertFalse(controller.isWindowVisible)
        XCTAssertFalse(controller.isPreviewOverlayVisible, "end 后覆盖层必须隐藏")
    }

    /// off 场 begin：覆盖层保持隐藏（原始预览直出，与一期一致）。
    func testPreviewOverlayHiddenInOffMode() {
        let controller = makeController()
        controller.beginRecording(geometry: geometry, backgroundProcessor: nil)
        XCTAssertTrue(controller.isWindowVisible)
        XCTAssertFalse(controller.isPreviewOverlayVisible, "off 场覆盖层必须隐藏（原始预览直出）")
        controller.endRecording()
        XCTAssertFalse(controller.isPreviewOverlayVisible)
    }

    // MARK: P5 实时换背景（验收裁定：录制中改动实时生效）

    /// 录制中热切换：处理器落到帧路径 + 覆盖层保持显示（新背景的呈现面）。
    func testSwitchBackgroundProcessorMidRecordingSwapsAndRewires() {
        let controller = makeController()
        controller.beginRecording(
            geometry: geometry,
            backgroundProcessor: CameraBackgroundProcessor(mode: .blur, segmenter: NoopPersonSegmenter()))
        XCTAssertTrue(controller.isPreviewOverlayVisible)

        let second = CameraBackgroundProcessor(mode: .builtin(.solidSlate), segmenter: NoopPersonSegmenter())
        controller.switchBackgroundProcessor(to: second)

        XCTAssertTrue(controller.activeBackgroundProcessor === second, "热切换必须落到帧路径（帧回调逐帧读的处理器）")
        XCTAssertTrue(controller.isPreviewOverlayVisible, "背景切换后覆盖层仍显示（新背景的呈现面）")
    }

    /// 录制中热切到 off：处理器清空（帧路径回零开销旁路）+ 覆盖层隐藏（露原始预览）。
    func testSwitchToOffMidRecordingClearsProcessorAndOverlay() {
        let controller = makeController()
        controller.beginRecording(
            geometry: geometry,
            backgroundProcessor: CameraBackgroundProcessor(mode: .blur, segmenter: NoopPersonSegmenter()))

        controller.switchBackgroundProcessor(to: nil)

        XCTAssertNil(controller.activeBackgroundProcessor)
        XCTAssertFalse(controller.isPreviewOverlayVisible, "off 覆盖层必须隐藏（露原始预览，与 begin off 场同语义）")
    }

    /// 非录制中（begin 未调用）：live 下发静默 no-op——初值归 begin 快照链。
    func testSwitchIgnoredBeforeBegin() {
        let controller = makeController()
        controller.switchBackgroundProcessor(
            to: CameraBackgroundProcessor(mode: .blur, segmenter: NoopPersonSegmenter()))
        XCTAssertNil(controller.activeBackgroundProcessor, "会话闸外不得触碰帧路径")
    }

    /// 场次结束（end）后到达的 live 变化：静默 no-op——下一场 begin 快照按当时设置装配。
    func testSwitchIgnoredAfterRecordingEnds() {
        let controller = makeController()
        controller.beginRecording(geometry: geometry)
        controller.endRecording()

        controller.switchBackgroundProcessor(
            to: CameraBackgroundProcessor(mode: .blur, segmenter: NoopPersonSegmenter()))
        XCTAssertNil(controller.activeBackgroundProcessor)
    }

    /// 覆盖层 API：装配后初始隐藏；贴图/清图调用不崩（呈现面的 contents 由呈现器维护）。
    func testPreviewOverlayImageAPIBasics() {
        let window = CameraPiPWindow.makeDefault()
        window.installPreviewLayer(nil)
        XCTAssertFalse(window.isPreviewOverlayVisible, "装配后覆盖层初始隐藏")
        window.setPreviewOverlayVisible(true)
        XCTAssertTrue(window.isPreviewOverlayVisible)
        window.updatePreviewOverlayImage(nil) // 清图不崩
        window.setPreviewOverlayVisible(false)
        XCTAssertFalse(window.isPreviewOverlayVisible)
    }
}

/// 覆盖层装配钉测用假分割缝（begin 路径只存处理器不调分割；真 Vision 请求不得进测试进程）。
private final class NoopPersonSegmenter: PersonSegmenting {
    func segmentationMask(for pixelBuffer: CVPixelBuffer) async -> CIImage? { nil }
}

// MARK: - PiPPreviewFramePresenter（P5 预览跟背景：镜像 + 缩限 + 回调缝）

final class PiPPreviewFramePresenterTests: XCTestCase {
    /// 16×8 帧：左半纯红、右半纯蓝（缓冲列号 0-7 红、8-15 蓝）。
    private func makeTwoToneFrame() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, 16, 8, kCVPixelFormatType_32BGRA, nil, &buffer
        ) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<8 {
            let line = base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for column in 0..<16 {
                line[column * 4 + 0] = column < 8 ? 0 : 255 // B
                line[column * 4 + 1] = 0                    // G
                line[column * 4 + 2] = column < 8 ? 255 : 0 // R
                line[column * 4 + 3] = 255                  // A
            }
        }
        return buffer
    }

    /// 软渲染读图：绘入 RGBA 位图按 (x, y) 取通道（确定性出图，PiPCompositorTests 同精神）。
    private func sample(
        _ cg: CGImage, x: Int, y: Int
    ) -> (red: Int, green: Int, blue: Int) {
        let context = CGContext(
            data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
            bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        let offset = (y * cg.width + x) * 4
        return (red: Int(data[offset]), green: Int(data[offset + 1]), blue: Int(data[offset + 2]))
    }

    /// 镜像钉测：左红右蓝帧 → 呈现图左蓝右红（对齐预览层系统自动镜像的自拍观感——
    /// 不镜像则开录瞬间画面横向跳变）。
    func testPresentMirrorsFrameHorizontally() throws {
        var delivered: CGImage?
        let presenter = PiPPreviewFramePresenter(
            context: CIContext(options: [.useSoftwareRenderer: true]),
            applyOnMain: { delivered = $0 })
        presenter.present(try XCTUnwrap(makeTwoToneFrame()))
        let cg = try XCTUnwrap(delivered, "渲染失败不得静默无图")
        let midY = cg.height / 2
        let left = sample(cg, x: 2, y: midY)
        let right = sample(cg, x: cg.width - 3, y: midY)
        XCTAssertGreaterThan(left.blue, 200, "呈现图左缘应为原帧右半的蓝（镜像）")
        XCTAssertLessThan(left.red, 60, "呈现图左缘不应残留原帧左半的红")
        XCTAssertGreaterThan(right.red, 200, "呈现图右缘应为原帧左半的红（镜像）")
        XCTAssertLessThan(right.blue, 60, "呈现图右缘不应残留原帧右半的蓝")
    }
}

// MARK: - PiPAssemblyPlan（半装配残留的装配决策，修复轮 Minor #1）

final class PiPAssemblyPlanTests: XCTestCase {
    /// 半装配残留（上一场 canAddOutput 失败：有输入/无输出）→ 只补输出，不得整块跳过
    /// （旧实现仅看 inputs.isEmpty，会永久缺失输出——PiP 静默消失）。
    func testPlanAddsOutputWhenOnlyInputPresent() {
        let plan = CameraPiPController.assemblyPlan(inputs: 1, outputs: 0)
        XCTAssertFalse(plan.input, "输入已在位，不得重复装配")
        XCTAssertTrue(plan.output, "有输入无输出的残留必须补装输出（否则下一场 PiP 静默消失）")
    }

    func testPlanAssemblesBothWhenSessionEmpty() {
        let plan = CameraPiPController.assemblyPlan(inputs: 0, outputs: 0)
        XCTAssertTrue(plan.input)
        XCTAssertTrue(plan.output)
    }

    func testPlanSkipsBothWhenFullyAssembled() {
        let plan = CameraPiPController.assemblyPlan(inputs: 1, outputs: 1)
        XCTAssertFalse(plan.input)
        XCTAssertFalse(plan.output, "完整装配（跨场复用）不得重复添加")
    }

    func testPlanAddsInputWhenOnlyOutputPresent() {
        let plan = CameraPiPController.assemblyPlan(inputs: 0, outputs: 1)
        XCTAssertTrue(plan.input)
        XCTAssertFalse(plan.output)
    }
}

// MARK: - PiPExposureAnchoring（曝光锚定计划：亮源入镜拽走测光的守卫，验收裁定）

final class PiPExposureAnchoringTests: XCTestCase {
    /// 能力齐备：测光点钉画面中央（人像常规位）+ 连续自动曝光。
    func testPlanAnchorsCenterWithContinuousExposure() {
        let plan = CameraPiPController.exposureAnchoringPlan(
            isPointOfInterestSupported: true, isContinuousExposureSupported: true)
        XCTAssertEqual(plan.point, CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(plan.mode, .continuousAutoExposure)
    }

    /// 测光点不支持（老设备）：逐项跳过，只带曝光模式。
    func testPlanSkipsPointWhenUnsupported() {
        let plan = CameraPiPController.exposureAnchoringPlan(
            isPointOfInterestSupported: false, isContinuousExposureSupported: true)
        XCTAssertNil(plan.point)
        XCTAssertEqual(plan.mode, .continuousAutoExposure)
    }

    /// 连续曝光不支持：只带测光点。
    func testPlanSkipsModeWhenUnsupported() {
        let plan = CameraPiPController.exposureAnchoringPlan(
            isPointOfInterestSupported: true, isContinuousExposureSupported: false)
        XCTAssertEqual(plan.point, CGPoint(x: 0.5, y: 0.5))
        XCTAssertNil(plan.mode)
    }

    /// 两项都不支持：空计划 = 不触碰设备配置（应用层跳过锁配置）。
    func testPlanEmptyWhenNoCapabilitySupported() {
        let plan = CameraPiPController.exposureAnchoringPlan(
            isPointOfInterestSupported: false, isContinuousExposureSupported: false)
        XCTAssertNil(plan.point)
        XCTAssertNil(plan.mode)
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
