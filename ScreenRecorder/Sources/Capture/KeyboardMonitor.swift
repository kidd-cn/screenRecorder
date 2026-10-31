import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

// MARK: - 安全输入读数（简报钉定事实的跨 SDK 出口）

/// 安全输入会话标志（系统密码框等安全输入加固进行中）。简报钉定的
/// `NSEvent.isSecureInputEnabled` 在本工具链的 macOS 26 SDK 已被移除（AppKit 头文件
/// 无声明、swiftinterface 无成员、运行时 AppKit 二进制无该 selector——grep 实证），
/// 改读其底层同源出口 HIToolbox `IsSecureEventInputEnabled`（导出符号仍在 tbd，
/// `Carbon.HIToolbox` 模块随 KeyboardShortcuts 依赖已在链接图中；AppKit 旧实现即转调
/// 此层的同一会话标志，语义逐字等同）。轮询节拍与驱动语义不变：KeyboardMonitor 以
/// 0.5s timer 语义轮询本函数 → `state.setSecureInputActive(_:)`。
@_silgen_name("IsSecureEventInputEnabled")
private func isSecureEventInputEnabled() -> Bool

// MARK: - InputMonitoringPermission（输入监控 TCC 授权：沿用一期 Permissions.swift 模式）

/// 输入监控（监听事件，kTCCServiceListenEvent）授权检测与请求——P4 唯一新增 TCC 权限。
/// 模式与一期 `PermissionChecker` 的 screen 对逐字同构：`isGranted()` 只读预检；
/// `request()` 触发系统弹窗后轮询预检等待用户操作（此前拒绝过则请求静默失败，
/// 调用方需引导用户去系统设置手动允许）。
enum InputMonitoringPermission {
    /// 只读预检：`CGPreflightListenEventAccess()`（CoreGraphics，macOS 10.15+；floor 13 无门槛）。
    static func isGranted() -> Bool {
        CGPreflightListenEventAccess()
    }

    /// 发起系统请求并轮询预检：每 1s 查询一次、上限 60 次（约 1 分钟），期间用户授权即
    /// 提前返回；超限或所在任务被取消（`Task.sleep` 抛出取消错误）即放弃。返回最终
    /// 预检结果（false = 用户未授权/此前拒绝过，弹窗不会再出现——引导 UI 应带路系统设置）。
    static func request() async -> Bool {
        if isGranted() { return true }
        CGRequestListenEventAccess()
        for _ in 0 ..< 60 {
            if isGranted() { return true }
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return isGranted() // 任务被取消，以现场预检收尾
            }
        }
        return isGranted()
    }
}

// MARK: - KeyboardEventSource（事件源缝：简报 Produces，形状按假源测试需求最小化）

/// 一次装机交付的三个键盘事件入口（record-only：handler 只读事件、不拦截不消费）。
struct KeyboardEventHandlers {
    var onKeyDown: (NSEvent) -> Void
    var onKeyUp: (NSEvent) -> Void
    var onFlagsChanged: (NSEvent) -> Void
}

/// 键盘事件源抽象（简报 `EventSource` 缝的实现者定形）：只抽象「装卸全局/本地键盘监听」
/// 两件事——事件 → `KeyDescriptor` 换算与状态机馈送全在 `KeyboardMonitor`（可无头钉测），
/// 真实实现包 NSEvent API（无头不可测，测试注入记录型假源）。命名较简报的 `EventSource`
/// 具体化为 `KeyboardEventSource`（模块内更可检索；形状授权在简报「形状由实现者按假源
/// 测试需求定，缝最小化」）。
protocol KeyboardEventSource: AnyObject {
    /// 安装全局监听（其他应用前台的键盘事件；**需 Input Monitoring 授权**——授权判定在
    /// `KeyboardMonitor.start()`，未经判定不得调用本方法）。回调在主线程交付。
    func installGlobal(handlers: KeyboardEventHandlers)
    /// 安装本地监听（本 App 前台的键盘事件；无需授权）。回调在主线程交付，事件原样放行。
    func installLocal(handlers: KeyboardEventHandlers)
    /// 摘除全部监听（幂等；未装机为 no-op）。
    func removeAll()
}

