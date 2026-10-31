import AppKit
import CoreGraphics
import Foundation
import XCTest

@testable import ScreenRecorder

// MARK: - ClickOverlayState（简报 Produces 钉测）

final class ClickOverlayStateTests: XCTestCase {
    func testBriefPinnedDefaults() {
        let state = ClickOverlayState(point: .zero, appearedAt: Date())
        XCTAssertEqual(state.radiusInPixels, 24, "简报钉死默认半径 24（捕获像素）")
        XCTAssertEqual(state.fadeDuration, 0.6, "简报钉死默认淡出 0.6s")
        XCTAssertEqual(state.alpha, 1, "交付态默认全不透明（currentState 按衰减回填）")
    }

    func testEquatable() {
        let t = Date(timeIntervalSinceReferenceDate: 100)
        XCTAssertEqual(ClickOverlayState(point: CGPoint(x: 1, y: 2), appearedAt: t),
                       ClickOverlayState(point: CGPoint(x: 1, y: 2), appearedAt: t))
        XCTAssertNotEqual(ClickOverlayState(point: .zero, appearedAt: t),
                          ClickOverlayState(point: .zero, appearedAt: t, alpha: 0.5))
    }
}

// MARK: - evaluate（简报 Step 1 钉死场景：0.3s≈0.5 / 0.7s nil）

final class ClickHighlightEvaluateTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    func testMidFadeIsHalfOpacity() {
        let alpha = ClickHighlightTracker.evaluate(click: t0, date: t0.addingTimeInterval(0.3), fadeDuration: 0.6)
        XCTAssertEqual(alpha ?? -1, 0.5, accuracy: 0.01, "简报钉死：0.3s / 0.6s ≈ 0.5")
    }

    func testAtClickMomentIsFullOpacity() {
        XCTAssertEqual(ClickHighlightTracker.evaluate(click: t0, date: t0, fadeDuration: 0.6), 1)
    }

    func testAfterFadeDurationReturnsNil() {
        XCTAssertNil(ClickHighlightTracker.evaluate(click: t0, date: t0.addingTimeInterval(0.7), fadeDuration: 0.6),
                     "简报钉死：超时（0.7s > 0.6s）nil")
    }

    func testExactlyAtFadeDurationReturnsNil() {
        XCTAssertNil(ClickHighlightTracker.evaluate(click: t0, date: t0.addingTimeInterval(0.6), fadeDuration: 0.6),
                     "衰减末点透明度恰为 0，与超时同语义 nil")
    }

    func testNegativeElapsedReturnsNil() {
        XCTAssertNil(ClickHighlightTracker.evaluate(click: t0, date: t0.addingTimeInterval(-0.1), fadeDuration: 0.6),
                     "时钟回拨/负间隔防御")
    }

    func testZeroFadeDurationReturnsNil() {
        XCTAssertNil(ClickHighlightTracker.evaluate(click: t0, date: t0, fadeDuration: 0))
    }
}

// MARK: - 监听生命周期（简报 Step 1：enabled == false 时 start 后 monitor 未装）

final class ClickHighlightTrackerMonitorTests: XCTestCase {
    func testDisabledTrackerDoesNotInstallMonitorsOnStart() {
        let tracker = ClickHighlightTracker(enabled: false)
        tracker.start()
        tracker.start() // 幂等
        XCTAssertFalse(tracker.isMonitoring, "简报钉死：disabled 时 start 后 monitor 未装")
        tracker.stop()
        XCTAssertFalse(tracker.isMonitoring)
    }

    func testEnabledTrackerInstallsMonitorsAndStopRemovesThem() {
        let tracker = ClickHighlightTracker(enabled: true)
        tracker.start()
        XCTAssertTrue(tracker.isMonitoring)
        tracker.start() // 重复 start 幂等
        tracker.stop()
        tracker.stop() // 重复 stop 幂等
        XCTAssertFalse(tracker.isMonitoring)
    }

    func testStopWithoutStartIsNoOp() {
        let tracker = ClickHighlightTracker(enabled: true)
        tracker.stop()
        XCTAssertFalse(tracker.isMonitoring)
    }

