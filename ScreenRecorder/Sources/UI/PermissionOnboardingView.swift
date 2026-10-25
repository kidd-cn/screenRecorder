import AVFoundation
import Combine
import SwiftUI

/// 权限引导界面：列出屏幕录制/麦克风/摄像头三项 TCC 状态，未授权项提供「去授权」，
/// 并引导用户到系统设置手动允许；三项全部就绪后回调 `onAllGranted`。
/// Task 7+ 负责把本视图接入主流程（仅当 `!status.screen` 时展示）；当前独立可编译，含 #Preview。
struct PermissionOnboardingView: View {
    /// 三项权限全部就绪时回调；同一视图生命周期内最多触发一次。
    var onAllGranted: () -> Void

    private enum PermissionKind {
        case screen, microphone, camera
    }

    @State private var status = PermissionChecker.currentStatus()
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
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(nsColor: .separatorColor))
            )

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
    private func recheck() {
        guard !isRequesting else { return }
        status = PermissionChecker.currentStatus()
        notifyIfAllGranted()
    }

    /// 只对指定行发起请求：把其余两项视为已授权传入 `requestMissing(from:)`，
    /// 使请求逻辑全部收敛在 PermissionChecker（视图不直接触碰 TCC API）。
    private func request(_ kind: PermissionKind) {
        guard !isRequesting else { return }
        isRequesting = true
        requestTask = Task {
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
            }
            status = await PermissionChecker.requestMissing(from: target)
            isRequesting = false // 取消也必须复位，否则控件永久禁用
            if !Task.isCancelled {
                notifyIfAllGranted() // 视图已消失时不再触发回调
            }
        }
    }

    private func openSystemSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
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
