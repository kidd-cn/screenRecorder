import XCTest

@testable import ScreenRecorder

/// LaunchAtLoginCoordinator 地板钉测（Task 11 简报 Step 1）：fake 注入走
/// `LoginItemRegistering` 缝——SMAppService 注册是进程级副作用，测试绝不触真；
/// 通知缝用本地记录闭包，不触真 UNUserNotificationCenter（通知中心在无头测试进程
/// 不可用）。同步用例主线程执行（@Published sink 在 willSet 阶段同步发射，断言
/// 确定性完成、无等待）。持久化走独立 UserDefaults suite（同 SettingsStoreTests 纪律）。
@MainActor
final class LoginItemServiceTests: XCTestCase {
    private static let suiteName = "test.settings.loginItem"

    private var defaults: UserDefaults!
    /// 保活引用（cancellables 在 coordinator 自身，释放即摘订阅——必须活过整条用例）。
    private var coordinator: LaunchAtLoginCoordinator?

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)
        defaults.removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() {
        coordinator = nil
        defaults.removePersistentDomain(forName: Self.suiteName)
        defaults = nil
        super.tearDown()
    }

    /// 简报钉测 1：假 register 写入结果态——开→fake 落为启用、开关保持 true；
    /// 关→fake 落为停用、开关回到 false。全程假服务恰被调用一次开、一次关。
    func testFakeServiceRoundTrip() {
        let settings = SettingsStore(userDefaults: defaults)
        let service = FakeLoginItemService()
        coordinator = LaunchAtLoginCoordinator(
            settings: settings,
            service: service,
            onRegistrationFailure: { _ in })

        XCTAssertFalse(settings.launchAtLogin, "默认关（opt-in，简报钉定默认值）")

        settings.launchAtLogin = true
        XCTAssertTrue(service.isEnabled, "假 register 写入结果态：fake 落为启用")
        XCTAssertTrue(settings.launchAtLogin, "注册成功：开关保持用户选择")

        settings.launchAtLogin = false
        XCTAssertFalse(service.isEnabled, "假 unregister 写入结果态：fake 落为停用")
        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertEqual(service.receivedCalls, [true, false], "开→关各触服务恰好一次")
    }

    /// 简报钉测 2：服务抛错 → 开关回翻（真实态优先于 UI 态）+ 通知回调被调；
    /// 回翻译写期间 sink 不再触服务（装配层 sink 重入护栏 Bool 闩：恰一次调用）。
    /// 回翻经主 actor Task 延后一轮落地（willSet 相位内同步写回会被外层赋值收尾覆盖，
    /// 见 LaunchAtLoginCoordinator.apply 注释），故用轮询等待（同 CountdownOverlay
    /// ControllerTests 的 Task.yield 轮询纪律）。
    func testFailureRevertsSettingAndNotifies() async {
        let settings = SettingsStore(userDefaults: defaults)
        let service = FakeLoginItemService()
        service.errorToThrow = StubError()
        var failureMessages: [String] = []
        coordinator = LaunchAtLoginCoordinator(
            settings: settings,
            service: service,
            onRegistrationFailure: { message in failureMessages.append(message) })

        settings.launchAtLogin = true
        await waitFor { settings.launchAtLogin == false }

        XCTAssertFalse(settings.launchAtLogin, "注册失败：开关回翻（真实态优先于 UI 态）")
        XCTAssertFalse(service.isEnabled, "失败不落结果态：fake 保持停用")
        XCTAssertEqual(service.receivedCalls, [true], "重入护栏：回翻译写不再触服务（恰一次调用）")
        XCTAssertEqual(failureMessages.count, 1, "通知回调被调恰一次")
        XCTAssertEqual(failureMessages.first, StubError().errorDescription, "失败文案取自错误 localizedDescription")
    }

    /// 轮询等待（主 actor Task.yield 让回翻 Task 跳转落地；5s 超时兜底，同
    /// CountdownOverlayControllerTests 纪律）。
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
}

/// 假登录项服务（测试桩）：记录调用并模拟 SMAppService 的结果态；`errorToThrow`
/// 置非 nil 时抛错（模拟注册/注销失败）。
private final class FakeLoginItemService: LoginItemRegistering {
    private(set) var isEnabled = false
    private(set) var receivedCalls: [Bool] = []
    var errorToThrow: (any Error)?

    func setEnabled(_ enabled: Bool) throws {
        receivedCalls.append(enabled)
        if let errorToThrow { throw errorToThrow }
        isEnabled = enabled
    }
}

/// 测试桩错误（LocalizedError 保证 localizedDescription 非空，钉失败文案来源）。
private struct StubError: LocalizedError {
    var errorDescription: String? { "注册失败（测试桩）" }
}