/// NSEvent 生产实现：`.keyDown/.keyUp/.flagsChanged` 全局 + 本地监听（简报钉定 NSEvent
/// API 路线；CGEventTap 为备选未采用——NSEvent 与一期 ClickHighlightTracker 的监听惯例
/// 同源，且全局 keyDown monitor 在缺授权时由系统按 TCC 语义处理，无需自管 tap 生命周期）。
/// 线程模型：装卸与回调全在主线程（NSEvent monitor 契约），无共享可变态、无锁。
final class NSEventKeyboardSource: KeyboardEventSource {
    /// 键盘三类事件掩码（简报钉定）。
    private static let monitoredEvents: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]

    private var globalMonitors: [Any] = []
    private var localMonitors: [Any] = []

    func installGlobal(handlers: KeyboardEventHandlers) {
        // 装机失败（monitor 返回 nil，理论不可达）静默忽略——监听层降级纪律，无错误刷屏。
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: Self.monitoredEvents, handler: { event in
            Self.route(event, to: handlers)
        }) {
            globalMonitors.append(monitor)
        }
    }

    func installLocal(handlers: KeyboardEventHandlers) {
        // record-only：本地 monitor 必须原样返回事件（吞掉会阻断本 App 自身的键盘处理）。
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: Self.monitoredEvents, handler: { event in
            Self.route(event, to: handlers)
            return event
        }) {
            localMonitors.append(monitor)
        }
    }

    func removeAll() {
        for monitor in globalMonitors { NSEvent.removeMonitor(monitor) }
        for monitor in localMonitors { NSEvent.removeMonitor(monitor) }
        globalMonitors = []
        localMonitors = []
    }

    /// 按事件类型分派（全局 monitor 收到的事件 window 为 nil，但 type 仍区分三类）。
    private static func route(_ event: NSEvent, to handlers: KeyboardEventHandlers) {
        switch event.type {
        case .keyDown: handlers.onKeyDown(event)
        case .keyUp: handlers.onKeyUp(event)
        case .flagsChanged: handlers.onFlagsChanged(event)
        default: break
        }
    }
}

// MARK: - KeyboardOverlaySnapshotStore（主 actor 写 / video 队列读的快照桥）

/// 键帽快照桥（MarkingStrokeStore / PiPFrameStore 同款锁纪律）：`KeyboardOverlayState` 在
/// 主 actor（Task 8 纪律），合成取数缝在 SCStream video 队列——NSLock 保护单个不可变
/// 快照，锁内一次结构体拷贝，合成热路径零分配零栅格化。UI/状态侧一律走
/// `KeyboardOverlayState.snapshot(style:lingerSeconds:now:)` 纯读口径取值（Task 8 纪律：
/// 永不读 phase 判过期），本桥只做过河；刷新节奏在 `KeyboardMonitor`（事件即时刷新 +
/// 定期循环兜 linger 到期）。
@MainActor
final class KeyboardOverlaySnapshotStore {
    private let lock = NSLock()
    /// 最新快照（nil = 无键帽：开关关 / 无按键 / linger 到期 / 安全输入）。一律锁内读写；
    /// `nonisolated(unsafe)` 为跨线程读缝（video 队列 provider）豁免 actor 隔离，线程安全
    /// 由 lock 保证——与 MarkingStrokeStore.snapshot 同纪律。
    nonisolated(unsafe) private var snapshot: KeyboardOverlaySnapshot?

    /// 覆写最新快照（主 actor：监听层事件回调 / 刷新循环）。nil 原样写入（与笔画桥的
    /// 空快照归一同语义：无键帽帧合成直通）。
    func update(_ snapshot: KeyboardOverlaySnapshot?) {
        lock.lock()
        self.snapshot = snapshot
        lock.unlock()
    }

    /// video 队列读缝（非隔离）：锁内取不可变快照，锁外消费。
    nonisolated func currentSnapshot() -> KeyboardOverlaySnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }
}

// MARK: - KeyboardMonitor（监听层：NSEvent → KeyDescriptor → KeyboardOverlayState）

