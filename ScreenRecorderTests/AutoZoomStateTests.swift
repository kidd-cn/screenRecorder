import CoreGraphics
import XCTest

@testable import ScreenRecorder

/// AutoZoomState 时间线 + ZoomTransforms 钳制钉测（Task 1 简报 Step 1）。
/// 全部经注入 now 驱动（headless 硬规矩：逻辑内不读墙钟），断言走「放大窗口 =
/// viewport 经仿射逆映射回底帧的矩形」这一几何口径，不偷看实现内部。
@MainActor
final class AutoZoomStateTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)

    /// 浮点噪声容差（1e-9 远小于任何视觉精度，钳制贴边按零越界钉）。
    private static let accuracy: CGFloat = 1e-9

    // MARK: 简报钉测

    func testIdleTransformIsNil() {
        let state = AutoZoomState(level: 1.6)

        XCTAssertNil(state.currentTransform(in: bounds, now: 0))
        XCTAssertNil(state.currentTransform(in: bounds, now: 10))

        state.tick(now: 10) // 空转推进不产生变换
        XCTAssertNil(state.currentTransform(in: bounds, now: 10))
    }

    /// 四角点击各一次：满档位时放大窗口完全在 bounds 内且点击角恰好贴边
    /// （钳制后越界为零——窗口边 == bounds 边，容差内相等）。
    func testClickAttacksToClampedCenter() throws {
        // (minX 贴下边, minY 贴下边) 的期望组合：角点哪两条边被钉住。
        let corners: [(point: CGPoint, pinsMinX: Bool, pinsMinY: Bool)] = [
            (CGPoint(x: 0, y: 0), true, true),
            (CGPoint(x: 1, y: 0), false, true),
            (CGPoint(x: 0, y: 1), true, false),
            (CGPoint(x: 1, y: 1), false, false),
        ]

        for corner in corners {
            let state = AutoZoomState(level: 1.9)
            state.click(atNormalizedPoint: corner.point, now: 0)

            let transform = try XCTUnwrap(
                state.currentTransform(in: bounds, now: AutoZoomState.attackDuration),
                "角点 \(corner.point) 满档位应有变换")
            let window = zoomWindow(of: transform, in: bounds)

            XCTAssertEqual(transform.a, 1.9, accuracy: Self.accuracy)
            XCTAssertEqual(transform.d, 1.9, accuracy: Self.accuracy)
            // 完全在 bounds 内（放大窗口不越出底帧）
            XCTAssertGreaterThanOrEqual(window.minX, bounds.minX - Self.accuracy)
            XCTAssertGreaterThanOrEqual(window.minY, bounds.minY - Self.accuracy)
            XCTAssertLessThanOrEqual(window.maxX, bounds.maxX + Self.accuracy)
            XCTAssertLessThanOrEqual(window.maxY, bounds.maxY + Self.accuracy)
            // 越界为零：点击角两条边恰好贴住 bounds 边
            let pinnedX = corner.pinsMinX ? window.minX : window.maxX
            let pinnedY = corner.pinsMinY ? window.minY : window.maxY
            XCTAssertEqual(pinnedX, corner.pinsMinX ? bounds.minX : bounds.maxX,
                           accuracy: Self.accuracy, "角点 \(corner.point) x 边应贴边")
            XCTAssertEqual(pinnedY, corner.pinsMinY ? bounds.minY : bounds.maxY,
                           accuracy: Self.accuracy, "角点 \(corner.point) y 边应贴边")
        }
    }

    /// hold 内再点击以新中心重启 attack：t=1.0 中心已朝 B 越过中线，
    /// B 的攻击完成（t=1.05）后窗口中心钳制跟随 B。
    func testHoldThenReclickRecenters() throws {
        let state = AutoZoomState(level: 1.6)
        let pointA = CGPoint(x: 0.2, y: 0.5)
        let pointB = CGPoint(x: 0.8, y: 0.5)

        state.click(atNormalizedPoint: pointA, now: 0.2)
        state.tick(now: 0.5) // A 攻击完成（0.2+0.25）进入 hold
        XCTAssertEqual(state.phase, .hold)
        let windowA = zoomWindow(
            of: try XCTUnwrap(state.currentTransform(in: bounds, now: 0.5)), in: bounds)
        XCTAssertEqual(windowA.midX, 31.25, accuracy: Self.accuracy, "应居中于钳制后的 A")
        XCTAssertEqual(windowA.midY, 50, accuracy: Self.accuracy)

        state.click(atNormalizedPoint: pointB, now: 0.8) // hold 内再点击 → 重启 attack
        XCTAssertEqual(state.phase, .attack)
        // t=1.0：B 的新攻击进行中（进度 0.8 缓动后 0.92），中心已越过中线朝 B
        let windowMid = zoomWindow(
            of: try XCTUnwrap(state.currentTransform(in: bounds, now: 1.0)), in: bounds)
        XCTAssertGreaterThan(windowMid.midX, bounds.midX)
        // t=1.05：B 攻击完成（0.8+0.25），中心 = 钳制后的 B（80 → 68.75）
        let windowB = zoomWindow(
            of: try XCTUnwrap(state.currentTransform(in: bounds, now: 1.05)), in: bounds)
        XCTAssertEqual(windowB.midX, 68.75, accuracy: Self.accuracy, "中心应跟随 B")
        XCTAssertEqual(windowB.midY, 50, accuracy: Self.accuracy)
    }

    func testReleaseCompletesToNil() {
        let state = AutoZoomState(level: 1.6)
        state.click(atNormalizedPoint: CGPoint(x: 0.5, y: 0.5), now: 0)
        let total = AutoZoomState.attackDuration + AutoZoomState.holdDuration
            + AutoZoomState.releaseDuration

        XCTAssertNotNil(state.currentTransform(in: bounds, now: 1.0), "hold 期应有变换")
        XCTAssertNotNil(state.currentTransform(in: bounds, now: 1.6), "release 后段仍在缓出")
        state.tick(now: total)
        XCTAssertEqual(state.phase, .idle, "总时长整点时间线走完")
        XCTAssertNil(state.currentTransform(in: bounds, now: total), "总时长整点收敛为 nil")
        XCTAssertNil(state.currentTransform(in: bounds, now: 2.0))
    }

    func testInvalidLevelIsNil() {
        for level in [CGFloat(1.0), CGFloat(0.9), CGFloat(-2)] {
            let state = AutoZoomState(level: level)
            state.click(atNormalizedPoint: CGPoint(x: 0.5, y: 0.5), now: 0)
            state.tick(now: 0.5)
            XCTAssertNil(state.currentTransform(in: bounds, now: 0.5), "level=\(level) 应无变换")
        }
    }

    // MARK: 边界补钉（自审清单：release 重定心 / 空 bounds / 攻击缓动单调）

    /// release 期内再 click 同样以新中心重启 attack：新攻击完成时中心跟随 B
    /// （旧时间线此刻已整体结束——若未重启，此处应为 nil 而非 B 的满档变换）。
    func testClickDuringReleaseRestartsAttack() throws {
        let state = AutoZoomState(level: 1.6)
        let releaseStart = AutoZoomState.attackDuration + AutoZoomState.holdDuration
        state.click(atNormalizedPoint: CGPoint(x: 0.2, y: 0.5), now: 0)
        state.click(atNormalizedPoint: CGPoint(x: 0.8, y: 0.5), now: releaseStart + 0.15)

        XCTAssertEqual(state.phase, .attack, "release 内点击应重启 attack")
        XCTAssertNotNil(state.currentTransform(in: bounds, now: releaseStart + 0.25))
        let window = zoomWindow(
            of: try XCTUnwrap(state.currentTransform(in: bounds, now: 1.65)), in: bounds)
        XCTAssertEqual(window.midX, 68.75, accuracy: Self.accuracy, "中心应跟随重启后的 B")
    }

    /// bounds 空（零宽/零高）返回 nil——即使时间线活跃。
    func testEmptyBoundsIsNil() {
        let state = AutoZoomState(level: 1.6)
        state.click(atNormalizedPoint: CGPoint(x: 0.5, y: 0.5), now: 0)

        XCTAssertNil(state.currentTransform(in: .zero, now: 0.1))
        XCTAssertNil(state.currentTransform(in: CGRect(x: 0, y: 0, width: 100, height: 0), now: 0.1))
    }

    /// attack 期内有效档位单调增大（缓动曲线端点精确、中途不减）。
    func testAttackZoomRampsMonotonically() throws {
        let state = AutoZoomState(level: 1.9)
        state.click(atNormalizedPoint: CGPoint(x: 0.5, y: 0.5), now: 0)

        var lastScale: CGFloat = 1
        for step in 1...10 {
            let now = AutoZoomState.attackDuration * Double(step) / 10
            let transform = try XCTUnwrap(state.currentTransform(in: bounds, now: now))
            XCTAssertGreaterThan(transform.a, lastScale, "t=\(now) 档位应继续增大")
            lastScale = transform.a
        }
        XCTAssertEqual(lastScale, 1.9, accuracy: Self.accuracy, "攻击末点满档位")
    }

    // MARK: RecordingConfiguration 快照缺省（Task 1 Models 扩展）

    /// 开录快照缺省：自动缩放关、档位 1.6（与 SettingsStore 缺省同源，Task 2 装配透传）。
    func testRecordingConfigurationAutoZoomDefaults() {
        let config = RecordingConfiguration(
            mode: .display(CGMainDisplayID()),
            captureSystemAudio: true,
            captureMicrophone: true,
            includeCamera: false,
            fps: 30,
            codec: .h264,
            outputURL: URL(fileURLWithPath: "/tmp/out.mov"),
            clickHighlightEnabled: false)

        XCTAssertFalse(config.autoZoomEnabled)
        XCTAssertEqual(config.autoZoomLevel, 1.6)
    }

    // MARK: 助手

    /// 放大窗口：viewport（bounds）经仿射逆映射回底帧内容的矩形（纯缩放+平移，无旋转，
    /// 角点包围盒精确）。
    private func zoomWindow(of transform: CGAffineTransform, in bounds: CGRect) -> CGRect {
        bounds.applying(transform.inverted())
    }
}