    func testSetEnabledFalseWhileMonitoringRemovesMonitors() {
        let tracker = ClickHighlightTracker(enabled: true)
        tracker.start()
        XCTAssertTrue(tracker.isMonitoring)
        tracker.setEnabled(false)
        XCTAssertFalse(tracker.isMonitoring, "监听中关闭须立即摘除 monitor")
        tracker.setEnabled(true)
        XCTAssertFalse(tracker.isMonitoring, "setEnabled 只对齐开关，不自动装机（装机仍是 start() 职责）")
    }
}

// MARK: - currentState（快照 + 换算 + 衰减）

final class ClickHighlightTrackerStateTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    func testNilWithoutClicks() {
        let tracker = ClickHighlightTracker(enabled: true)
        XCTAssertNil(tracker.currentState(at: t0, inCapturePixelsOf: { $0 }))
    }

    func testCurrentStateConvertsPointAndCarriesFadeAlpha() {
        let tracker = ClickHighlightTracker(enabled: true)
        tracker.recordClick(point: CGPoint(x: 100, y: 200), at: t0)
        let state = tracker.currentState(at: t0.addingTimeInterval(0.3)) { point in
            CGPoint(x: point.x * 2, y: point.y * 2) // 任意转换器（接线层职责）
        }
        XCTAssertEqual(state?.point, CGPoint(x: 200, y: 400), "point 必须经 pointConverter 换算后交付")
        XCTAssertEqual(state?.alpha ?? -1, 0.5, accuracy: 0.01, "交付态带衰减透明度")
        XCTAssertEqual(state?.radiusInPixels, 24)
        XCTAssertEqual(state?.fadeDuration, 0.6)
    }

    func testCurrentStateNilAfterFade() {
        let tracker = ClickHighlightTracker(enabled: true)
        tracker.recordClick(point: .zero, at: t0)
        XCTAssertNil(tracker.currentState(at: t0.addingTimeInterval(0.7), inCapturePixelsOf: { $0 }),
                     "超时后 nil（合成侧按无高亮直通）")
    }

    func testLatestClickWins() {
        let tracker = ClickHighlightTracker(enabled: true)
        tracker.recordClick(point: CGPoint(x: 1, y: 1), at: t0)
        tracker.recordClick(point: CGPoint(x: 9, y: 9), at: t0.addingTimeInterval(0.1))
        let state = tracker.currentState(at: t0.addingTimeInterval(0.2), inCapturePixelsOf: { $0 })
        XCTAssertEqual(state?.point, CGPoint(x: 9, y: 9))
        XCTAssertEqual(state?.appearedAt, t0.addingTimeInterval(0.1))
    }

    /// 并发冒烟：主线程写（模拟事件回调）/ 后台队列读（模拟 video 队列）不崩、读数合法。
    func testConcurrentRecordAndReadStaysConsistent() {
        let tracker = ClickHighlightTracker(enabled: true)
        let writer = DispatchQueue(label: "clicktracker.writer")
        let reader = DispatchQueue(label: "clicktracker.reader")
        let expectation = expectation(description: "hammer")
        reader.async {
            for _ in 0..<500 {
                _ = tracker.currentState { $0 } // 并发下不崩；nil 或合法状态
            }
            expectation.fulfill()
        }
        writer.async {
            for i in 0..<500 {
                tracker.recordClick(point: CGPoint(x: CGFloat(i), y: 0), at: Date())
            }
        }
        wait(for: [expectation], timeout: 10)
    }
}

// MARK: - 坐标换算助手（Cocoa 全局 → CG 全局，接线层取数）

final class ClickHighlightCoordinateTests: XCTestCase {
    func testCgGlobalPointFlipsYByPrimaryScreenHeight() {
        XCTAssertEqual(
            ClickHighlightTracker.cgGlobalPoint(fromCocoaGlobal: CGPoint(x: 100, y: 200), primaryScreenHeight: 900),
            CGPoint(x: 100, y: 700), "同一物理点到主屏上/下边等距：cgY = 主屏高 − cocoaY")
        XCTAssertEqual(
            ClickHighlightTracker.cgGlobalPoint(fromCocoaGlobal: .zero, primaryScreenHeight: 900),
            CGPoint(x: 0, y: 900), "Cocoa 左下原点 = CG 左上原点")
    }
}

// MARK: - onClick 转发缝（P1a：缩放/点击音效等消费方装配用）

