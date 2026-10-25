import SwiftUI

/// App 装配容器（修复轮 1 Important #1）：整条有状态装配链（settings / fileStore /
/// coordinator / notifier / controller / 浮条面板）收敛在单个 `@StateObject` 持有的对象里。
/// SwiftUI 不保证 App struct 只 init 一次——若散装为 App 的普通 `let`，重跑 init 会造出
/// 第二个浮条面板（双浮条叠影）与孤儿 coordinator/fileStore（菜单经 #2 取 URL、controller
/// 收尾 #1）。`@StateObject` 保证 wrappedValue 只构造一次并随 App 生命周期存活。
@MainActor
final class AppAssembly: ObservableObject {
    let settings: SettingsStore
    let controller: CaptureController
    let fileStore: RecordingFileStore
    /// 面板自持 controller.$state 订阅驱动显隐；装配层只需持有保活。
    private let floatingBarPanel: FloatingControlBarPanel

    init() {
        let settings = SettingsStore()
        let fileStore = RecordingFileStore(baseDirectory: settings.outputDirectory)
        let coordinator = RecordingSessionCoordinator()
        let notifier = UNRecordingNotifier()
        let controller = CaptureController(
            session: coordinator,
            store: fileStore,
            countdownSeconds: settings.countdownSeconds,
            onFinishedFile: { url in
                Task { @MainActor in notifier.notifySaved(fileURL: url) }
            }
        )
        controller.notifier = notifier
        // 磁盘监控 / 流失败出口 → 状态机（DiskSpaceMonitor 与 onStreamFailure 均主队列保证）
        coordinator.onInterruption = { error in
            Task { @MainActor in controller.handleSessionFailure(error) }
        }
        coordinator.onDiskSpaceWarning = {
            Task { @MainActor in controller.showDiskSpaceWarning() }
        }

        self.settings = settings
        self.controller = controller
        self.fileStore = fileStore
        self.floatingBarPanel = FloatingControlBarPanel(controller: controller)
    }
}

@main
struct ScreenRecorderApp: App {
    @StateObject private var assembly: AppAssembly

    init() {
        _assembly = StateObject(wrappedValue: AppAssembly())
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                controller: assembly.controller,
                settings: assembly.settings,
                fileStore: assembly.fileStore
            )
        } label: {
            Image(systemName: "record.circle")
        }
        Window("授权设置", id: "permission-onboarding") {
            PermissionOnboardingWindowContent()
        }
    }
}

/// 权限引导窗口的薄容器：三项权限全部就绪即关闭窗口。
/// 启动时已全绿则首帧闪现后立即自动关闭（已裁决可接受的外观瑕疵）。
private struct PermissionOnboardingWindowContent: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PermissionOnboardingView(onAllGranted: { dismiss() })
    }
}
