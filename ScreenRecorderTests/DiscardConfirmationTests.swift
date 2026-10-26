import XCTest

@testable import ScreenRecorder

// MARK: - DiscardConfirmation（验收修复缺陷②抽出逻辑）无头单测

/// 丢弃两击确认抽出逻辑：时间由调用方逐次注入（`PauseMediaClock` 同款时钟注入形状），
/// 全部判定确定无等待。覆盖简报要求的四条路径：首次 tap → 武装；武装窗口内 tap → 确认
/// + 自动复位；超时（tick / 过期 tap）→ 解除；离开 recording/paused → 显式解除。
@MainActor
final class DiscardConfirmationTests: XCTestCase {

    /// 窗口内安全取样点（< 5s）。
    private static let insideWindow: TimeInterval = 4.9

    // MARK: 首次 tap → 武装

    /// idle 下首次 tap：进入武装、不确认（首击绝不能直接丢弃）。
    func testFirstTapArmsWithoutConfirming() {
        let confirmation = DiscardConfirmation()

        let confirmed = confirmation.tap(at: 100)

        XCTAssertFalse(confirmed)
        XCTAssertEqual(confirmation.phase, .armed)
        XCTAssertTrue(confirmation.isArmed)
    }

    // MARK: 武装窗口内 tap → 确认 + 自动复位

    /// 武装后窗口内（< 5s）再 tap：确认，且相位自动复位 idle——下一次单击重新武装，
    /// 不残留「一击即丢」的确认态。
    func testSecondTapInsideWindowConfirmsAndResets() {
        let confirmation = DiscardConfirmation()
        confirmation.tap(at: 100)

        let confirmed = confirmation.tap(at: 100 + Self.insideWindow)

        XCTAssertTrue(confirmed)
        XCTAssertEqual(confirmation.phase, .idle)
        XCTAssertFalse(confirmation.isArmed)

        XCTAssertFalse(confirmation.tap(at: 200))
        XCTAssertEqual(confirmation.phase, .armed)
    }

    /// 武装窗口边界：恰好 5s 视为过期（窗口为 [0, 5)），重新武装而非确认。
    func testSecondTapAtExactlyWindowIsNotConfirmed() {
        let confirmation = DiscardConfirmation()
        confirmation.tap(at: 100)

        let confirmed = confirmation.tap(at: 100 + DiscardConfirmation.disarmWindow)

        XCTAssertFalse(confirmed, "恰好 5s 已过期：不得确认")
        XCTAssertEqual(confirmation.phase, .armed, "过期 tap 重新武装（fresh 窗口）")
    }

    // MARK: 超时 → 解除

    /// tick 在窗口内：保持武装；窗口外：解除。视图层的自动解除定时只是驱动源，
    /// 判定全部收在此处（定时漂移不产生误确认/误解除）。
    func testTickDisarmsOnlyAfterWindow() {
        let confirmation = DiscardConfirmation()
        confirmation.tap(at: 100)

        confirmation.tick(at: 100 + 4.999)
        XCTAssertEqual(confirmation.phase, .armed, "窗口内 tick 不得解除")

        confirmation.tick(at: 100 + 5.5)
        XCTAssertEqual(confirmation.phase, .idle, "窗口外 tick 必须解除")
    }

    /// 过期后未及 tick 的 tap 也不得误确认：过期武装视为重新武装，armedAt 已刷新。
    func testStaleTapRearmsInsteadOfConfirming() {
        let confirmation = DiscardConfirmation()
        confirmation.tap(at: 100)

        let confirmed = confirmation.tap(at: 200) // 100s 已过，自动解除定时未及 tick

        XCTAssertFalse(confirmed)
        XCTAssertEqual(confirmation.phase, .armed)

        XCTAssertTrue(confirmation.tap(at: 201), "新武装窗口内第二次 tap 正常确认")
    }

    /// idle 下 tick 是无操作（未武装不存在过期）。
    func testTickInIdleIsNoOp() {
        let confirmation = DiscardConfirmation()

        confirmation.tick(at: 1000)

        XCTAssertEqual(confirmation.phase, .idle)
    }

    // MARK: 显式解除（离开 recording/paused，现有 onChange 行为保留）

