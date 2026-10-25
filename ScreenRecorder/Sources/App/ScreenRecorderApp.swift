import SwiftUI

@main
struct ScreenRecorderApp: App {
    @StateObject private var settings: SettingsStore
    @StateObject private var controller: CaptureController
    private let fileStore: RecordingFileStore
    private let floatingBarPanel: FloatingControlBarPanel

    init() {
        // 装配点（T11）：SettingsStore / FileStore / Coordinator / Controller / 浮条面板 / 通知。
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

        _settings = StateObject(wrappedValue: settings)
        _controller = StateObject(wrappedValue: controller)
        self.fileStore = fileStore
        self.floatingBarPanel = FloatingControlBarPanel(controller: controller)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(controller: controller, settings: settings, fileStore: fileStore)
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
