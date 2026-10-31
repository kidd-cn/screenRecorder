import Combine
import XCTest

@testable import ScreenRecorder

/// RecordingScheduler 地板钉测（P6b，Task 12 简报 Step 1 七条）：全部依赖走 init 注入缝
/// ——now / timerFactory / start / stop / notify / notifyMissed / isLocked / isBusy 均为
/// 本地记录闭包，不触真时钟、真 Timer、真 UNUserNotificationCenter、真 CGSession
///（isLocked 注入假值——裁定：测试绝不触真 CGSessionCopyCurrentDictionary）。计时器缝
/// 无头驱动：timerFactory 捕获心跳闭包（生产 = 主 run loop 每秒一拍，仅在排程/停录等待期
/// 保活），用例直调即「到点」，改 fakeNow 即「时间前进」。错过带动作缝（notifyMissed）
/// 按裁定钉死两件事：错过通知恰一次 + 动作闭包路由 start 闭包；category 注册与真实
/// 通知中心接线归装配层（真机验收，不在本钉测范围）。
@MainActor
final class RecordingSchedulerTests: XCTestCase {
    /// 夹具基准时刻（受控 now 缝的返回值，用例内随意推进）。
    private var fakeNow = Date(timeIntervalSinceReferenceDate: 800_000_000)
    /// timerFactory 捕获的心跳闭包（生产每秒一拍；测试直调 = 到点一拍）。
    private var tickBody: (() -> Void)?
    /// start 缝被调次数（含被拒——R1 次生变体钉测用）。
    private var startAttempts = 0
    /// start 缝受理次数（返回 true 的调用）。
    private var startCalls = 0
    /// start 缝返回值开关（false = 模拟起录未成立：空闲预检失败/begin 失败/开录即被停）。
    private var startAccepted = true
    private var stopCalls = 0
    /// 普通通知（忙/锁屏跳过路径）记录：标题 + 正文。
    private var notifications: [(title: String, body: String?)] = []
    /// 错过补通知（带「开始录制」动作）记录。
    private struct MissedRecord {
        let title: String
        let body: String?
        let startAction: () -> Void
    }
    private var missedNotifications: [MissedRecord] = []
    private var locked = false
    private var busy = false
    /// 保活引用（心跳闭包弱引调度器，用例期间必须存活）。
    private var scheduler: RecordingScheduler?

    override func tearDown() {
        scheduler = nil
        tickBody = nil
        super.tearDown()
    }

    // MARK: 夹具

    private func makeScheduler() -> RecordingScheduler {
        let scheduler = RecordingScheduler(
            now: { [weak self] in self?.fakeNow ?? Date() },
            timerFactory: { [weak self] body in
                self?.tickBody = body
                return AnyCancellable {}
            },
            start: { [weak self] in
                guard let self else { return false }
                self.startAttempts += 1
                guard self.startAccepted else { return false }
                self.startCalls += 1
                return true
            },
            stop: { [weak self] in self?.stopCalls += 1 },
            notify: { [weak self] title, body in self?.notifications.append((title, body)) },
            notifyMissed: { [weak self] title, body, action in
                self?.missedNotifications.append(
                    MissedRecord(title: title, body: body, startAction: action))
            },
            isLocked: { [weak self] in self?.locked ?? false },
            isBusy: { [weak self] in self?.busy ?? false })
        self.scheduler = scheduler
        return scheduler
    }

    /// 排程于当前 fakeNow 触发（用例再按需推进时钟）。
    private func makeSchedule(startAt: Date, durationLimit: TimeInterval? = nil)
        -> RecordingScheduler.Schedule {
        RecordingScheduler.Schedule(startAt: startAt, durationLimit: durationLimit)
    }

