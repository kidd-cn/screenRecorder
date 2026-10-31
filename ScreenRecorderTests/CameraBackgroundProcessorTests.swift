import CoreImage
import CoreMedia
import CoreVideo
import XCTest

@testable import ScreenRecorder

// MARK: - 像素缓冲夹具（32BGRA 纯色填充 + 采样，PiPCompositorTests 同款口径）

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

/// 颜色容差 ±8：本处理器走生产 GPU 上下文（PiPCompositor 同款 useSoftwareRenderer: false），
/// CI 色彩管理往返对纯色主分量近恒等；渐变域与边沿抗锯齿带外余量放宽（软渲染钉测为 ±3）。
private let colorTolerance = 8

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
    guard let base = CVPixelBufferGetBaseAddress(buffer) else {
        return BGRAColor(blue: 0, green: 0, red: 0, alpha: 0)
    }
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

// MARK: - mask 夹具（Vision 真请求不得进无头测试进程，全部走假 segmenter）

/// 全前景 mask（白满幅 → CIBlendWithMask 全取前景，输出内容=原帧、缓冲必换新）。
private func fullForegroundMask(width: Int, height: Int) -> CIImage {
    CIImage(color: CIColor.white).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
}

/// 左半前景 mask（CI 坐标 x∈[0, w/2) 白=前景、右半黑=背景；缓冲列号与 CI x 同向——
/// 前景落在缓冲左半、背景落在缓冲右半）。
private func leftHalfForegroundMask(width: Int, height: Int) -> CIImage {
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    let foreground = CIImage(color: CIColor.white)
        .cropped(to: CGRect(x: 0, y: 0, width: width / 2, height: height))
    let background = CIImage(color: CIColor.black).cropped(to: bounds)
    return foreground.composited(over: background)
}

/// 测试缝假实现（简报 Produces：Vision 真请求只在生产实现）：按注入闭包产出 mask，计数调用。
private final class FakePersonSegmenter: PersonSegmenting {
    private let provider: (CVPixelBuffer) -> CIImage?
    private let lock = NSLock()
    private var callCount = 0

    init(provider: @escaping (CVPixelBuffer) -> CIImage?) {
        self.provider = provider
    }

    func segmentationMask(for pixelBuffer: CVPixelBuffer) async -> CIImage? {
        lock.withStateLock { callCount += 1 } // 同步作用域锁（async 上下文禁裸 lock/unlock）
        return provider(pixelBuffer)
    }

    var recordedCallCount: Int {
        lock.withStateLock { callCount }
    }
}

/// 门控假实现（修复轮 1 钉测「newest-wins 过载合并」）：把分割卡在门上造出「在途未完」
/// 的过载场景——每次调用先记录到访帧（先后序即分割调用序），未放行则挂起在门上；
/// `openGate(returning:)` 放行全部挂起调用（统一返回注入 mask），此后新到访调用立即返回。
private final class GatedPersonSegmenter: PersonSegmenting {
    private let lock = NSLock()
    private var open = false
    private var nextMask: CIImage?
    private var waiting: [CheckedContinuation<CIImage?, Never>] = []
    private var buffers: [CVPixelBuffer] = []

    /// 到访分割的帧（按调用先后序；门控下恰为「首帧在途 + 最新合并帧」）。
    var recordedBuffers: [CVPixelBuffer] {
        lock.withStateLock { buffers }
    }

    var recordedCallCount: Int {
        lock.withStateLock { buffers.count }
    }

    /// 放行：挂起调用全部以注入 mask 返回；此后新调用不再挂起。
    func openGate(returning mask: CIImage?) {
        let pending: [CheckedContinuation<CIImage?, Never>] = lock.withStateLock {
            open = true
            nextMask = mask
            let pendingNow = waiting
            waiting = []
            return pendingNow
        }
        for continuation in pending { // 锁外 resume（恢复方下游可能再取同锁）
            continuation.resume(returning: mask)
        }
    }

