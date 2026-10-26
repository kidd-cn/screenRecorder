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
