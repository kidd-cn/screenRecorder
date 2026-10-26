import XCTest

@testable import ScreenRecorder

/// MicrophoneRouteWatcher 内部分发逻辑钉测（与 SourceLossMonitorTests 同型：AVAudioEngine
/// 配置变化通知无法无头伪造，经 `simulateConfigurationChange()` 测分发——与生产通知观察者
/// 走同一投递路径）。同步用例主线程执行：投递契约「主线程内联 / 非主线程主队列跳转」
///（裁定 4 选定的序列化上下文）在测试里确定性同步完成。
final class MicrophoneRouteWatcherTests: XCTestCase {
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

    func testSimulateConfigurationChangeInvokesCallback() {
        let counter = CallbackCounter()
        let watcher = MicrophoneRouteWatcher(onRouteChanged: { counter.record() })
        XCTAssertFalse(watcher.isObserving)

        watcher.start()
        XCTAssertTrue(watcher.isObserving)

        watcher.simulateConfigurationChange()
        XCTAssertEqual(counter.value, 1, "配置变化：onRouteChanged 恰好一次")

        watcher.simulateConfigurationChange()
        XCTAssertEqual(counter.value, 2, "路由变化非一次会话事件：观察器持续转发（去重/幂等由混音器重建侧把守）")
    }

    func testStopPreventsFurtherCallbacks() {
        let counter = CallbackCounter()
        let watcher = MicrophoneRouteWatcher(onRouteChanged: { counter.record() })

        watcher.start()
        watcher.stop()
        XCTAssertFalse(watcher.isObserving)

        watcher.simulateConfigurationChange()
        XCTAssertEqual(counter.value, 0, "stop() 后再 simulate 不得调用")
    }

    func testRestartReinstallsObservation() {
        let counter = CallbackCounter()
        let watcher = MicrophoneRouteWatcher(onRouteChanged: { counter.record() })

        watcher.start()
        watcher.stop()
        watcher.start()
        XCTAssertTrue(watcher.isObserving, "start 幂等重装：先摘旧 observer 再挂新")

        watcher.simulateConfigurationChange()
        XCTAssertEqual(counter.value, 1)
    }
}