    func segmentationMask(for pixelBuffer: CVPixelBuffer) async -> CIImage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<CIImage?, Never>) in
            var resumeWith: CIImage?
            var resumeNow = false
            lock.withStateLock {
                buffers.append(pixelBuffer)
                if open {
                    resumeWith = nextMask
                    resumeNow = true
                } else {
                    waiting.append(continuation)
                }
            }
            if resumeNow {
                continuation.resume(returning: resumeWith)
            }
        }
    }
}

// MARK: - CameraBackgroundMode / RecordingConfiguration（P5 模型钉测）

final class CameraBackgroundModeTests: XCTestCase {
    /// 五态 Codable 往返保值（关联值枚举合成编码；SettingsStore 以 JSON 整只落库）。
    func testCameraBackgroundModeCodableRoundTrip() throws {
        let modes: [CameraBackgroundMode] = [
            .off, .blur,
            .builtin(.gradientWarm), .builtin(.gradientCool), .builtin(.solidSlate),
        ]
        for mode in modes {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(CameraBackgroundMode.self, from: data)
            XCTAssertEqual(decoded, mode, "Codable 往返必须保值")
        }
    }

    /// RecordingConfiguration 快照字段缺省 off（原画面）——既有装配点零改动即合法。
    func testRecordingConfigurationDefaultsCameraBackgroundOff() {
        let config = RecordingConfiguration(
            mode: .display(CGMainDisplayID()),
            captureSystemAudio: true,
            captureMicrophone: true,
            includeCamera: true,
            fps: 30,
            codec: .h264,
            outputURL: URL(fileURLWithPath: "/tmp/camera-background-test.mp4"),
            clickHighlightEnabled: false)
        XCTAssertEqual(config.cameraBackground, .off, "缺省 off：帧路径零开销旁路")
    }
}

// MARK: - CameraBackgroundProcessor（简报 floor 钉测 + 观感/缓冲纪律钉测）

final class CameraBackgroundProcessorTests: XCTestCase {
    private let fixtureWidth = 32
    private let fixtureHeight = 24

    /// 简报钉测：off 零开销直通——原缓冲原样返回（同一实例），且不得触碰 segmenter（零 Vision 调用）。
    func testOffModePassesThroughSameBuffer() async throws {
        let segmenter = FakePersonSegmenter { _ in
            XCTFail("off 模式不得调用人像分割（零 Vision 调用）")
            return nil
        }
        let processor = CameraBackgroundProcessor(mode: .off, segmenter: segmenter)
        let frame = try XCTUnwrap(makeColorBuffer(
            width: fixtureWidth, height: fixtureHeight,
            color: BGRAColor(blue: 1, green: 2, red: 3, alpha: 4)))

        let output = await processor.process(frame)

        XCTAssertTrue(output === frame, "off 模式必须原缓冲直通（同一实例，零渲染零换装）")
        XCTAssertEqual(segmenter.recordedCallCount, 0, "off 模式不得触碰分割缝")
    }

    /// 简报钉测：mask 不可得（nil）→ 原帧直通不丢帧（blur 与 builtin 两态同钉）。
    func testMaskNilReturnsOriginalFrame() async throws {
        let segmenter = FakePersonSegmenter { _ in nil }
        let frame = try XCTUnwrap(makeColorBuffer(
            width: fixtureWidth, height: fixtureHeight,
            color: BGRAColor(blue: 9, green: 8, red: 7, alpha: 255)))

        let blurOutput = await CameraBackgroundProcessor(
            mode: .blur, segmenter: segmenter).process(frame)
        XCTAssertTrue(blurOutput === frame, "blur：mask 不可得必须原帧直通（不丢帧）")

        let builtinOutput = await CameraBackgroundProcessor(
            mode: .builtin(.gradientWarm), segmenter: segmenter).process(frame)
        XCTAssertTrue(builtinOutput === frame, "builtin：mask 不可得必须原帧直通（不丢帧）")
    }