    /// 离开 recording/paused 的 onChange 路径：显式解除回 idle。
    func testDisarmResetsPhase() {
        let confirmation = DiscardConfirmation()
        confirmation.tap(at: 100)

        confirmation.disarm()

        XCTAssertEqual(confirmation.phase, .idle)
    }

    /// 解除后单击重新武装——钉住修复轮 1 Minor #5 的语义：武装中浮条隐藏（收尾）后
    /// 新录制重现浮条，首击必须是武装而不是确认。
    func testTapAfterDisarmArmsFresh() {
        let confirmation = DiscardConfirmation()
        confirmation.tap(at: 100)
        confirmation.disarm()

        XCTAssertFalse(confirmation.tap(at: 101))
        XCTAssertEqual(confirmation.phase, .armed)
    }

    /// 解除幂等：idle 下 disarm 再 disarm / tick 均无副作用。
    func testDisarmIsIdempotent() {
        let confirmation = DiscardConfirmation()
        confirmation.disarm()
        confirmation.disarm()
        confirmation.tick(at: 1000)

        XCTAssertEqual(confirmation.phase, .idle)
    }

    // MARK: 裁定常量

    /// 裁定 4：disarm 窗口 3s → 5s（钉死常量，防回归回 3s）。
    func testDisarmWindowIsFiveSeconds() {
        XCTAssertEqual(DiscardConfirmation.disarmWindow, 5)
    }
}

// MARK: - DragSurfaceRouter（验收修复缺陷①命中分流）纯逻辑单测

/// 拖拽命中分流：交互热区（按钮）命中 → 交回 SwiftUI 正常处理；未命中（胶囊背景）
/// → 显式窗口拖动（裁定 1：拖拽面 = 胶囊背景，按钮热区除外照常响应）。
final class DragSurfaceRouterTests: XCTestCase {

    /// 三个按钮的典型热区（窗坐标，暂停/停止/丢弃）。
    private static let buttons: [CGRect] = [
        CGRect(x: 100, y: 0, width: 18, height: 18),
        CGRect(x: 132, y: 0, width: 18, height: 18),
        CGRect(x: 164, y: 0, width: 30, height: 30),
    ]

    /// 按钮中心命中：不拖动（事件必须落到 SwiftUI 按钮）。
    func testPointOverButtonFallsThroughToSwiftUI() {
        for rect in Self.buttons {
            let center = CGPoint(x: rect.midX, y: rect.midY)
            XCTAssertFalse(
                DragSurfaceRouter.shouldPerformWindowDrag(point: center, interactiveRegions: Self.buttons),
                "按钮热区内不得启动窗口拖动：\(rect)")
        }
    }

    /// 背景命中：启动显式拖动。
    func testPointOnBackgroundStartsDrag() {
        XCTAssertTrue(DragSurfaceRouter.shouldPerformWindowDrag(
            point: CGPoint(x: 60, y: 9), interactiveRegions: Self.buttons))
        XCTAssertTrue(DragSurfaceRouter.shouldPerformWindowDrag(
            point: CGPoint(x: 40, y: 25), interactiveRegions: Self.buttons))
    }

    /// 热区为空（布局未上报的理论窗口）：整面皆拖拽面——宁多拖不劫持点击。
    func testEmptyRegionsDragEverywhere() {
        XCTAssertTrue(DragSurfaceRouter.shouldPerformWindowDrag(
            point: CGPoint(x: 110, y: 9), interactiveRegions: []))
    }

    /// 热区边界取含（CGRect.contains 语义）：边界判交互——宁可少拖一格，不吞按钮点击。
    func testRegionEdgeIsInteractive() {
        XCTAssertFalse(DragSurfaceRouter.shouldPerformWindowDrag(
            point: CGPoint(x: 100, y: 0), interactiveRegions: Self.buttons))
    }

    /// 热区外紧邻点（差 1pt）仍是拖拽面。
    func testPointJustOutsideRegionIsDragSurface() {
        XCTAssertTrue(DragSurfaceRouter.shouldPerformWindowDrag(
            point: CGPoint(x: 99, y: 0), interactiveRegions: Self.buttons))
    }
}
