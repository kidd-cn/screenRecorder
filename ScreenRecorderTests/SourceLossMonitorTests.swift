import CoreGraphics
import XCTest

@testable import ScreenRecorder

/// SourceLossMonitor 内部分发逻辑钉测（brief Step 1：Fake 通知中心不便测，经
/// `simulateDisplayRemoved()` 测内部分发——与生产 CGDisplayReconfigurationCallBack
/// 的 remove 事件走同一投递路径）。XCTest 同步用例在主线程执行：投递契约「主线程内联 /
/// 非主线程主队列跳转」在测试里确定性地同步完成，无需 spin RunLoop。
final class SourceLossMonitorTests: XCTestCase {
    /// 回调计数器（跨线程安全：生产回调固定主线程，此处防御性加锁）。
    private final class CallbackCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func record() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    // MARK: - 裁定 2：仅被采集显示器的移除触发；nil displayID = 采集全台语义

    func testRemovalOfCapturedDisplayFiresExactlyOnce() {
        let counter = CallbackCounter()
        let monitor = SourceLossMonitor(onSourceLost: { counter.record() })

        monitor.start(displayID: 7)
        XCTAssertTrue(monitor.isActive)
        XCTAssertEqual(monitor.monitoredDisplayID, 7)

        monitor.simulateDisplayRemoved(7)
        XCTAssertEqual(counter.value, 1, "被采集显示器移除：onSourceLost 恰好一次")

        monitor.simulateDisplayRemoved(7) // 首发即闩：重复事件不再触发
        monitor.simulateDisplayRemoved(8)
        XCTAssertEqual(counter.value, 1, "fire-once 闩位：后续移除事件不重复触发")
    }

    func testRemovalOfOtherDisplayDoesNotFire() {
        let counter = CallbackCounter()
        let monitor = SourceLossMonitor(onSourceLost: { counter.record() })

        monitor.start(displayID: 7)
        monitor.simulateDisplayRemoved(8)

        XCTAssertEqual(counter.value, 0, "非被采集显示器的移除不得触发")
        XCTAssertTrue(monitor.isActive, "误伤性移除不解除武装：监视器保持在位")
    }

    func testNilDisplayIDFiresOnAnyDisplayRemoval() {
        let counter = CallbackCounter()
        let monitor = SourceLossMonitor(onSourceLost: { counter.record() })

        monitor.start(displayID: nil) // window 模式：无定显示器 → 任一移除即源丢失
        XCTAssertNil(monitor.monitoredDisplayID)

        monitor.simulateDisplayRemoved(42)
        XCTAssertEqual(counter.value, 1, "采集全台语义：任一显示器移除触发")

        monitor.simulateDisplayRemoved(43)
        XCTAssertEqual(counter.value, 1, "fire-once 闩位对 nil displayID 同样生效")
    }

    // MARK: - brief Step 1：stop 后再 simulate 不调用

    func testStopPreventsFurtherCallbacks() {
        let counter = CallbackCounter()
        let monitor = SourceLossMonitor(onSourceLost: { counter.record() })

        monitor.start(displayID: 7)
        monitor.stop()
        XCTAssertFalse(monitor.isActive)

        monitor.simulateDisplayRemoved(7)
        XCTAssertEqual(counter.value, 0, "stop() 后再 simulate 不得调用")
    }

    func testRestartRearmsMonitor() {
        let counter = CallbackCounter()
        let monitor = SourceLossMonitor(onSourceLost: { counter.record() })

        monitor.start(displayID: 7)
        monitor.simulateDisplayRemoved(7)
        XCTAssertEqual(counter.value, 1)

        monitor.stop()
        monitor.start(displayID: 9) // 下一场录制：换显示器重开
        XCTAssertTrue(monitor.isActive)
        XCTAssertEqual(monitor.monitoredDisplayID, 9)

        monitor.simulateDisplayRemoved(9)
        XCTAssertEqual(counter.value, 2, "start 重新武装：新会话可再次触发")
    }

    // MARK: - 源丢失错误文案（handleSessionFailure 归类用）

    func testSourceLossErrorCarriesDisplayContext() {
        XCTAssertEqual(
            SourceLossError(removedDisplayID: 3).errorDescription,
            "被采集的显示器（id=3）已断开连接")
        XCTAssertNil(SourceLossError(removedDisplayID: nil).removedDisplayID)
        XCTAssertEqual(
            SourceLossError(removedDisplayID: nil).errorDescription,
            "被采集的显示器已断开连接")
    }

    // MARK: - P3a：App 模式（全部窗口关闭才触发——部分关闭继续，全关自动保存）

    func testAppExitWithAllWindowsClosedTriggersSourceLoss() {
        let counter = CallbackCounter()
        let monitor = SourceLossMonitor(onSourceLost: { counter.record() })

        monitor.start(displayID: nil, appBundleID: "com.example.app")
        XCTAssertTrue(monitor.isActive)
        XCTAssertEqual(monitor.monitoredAppBundleID, "com.example.app")

        monitor.simulateAppWindowCount(2)
        XCTAssertEqual(counter.value, 0, "部分关闭（仍有窗口）继续录制，不触发")
        monitor.simulateAppWindowCount(1)
        XCTAssertEqual(counter.value, 0, "最后一个窗口关闭之前不触发")
        monitor.simulateAppWindowCount(0)
        XCTAssertEqual(counter.value, 1, "全部窗口关闭：onSourceLost 恰好一次（自动保存路径）")
        monitor.simulateAppWindowCount(0)
        XCTAssertEqual(counter.value, 1, "fire-once 闩位对 App 判定同样生效")
    }

    func testAppModeIgnoresDisplayRemovalAndUnreadableCount() {
        let counter = CallbackCounter()
        let monitor = SourceLossMonitor(onSourceLost: { counter.record() })

        monitor.start(displayID: 7, appBundleID: "com.example.app")
        monitor.simulateDisplayRemoved(7)
        XCTAssertEqual(counter.value, 0, "App 模式：显示器移除不参与判定（app 窗口可跨屏存活）")
        monitor.simulateAppWindowCount(nil)
        XCTAssertEqual(counter.value, 0, "窗口清单读取失败（nil = 未知）不判定，绝不误杀录制")
        XCTAssertTrue(monitor.isActive, "未触发时监视器保持在位")
        monitor.simulateAppWindowCount(0)
        XCTAssertEqual(counter.value, 1, "随后读数归零照常触发")
    }

    func testAppSourceLostErrorCarriesBundleContext() {
        XCTAssertEqual(
            AppSourceLostError(bundleID: "com.example.app").errorDescription,
            "被采集的应用（bundle id=com.example.app）的窗口已全部关闭")
    }
}