    /// 轮询等待（主 actor Task.yield 让调度器内 Task { await start() } 落地；5s 超时兜底，
    /// 同 CountdownOverlayControllerTests / LoginItemServiceTests 纪律）。
    private func waitFor(
        _ condition: @escaping () -> Bool,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition(), "等待条件超时", file: file, line: line)
    }

    // MARK: - 四路径钉测（简报规格钉定）

    /// 简报钉测 1（到点且空闲 → start）：到点一拍即 start 恰一次、不 stop、无任何通知，
    /// 排程消费（active 归 nil，one-shot 不重触发）。
    func testFiresWhenIdle() async {
        let scheduler = makeScheduler()
        let startAt = fakeNow
        scheduler.schedule(makeSchedule(startAt: startAt))
        XCTAssertEqual(scheduler.active?.startAt, startAt, "前置：排程进入待触发态")

        tickBody?()

        await waitFor { self.startCalls == 1 }
        XCTAssertEqual(self.startCalls, 1, "到点且空闲：start 恰一次")
        XCTAssertEqual(self.stopCalls, 0, "无时长上限：不得 stop")
        XCTAssertTrue(self.notifications.isEmpty, "空闲路径无跳过通知")
        XCTAssertTrue(self.missedNotifications.isEmpty, "空闲路径无错过通知")
        XCTAssertNil(scheduler.active, "触发即消费（one-shot），active 归 nil")
    }

    /// 简报钉测 2（正在录制/收尾 → 跳过+notify，不 start）：恰一条通知；重复心跳不再通知
    ///（排程 one-shot 消费——Review Focus #5「通知每路径至多一条」）。
    func testSkipsWhenRecordingNotifiesOnce() async {
        let scheduler = makeScheduler()
        busy = true
        scheduler.schedule(makeSchedule(startAt: fakeNow))

        tickBody?()
        tickBody?()

        XCTAssertEqual(self.startCalls, 0, "忙路径不 start")
        XCTAssertEqual(self.notifications.count, 1, "跳过通知恰一条（重复心跳不再发）")
        XCTAssertTrue(self.missedNotifications.isEmpty, "忙路径不走错过缝")
        XCTAssertNil(scheduler.active, "跳过即消费排程")
    }

    /// 简报钉测 3（锁屏 → 跳过+notify，不 start）：isLocked 缝注入假值（不触真 CGSession），
    /// 恰一条通知；重复心跳不再通知。
    func testSkipsWhenLockedNotifies() async {
        let scheduler = makeScheduler()
        locked = true
        scheduler.schedule(makeSchedule(startAt: fakeNow))

        tickBody?()
        tickBody?()

        XCTAssertEqual(self.startCalls, 0, "锁屏路径不 start")
        XCTAssertEqual(self.notifications.count, 1, "锁屏跳过通知恰一条")
        XCTAssertTrue(self.missedNotifications.isEmpty, "锁屏路径不走错过缝")
        XCTAssertNil(scheduler.active, "跳过即消费排程")
    }

    /// 简报钉测 4（错过 >60s，裁定扩展版）：不 start，错过补通知恰一条（普通通知缝 0 条，
    /// 合计仍恰一条），标题「定时录制已错过」（简报钉定文案）；动作闭包直通 start 缝
    ///（裁定无头钉死两件事：通知恰一次 + 动作闭包路由 start；category 注册与真实通知
    /// 中心接线归装配层，真机验收）。
    func testMissedByOver60sNotifiesWithStartAction() async {
        let scheduler = makeScheduler()
        let startAt = fakeNow
        scheduler.schedule(makeSchedule(startAt: startAt))

        fakeNow = startAt.addingTimeInterval(61) // 严格大于 60s = 睡眠错过
        tickBody?()

        XCTAssertEqual(self.startCalls, 0, "错过路径不 start")
        XCTAssertEqual(self.missedNotifications.count, 1, "错过补通知恰一条")
        XCTAssertEqual(self.notifications.count, 0, "错过路径不走普通通知缝（合计恰一条）")
        XCTAssertEqual(self.missedNotifications.first?.title, "定时录制已错过", "标题用简报钉定文案")

        self.missedNotifications.first?.startAction()
        await waitFor { self.startCalls == 1 }
        XCTAssertEqual(self.startCalls, 1, "动作闭包路由 start 闭包（恰一次）")
    }

    /// 简报钉测 5（≤60s 视为正常触发）：+59s 一拍即 start，无错过通知、无跳过通知
    ///（阈值严格大于 60s，边界归正常侧）。
    func testMissedByUnder60sFiresNormally() async {
        let scheduler = makeScheduler()
        let startAt = fakeNow
        scheduler.schedule(makeSchedule(startAt: startAt))

        fakeNow = startAt.addingTimeInterval(59)
        tickBody?()

        await waitFor { self.startCalls == 1 }
        XCTAssertEqual(self.startCalls, 1, "≤60s 视为正常触发")
        XCTAssertTrue(self.missedNotifications.isEmpty, "正常触发无错过通知")
        XCTAssertTrue(self.notifications.isEmpty, "正常触发无跳过通知")
        XCTAssertNil(scheduler.active)
    }

    /// 简报钉测 6（取消）：cancel 后心跳到点也不 start、不 stop、不通知（生产计时器随
    /// cancel 沉降；此处直调残留心跳兜底证伪）。
    func testCancelPreventsFire() async {
        let scheduler = makeScheduler()
        scheduler.schedule(makeSchedule(startAt: fakeNow))

        scheduler.cancel()
        XCTAssertNil(scheduler.active, "取消即清排程")

        tickBody?()

        XCTAssertEqual(self.startCalls, 0, "取消后到点不得 start")
        XCTAssertEqual(self.stopCalls, 0, "取消不影响停录缝")
        XCTAssertTrue(self.notifications.isEmpty)
        XCTAssertTrue(self.missedNotifications.isEmpty)
    }

    /// 简报钉测 7（时长上限）：到点 start 后，上限到点自动 stop 恰一次；上限内不提前 stop。
    func testDurationLimitStopsRecording() async {
        let scheduler = makeScheduler()
        let startAt = fakeNow
        scheduler.schedule(makeSchedule(startAt: startAt, durationLimit: 60))

        tickBody?() // 到点起录
        await waitFor { self.startCalls == 1 }
        XCTAssertEqual(self.stopCalls, 0, "上限未到不 stop")

        fakeNow = startAt.addingTimeInterval(60) // 排定时刻 + 上限 = 停录时刻
        tickBody?()

        XCTAssertEqual(self.stopCalls, 1, "上限到点自动 stop 恰一次")
        XCTAssertEqual(self.startCalls, 1, "上限停录不重复 start")
    }

    // MARK: - R1 修复轮钉测（会话存活闩：残留 deadline 不得误停后续手动场）

    /// R1 Important 1 主复现链：排程带上限 → 到点 fire（deadline 武装）→ 定时场存活确认
    ///（busy 命中闩转 confirmed）→ 用户手动终场（confirmed 后转闲 → 撤销停录等待）→
    /// 用户手动开新场 → 原 deadline 到点不得误停新场。stop 缝签名不变，身份归调度器内部
    /// 存活闩，判定用既有 isBusy 缝（审阅修复方向逐字）。
    func testStopDeadlineDisarmedWhenScheduledSessionEndsBeforeLimit() async {
        let scheduler = makeScheduler()
        let startAt = fakeNow
        scheduler.schedule(makeSchedule(startAt: startAt, durationLimit: 60))

        tickBody?() // 到点 fire：deadline 武装（awaitingStart）
        await waitFor { self.startCalls == 1 }

        busy = true // 定时场存活
        tickBody?() // 闩重估：awaitingStart + 忙 → confirmed
        XCTAssertEqual(self.stopCalls, 0, "上限未到不 stop")

        busy = false // 用户手动停止定时场
        fakeNow = startAt.addingTimeInterval(30)
        tickBody?() // 闩重估：confirmed + 闲 → 撤销停录等待
        XCTAssertEqual(self.stopCalls, 0, "定时场已终结：不 stop")

        busy = true // 用户手动开新场
        fakeNow = startAt.addingTimeInterval(60) // 原 deadline 到点
        tickBody?()
        XCTAssertEqual(self.stopCalls, 0, "残留 deadline 已撤销：不得误停新手动场")
        XCTAssertEqual(self.startCalls, 1, "上限停录不重复 start")
    }

    /// R1 Important 1 次生变体钉测：fire 时空闲预检通过、起录未成立（start 缝返回 false——
    /// 生产 = Task 落地时二次 guard 失败 / begin 失败 / 开录即被停）→ 撤销停录等待：原
    /// deadline 到点不 stop，其后在忙的手动场不受残留 deadline 波及。
    func testStartRefusalDisarmsStopDeadline() async {
        let scheduler = makeScheduler()
        let startAt = fakeNow
        startAccepted = false
        scheduler.schedule(makeSchedule(startAt: startAt, durationLimit: 60))

        tickBody?() // fire：deadline 武装，起录发起但未成立
        await waitFor { self.startAttempts == 1 }
        for _ in 0..<20 { await Task.yield() } // 让 Task 内「未成立 → 撤销等待」续延落地（同 CountdownOverlayControllerTests 纪律）

        busy = true // 用户手动场接管
        fakeNow = startAt.addingTimeInterval(60) // 原 deadline 到点
        tickBody?()
        XCTAssertEqual(self.stopCalls, 0, "起录未成立：deadline 已撤销，到点不得 stop")
        XCTAssertEqual(self.startAttempts, 1, "起录缝恰被调一次（未重试）")
    }
}
