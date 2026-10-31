import Combine
import CoreGraphics
import Foundation

/// 定时录制调度器（P6b，Task 12 简报 Produces 逐字）：单次排程（开始时刻 + 可选时长上限），
/// 四路径规格钉定——到点且空闲 → start；正在录制/收尾 → 跳过 + notify（不 start）；锁屏 →
/// 跳过 + notify（锁屏检测抽 `isLocked` 注入缝，生产 = `CGSessionCopyCurrentDictionary`
/// 登录窗判定，测试注入假值、绝不触真 CGSession）；触发时刻已过 **>60s**（睡眠错过）→
/// 不 start、补 notify（独立带「开始录制」动作缝，动作闭包路由 start 闭包）；≤60s 视为
/// 正常触发。通知每路径**至多一条**（Review Focus #5）：排程 one-shot 消费——fire 即置
/// `active = nil`，任何路径都不可能二次触发。
///
/// 计时器缝（`timerFactory`）：调度器只管「每拍重估、到点办事」，计时器形状归注入方——
/// 生产 = 主 run loop 每秒一拍（common mode），且仅在排程/停录等待期保活（`settleTimer`
/// 沉降摘除，不空转）；测试捕获心跳闭包直调（无头、确定性好，不触真 Timer）。
/// @MainActor ObservableObject：`active` 是菜单/状态图标的排程态真源（@ObservedObject
/// 直绑，装配层不 sink）；声明为 `@Published private(set)`、无 didSet（Task 1 didSet
/// 纪律：写回必重入，本属性无回写需求）。
@MainActor
final class RecordingScheduler: ObservableObject {
    /// 单次排程：开始时刻 + 可选时长上限（nil = 不限时）。
    struct Schedule: Equatable {
        var startAt: Date
        var durationLimit: TimeInterval?
    }

    /// 当前待触发的排程（nil = 无排程/已触发/已取消/已跳过）。fire 即消费（one-shot）；
    /// 触发后的时长上限停录时刻另存 `stopDeadline`（与 active 解耦——「取消定时录制」
    /// 菜单项只覆盖等待期）。
    @Published private(set) var active: Schedule?

    /// 错过判定阈值（简报钉定）：触发时刻已过 **>60s**（睡眠错过）→ 不 start、补通知；
    /// ≤60s 视为正常触发。恰好 60s 归正常侧（严格大于）。
    static let missedThreshold: TimeInterval = 60

    // MARK: 错过/跳过文案（错过标题为简报钉定文案；其余自拟，简报未钉定）

    /// 错过补通知标题（简报钉定）。
    static let missedTitle = "定时录制已错过"
    /// 忙/锁屏跳过通知标题（共用）。
    static let skipTitle = "定时录制未开始"
    static let busyBody = "已有录制正在进行，本次定时录制已跳过。"
    static let lockedBody = "屏幕处于锁定状态，本次定时录制已跳过。"

    // MARK: 注入缝（测试全量注入假值；生产接线见 AppAssembly）

    private let now: () -> Date
    /// 计时器工厂：收心跳闭包、返回保活句柄。心跳闭包在 @MainActor 语境构造（继承主
    /// actor 隔离），生产计时器须在主线程派发（主 run loop），与调度器隔离一致。
    private let timerFactory: (@escaping () -> Void) -> AnyCancellable
    /// 到点起录缝（生产 = 装配层 startScheduledRecording：last-used 模式 + 绕过倒计时）。
    /// 返回是否受理（空闲预检通过）；begin 失败的通知由控制器既有失败路径负责，不重复。
    private let start: () async -> Bool
    /// 时长上限到点的停录缝（生产 = controller.stop，自守卫：非录制/暂停 no-op）。
    private let stop: () -> Void
    /// 普通通知缝（忙/锁屏跳过；生产 = UNRecordingNotifier）。
    private let notify: (String, String?) -> Void
    /// 错过补通知缝（裁定扩展：独立于 notify 的带动作通道，供无头钉测「通知恰一次 +
    /// 动作闭包路由 start」）。动作闭包由调度器组装（内部路由 start 缝）。
    private let notifyMissed: (String, String?, @escaping () -> Void) -> Void
    /// 锁屏判定缝。生产默认来源 `isScreenLocked()`（CGSessionCopyCurrentDictionary）。
    private let isLocked: () -> Bool
    /// 忙判定缝（生产 = 控制器非 idle：录制/暂停/收尾为忙；倒计时也算忙——已有一场将启，
    /// 定时起录让位并通知，避免与在途 start 竞态）。
    private let isBusy: () -> Bool

    /// 计时器保活句柄（schedule 建；fire/cancel/skip 沉降摘除——心跳只在等待期运行）。
    private var timerCancellable: AnyCancellable?
    /// fire 后的停录时刻（时长上限从排定时刻起算：startAt + limit——begin 延迟不挤占上限）。
    private var stopDeadline: Date?

