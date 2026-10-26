import CoreGraphics
import Foundation

/// C 回调桥（文件级函数：C 函数指针可由无捕获函数引用构成；start/remove 两处引用同址，
/// 保证 `CGDisplayRemoveReconfigurationCallback` 精确摘除本监视器的注册）。
private func sourceLossDisplayReconfigurationCallback(
    display: CGDirectDisplayID,
    flags: CGDisplayChangeSummaryFlags,
    userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo, flags.contains(.removeFlag) else { return } // begin/加显/移位等事件不关心（kCGDisplayRemoveFlag 的 Swift 名）
    let monitor = Unmanaged<SourceLossMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    monitor.handleDisplayRemoved(display)
}

/// 源丢失错误（装配层接线时包装给 `CaptureController.handleSessionFailure` 做文案归类，
/// `failureMessage` 渲染为「录制中断。……原因：<errorDescription>」）。
struct SourceLossError: LocalizedError {
    /// 断开的显示器 id（nil = 采集全台语义，未定点具体显示器）。
    let removedDisplayID: CGDirectDisplayID?

    var errorDescription: String? {
        guard let removedDisplayID else { return "被采集的显示器已断开连接" }
        return "被采集的显示器（id=\(removedDisplayID)）已断开连接"
    }
}

/// 源丢失监视器（Task 18）：录制期监听显示器断连，被采集显示器消失时经 `onSourceLost`
/// 通知装配层走 `CaptureController.handleSessionFailure` 自动保存路径（成片保留 + 「录制
/// 已自动保存」通知）。匹配语义（裁定 2）：display/region 模式按被采集 displayID 精确匹配；
/// window/nil = 采集全台语义，任一显示器移除即触发。无锁屏监听（裁定 3：锁屏不构成中断，
/// 不加任何 lock-screen 出口）。
///
/// API 偏差台账：brief 写 `CGDisplayWasRemovedNotification`——该符号在现行 SDK 无公开声明
///（全 SDK 头文件检索无果），改用其公开等价物 `CGDisplayRegisterReconfigurationCallback`
/// 的 `kCGDisplayRemoveFlag` 事件：同为 CoreGraphics 显示移除通知，且回调直接携带
/// displayID（无需解析通知 userInfo）。
///
/// 语义：首发即闩（fire-once，与 SCStreamRecorder.recordFailure 的 first-failure-wins 同型）
/// ——单会话源丢失只上报一次，重复 remove 事件/无关显示器移除不再触发；`stop()` 摘除回调
/// 注册并复位闩位；再次 `start` 重新武装（新会话新显示器）。重入防护与控制器 `.finishing`
/// 去抖闸双保险。
///
/// 线程模型：`start`/`stop`/`simulateDisplayRemoved` 任意线程可调（状态经 NSLock 串行化）；
/// CG 重配置回调在系统事件处理线程投递——投递契约与 DiskSpaceMonitor 同型：主线程内联
/// 同步执行，非主线程 `DispatchQueue.main.async` 跳转，保证 `onSourceLost` 固定主线程
///（装配层闭包内再跳主 actor 进控制器）。
final class SourceLossMonitor {
    private let onSourceLost: () -> Void
    private let lock = NSLock()
    /// 被监视显示器（nil = 采集全台语义）。
    private var capturedDisplayID: CGDirectDisplayID?
    /// 已 start（录制期）。`isActive` 供生命周期钉测与诊断。
    private var armed = false
    /// 本会话已上报（fire-once 闩）。
    private var fired = false
    /// CG 回调是否已注册（跨 start/stop 幂等）。
    private var registered = false

    /// 被监视的显示器 id（nil = 采集全台语义；诊断/单测钉匹配语义用）。
    var monitoredDisplayID: CGDirectDisplayID? {
        lock.withStateLock { capturedDisplayID }
    }

    /// 是否在监视中（start 后、stop 前；单测钉生命周期契约用）。
    var isActive: Bool {
        lock.withStateLock { armed }
    }

    init(onSourceLost: @escaping () -> Void) {
        self.onSourceLost = onSourceLost
    }

    deinit {
        stop()
    }

    /// 开始监视（重复 start 重对齐目标显示器并重新武装；CG 回调注册幂等——恰注册一次）。
    func start(displayID: CGDirectDisplayID?) {
        let needsRegistration: Bool = lock.withStateLock {
            capturedDisplayID = displayID
            fired = false
            armed = true
            if registered { return false }
            registered = true
            return true
        }
        guard needsRegistration else { return }
        let status = CGDisplayRegisterReconfigurationCallback(
            sourceLossDisplayReconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        if status != .success {
            NSLog("SourceLossMonitor: CGDisplayRegisterReconfigurationCallback 失败（\(status.rawValue)），源丢失监视不可用")
        }
    }

    /// 停止监视并复位（幂等）。返回后不会再有任何回调。
    func stop() {
        let wasRegistered: Bool = lock.withStateLock {
            let owned = registered
            registered = false
            armed = false
            fired = false
            capturedDisplayID = nil
            return owned
        }
        guard wasRegistered else { return }
        CGDisplayRemoveReconfigurationCallback(
            sourceLossDisplayReconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    /// 测试缝（brief Step 1：Fake 通知中心不便测，测内部分发逻辑）：模拟一次显示器移除，
    /// 与生产 CG 回调走完全相同的匹配与投递路径。
    func simulateDisplayRemoved(_ displayID: CGDirectDisplayID) {
        handleDisplayRemoved(displayID)
    }

    // MARK: - 内部

    /// 移除事件匹配与 fire-once 闩（锁内裁决），命中后主线程投递 `onSourceLost`。
    /// internal：文件级 C 回调桥转回实例入口（private 类型成员自顶层函数不可达）。
    func handleDisplayRemoved(_ displayID: CGDirectDisplayID) {
        let shouldFire: Bool = lock.withStateLock {
            guard armed, !fired else { return false }
            guard capturedDisplayID == nil || capturedDisplayID == displayID else { return false }
            fired = true
            return true
        }
        guard shouldFire else { return }
        if Thread.isMainThread {
            onSourceLost()
        } else {
            DispatchQueue.main.async(execute: onSourceLost)
        }
    }
}
