import AppKit
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

/// P3a：App 模式源丢失错误——被采集应用的**全部**窗口均已关闭（部分关闭不触发，规格
/// 画布纪律「全关自动保存」）。装配层按当前捕获模式选择本错误或 `SourceLossError`。
struct AppSourceLostError: LocalizedError {
    let bundleID: String

    var errorDescription: String? {
        "被采集的应用（bundle id=\(bundleID)）的窗口已全部关闭"
    }
}

/// 源丢失监视器（Task 18）：录制期监听显示器断连，被采集显示器消失时经 `onSourceLost`
/// 通知装配层走 `CaptureController.handleSessionFailure` 自动保存路径（成片保留 + 「录制
/// 已自动保存」通知）。匹配语义（裁定 2）：display/region 模式按被采集 displayID 精确匹配；
/// window/nil = 采集全台语义，任一显示器移除即触发。无锁屏监听（裁定 3：锁屏不构成中断，
/// 不加任何 lock-screen 出口）。
///
/// App 模式（P3a）：`start(displayID:appBundleID:)` 的 appBundleID 非 nil 时改为轮询该
/// bundle 的**仍存在普通层窗口数（全窗口清单口径）**——最小化（进 Dock）、⌘H 隐藏、切到
/// 其他 Space 的窗口都算存在，只有真正关闭才从清单消失；**全部窗口关闭（计数 0）才触发**
/// 源丢失（不可见 ≠ 关闭），部分关闭继续录制（规格画布纪律：新窗口不入画、部分关闭继续、
/// 全关自动保存）；显示器移除事件不参与判定（app 窗口可跨屏存活，拔显示器 ≠ 源丢失）。
/// 窗口关闭无系统级推送通知，轮询是唯一口径（DispatchSourceTimer，DiskSpaceMonitor 同款
/// 模式）；窗口清单读取失败按「未知」处理不判定，绝不因读取失败误杀录制。
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
/// 线程模型：`start`/`stop`/`simulateDisplayRemoved`/`simulateAppWindowCount` 任意线程可调
///（状态经 NSLock 串行化）；CG 重配置回调在系统事件处理线程投递、App 窗口计数轮询在
/// 专属后台队列执行——投递契约与 DiskSpaceMonitor 同型：主线程内联同步执行，非主线程
/// `DispatchQueue.main.async` 跳转，保证 `onSourceLost` 固定主线程（装配层闭包内再跳
/// 主 actor 进控制器）。
final class SourceLossMonitor {
    private let onSourceLost: () -> Void
    private let lock = NSLock()
    /// 被监视显示器（nil = 采集全台语义）。
    private var capturedDisplayID: CGDirectDisplayID?
    /// 被监视 App 的 bundle id（P3a；nil = 非 App 模式，显示器事件照常参与判定）。
    private var capturedBundleID: String?
    /// 已 start（录制期）。`isActive` 供生命周期钉测与诊断。
    private var armed = false
    /// 本会话已上报（fire-once 闩）。
    private var fired = false
    /// CG 回调是否已注册（跨 start/stop 幂等）。
    private var registered = false
    /// App 模式窗口计数轮询 timer（P3a；仅 appBundleID 非 nil 时在位，状态锁内换装）。
    private var appPollTimer: DispatchSourceTimer?
    private let appPollQueue = DispatchQueue(label: "screenRecorder.SourceLossMonitor.appPoll", qos: .utility)
    /// App 模式窗口计数轮询间隔（秒）。窗口关闭是用户可感知操作（比磁盘耗尽更频繁），
    /// 间隔取 2s：全关自动保存的延迟可感知但不抖动。
    private static let appPollInterval: TimeInterval = 2

    /// 被监视的显示器 id（nil = 采集全台语义；诊断/单测钉匹配语义用）。
    var monitoredDisplayID: CGDirectDisplayID? {
        lock.withStateLock { capturedDisplayID }
    }

