import Foundation

/// 磁盘剩余空间读取抽象；真实实现见 `VolumeFreeSpaceProvider`，测试可注入假实现。
protocol DiskFreeSpaceProviding {
    /// 返回 `url` 所在卷的可用字节数；卷查询失败（路径不存在、卷不可用等）返回 nil，不抛错。
    func freeBytes(at url: URL) -> Int64?
}

/// 真实实现：读 `volumeAvailableCapacityForImportantUsageKey`
///（系统对「可用于写入」的保守估计，已计入预留空间，是录制安全网的正确口径）。
struct VolumeFreeSpaceProvider: DiskFreeSpaceProviding {
    func freeBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// 磁盘空间安全网（Review Focus #3）：跌破 warn/stop 阈值时在主队列回调，
/// 让上层先把已录内容安全收尾（finalization 产出可播放文件），而不是写出一个死文件。
///
/// 主队列回调契约的实现选择：`checkNow()` 在主线程被调用时，回调在调用线程同步内联执行
///（主线程同步执行 ≡ 主队列执行，AppKit/UIKit 线程安全语义等价）；在非主线程被调用时
///（含轮询 timer 的后台队列）经 `DispatchQueue.main.async` 派发。两条路径都保证回调体
/// 运行在主线程，测试因此可同步断言、无需 spin RunLoop。
///
/// 迟滞语义（每次下探最多触发一次，防抖动）：
/// - `onWarn`：低于 `warnBelow` 时触发并锁存；回升严格越过 `warnBelow + 500MB` 才重新武装。
/// - `onStop`：同构，独立锁存于 `stopBelow ± 500MB`。
/// - provider 返回 nil：不回调、不崩溃、不改任何状态。
final class DiskSpaceMonitor {
    /// 剩余空间跌破 `warnBelow` 时触发（主队列保证）。
    var onWarn: (() -> Void)?
    /// 剩余空间跌破 `stopBelow` 时触发（主队列保证）。
    var onStop: (() -> Void)?

    private let provider: DiskFreeSpaceProviding
    private let url: URL
    private let warnBelow: Int64
    private let stopBelow: Int64
    private let pollInterval: TimeInterval
    private let hysteresis: Int64 = 500_000_000

    /// 全部可变状态只在 stateQueue 上触碰；回调在 sync 块外投递，不会死锁。
    private let stateQueue = DispatchQueue(label: "screenRecorder.DiskSpaceMonitor.state")
    private var warnArmed = true
    private var stopArmed = true
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "screenRecorder.DiskSpaceMonitor.timer", qos: .utility)

    init(provider: DiskFreeSpaceProviding,
         url: URL,
         warnBelow: Int64 = 2_000_000_000,
         stopBelow: Int64 = 500_000_000,
         pollInterval: TimeInterval = 30) {
        self.provider = provider
        self.url = url
        self.warnBelow = warnBelow
        self.stopBelow = stopBelow
        self.pollInterval = pollInterval
    }

    deinit {
        timer?.cancel() // 未 cancel 的 DispatchSourceTimer 会被 libdispatch 持有到进程结束
    }

    /// 立即检查一次；监控未开启时同样可用。
    func checkNow() {
        let toFire: [(() -> Void)?] = stateQueue.sync {
            guard let free = provider.freeBytes(at: url) else { return [] } // nil：不回调、不改状态
            var fired: [(() -> Void)?] = []
            if warnArmed {
                if free < warnBelow {
                    warnArmed = false
                    fired.append(onWarn)
                }
            } else if free > warnBelow + hysteresis {
                warnArmed = true
            }
            if stopArmed {
                if free < stopBelow {
                    stopArmed = false
                    fired.append(onStop)
                }
            } else if free > stopBelow + hysteresis {
                stopArmed = true
            }
            return fired
        }
        for callback in toFire {
            guard let callback else { continue }
            if Thread.isMainThread {
                callback()
            } else {
                DispatchQueue.main.async(execute: callback)
            }
        }
    }

    /// 开启轮询（后台队列上的 DispatchSourceTimer）；已开启时幂等。
    /// 首次触发在 `pollInterval` 之后——启动时的即时检查由调用方直接调 `checkNow()`。
    func startMonitoring() {
        stateQueue.sync {
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: timerQueue)
            source.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
            source.setEventHandler { [weak self] in self?.checkNow() }
            source.resume()
            timer = source
        }
    }

    /// 停止轮询；未开启时幂等。停止后可再次 `startMonitoring()`。
    func stopMonitoring() {
        stateQueue.sync {
            timer?.cancel()
            timer = nil
        }
    }
}
