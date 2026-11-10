import CoreGraphics
import XCTest

@testable import ScreenRecorder

/// 可编程假 provider（同 DiskSpaceMonitorTests 模式）：直接返回预设字节数。
private final class FakeFreeSpaceProvider: DiskFreeSpaceProviding {
    var freeBytesValue: Int64?

    func freeBytes(at url: URL) -> Int64? { freeBytesValue }
}

/// RecordingSessionCoordinator 无头可测面：begin 前置磁盘检查 / 无会话时的空操作语义。
/// begin 成功路径依赖 ScreenCaptureKit TCC（无头环境不可确定性驱动），归批量真机轮验收。

/// windowFactory 捕获盒（闭包不可捕获 inout 参数，转经引用盒；CameraPiPTests
/// capturedWindow 同款语义）。
private final class PiPWindowBox {
    var panel: CameraPiPWindow?
}

@MainActor
final class RecordingSessionCoordinatorTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingSessionCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func makeConfig() -> RecordingConfiguration {
        RecordingConfiguration(
            mode: .display(1),
            captureSystemAudio: false,
            captureMicrophone: false,
            micVolume: 1.0,
            includeCamera: false,
            fps: 30,
            codec: .h264,
            outputURL: tempDirectory.appendingPathComponent("target.mp4"),
            clickHighlightEnabled: false
        )
    }

    func testBeginThrowsInsufficientDiskSpaceBelowStopThreshold() async {
        let provider = FakeFreeSpaceProvider()
        provider.freeBytesValue = 400_000_000
        let coordinator = RecordingSessionCoordinator(
            diskProvider: provider, warnBelow: 2_000_000_000, stopBelow: 500_000_000)

        do {
            _ = try await coordinator.begin(makeConfig())
            XCTFail("低于 stop 阈值时 begin 应失败，不开录")
        } catch let error as CaptureSessionError {
            XCTAssertEqual(error, .insufficientDiskSpace(freeBytes: 400_000_000, requiredBytes: 500_000_000))
        } catch {
            XCTFail("意外错误类型：\(error)")
        }
    }

    func testFinishWithoutBeginReturnsNil() async {
        let coordinator = RecordingSessionCoordinator()

        let url = await coordinator.finish()

        XCTAssertNil(url)
    }

    func testPauseResumeWithoutSessionAreNoOps() {
        let coordinator = RecordingSessionCoordinator()

        coordinator.pause()
        coordinator.resume()
    }

    /// 终审 F2：麦克风 live 下发（静音/音量）在无进行中录制时为 no-op——不得崩溃；
    /// 持久化值自下一场开录的 config 快照生效。
    func testMicLiveSettersWithoutSessionAreNoOps() {
        let coordinator = RecordingSessionCoordinator()

        coordinator.setMicMuted(true)
        coordinator.setMicMuted(false)
        coordinator.setMicVolume(0.5)
    }

    // MARK: - Fix A 接线钉测（spec §5 缺口：协调器 begin 的 T5 双缝）

    private let pipGeometry = PiPCaptureGeometry(
        captureOriginInCGPoints: .zero,
        scale: 2,
        capturePixelSize: CGSize(width: 2880, height: 1800))

    /// 夹具缩略图（纯色 CGImage——只验投递落点，不验内容；CameraPiPTests 同款夹具）。
    private static func makeSolidImage() -> CGImage? {
        let context = CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return context?.makeImage()
    }

    private func makePipControllerCapturingWindow(
        into box: PiPWindowBox
    ) -> CameraPiPWindowController {
        CameraPiPWindowController(
            windowFactory: {
                let made = CameraPiPWindow.makeDefault()
                box.panel = made
                return made
            },
            startCamera: { _ in },
            stopCamera: { _ in })
    }

    /// 钉测 1（接线真值）：`layoutSwappedProvider` 非 nil 且真读 `isLayoutSwapped`——
    /// 旗标翻转前后闭包取值跟随（video 队列逐帧直读语义）。begin 成功路径依赖
    /// ScreenCaptureKit TCC（无头不可驱动），接线断言经 begin 单点抽出的
    /// `wirePipSwapSeams` 直接驱动（Fix A 最小 internal 缝，armForTesting 同款先例）。
    func testWirePipSwapSeamsProviderReadsLiveSwapFlag() throws {
        let pipController = CameraPiPWindowController(
            windowFactory: { CameraPiPWindow.makeDefault() },
            startCamera: { _ in },
            stopCamera: { _ in })
        let coordinator = RecordingSessionCoordinator(cameraPiP: pipController)
        let recorder = SCStreamRecorder(config: makeConfig())

        coordinator.wirePipSwapSeams(on: recorder, wantsPiP: true)

        let provider = try XCTUnwrap(
            recorder.layoutSwappedProvider, "对调取数缝必须已装配（recorder 可逐帧问询对调态）")
        XCTAssertFalse(provider(), "初值恒屏幕为主（未对调）")
        pipController.setLayoutSwapped(true)
        XCTAssertTrue(provider(), "闭包必须真读 isLayoutSwapped（旗标翻转须穿透到取数缝）")
        pipController.setLayoutSwapped(false)
        XCTAssertFalse(provider(), "换回后取数缝回到屏幕为主")
    }

    /// 钉测 2（消费缝 wantsPiP 门控 + 端到端投递）：wantsPiP 为真时 `screenThumbnailConsumer`
    /// 非 nil 且喂图真落浮窗缩略图层（updateScreenThumbnail 主 actor hop 后 contents 非 nil）；
    /// wantsPiP 为假（含 cameraPiP 在位）时消费缝保持 nil（无 PiP 不产缩略图，热路径零渲染）。
    func testWirePipSwapSeamsThumbnailConsumerGatedByWantsPiP() async throws {
        let box = PiPWindowBox()
        let pipController = makePipControllerCapturingWindow(into: box)
        let coordinator = RecordingSessionCoordinator(cameraPiP: pipController)
        let recorder = SCStreamRecorder(config: makeConfig())

        coordinator.wirePipSwapSeams(on: recorder, wantsPiP: true)

        let consumer = try XCTUnwrap(
            recorder.screenThumbnailConsumer, "wantsPiP 场缩略图消费缝必须装配")
        pipController.beginRecording(geometry: pipGeometry) // 浮窗落位（updateScreenThumbnail 落点）
        let cg = try XCTUnwrap(Self.makeSolidImage(), "夹具缩略图创建失败")
        consumer(cg)
        for _ in 0..<100 {
            if box.panel?.windowThumbnailImage != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms 让出主 actor（贴图 Task 落地）
        }
        XCTAssertNotNil(
            box.panel?.windowThumbnailImage,
            "喂图必须真落浮窗缩略图层（消费缝直通 updateScreenThumbnail 链）")

        // wantsPiP = false：消费缝不得装配（cameraPiP 在位也不例外——门控在 wantsPiP）。
        let plainRecorder = SCStreamRecorder(config: makeConfig())
        coordinator.wirePipSwapSeams(on: plainRecorder, wantsPiP: false)
        XCTAssertNil(
            plainRecorder.screenThumbnailConsumer,
            "无 PiP 场（含 cameraPiP 在位）缩略图消费缝必须保持 nil")
    }
}

