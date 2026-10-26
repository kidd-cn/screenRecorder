import CoreGraphics
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var controller: CaptureController
    /// 开始全屏录制（T17 装配缝）：`RecordingConfiguration` 装配与「上次使用模式」持久化
    /// 收敛在 AppAssembly 的唯一开始入口，菜单与全局快捷键共用，避免两处装配漂移。
    let onStartFullScreen: () -> Void
    /// 打开文件列表窗口（T18，窗口与控制器归 AppAssembly，见 T17 装配红线）。
    let onOpenRecordingList: () -> Void
    /// 打开偏好设置窗口（窗口与控制器归 AppAssembly，见 T17 装配红线）。
    let onOpenPreferences: () -> Void

    var body: some View {
        Label("屏幕录制", systemImage: "record.circle")
        Divider()
        Button(startActionTitle) {
            onStartFullScreen()
        }
        .disabled(controller.state != .idle)
        Divider()
        Button("文件列表…") {
            onOpenRecordingList()
        }
        Button("偏好设置…") {
            onOpenPreferences()
        }
        Button("关于") {
            NSApplication.shared.orderFrontStandardAboutPanel(nil)
        }
        Button("退出") {
            NSApplication.shared.terminate(nil)
        }
    }

    private var startActionTitle: String {
        controller.state == .idle ? "开始录制（全屏）" : "录制中…"
    }
}
