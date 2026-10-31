import AVFoundation
import Combine
import SwiftUI

/// 权限引导界面：列出屏幕录制/麦克风/摄像头三项 TCC 状态，未授权项提供「去授权」，
/// 并引导用户到系统设置手动允许；三项全部就绪后回调 `onAllGranted`。
/// P4 追加第四项「输入监控」（可选功能权限，仅服务键盘按键可视化）：**不参与**
/// `allGranted` 回调门槛——录制主链路不依赖它（未授权自动降级仅本地监听），把它算进
/// 「全部就绪」会让不需要键帽可视化的用户永远关不掉引导窗；请求/状态走
/// `InputMonitoringPermission`（一期 Permissions.swift 同构的预检/请求模式）。
/// Task 7+ 负责把本视图接入主流程（仅当 `!status.screen` 时展示）；当前独立可编译，含 #Preview。
struct PermissionOnboardingView: View {
    /// 三项权限全部就绪时回调；同一视图生命周期内最多触发一次（输入监控不参与判定，
    /// 见类注释）。
    var onAllGranted: () -> Void

    private enum PermissionKind {
        case screen, microphone, camera, inputMonitoring
    }

    @State private var status = PermissionChecker.currentStatus()
    /// 输入监控授权态（P4）：与三项 TCC 状态分开存（PermissionChecker.currentStatus 不含
    /// 第四项；`CGPreflightListenEventAccess` 是布尔预检，无 notDetermined 中间态）。
    @State private var inputMonitoringGranted = InputMonitoringPermission.isGranted()
    @State private var isRequesting = false
    @State private var hasNotifiedAllGranted = false
    @State private var requestTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("授权设置")
                .font(.title2).bold()
            Text("录制需要以下系统权限，请逐项允许。")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                row(icon: "display", title: "屏幕录制", isGranted: status.screen, kind: .screen)
                Divider().padding(.leading, 44)
                row(icon: "mic", title: "麦克风", isGranted: status.microphone == .authorized, kind: .microphone)
                Divider().padding(.leading, 44)
                row(icon: "video", title: "摄像头", isGranted: status.camera == .authorized, kind: .camera)
                Divider().padding(.leading, 44)
                row(icon: "keyboard", title: "输入监控", isGranted: inputMonitoringGranted, kind: .inputMonitoring)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(nsColor: .separatorColor))
            )

            Text("输入监控仅用于录制其他应用中的键盘按键（可选）；未授权时仍可正常录制，只是键帽只显示本应用内的按键。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if isRequesting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("等待授权中…若未弹出提示，请到系统设置手动允许。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("重新检查", action: recheck)
                    .disabled(isRequesting)
                Spacer()
                Button("打开系统设置", action: openSystemSettings)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear(perform: recheck)
        // 用户在系统设置授权后切回本 App 时自动刷新状态
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            recheck()
        }
        .onDisappear { requestTask?.cancel() }
    }

    private func row(icon: String, title: String, isGranted: Bool, kind: PermissionKind) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(isGranted ? Color.green : Color.secondary)
            Text(title)
            Spacer()
            if isGranted {
                Label("已授权", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            } else {
                Button("去授权") { request(kind) }
                    .disabled(isRequesting)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - 动作

    /// 只读刷新状态；全部就绪则触发回调（请求进行中不抢跑，轮询会自行检测到授权）。
    /// 输入监控一并预检刷新（不在 allGranted 判定内，见类注释）。
    private func recheck() {
        guard !isRequesting else { return }
        status = PermissionChecker.currentStatus()
        inputMonitoringGranted = InputMonitoringPermission.isGranted()
        notifyIfAllGranted()
    }

    /// 只对指定行发起请求：三项 TCC 权限把其余项视为已授权传入 `requestMissing(from:)`，
    /// 使请求逻辑全部收敛在 PermissionChecker（视图不直接触碰 TCC API）；输入监控（P4）
    /// 走独立请求路径（PermissionChecker 不含第四项），请求被拒（此前拒绝过则系统不再
    /// 弹窗）即带路对应系统设置面板。
    private func request(_ kind: PermissionKind) {
        guard !isRequesting else { return }
        isRequesting = true
        requestTask = Task {
            switch kind {
            case .screen, .microphone, .camera:
                var target = PermissionChecker.currentStatus()
                switch kind {
                case .screen:
                    target.screen = false
                    target.microphone = .authorized
                    target.camera = .authorized
                case .microphone:
                    target.screen = true
                    target.microphone = .notDetermined
                    target.camera = .authorized
                case .camera:
                    target.screen = true
                    target.microphone = .authorized
                    target.camera = .notDetermined
                case .inputMonitoring:
                    break
                }
                status = await PermissionChecker.requestMissing(from: target)
            case .inputMonitoring:
                inputMonitoringGranted = await InputMonitoringPermission.request()
                if !inputMonitoringGranted, !Task.isCancelled {
                    openInputMonitoringSettings()
                }
            }
            isRequesting = false // 取消也必须复位，否则控件永久禁用
            if !Task.isCancelled {
                notifyIfAllGranted() // 视图已消失时不再触发回调（输入监控不参与判定）
            }
        }
    }

    private func openSystemSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    /// 输入监控面板（P4）：请求未获准时的带路出口（与 openSystemSettings 分开——
    /// 两个面板不相邻，带错面板用户找不到开关）。
    private func openInputMonitoringSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_InputMonitoring")!)
    }

    private func notifyIfAllGranted() {
        guard status.allGranted, !hasNotifiedAllGranted else { return }
        hasNotifiedAllGranted = true
        onAllGranted()
    }
}

#Preview {
    PermissionOnboardingView(onAllGranted: {})
}