// MARK: - P1a 暂停门（spec §5「暂停时不触发」钉死）

/// 无头钉测面 = `RecordingSessionCoordinator.feedZoomClick`（暂停门 + 换算链所在方法）；
/// begin 成功路径依赖 ScreenCaptureKit TCC（无头不可确定性驱动，同上类台账注记），
/// 暂停门经直接喂入 + 无会话 pause/resume（只置位门，recorder no-op）驱动。
/// 数学口径：翻转高度取画布高 240 → cocoa (x, y) → cg (x, 240−y) → 像素同值 → 归一化
/// (x/320, 1 − (240−y)/240)；点击锚 now=10、探针 now=10.125（攻击 0.25s 中点，进度 0.5）。
@MainActor
final class ZoomPauseGateTests: XCTestCase {
    private let bounds = CGRect(origin: .zero, size: CGSize(width: 320, height: 240))
    private let geometry = PiPCaptureGeometry(
        captureOriginInCGPoints: .zero,
        scale: 1,
        capturePixelSize: CGSize(width: 320, height: 240))
    private let flipHeight: CGFloat = 240

    /// 暂停中丢弃新点击：攻击中锚点不被重启（若门失效，(0.75, 0.75) 新中心会改写
    /// 变换）；已在途的缩放原样继续走完（不 reset、不 snap-cut）。
    func testPausedCoordinatorDropsNewZoomClicks() {
        let coordinator = RecordingSessionCoordinator()
        let zoomState = AutoZoomState(level: 1.6)

        coordinator.feedZoomClick(CGPoint(x: 80, y: 60), into: zoomState,
                                  geometry: geometry, flipHeight: flipHeight, now: 10)
        let attackMid = zoomState.frameTransform(in: bounds, now: 10.125)
        XCTAssertNotNil(attackMid, "未暂停：点击喂入，攻击中变换非 nil")

        coordinator.pause()
        coordinator.feedZoomClick(CGPoint(x: 240, y: 180), into: zoomState,
                                  geometry: geometry, flipHeight: flipHeight, now: 10)

        XCTAssertEqual(zoomState.frameTransform(in: bounds, now: 10.125), attackMid,
                       "暂停中：新点击被丢弃，攻击中变换原样走完（锚点仍 (0.25, 0.25)）")
    }

