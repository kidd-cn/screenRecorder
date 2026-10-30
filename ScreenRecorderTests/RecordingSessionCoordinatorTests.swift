import XCTest

@testable import ScreenRecorder

/// 可编程假 provider（同 DiskSpaceMonitorTests 模式）：直接返回预设字节数。
private final class FakeFreeSpaceProvider: DiskFreeSpaceProviding {
    var freeBytesValue: Int64?

    func freeBytes(at url: URL) -> Int64? { freeBytesValue }
}

/// RecordingSessionCoordinator 无头可测面：begin 前置磁盘检查 / 无会话时的空操作语义。
/// begin 成功路径依赖 ScreenCaptureKit TCC（无头环境不可确定性驱动），归批量真机轮验收。
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