/// 键盘监听器（P4）：全局 + 本地 `.keyDown/.keyUp/.flagsChanged` 监听换算成
/// `KeyDescriptor` 馈送 `KeyboardOverlayState`（record-only：只读事件不拦截），并把
/// 状态机快照按现场样式定期灌入 `KeyboardOverlaySnapshotStore` 供合成热路径取数。
///
/// - **授权降级**（规格钉定）：Input Monitoring 预检通过才装全局监听；未授权降级为仅
///   本地监听（本 App 前台按键仍可视化）——不崩溃、无错误刷屏，授权引导归
///   PermissionOnboardingView（预检/请求模式见 `InputMonitoringPermission`，一期
///   Permissions.swift 同构）。每次 start 现场预检：用户中途授权自下一场录制生效。
/// - **安全输入**（规格钉定）：`isSecureEventInputEnabled`（简报钉定 API 在本 SDK 的
///   出口，见文件头 shim 注释）0.5s 轮询（timer 语义）驱动 `state.setSecureInputActive(_:)`；
///   轮询生命周期跟随监听生命周期（监听活跃才轮询）。节拍判定逻辑收敛在
///   `pollSecureInputOnce()`（确定性缝，无头钉测走它）。
/// - **生命周期**（record-only，与 ClickHighlightTracker start/stop 纪律对称）：随录制
///   启动装机、随收尾摘除（装配层按 `controller.$state` 驱动）；暂停不是生命周期事件
///   ——recording/paused 都保持监听，键帽暂停期照常聚合（输出侧已有暂停段剔除）。
///   `stop` 清空状态机（残影防御：收尾前一瞬的按键不得淡入下一场录制开头）并刷新桥值。
/// - **enabled 开关**（快照语义）：初值 `init(enabled:)`，录制开始由装配层以设置快照
///   重对齐（`setEnabled`，与 tracker 同纪律：监听中关闭立即摘除、只对齐不自动装机）。
///   样式/停留时长是 live 语义：刷新循环逐拍经 provider 读当前设置，改动即时生效。
/// - **线程模型**：本类与状态机全在主 actor；NSEvent 回调主线程交付，经
///   `MainActor.assumeIsolated` 零调度跳转进主 actor（事件次序保序，CaptureController
///   tracker onClick 同款）；桥值供 SCStream video 队列经 store 锁读。刷新循环为
///   主 actor Task（事件即时刷新 + 0.1s 兜底循环——linger 到期是时间驱动而非事件驱动，
///   无循环则过期键帽永驻桥值）。时钟注入 `now`（生产 = 系统运行时长，与 zoom 链同口径；
///   事件时刻与刷新时刻必须同钟，linger 锚定才自洽）。
@MainActor
final class KeyboardMonitor {
    /// 安全输入轮询节拍（简报钉死 0.5s）。
    static let secureInputPollInterval: TimeInterval = 0.5
    /// 快照桥兜底刷新节拍（linger 到期是时间驱动；0.1s ≈ 30fps 的 3 帧，键帽消失延迟
    /// 上界；按键即时刷新不受此拍影响）。
    static let snapshotRefreshInterval: TimeInterval = 0.1
    /// 修饰键记账位掩码（flagsChanged 差分只认这六位；与状态机记账口径同源常量拼装）。
    private static let accountingBitsMask: ModifierFlagsMask =
        KeyboardModifierMaskBits.capsLock | KeyboardModifierMaskBits.shift
            | KeyboardModifierMaskBits.control | KeyboardModifierMaskBits.option
            | KeyboardModifierMaskBits.command | KeyboardModifierMaskBits.function

    private let state: KeyboardOverlayState
    private let store: KeyboardOverlaySnapshotStore
    private let source: KeyboardEventSource
    /// enabled 总开关（快照语义；`setEnabled` 是录制开始的重对齐点）。
    private var enabled: Bool
    private let globalPermissionProbe: () -> Bool
    private let secureInputProbe: () -> Bool
    private let styleProvider: () -> KeyboardOverlayStyle
    private let lingerProvider: () -> TimeInterval
    private let now: () -> TimeInterval