    /// 被监视的 App bundle id（P3a；nil = 非 App 模式；诊断/单测钉匹配语义用）。
    var monitoredAppBundleID: String? {
        lock.withStateLock { capturedBundleID }
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

    /// 开始监视（重复 start 重对齐目标并重新武装；CG 回调注册幂等——恰注册一次）。
    /// `appBundleID` 非 nil = App 内容模式（P3a，见类注释）：显示器事件退出判定，改由
    /// 窗口计数轮询承担源丢失判定。
    func start(displayID: CGDirectDisplayID?, appBundleID: String? = nil) {
        let needsRegistration: Bool = lock.withStateLock {
            capturedDisplayID = displayID
            capturedBundleID = appBundleID
            fired = false
            armed = true
            if registered { return false }
            registered = true
            return true
        }
        if needsRegistration {
            let status = CGDisplayRegisterReconfigurationCallback(
                sourceLossDisplayReconfigurationCallback,
                Unmanaged.passUnretained(self).toOpaque()
            )
            if status != .success {
                // 注册失败复位标记（审查修复轮 1 #2）：否则标记滞留 true——后续 start 永不重试
                // 注册，stop 还会去摘除一对从未注册的回调。
                lock.withStateLock { registered = false }
                NSLog("SourceLossMonitor: CGDisplayRegisterReconfigurationCallback 失败（\(status.rawValue)），源丢失监视不可用")
            }
        }
        restartAppPolling()
    }

    /// 停止监视并复位（幂等）。返回后不再发起新的投递；已在途（已排入主队列等待投递）的
    /// 最后一次命中仍可能送达，但会被 `handleDisplayRemoved`/`handleAppWindowCount` 的
    /// `armed` 闸吸收（stop 已清位，不会触发 `onSourceLost`）。
    func stop() {
        let wasRegistered: Bool = lock.withStateLock {
            let owned = registered
            registered = false
            armed = false
            fired = false
            capturedDisplayID = nil
            capturedBundleID = nil
            appPollTimer?.cancel() // cancel 线程安全且不内联进本锁；在途节拍由 armed 闸吸收
            appPollTimer = nil
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

    /// 测试缝（P3a）：模拟一次 App 窗口计数读数（生产 = 轮询节拍的
    /// `existingAppWindowCount` 读数），与生产轮询走完全相同的判定与投递路径。
    /// nil = 窗口清单读取失败（未知不判定）。
    func simulateAppWindowCount(_ count: Int?) {
        handleAppWindowCount(count)
    }

    // MARK: - 内部

    /// 按当前模式重排 App 窗口计数轮询（appBundleID 非 nil 且在位才轮询）；start/stop
    /// 共用的唯一 timer 换装点（状态锁内 cancel + 重建，与 armed/bundleID 同锁无竞态）。
    private func restartAppPolling() {
        lock.lock()
        appPollTimer?.cancel()
        appPollTimer = nil
        if armed, let bundleID = capturedBundleID {
            let source = DispatchSource.makeTimerSource(queue: appPollQueue)
            source.schedule(deadline: .now() + Self.appPollInterval, repeating: Self.appPollInterval)
            source.setEventHandler { [weak self] in self?.pollAppWindows(ofBundleID: bundleID) }
            source.resume()
            appPollTimer = source
        }
        lock.unlock()
    }

    /// 轮询节拍（appPollQueue）：读当前 bundle 的仍存在普通层窗口数 → 判定。
    /// bundleID 由 timer 装配时定格（start 换场必经 restartAppPolling 重建 timer，不读错场）。
    private func pollAppWindows(ofBundleID bundleID: String) {
        let isLive: Bool = lock.withStateLock { armed && capturedBundleID == bundleID }
        guard isLive else { return }
        handleAppWindowCount(Self.existingAppWindowCount(ofBundleID: bundleID))
    }

    /// 生产窗口计数（P3a）：**全窗口清单**里该 bundle 的普通层（layer 0）窗口数——
    /// `.optionAll` 含最小化（进 Dock）、⌘H 隐藏、切到其他 Space 的窗口（都算存在），
    /// 只有真正关闭的窗口才从清单消失，因此计数 0 = 全部窗口关闭（不可见 ≠ 关闭——
    /// 修复轮 1 Important 1：on-screen 口径会把最小化/隐藏/跨 Space 误判成已关闭）。
    /// 窗口清单没有 bundle id 键（`kCGWindowOwnerBundleID` 在现行 SDK 头文件中不存在，
    /// 实测字典亦无此键），归属经所有者 PID → `NSRunningApplication.bundleIdentifier`
    /// 解析；解析不出 App 的窗口（Window Server 等）不属于用户 App，自然不匹配。
    /// 清单读取失败返回 nil（未知不判定——绝不因读取失败误杀录制）。
    static func existingAppWindowCount(ofBundleID bundleID: String) -> Int? {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        var count = 0
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int ?? 0) == 0 else { continue }
            guard let pid = info[kCGWindowOwnerPID as String] as? Int,
                  NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier == bundleID else { continue }
            count += 1
        }
        return count
    }

    /// App 模式判定与投递（P3a）：仍存在窗口数 0 = 全部窗口关闭 → fire-once 闩 → 主线程
    /// 投递；计数 > 0（部分关闭/部分不可见继续录）与 nil（读取失败不判定）不触发。与
    /// display 路径共用同一闩位（fired）与同一投递契约（主线程内联 / 非主线程主队列跳转）。
    private func handleAppWindowCount(_ count: Int?) {
        let shouldFire: Bool = lock.withStateLock {
            guard armed, !fired, capturedBundleID != nil else { return false }
            guard count == 0 else { return false }
            fired = true
            return true
        }
        guard shouldFire else { return }
        deliverOnSourceLost()
    }

    /// 移除事件匹配与 fire-once 闩（锁内裁决），命中后主线程投递 `onSourceLost`。
    /// internal：文件级 C 回调桥转回实例入口（private 类型成员自顶层函数不可达）。
    /// P3a：App 模式（capturedBundleID 非 nil）显示器事件整体退出判定。
    func handleDisplayRemoved(_ displayID: CGDirectDisplayID) {
        let shouldFire: Bool = lock.withStateLock {
            guard armed, !fired else { return false }
            guard capturedBundleID == nil else { return false }
            guard capturedDisplayID == nil || capturedDisplayID == displayID else { return false }
            fired = true
            return true
        }
        guard shouldFire else { return }
        deliverOnSourceLost()
    }

    /// 投递契约（与 DiskSpaceMonitor 同型）：主线程内联同步执行，非主线程主队列跳转。
    private func deliverOnSourceLost() {
        if Thread.isMainThread {
            onSourceLost()
        } else {
            DispatchQueue.main.async(execute: onSourceLost)
        }
    }
}
