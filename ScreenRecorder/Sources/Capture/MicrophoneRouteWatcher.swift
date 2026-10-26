import AVFoundation
import Foundation

/// 麦克风路由观察器（Task 18，T9 台账收敛）：录制期监听 `.AVAudioEngineConfigurationChange`
///（engine 路由/硬件格式变化——含蓝牙耳机断连、输入设备插拔、采样率切换），回调装配层对
/// 当前混音器做自愈重建（裁定 5：重建后录制以新设备格式继续，无需用户干预；无 UI）。
///
/// 队列裁定（裁定 4 落实，选定的序列化上下文 = **主队列**）：`.AVAudioEngineConfigurationChange`
/// 由 AVAudioEngine 内部私有队列投递，禁止在该上下文直接做 engine/节点手术。观察器把回调
/// 跳转到主队列——全局串行、非渲染线程，且与浮条 `setMicMuted` 等其余 tap 手术同队列，
/// 天然互斥（与 SystemAudioMixer 既有手术纪律一致：手术全部离渲染线程）。投递实现与
/// DiskSpaceMonitor 同型：主线程内联同步执行，非主线程 `DispatchQueue.main.async` 跳转
///（测试由此确定性同步，无需 spin RunLoop）。
///
/// 生命周期（同 T16 ClickHighlightTracker 形状）：AppAssembly 持有实例并注入
/// CaptureController，`enterRecordingPhase` 启动、两条收尾出口摘除——倒计时与收尾期不监听；
/// 未装机（nil）全链路 no-op。回调去重/幂等由混音器重建侧把守（engine 未运行快照即 no-op）。
final class MicrophoneRouteWatcher {
    private let onRouteChanged: () -> Void
    private let lock = NSLock()
    /// 已挂观察句柄（nil = 未观察）。
    private var observer: NSObjectProtocol?

    /// 是否在观察中（internal 缝：单测钉生命周期契约）。
    var isObserving: Bool {
        lock.withStateLock { observer != nil }
    }

    init(onRouteChanged: @escaping () -> Void) {
        self.onRouteChanged = onRouteChanged
    }

    deinit {
        stop()
    }

    /// 开始监听（幂等：重复 start 先摘旧 observer 再重挂）。
    func start() {
        stop()
        let newObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVAudioEngineConfigurationChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.deliverRouteChange()
        }
        lock.withStateLock { observer = newObserver }
    }

    /// 停止监听（幂等）。返回后不会再有任何回调。
    func stop() {
        let stale: NSObjectProtocol? = lock.withStateLock {
            let owned = observer
            observer = nil
            return owned
        }
        if let stale {
            NotificationCenter.default.removeObserver(stale)
        }
    }

    /// 测试缝：模拟一次配置变化（与生产通知观察者走完全相同的投递路径）。未观察中
    ///（stop 后）不投递——生产通知只能经 observer 到达，语义一致。
    func simulateConfigurationChange() {
        guard isObserving else { return }
        deliverRouteChange()
    }

    // MARK: - 内部

    /// 投递：主线程内联 / 非主线程主队列跳转（见类注释队列裁定）。
    private func deliverRouteChange() {
        let callback = onRouteChanged
        if Thread.isMainThread {
            callback()
        } else {
            DispatchQueue.main.async(execute: callback)
        }
    }
}