    init(now: @escaping () -> Date,
         timerFactory: @escaping (@escaping () -> Void) -> AnyCancellable,
         start: @escaping () async -> Bool,
         stop: @escaping () -> Void,
         notify: @escaping (String, String?) -> Void,
         notifyMissed: @escaping (String, String?, @escaping () -> Void) -> Void,
         isLocked: @escaping () -> Bool,
         isBusy: @escaping () -> Bool) {
        self.now = now
        self.timerFactory = timerFactory
        self.start = start
        self.stop = stop
        self.notify = notify
        self.notifyMissed = notifyMissed
        self.isLocked = isLocked
        self.isBusy = isBusy
    }

    // MARK: 排程入口（简报 Produces 逐字）

    /// 排定（重复排定 = 整只替换）：武装心跳计时器。既有停录等待（`stopDeadline`）不受
    /// 影响——新排程到点若会话仍忙，走忙碌跳过路径。
    func schedule(_ s: Schedule) {
        active = s
        timerCancellable?.cancel()
        timerCancellable = timerFactory { [weak self] in self?.tick() }
    }

    /// 取消排程（菜单「取消定时录制」）：清排程与停录等待、沉降心跳。等待期后本方法
    /// 无 UI 入口（fire 已消费 active），语义上 = 撤销一切尚未发生的定时动作。
    func cancel() {
        active = nil
        stopDeadline = nil
        timerCancellable?.cancel()
        timerCancellable = nil
    }

    // MARK: 心跳重估（四路径，全同步判态——通知恰一条的前提）

    /// 心跳重估：先结算时长上限停录，再判到点触发。未到点不消费（等下一拍）。
    private func tick() {
        let current = now()
        // 1) 时长上限停录（优先：录制已在进行，到点即 stop；stop 自守卫，空闲/收尾 no-op）
        if let deadline = stopDeadline, current >= deadline {
            stopDeadline = nil
            stop()
        }
        // 2) 到点触发（未到点不消费）
        guard let schedule = active, current >= schedule.startAt else {
            settleTimer()
            return
        }
        // one-shot：立即消费——后续任何路径都不可能二次触发/二次通知
        active = nil
        let lateness = current.timeIntervalSince(schedule.startAt)
        // 3) 错过路径（>60s，睡眠错过）：不 start，补一条带「开始录制」动作的通知；
        //    动作闭包路由 start 缝（无头钉测钉死）。错过优先于忙/锁屏：排程陈旧是首要事实。
        if lateness > Self.missedThreshold {
            notifyMissed(Self.missedTitle, Self.missedBody(schedule), { [weak self] in
                guard let self else { return }
                Task { _ = await self.start() }
            })
            settleTimer()
            return
        }
        // 4) 忙路径：正在录制/收尾（生产含倒计时）→ 跳过 + 恰一条通知，不 start
        if isBusy() {
            notify(Self.skipTitle, Self.busyBody)
            settleTimer()
            return
        }
        // 5) 锁屏路径：登录窗会话 → 跳过 + 恰一条通知，不 start（屏幕解锁后用户自行开始）
        if isLocked() {
            notify(Self.skipTitle, Self.lockedBody)
            settleTimer()
            return
        }
        // 6) 空闲路径：到点且空闲 → start（定时起录不走倒计时——绕行缝在装配层）；
        //    有时长上限则武装停录时刻（从排定时刻起算）。
        if let limit = schedule.durationLimit {
            stopDeadline = schedule.startAt.addingTimeInterval(limit)
        }
        Task { _ = await self.start() }
        settleTimer()
    }

    /// 沉降心跳：无排程且无停录等待时摘除计时器（生产不空转；测试夹具直调心跳不受影响）。
    private func settleTimer() {
        guard active == nil, stopDeadline == nil else { return }
        timerCancellable?.cancel()
        timerCancellable = nil
    }

    /// 错过通知正文（自拟）：带上原定时刻，方便用户对账。
    private static func missedBody(_ schedule: Schedule) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "原定 \(formatter.string(from: schedule.startAt)) 的定时录制未能开始"
            + "（可能因 Mac 睡眠错过），可点按通知上的「开始录制」立即开始。"
    }

    // MARK: 锁屏判定（系统惯例）

    /// 锁屏判定（系统惯例，生产注入缝的默认来源）：`CGSessionCopyCurrentDictionary` 的
    /// 登录窗会话字典缺 `kCGSSessionOnKeysKey` = 锁屏（图形会话不在 onKeys 集合）。字典
    /// 取不到（会话未就绪的极端窗口）按未锁处理——起录与否交由 busy/空闲判定。测试绝不
    /// 触真 CGSession：一律经 init 的 `isLocked` 缝注入假值。
    static func isScreenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() else { return false }
        return (session as NSDictionary)["kCGSSessionOnKeysKey"] == nil
    }
}