    /// 简报钉测：blur 全前景 mask → 输出≠输入（处理流水线真实运行：缓冲换新、分割恰一调用）。
    func testBlurDiffersFromOriginal() async throws {
        let segmenter = FakePersonSegmenter { [width = fixtureWidth, height = fixtureHeight] _ in
            fullForegroundMask(width: width, height: height)
        }
        let processor = CameraBackgroundProcessor(mode: .blur, segmenter: segmenter)
        let frame = try XCTUnwrap(makeColorBuffer(
            width: fixtureWidth, height: fixtureHeight,
            color: BGRAColor(blue: 0, green: 200, red: 0, alpha: 255)))

        let output = await processor.process(frame)

        XCTAssertFalse(output === frame, "blur：输出必须是处理后的新缓冲（≠输入）")
        XCTAssertEqual(segmenter.recordedCallCount, 1, "每帧恰一次分割调用")
    }

    /// 简报钉测：builtin 全前景 mask → 输出≠输入（同上，builtin 路）。
    func testBuiltinBackgroundDiffersFromOriginal() async throws {
        let segmenter = FakePersonSegmenter { [width = fixtureWidth, height = fixtureHeight] _ in
            fullForegroundMask(width: width, height: height)
        }
        let processor = CameraBackgroundProcessor(
            mode: .builtin(.gradientCool), segmenter: segmenter)
        let frame = try XCTUnwrap(makeColorBuffer(
            width: fixtureWidth, height: fixtureHeight,
            color: BGRAColor(blue: 0, green: 0, red: 200, alpha: 255)))

        let output = await processor.process(frame)

        XCTAssertFalse(output === frame, "builtin：输出必须是处理后的新缓冲（≠输入）")
        XCTAssertEqual(segmenter.recordedCallCount, 1)
    }

