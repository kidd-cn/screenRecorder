import AppKit
import CoreGraphics
import Foundation

// MARK: - ClickOverlayState（简报 Produces 逐字 + alpha 扩展缝）

/// 一次点击高亮在捕获像素空间画布上的叠加状态。
/// `alpha` 为对简报字段表的必要扩展（偏差台账）：衰减不透明度由 `ClickHighlightTracker.evaluate`
/// 统一计算、`currentState` 回填后交付，合成器不再读墙钟——逐帧合成成为确定性纯函数，
/// 无头像素测试可钉，PTS 透传语义不受影响。
struct ClickOverlayState: Equatable {
    /// 点击位置（捕获像素空间，缓冲区左上原点、y 向下——与 SCStream 输出缓冲行序一致）。
    var point: CGPoint
    /// 点击时刻（Date 轴；`evaluate` 据此计算衰减进度）。
    var appearedAt: Date
    /// 高亮圈半径（捕获像素）；简报钉死默认 24。
    var radiusInPixels: CGFloat = 24
    /// 淡出时长（秒）；简报钉死默认 0.6。
    var fadeDuration: TimeInterval = 0.6
    /// 衰减后不透明度（0…1]；`currentState` 回填，合成器按此做整体 alpha。
    var alpha: CGFloat = 1
}

// MARK: - ClickHighlightTracker（简报 Produces：事件监听 + 衰减态快照）

/// 点击高亮跟踪器（T16）：录制期监听全局（其他应用前台）+ 本地（本应用激活）鼠标按下事件，
/// 只记录、不拦截（本地 monitor 原样返回事件）。macOS 上 NSEvent 鼠标事件全局监听不需要新增
/// TCC 权限（仅键盘全局监听需要 Input Monitoring；简报钉「无新增权限」）。
///
/// 线程模型：`start` / `stop` / `setEnabled` 在主线程调用（CaptureController 主 actor 生命周期
/// 钩子；NSEvent monitor 主线程装卸，回调派发主队列）；点击事件回调在主线程写 `lastClick`，
/// `currentState` 在 SCStream video 队列做快照读——NSLock 保护单个（坐标， 时刻）不可变快照，
/// 锁内只有一次结构体拷贝（纳秒级），合成热路径不加锁、不分配。
/// UI-free：不持窗口/视图，只存坐标与时刻；坐标系一概不关心，屏坐标 → 捕获像素的换算完全
/// 委托 `currentState` 的 `pointConverter` 闭包（由接线层按捕获模式组装，见
/// `RecordingSessionCoordinator.begin`）。
final class ClickHighlightTracker: NSObject {
    /// 高亮圈默认半径（捕获像素，简报钉死默认）。
    static let defaultRadiusInPixels: CGFloat = 24
    /// 淡出时长默认（秒，简报钉死 600ms）。
    static let defaultFadeDuration: TimeInterval = 0.6

