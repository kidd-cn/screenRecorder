import CoreGraphics
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var controller: CaptureController
    @ObservedObject var settings: SettingsStore
    let fileStore: RecordingFileStore

    var body: some View {
        Label("屏幕录制", systemImage: "record.circle")
        Divider()
        Button(startActionTitle) {
            startFullScreenRecording()
        }
        .disabled(controller.state != .idle)
        Divider()
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

    /// 正式入口（简报 Step 6，非调试项）：全屏（主显示器）录制。在点击时刻从 SettingsStore
    /// 快照装配 `RecordingConfiguration`（快照语义：录制中途改设置不影响进行中的录制）。
    private func startFullScreenRecording() {
        guard controller.state == .idle else { return }
        try? fileStore.ensureDirectory()
        let config = RecordingConfiguration(
            mode: .display(CGMainDisplayID()),
            captureSystemAudio: settings.captureSystemAudio,
            captureMicrophone: settings.captureMicrophone,
            micVolume: settings.micVolume, // T9 预留接线点：麦克风增益快照进配置
            includeCamera: settings.pipEnabled,
            fps: settings.fps,
            codec: settings.videoCodec,
            outputURL: fileStore.nextFileURL(),
            clickHighlightEnabled: settings.clickHighlightEnabled
        )
        Task { await controller.start(mode: .display(CGMainDisplayID()), config: config) }
    }
}