    /// 是否已装监听（主 actor 可读；internal 缝供无头钉测）。
    private(set) var isMonitoring = false
    /// 本次装机是否含全局监听（false = 授权缺失降级仅本地；internal 缝供无头钉测）。
    private(set) var usesGlobalListening = false
    /// 安全输入轮询循环是否在跑（internal 缝供无头钉测；nil task = 已停）。
    var isSecureInputPolling: Bool { securePollTask != nil }

    /// flagsChanged 差分基准（上一事件的修饰掩码；0 = 尚未见事件）。主 actor 独占读写。
    private var lastModifierFlags: ModifierFlagsMask = 0
    private var securePollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    /// - Parameters:
    ///   - state: 键帽聚合状态机（Task 8；所有权归装配层，本监听器只写事件）。
    ///   - store: 快照桥（本监听器是唯一写入方）。
    ///   - source: 事件源缝（生产 NSEventKeyboardSource，测试假源）。
    ///   - enabled: 总开关初值（快照语义，录制开始由装配层重对齐）。
    ///   - globalPermissionProbe: Input Monitoring 预检缝（生产 `CGPreflightListenEventAccess`）。
    ///   - secureInputProbe: 安全输入读数缝（生产 `isSecureEventInputEnabled` shim，见文件头）。
    ///   - styleProvider: 键帽样式 live 读缝（装配层读 SettingsStore 当前值）。
    ///   - lingerProvider: 停留时长 live 读缝（同上）。
    ///   - now: 单调时钟缝（生产系统运行时长；事件与刷新必须同钟）。
    init(state: KeyboardOverlayState,
         store: KeyboardOverlaySnapshotStore,
         source: KeyboardEventSource = NSEventKeyboardSource(),
         enabled: Bool,
         globalPermissionProbe: @escaping () -> Bool = { InputMonitoringPermission.isGranted() },
         secureInputProbe: @escaping () -> Bool = { isSecureEventInputEnabled() },
         styleProvider: @escaping () -> KeyboardOverlayStyle = {
             KeyboardOverlayStyle(colorAlternate: false, fontSize: 14)
         },
         lingerProvider: @escaping () -> TimeInterval = { 2 },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.state = state
        self.store = store
        self.source = source
        self.enabled = enabled
        self.globalPermissionProbe = globalPermissionProbe
        self.secureInputProbe = secureInputProbe
        self.styleProvider = styleProvider
        self.lingerProvider = lingerProvider
        self.now = now
    }

    /// 主开关重对齐（录制开始由装配层以设置快照调用；监听中关闭立即摘除，同 tracker 纪律）。
    func setEnabled(_ newValue: Bool) {
        enabled = newValue
        if !newValue { stop() } // 锁外摘除（无锁类；stop 自守卫幂等）
    }

    /// 安装监听与轮询/刷新循环（幂等；disabled 为 no-op）。录制进入 recording/paused 时
    /// 由装配层调用。授权现场预检：通过才装全局（未经授权装全局 keyDown monitor 会触发
    /// TCC 弹窗打断录制，规格钉定降级不弹），本地监听恒装。
    func start() {
        guard enabled, !isMonitoring else { return }
        usesGlobalListening = globalPermissionProbe()
        let handlers = KeyboardEventHandlers(
            onKeyDown: { [weak self] event in
                MainActor.assumeIsolated { self?.handleKeyDown(event) }
            },
            onKeyUp: { [weak self] event in
                MainActor.assumeIsolated { self?.handleKeyUp(event) }
            },
            onFlagsChanged: { [weak self] event in
                MainActor.assumeIsolated { self?.handleFlagsChanged(event) }
            })
        if usesGlobalListening {
            source.installGlobal(handlers: handlers)
        }
        source.installLocal(handlers: handlers)
        isMonitoring = true
        lastModifierFlags = 0
        startSecureInputPoll()
        startSnapshotRefresh()
        refreshStore() // 桥值对齐当前状态（上场残影已在 stop 清空，此处恒 nil）
    }

    /// 摘除监听与循环（幂等；未 start 为 no-op）。录制收尾由装配层调用。
    /// 残影防御：清空状态机并刷新桥值——stop 前一瞬的按键不得淡入下一场录制开头
    /// （ClickHighlightTracker.stopInternal 清 lastClick 同语义）。
    func stop() {
        guard isMonitoring else { return }
        source.removeAll()
        isMonitoring = false
        usesGlobalListening = false
        securePollTask?.cancel()
        securePollTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        lastModifierFlags = 0
        state.reset()
        refreshStore()
    }