    private static let monitoredEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]

    private struct ClickRecord {
        var point: CGPoint
        var appearedAt: Date
    }

    private let lock = NSLock()
    /// 主开关（opt-in；`init(enabled:)` 为初值，录制开始由 CaptureController 以 config 快照重对齐）。
    private var enabled: Bool
    private let fadeDuration: TimeInterval
    /// 最近一次点击（Cocoa 全局坐标、左下原点——NSEvent 原生口径）。
    private var lastClick: ClickRecord?
    /// 已装监听句柄（nil = 未监听；主线程装卸，句柄读写一并锁保护供 isMonitoring 跨线程读）。
    private var globalMonitor: Any?
    private var localMonitor: Any?
    /// 点击转发缝（P1a，Task 2/3 消费：自动缩放中心、点击音效）：每次 `recordClick` 触发
    /// 一次，载荷 = 原始记录坐标与时刻。fire-and-forget：nil 安全、无返回值、handler 内部
    /// 自负（tracker 不等待、不重试）。读写两端线程不同（接线层在 begin 装配、点击回调在
    /// 主线程触发）——与 `enabled` 同一锁纪律，锁内读写、锁外触发（handler 不得在 tracker
    /// 锁内回调 tracker）。
    private var onClickHandler: ((CGPoint, Date) -> Void)?

    /// 本地事件抑制缝（P2 边录边标记，spec §5「绘图拖拽不得触发点击高亮/缩放/音效」钉死）：
    /// 返回 true 的本地鼠标按下**不记录**为点击——记录是环渲染 / 缩放喂入 / 音效调度三条链
    /// 的共同上游，掐住记录即全链静默。背景（Task 5 调查结论）：标记覆盖层/工具条是本 App
    /// 自己的窗口，其按下事件不达全局 monitor（全局监听收不到被本 App 处理的事件）；但
    /// **本地 monitor 收得到**本 App 窗口的 mouseDown——须按事件目标窗口显式过滤（装配层
    /// 注入按 `NSWindow.identifier` 判定的闭包，见 ScreenRecorderApp）。本地 monitor 主线程
    /// 调用，读写与 `onClick` 同一锁纪律（锁内读、锁外调）。
    var isLocalClickSuppressed: ((NSEvent) -> Bool)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return suppressionCheck
        }
        set {
            lock.lock()
            suppressionCheck = newValue
            lock.unlock()
        }
    }
    private var suppressionCheck: ((NSEvent) -> Bool)?

    /// 点击转发缝（P1a 简报 Produces 逐字）。缺省 nil = 无消费方，记录路径行为不变。
    var onClick: ((CGPoint, Date) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return onClickHandler
        }
        set {
            lock.lock()
            onClickHandler = newValue
            lock.unlock()
        }
    }

    /// - Parameters:
    ///   - enabled: 总开关（opt-in，默认 false；`start()` 仅在启用时装机）。
    ///   - fadeDuration: 淡出时长（简报钉死默认 0.6s；仅测试注入覆盖）。
    init(enabled: Bool, fadeDuration: TimeInterval = ClickHighlightTracker.defaultFadeDuration) {
        self.enabled = enabled
        self.fadeDuration = fadeDuration
        super.init()
    }

    /// 是否已装事件监听（internal 缝：单测钉「disabled 不装机」契约；任意线程可读）。
    var isMonitoring: Bool {
        lock.lock()
        defer { lock.unlock() }
        return globalMonitor != nil || localMonitor != nil
    }

    /// 主开关重对齐（接线缝：CaptureController 在录制开始时以 `RecordingConfiguration`
    /// 快照覆盖，外部 `defaults write` 的改动自下一场录制生效）。监听中关闭立即摘除 monitor；
    /// 只对齐开关、不自动装机（装机仍是 `start()` 职责）。
    /// 修复轮 1 #2：`enabled` 一律锁内写（与 `start()` 锁内读同一纪律；调用方今日虽全主 actor）。
    func setEnabled(_ newValue: Bool) {
        lock.lock()
        enabled = newValue
        lock.unlock()
        if !newValue { stopInternal() } // 锁外摘监听（stopInternal 自持锁，不可嵌套）
    }

    /// 安装事件监听（幂等；未启用为 no-op）。录制进入生命周期钩子调用。
    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard enabled, globalMonitor == nil, localMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.monitoredEvents) { [weak self] _ in
            self?.recordLiveClick()
        }
        // 本应用激活期间（点浮条/菜单等）：本地 monitor 同样只记录不拦截；标记工具窗口
        // 的按下经抑制缝过滤（P2，见 isLocalClickSuppressed 类注释）。
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.monitoredEvents) { [weak self] event in
            self?.handleLocalMouseDown(event)
            return event
        }
    }

    /// 本地鼠标按下事件入口（internal 缝：monitor 与无头钉测共用）：抑制缝命中（标记工具
    /// 窗口的按下）不记录，其余照常。锁内读缝、锁外调用（与 onClick 同纪律）。
    func handleLocalMouseDown(_ event: NSEvent) {
        lock.lock()
        let check = suppressionCheck
        lock.unlock()
        if check?(event) == true { return }
        recordLiveClick()
    }

    /// 摘除事件监听（幂等；未 start 为 no-op）。录制收尾生命周期钩子调用。
    func stop() {
        stopInternal()
    }

    private func stopInternal() {
        lock.lock()
        defer { lock.unlock() }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        // 修复轮 1 #3：收尾清空最近点击——stop 前一瞬的点击（如「停止」按钮本身）不得把
        // 残影淡入 600ms 内重启的下一场录制开头。
        lastClick = nil
    }

    /// 事件回调路径：读当前光标位置（Cocoa 全局，左下原点）。`NSEvent.mouseLocation` 是
    /// 全局/本地 monitor 统一可用的取数（全局 monitor 事件的 window 为 nil，locationInWindow
    /// 需逐窗口换算不可靠）；回调与点击同属一个事件轮次，微秒级偏差远小于 24px 圈的视觉精度。
    private func recordLiveClick() {
        recordClick(point: NSEvent.mouseLocation, at: Date())
    }

    /// 记录一次点击（internal 缝：单测直接注入坐标/时刻，生产回调传实时读数）。
    /// P1a：记录后锁外转发 `onClick`（nil 安全 fire-and-forget）。
    func recordClick(point: CGPoint, at date: Date) {
        lock.lock()
        lastClick = ClickRecord(point: point, appearedAt: date)
        let handler = onClickHandler
        lock.unlock()
        handler?(point, date) // 锁外触发：handler 不得在 tracker 锁内回调 tracker
    }

    /// 当前叠加态（简报 Produces 签名逐字）：`fadeDuration` 窗口内返回带衰减透明度的状态
    /// （point 经 `pointConverter` 换算进捕获像素空间），超时/无点击 nil（合成侧按无高亮直通）。
    /// video 队列调用：锁内仅取不可变快照，换算与求值在锁外。
    func currentState(at date: Date = Date(),
                      inCapturePixelsOf pointConverter: (CGPoint) -> CGPoint) -> ClickOverlayState? {
        lock.lock()
        let record = lastClick
        lock.unlock()
        guard let record else { return nil }
        guard let alpha = Self.evaluate(click: record.appearedAt, date: date, fadeDuration: fadeDuration) else {
            return nil
        }
        return ClickOverlayState(
            point: pointConverter(record.point),
            appearedAt: record.appearedAt,
            radiusInPixels: Self.defaultRadiusInPixels,
            fadeDuration: fadeDuration,
            alpha: alpha)
    }

    /// 淡出不透明度纯函数（简报 Produces 逐字）：点击时刻全不透明，窗口内线性衰减，
    /// 超过 `fadeDuration`（含恰为 0 的末点）nil；负间隔（时钟回拨）防御性 nil。
    static func evaluate(click: Date, date: Date, fadeDuration: TimeInterval) -> CGFloat? {
        guard fadeDuration > 0, fadeDuration.isFinite else { return nil }
        let elapsed = date.timeIntervalSince(click)
        guard elapsed >= 0, elapsed < fadeDuration else { return nil }
        return CGFloat(1 - elapsed / fadeDuration)
    }

    // MARK: 坐标换算助手（接线层取数，与 RegionSelectorMath 同口径）

    /// Cocoa 全局（主屏左下原点、y 向上）→ CG 全局（主屏左上原点、y 向下）：
    /// x 不变，y 按主屏高度翻转（同一物理点到主屏上/下边等距）。多屏通用——两全局系共享主屏原点。
    static func cgGlobalPoint(fromCocoaGlobal point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    /// 主屏 Cocoa 全局高度（Y 翻转用；主线程调用，录制 begin 时快照一次）。
    /// 匹配不到主屏（实践中不可达）退化为键屏高，最终 0（换算出界外点，CI 自然裁剪）。
    static func primaryScreenHeight() -> CGFloat {
        NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 0
    }
}
