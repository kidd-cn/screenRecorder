import SwiftUI

struct MenuBarView: View {
    var body: some View {
        Label("屏幕录制", systemImage: "record.circle")
        Divider()
        Button("关于") {
            NSApplication.shared.orderFrontStandardAboutPanel(nil)
        }
        Button("退出") {
            NSApplication.shared.terminate(nil)
        }
    }
}