    /// 恢复重新开门：新点击以新中心 (0.5, 0.5) 重启攻击（门未开则仍停留旧锚点）。
    func testResumeReopensZoomClickFeed() {
        let coordinator = RecordingSessionCoordinator()
        let zoomState = AutoZoomState(level: 1.6)
        coordinator.feedZoomClick(CGPoint(x: 80, y: 60), into: zoomState,
                                  geometry: geometry, flipHeight: flipHeight, now: 10)
        coordinator.pause()
        coordinator.resume()

        coordinator.feedZoomClick(CGPoint(x: 160, y: 120), into: zoomState,
                                  geometry: geometry, flipHeight: flipHeight, now: 10)

        XCTAssertEqual(zoomState.frameTransform(in: bounds, now: 10.125),
                       ZoomTransforms.contentTransform(center: CGPoint(x: 0.5, y: 0.5),
                                                       level: 1.6,
                                                       progress: 0.5,
                                                       in: bounds),
                       "恢复后：新点击重新锚定（变换走 Task 1 真源 API 构造参照）")
    }
}

// MARK: - P1b 点击音效暂停门（spec §5「暂停期间不触发」）

/// 无头钉测面 = `RecordingSessionCoordinator.feedClickSound`（与 feedZoomClick 同门形状，
/// sink 缝注入 spy 观测「调度放行/丢弃」——begin 成功路径依赖 ScreenCaptureKit TCC，无头
/// 不可确定性驱动，同上类台账注记；无会话 pause/resume 只置位门，recorder no-op）。
@MainActor
final class ClickSoundPauseGateTests: XCTestCase {
    /// 调度 spy：计数 scheduleClickEffect 到达次数（生产实现 SCStreamRecorder 转发混音器）。
    private final class ScheduleSpy: ClickSoundScheduling {
        private(set) var scheduleCount = 0
        func scheduleClickEffect() { scheduleCount += 1 }
    }

    /// 暂停中丢弃新点击的音效调度（暂停期间不触发）；恢复后重新放行。
    /// 与缩放门同一 accessor（isRecordingPaused）与同一时间互斥论证（begin 复位先于喂入）。
    func testPausedCoordinatorDropsClickSoundScheduling() {
        let coordinator = RecordingSessionCoordinator()
        let spy = ScheduleSpy()

        coordinator.feedClickSound(into: spy)
        XCTAssertEqual(spy.scheduleCount, 1, "未暂停：音效调度放行")

        coordinator.pause()
        coordinator.feedClickSound(into: spy)
        XCTAssertEqual(spy.scheduleCount, 1, "暂停中：新点击的音效调度被丢弃（不得到达 scheduleClickEffect）")

        coordinator.resume()
        coordinator.feedClickSound(into: spy)
        XCTAssertEqual(spy.scheduleCount, 2, "恢复后：门重新打开，调度放行")
    }
}