    /// 当前键帽快照（internal 读缝：读时重算再取桥值——测试与诊断用；合成热路径不走此路，
    /// 由刷新循环与事件即时刷新保持桥值新鲜）。
    func currentSnapshot() -> KeyboardOverlaySnapshot? {
        refreshStore()
        return store.currentSnapshot()
    }

    // MARK: 事件入口（主线程回调 → 主 actor，零调度跳转）

    private func handleKeyDown(_ event: NSEvent) {
        guard isMonitoring else { return } // stop 后陈旧回调不馈送（残影防御）
        state.keyDown(Self.makeDescriptor(of: event), now: now())
        refreshStore() // 事件即时刷新：按键当帧即可见（不等兜底循环）
    }

    private func handleKeyUp(_ event: NSEvent) {
        guard isMonitoring else { return } // stop 后陈旧回调不馈送（残影防御）
        state.keyUp(Self.makeDescriptor(of: event), now: now())
        refreshStore() // 结算锚定与桥值同拍（linger 起点 = 刷新时刻口径）
    }

    /// flagsChanged → 修饰键 keyDown/keyUp 换算（Task 8 类注释钉定的路径）：与上一事件
    /// 掩码差分，命中的记账位（⇧⌃⌥⌘+caps/fn）此 events 置位 = 按下、清零 = 松开；差分
    /// 不命中六记账位（如仅 fn 变体的罕见组合流）静默忽略、仅推进基准。单位差分（常态）
    /// 精确；多位同时翻转按「有置位即按下」近似（无单事件可分的 keyCode 真值，实践不可达）。
    private func handleFlagsChanged(_ event: NSEvent) {
        guard isMonitoring else { return } // stop 后陈旧回调不馈送（残影防御）
        let newFlags = Int(event.modifierFlags.rawValue)
        let delta = newFlags ^ lastModifierFlags
        let accounting = delta & Self.accountingBitsMask
        if accounting != 0 {
            let descriptor = KeyDescriptor(keyCode: UInt64(event.keyCode), characters: "", modifiers: newFlags)
            if newFlags & accounting != 0 {
                state.keyDown(descriptor, now: now())
            } else {
                state.keyUp(descriptor, now: now())
            }
        }
        lastModifierFlags = newFlags
        refreshStore()
    }

    /// NSEvent → KeyDescriptor（简报换算）：keyCode 为 ANSI 硬件码、characters 原文直显
    /// （大小写交状态机直显口径）、modifiers 与 `NSEvent.ModifierFlags.rawValue` 位定义
    /// 一致（Task 8 typealias 注释钉定，一步换算无查表）。
    private static func makeDescriptor(of event: NSEvent) -> KeyDescriptor {
        KeyDescriptor(keyCode: UInt64(event.keyCode),
                      characters: event.characters ?? "",
                      modifiers: Int(event.modifierFlags.rawValue))
    }

    // MARK: 安全输入轮询（0.5s timer 语义；判定逻辑收敛于此供无头确定性钉测）

    /// 轮询一拍：读安全输入事实 → 驱动状态机置位/解除 → 刷新桥值。置位一次性清空状态
    /// （Task 8 语义），解除保守等新输入。轮询循环与无头钉测共用本入口（单一真源）。
    func pollSecureInputOnce() {
        state.setSecureInputActive(secureInputProbe())
        refreshStore()
    }

    private func startSecureInputPoll() {
        securePollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.pollSecureInputOnce()
                try? await Task.sleep(nanoseconds: UInt64(Self.secureInputPollInterval * 1_000_000_000))
            }
        }
    }

    // MARK: 快照桥刷新（事件即时 + 0.1s 兜底循环）

    private func refreshStore() {
        store.update(state.snapshot(style: styleProvider(),
                                    lingerSeconds: lingerProvider(),
                                    now: now()))
    }

    private func startSnapshotRefresh() {
        refreshTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.snapshotRefreshInterval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                self.refreshStore() // linger 到期是时间驱动：无事件也要让桥值过期
            }
        }
    }
}
