import CoreGraphics
import SwiftUI

struct MenuBarView: View {
    var body: some View {
        Label("屏幕录制", systemImage: "record.circle")
        Divider()
        // DEBUG: TODO(T7 验收) 验收通过后移除——Task 7 brief Step 4 的验收入口，
        // 验收：~/Movies/ScreenRecorder 生成可播 MP4、有视频轨、时长≈10s、帧率≈设置值、录一半移动窗口画面正常。
        Button("调试：录全屏 10 秒") {
            Task { await Self.debugRecordFullScreen10Seconds() }
        }
        Button("关于") {
            NSApplication.shared.orderFrontStandardAboutPanel(nil)
        }
        Button("退出") {
            NSApplication.shared.terminate(nil)
        }
    }

    // DEBUG: TODO(T7 验收) 验收通过后移除
    /// 手动验收辅助：主显示器全屏录 10 秒后自动停止。
    /// 产物与失败原因都走 NSLog（验收期间无 UI）；设置取自 SettingsStore 真实默认值。
    @MainActor
    private static func debugRecordFullScreen10Seconds() async {
        let settings = SettingsStore()
        let store = RecordingFileStore(baseDirectory: settings.outputDirectory)
        do {
            try store.ensureDirectory()
            let outputURL = store.nextFileURL()
            let recorder = SCStreamRecorder(config: RecordingConfiguration(
                mode: .display(CGMainDisplayID()),
                captureSystemAudio: settings.captureSystemAudio,
                captureMicrophone: settings.captureMicrophone,
                includeCamera: false,
                fps: settings.fps,
                codec: settings.videoCodec,
                outputURL: outputURL,
                clickHighlightEnabled: settings.clickHighlightEnabled
            ))
            recorder.onStreamFailure = { error in
                NSLog("[T7-debug] stream failure: \(error)")
            }
            NSLog("[T7-debug] start → \(outputURL.path)")
            try await recorder.start()
            try await Task.sleep(nanoseconds: 10_000_000_000)
            await recorder.stop()
            NSLog("[T7-debug] stop → finished=\(recorder.finishedFileURL?.path ?? "nil") lastError=\(String(describing: recorder.lastError))")
        } catch {
            NSLog("[T7-debug] failed: \(error)")
        }
    }
}
