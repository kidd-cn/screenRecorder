import Combine
import Foundation
import ServiceManagement

// MARK: - 登录项服务缝（P6a 开机自启）

/// 开机登录项注册缝（Task 11 简报 Produces 逐字）：生产实现包 `SMAppService.mainApp`
/// 的 register/unregister；测试注入 fake——注册是进程级副作用（写系统登录项），
/// 测试绝不触真 SMAppService（同 RecordingNotifying 注入缝纪律）。`SMAppService`
/// 恰为 macOS 13.0+ API，与部署地板一致，无需可用性护栏。
protocol LoginItemRegistering: AnyObject {
    func setEnabled(_ enabled: Bool) throws
}

/// 生产实现（简报 Produces 逐字）：启用 = register，停用 = unregister；两者都抛
/// `SMAppError`（LocalizedError）——失败文案直接取 localizedDescription。
final class SMAppLoginItemService: LoginItemRegistering {
    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

// MARK: - 开机自启接线（装配层 sink 消费，Task 11 裁定）

/// 开机自启装配单元：开关变化经 Combine sink 消费（接线裁定：副作用不进
/// SettingsStore didSet——失败回翻要在 sink 内写回 `launchAtLogin`，@Published 的
/// didSet 内写回必重入）。失败即回翻开关（真实态优先于 UI 态）并经注入缝发通知
///（生产走 UNUserNotificationCenter，授权被拒/失败静默跳过——装配层闭包决定）。
@MainActor
final class LaunchAtLoginCoordinator {
    private let settings: SettingsStore
    private let service: LoginItemRegistering
    /// 失败通知缝（@MainActor 闭包）：装配层接 UNUserNotificationCenter（尽力而为副
    /// 通道）；测试记录调用——两个地板测试不触真通知中心。
    private let onRegistrationFailure: @MainActor (String) -> Void
    /// 重入护栏闩：回翻译写期间 sink 的再发射（@Published 赋值即发射，含同值）被吞，
    /// 不再触发服务调用——否则回翻会二次触服务（写回 false 又被当成新的一次「关闭」
    /// 请求）。回翻译写都在主线程同步完成，闩无并发竞争面。
    private var isReverting = false
    /// 订阅保活（与 coordinator 同寿；释放即摘订阅，测试须保活 coordinator）。
    private var cancellables: Set<AnyCancellable> = []

    init(settings: SettingsStore,
         service: LoginItemRegistering,
         onRegistrationFailure: @escaping @MainActor (String) -> Void) {
        self.settings = settings
        self.service = service
        self.onRegistrationFailure = onRegistrationFailure
        // 开关变化的唯一消费点（Task 11 接线裁定：Combine sink，不进 SettingsStore
        // didSet）。dropFirst 跳过初值——装配时刻不回放既有值（注册态真源在
        // SMAppService，启动期不重复触 register/unregister）。
        settings.$launchAtLogin
            .dropFirst()
            .sink { [weak self] enabled in self?.apply(enabled) }
            .store(in: &cancellables)
    }

    /// 开关消费：成功 = 服务落结果态（请求态即结果态，无需回写）；失败 = 回翻开关
    ///（真实态优先于 UI 态）并经通知缝上报。回翻译写前闩住 sink——@Published 在
    /// willSet 阶段同步发射，回翻赋值触发的再发射落在闩内被吞，不再触发服务调用。
    private func apply(_ enabled: Bool) {
        guard !isReverting else { return }
        do {
            try service.setEnabled(enabled)
        } catch {
            let message = error.localizedDescription
            // 回翻必须延后一轮：sink 在 @Published willSet 阶段同步执行，此刻同步写回
            // 会被外层赋值的收尾（存储 + didSet 落库）覆盖——T1「didSet 内写回必重入」
            // 定论的同源陷阱，再深一层。Task 跳主 actor 让外层赋值先完整落地，再写回
            // 结果态（闩跨轮保持：写回触发的再发射仍落在闩内被吞）。
            isReverting = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.settings.launchAtLogin = !enabled
                self.isReverting = false
                self.onRegistrationFailure(message)
            }
        }
    }
}