    /// 简报钉测：处理保持帧尺寸与像素格式（blur/builtin 双态）——下游 PiPCompositor 的
    /// CIImage(cvPixelBuffer:) 与摆放数学依赖同尺寸同格式。
    func testProcessingRetainsFrameDimensions() async throws {
        let segmenter = FakePersonSegmenter { [width = fixtureWidth, height = fixtureHeight] _ in
            leftHalfForegroundMask(width: width, height: height)
        }
        let frame = try XCTUnwrap(makeColorBuffer(
            width: fixtureWidth, height: fixtureHeight,
            color: BGRAColor(blue: 0, green: 0, red: 255, alpha: 255)))

        for mode in [CameraBackgroundMode.blur, .builtin(.solidSlate)] {
            let output = await CameraBackgroundProcessor(mode: mode, segmenter: segmenter).process(frame)
            XCTAssertNotEqual(output, frame, "\(mode)：应产出新缓冲")
            XCTAssertEqual(CVPixelBufferGetWidth(output), fixtureWidth, "\(mode)：宽度必须保持")
            XCTAssertEqual(CVPixelBufferGetHeight(output), fixtureHeight, "\(mode)：高度必须保持")
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(output), kCVPixelFormatType_32BGRA,
                           "\(mode)：32BGRA 格式必须保持（与 videoDataOutput 一致）")
        }
    }

    /// 纯色灰蓝精确度 + 前景保留（左半前景 mask）：mask 黑域（右半）读内置纯色
    /// (0.42, 0.47, 0.58)≈(107,120,148)，前景域（左半）读原帧纯红——背景真实进画、前景
    /// 真实保留（builtin 路无模糊，无边带串色）。
    func testSolidSlateBackgroundFillsMaskedOutRegions() async throws {
        let segmenter = FakePersonSegmenter { [width = fixtureWidth, height = fixtureHeight] _ in
            leftHalfForegroundMask(width: width, height: height)
        }
        let processor = CameraBackgroundProcessor(mode: .builtin(.solidSlate), segmenter: segmenter)
        let frame = try XCTUnwrap(makeColorBuffer(
            width: fixtureWidth, height: fixtureHeight,
            color: BGRAColor(blue: 0, green: 0, red: 255, alpha: 255)))

        let output = await processor.process(frame)

        XCTAssertFalse(output === frame)
        assertColor(samplePixel(output, x: fixtureWidth / 4, y: fixtureHeight / 2),
                    equals: BGRAColor(blue: 0, green: 0, red: 255, alpha: 255),
                    "前景域必须保留原帧颜色（人像不被背景侵蚀）")
        assertColor(samplePixel(output, x: fixtureWidth * 3 / 4, y: fixtureHeight / 2),
                    equals: BGRAColor(blue: 148, green: 120, red: 107, alpha: 255),
                    "mask 黑域必须填入程序生成的纯色灰蓝背景")
    }

    /// blur/builtin 区分（同帧同 mask 对拍）：blur 的 mask 黑域是「自身高斯模糊」底（原帧
    /// 色晕开），builtin solidSlate 的同域是灰蓝——同点读数必须可判别。
    func testBlurAndBuiltinBackgroundsAreDistinguishableAtMaskedOutRegion() async throws {
        let segmenter = FakePersonSegmenter { [width = fixtureWidth, height = fixtureHeight] _ in
            leftHalfForegroundMask(width: width, height: height)
        }
        let frame = try XCTUnwrap(makeColorBuffer(
            width: fixtureWidth, height: fixtureHeight,
            color: BGRAColor(blue: 0, green: 0, red: 255, alpha: 255)))

        let blurred = await CameraBackgroundProcessor(
            mode: .blur, segmenter: segmenter).process(frame)
        let slated = await CameraBackgroundProcessor(
            mode: .builtin(.solidSlate), segmenter: segmenter).process(frame)

        let blurredPixel = samplePixel(blurred, x: fixtureWidth * 3 / 4, y: fixtureHeight / 2)
        let slatedPixel = samplePixel(slated, x: fixtureWidth * 3 / 4, y: fixtureHeight / 2)
        // blur 底来自纯红原帧的晕开（红主导），灰蓝底红分量远低——红通道须拉开判别距离。
        XCTAssertGreaterThan(abs(Int(slatedPixel.red) - Int(blurredPixel.red)), 40,
                             "同点读数必须可判别：blur=原帧晕开底、builtin=程序生成灰蓝底")
    }

    /// 缓冲池纪律（PiPCompositorTests 同款钉测思路）：连帧命中同一池实例——逐帧重建池
    /// 即逐帧分配，测试即红。池按帧实测尺寸建立（尺寸不变即复用）。
    func testConsecutiveProcessingReusesOutputPool() async throws {
        let segmenter = FakePersonSegmenter { [width = fixtureWidth, height = fixtureHeight] _ in
            fullForegroundMask(width: width, height: height)
        }
        let processor = CameraBackgroundProcessor(mode: .builtin(.solidSlate), segmenter: segmenter)
        let frame = try XCTUnwrap(makeColorBuffer(
            width: fixtureWidth, height: fixtureHeight,
            color: BGRAColor(blue: 1, green: 1, red: 1, alpha: 255)))

        _ = await processor.process(frame)
        let pool = processor.activeOutputPool
        XCTAssertNotNil(pool, "首次处理后必须已建输出缓冲池")

        _ = await processor.process(frame)
        XCTAssertTrue(processor.activeOutputPool === pool, "连帧必须命中同一池实例（池按尺寸复用）")
    }

    // MARK: CameraPiPController 帧路径挂点（dataOutput 帧 → processor → latestFrame 上游）

    /// 无处理器（off 场/未装配）：帧路径与一期逐字节一致——同一实例直通入库。
    func testControllerWithoutProcessorKeepsFrameIdentity() throws {
        let controller = CameraPiPController()
        let frame = try XCTUnwrap(makeColorBuffer(
            width: 8, height: 8, color: BGRAColor(blue: 1, green: 2, red: 3, alpha: 4)))

        controller.handleDeliveredFrame(try XCTUnwrap(makeSampleBuffer(frame)))

        XCTAssertTrue(controller.latestPixelBuffer === frame, "旁路必须保持原缓冲同一实例")
    }

    /// 处理器在位：帧进处理流水线，完成后 latestFrame 换为处理后缓冲（blur 全前景 mask
    /// → 内容不变、缓冲必新），恰一次分割调用——dataOutput 帧 → processor →
    /// latestPixelBuffer 的挂点全链钉测。
    func testControllerWithProcessorReplacesLatestFrameWithProcessedBuffer() throws {
        let controller = CameraPiPController()
        let segmenter = FakePersonSegmenter { [width = 12, height = 12] _ in
            fullForegroundMask(width: width, height: height)
        }
        controller.backgroundProcessor = CameraBackgroundProcessor(mode: .blur, segmenter: segmenter)
        let frame = try XCTUnwrap(makeColorBuffer(
            width: 12, height: 12, color: BGRAColor(blue: 0, green: 0, red: 200, alpha: 255)))

        controller.handleDeliveredFrame(try XCTUnwrap(makeSampleBuffer(frame)))

        // 轮询条件须带非 nil 前提：初值 nil 使「!== frame」恒真（等价于没等）。
        waitUntil("latestFrame 应换为处理后的新缓冲") {
            let latest = controller.latestPixelBuffer
            return latest != nil && latest !== frame
        }
        XCTAssertEqual(segmenter.recordedCallCount, 1, "处理器在位时每帧恰一次分割调用")
        XCTAssertEqual(CVPixelBufferGetWidth(try XCTUnwrap(controller.latestPixelBuffer)), 12,
                       "处理后帧尺寸必须保持")
    }

    /// 处理器卸下（下一场 off）：在位时入库的是处理后帧，卸下后帧路径立即回一期直通
    /// （同实例入库）——快照换装的旁路语义钉测。
    func testControllerFallsBackToBypassWhenProcessorRemoved() throws {
        let controller = CameraPiPController()
        let segmenter = FakePersonSegmenter { [width = 8, height = 8] _ in
            fullForegroundMask(width: width, height: height)
        }
        controller.backgroundProcessor = CameraBackgroundProcessor(mode: .blur, segmenter: segmenter)
        let processed = try XCTUnwrap(makeColorBuffer(
            width: 8, height: 8, color: BGRAColor(blue: 5, green: 6, red: 7, alpha: 255)))
        controller.handleDeliveredFrame(try XCTUnwrap(makeSampleBuffer(processed)))
        // 非 nil 前提同上（初值 nil 使「!== processed」恒真）。
        waitUntil("latestFrame 应换为处理后的新缓冲") {
            let latest = controller.latestPixelBuffer
            return latest != nil && latest !== processed
        }

        controller.backgroundProcessor = nil
        let plain = try XCTUnwrap(makeColorBuffer(
            width: 8, height: 8, color: BGRAColor(blue: 9, green: 9, red: 9, alpha: 255)))
        controller.handleDeliveredFrame(try XCTUnwrap(makeSampleBuffer(plain)))
        XCTAssertTrue(controller.latestPixelBuffer === plain, "卸下处理器后必须立即回一期直通")
    }

    // MARK: 修复轮 1 钉测（newest-wins 过载合并 + stop 冲刷）

    /// 过载合并：门卡住首帧（在途=1）时连喂 F2/F3/F4——不新增分割调用（Vision 队列恒
    /// ≤1 job），合并槽只保留最新帧 F4（F2/F3 被覆盖释放：管线驻留 ≤2 帧、内存有界，
    /// PiP 陈旧度收敛到一个处理周期）；放行后恰 F1 → F4 接力进分割，latestFrame 收敛为
    /// F4 的处理结果。过载允许丢帧是策略；钉的是「有界 + 只处理最新」。
    func testOverloadCoalescesToNewestFrameOnlySegmented() throws {
        let controller = CameraPiPController()
        let segmenter = GatedPersonSegmenter()
        controller.backgroundProcessor = CameraBackgroundProcessor(mode: .blur, segmenter: segmenter)
        let f1 = try makeFrame(blue: 10)
        let f2 = try makeFrame(blue: 20)
        let f3 = try makeFrame(blue: 30)
        let f4 = try makeFrame(blue: 40)

        controller.handleDeliveredFrame(try XCTUnwrap(makeSampleBuffer(f1)))
        waitUntil("F1 应已进入分割（在途被门卡住）") { segmenter.recordedCallCount == 1 }

        controller.handleDeliveredFrame(try XCTUnwrap(makeSampleBuffer(f2)))
        controller.handleDeliveredFrame(try XCTUnwrap(makeSampleBuffer(f3)))
        controller.handleDeliveredFrame(try XCTUnwrap(makeSampleBuffer(f4)))
        XCTAssertEqual(segmenter.recordedCallCount, 1,
                       "过载合并：在途未完不得新增分割调用（F2/F3 被 F4 覆盖，槽只留最新帧）")

        segmenter.openGate(returning: fullForegroundMask(width: 8, height: 8))
        waitUntil("F4 应作为合并结果接力进入分割") { segmenter.recordedCallCount == 2 }
        XCTAssertTrue(segmenter.recordedBuffers.first === f1, "首帧照常在途")
        XCTAssertTrue(segmenter.recordedBuffers.last === f4, "合并槽必须只保留最新帧（F4，非 F2/F3）")

        // latestFrame 收敛到 F4 的处理结果：按内容等（F1 的结果先落库、blue≈10，不算达成）。
        waitUntil("latestFrame 应换为最新合并帧（F4）的处理结果") {
            guard let latest = controller.latestPixelBuffer else { return false }
            return abs(Int(samplePixel(latest, x: 4, y: 4).blue) - 40) <= colorTolerance
        }
        let finalLatest = try XCTUnwrap(controller.latestPixelBuffer)
        XCTAssertFalse(finalLatest === f4, "latestFrame 必须是处理后的新缓冲")
    }

    /// stop 冲刷：F1 在途被门卡住、F2 落合并槽时 stop——stop 冲掉合并槽并复位在途闩；
    /// 放行后迟到的 F1 完成被场次守卫拒绝（不得把旧帧带进下一场开头），且不再有任何帧
    /// 进入分割（stop 后管线驻留归零）。
    func testStopFlushesPendingSlotAndRejectsLateFrames() throws {
        let controller = CameraPiPController()
        controller.authorizationStatus = { _ in .authorized }
        controller.isFrontCameraConnected = { false } // 无头确定：start 在装配前显式降级
        let segmenter = GatedPersonSegmenter()
        controller.backgroundProcessor = CameraBackgroundProcessor(mode: .blur, segmenter: segmenter)
        let f1 = try makeFrame(blue: 10)
        let f2 = try makeFrame(blue: 20)

        controller.handleDeliveredFrame(try XCTUnwrap(makeSampleBuffer(f1)))
        waitUntil("F1 应已进入分割（在途被门卡住）") { segmenter.recordedCallCount == 1 }
        controller.handleDeliveredFrame(try XCTUnwrap(makeSampleBuffer(f2)))
        XCTAssertEqual(segmenter.recordedCallCount, 1, "F2 应只落合并槽，不得新增分割调用")

        // stop 是 lifecycle 队列 async；随后的 start sync 与其 FIFO 排队——start 返回即
        // stop 已完装（跨场 happens-before，CameraPiPTests 同款同步法）。
        controller.stop()
        XCTAssertThrowsError(try controller.start(), "无前置摄像头：start 以 cameraNotFound 显式降级")

        XCTAssertNil(controller.latestPixelBuffer, "stop 后 latestFrame 必须清空（与一期一致）")
        XCTAssertEqual(segmenter.recordedCallCount, 1, "stop 必须冲掉合并槽：F2 不得进分割")

        segmenter.openGate(returning: fullForegroundMask(width: 8, height: 8))
        Thread.sleep(forTimeInterval: 1.0) // 给迟到的 F1 完成走完全链路的机会
        XCTAssertEqual(segmenter.recordedCallCount, 1, "stop 后不得再有帧进入分割")
        XCTAssertNil(controller.latestPixelBuffer,
                     "迟到的在途完成被场次守卫拒绝，不得把旧帧带进下一场开头")
    }

    /// 纯色测试帧（blue 通道区分不同帧实例——identity 与内容断言两用）。
    private func makeFrame(blue: UInt8) throws -> CVPixelBuffer {
        try XCTUnwrap(makeColorBuffer(
            width: 8, height: 8, color: BGRAColor(blue: blue, green: 0, red: 0, alpha: 255)))
    }

    /// 轮询异步处理完成（流水线是 fire-and-forget Task，无回调缝可挂 expectation）。
    private func waitUntil(_ message: String, timeout: TimeInterval = 5, condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("\(message)（\(timeout)s 内未达成）")
    }
}