final class ClickHighlightOnClickTests: XCTestCase {
    func testDefaultIsNilAndRecordClickSurvives() {
        let tracker = ClickHighlightTracker(enabled: true)
        XCTAssertNil(tracker.onClick, "未装配消费方时转发缝缺省 nil")
        tracker.recordClick(point: CGPoint(x: 1, y: 2), at: Date()) // handler 缺省：nil 安全不崩
    }

    func testOnClickFiresWithRecordedPayload() {
        let tracker = ClickHighlightTracker(enabled: true)
        var received: [(point: CGPoint, date: Date)] = []
        tracker.onClick = { received.append((point: $0, date: $1)) }
        let t0 = Date(timeIntervalSinceReferenceDate: 42)

        tracker.recordClick(point: CGPoint(x: 100, y: 200), at: t0)

        XCTAssertEqual(received.count, 1, "每次记录恰好转发一次（fire-and-forget）")
        XCTAssertEqual(received[0].point, CGPoint(x: 100, y: 200), "载荷 = 原始记录坐标")
        XCTAssertEqual(received[0].date, t0, "载荷 = 原始点击时刻")
    }

    func testOnClickCanBeClearedAndStaysNilSafe() {
        let tracker = ClickHighlightTracker(enabled: true)
        tracker.onClick = { _, _ in }
        tracker.onClick = nil
        tracker.recordClick(point: .zero, at: Date()) // 清空后再记录：nil 安全
        XCTAssertNil(tracker.onClick)
    }
}

// MARK: - 本地事件抑制缝（P2 边录边标记，spec §5「绘图拖拽不触发点击系效果」）

final class ClickHighlightSuppressionTests: XCTestCase {
    /// 合成 leftMouseDown（CGEvent 路线，与 ESC 测试同款——无头进程无真实窗口可点）。
    private func makeMouseDown() -> NSEvent {
        let cgEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: CGPoint(x: 100, y: 100),
            mouseButton: .left)!
        return NSEvent(cgEvent: cgEvent)!
    }

    /// 抑制缝钉测（无头走 `handleLocalMouseDown` 入口，不装真实 monitor）：
    /// 缺省 nil = 不过滤照常记录；缝返回 true = 不记录（无环/无缩放喂入/无音效——
    /// 记录是三条链的共同上游，掐住记录即全链静默）；缝返回 false / 复位 nil 恢复记录。
    ///
    /// 背景断言（Task 5 调查结论，验收清单）：标记覆盖层是本 App 自己的窗口，其按下事件
    /// **不会**到达 tracker 的全局 monitor（NSEvent 全局监听收不到被本 App 处理的事件，
    /// 计划所钉假设成立）；但本地 monitor（addLocalMonitorForEvents）**收得到**本 App
    /// 窗口的 mouseDown——计划假设「天然不达」对本地监听不成立，故需此缝按事件目标窗口
    /// 显式过滤（覆盖层/工具条面板的按下不得画环、不得触发缩放与音效）。
    func testLocalMouseDownSuppressionSeamSkipsClickRecording() {
        let tracker = ClickHighlightTracker(enabled: true)
        let event = makeMouseDown()

        // 缺省 nil：本地按下照常记录（本 App 窗口的普通点击——点浮条等——仍画环）。
        tracker.handleLocalMouseDown(event)
        XCTAssertNotNil(tracker.currentState { $0 }, "未装配抑制缝时本地按下照常记录")

        // 缝返回 true（标记工具窗口命中）：不记录——衰减窗口内无叠加态。
        tracker.isLocalClickSuppressed = { _ in true }
        tracker.stop() // 清残影（stopInternal 清 lastClick，与生产收尾同路径）
        tracker.handleLocalMouseDown(event)
        XCTAssertNil(tracker.currentState { $0 }, "被抑制的本地按下不得记录为点击（不画环/不喂缩放/不调度音效）")

        // 缝返回 false：恢复记录。
        tracker.isLocalClickSuppressed = { _ in false }
        tracker.handleLocalMouseDown(event)
        XCTAssertNotNil(tracker.currentState { $0 }, "缝放行时照常记录")

        // 复位 nil：同缺省，照常记录。
        tracker.isLocalClickSuppressed = nil
        tracker.stop()
        tracker.handleLocalMouseDown(event)
        XCTAssertNotNil(tracker.currentState { $0 }, "缝复位 nil 后照常记录")
    }
}
