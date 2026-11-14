import AppKit
import SwiftUI

/// 关于窗内容（2026-11-14 用户裁定简化）：只留身份信息——图标、名称、版本、
/// 一行定位、版权与关闭；功能清单/快捷键速查移除（偏好设置里已有）。
struct AboutView: View {
    /// 关闭出口（由窗口控制器注入）。
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
            Text("蜂鸟录屏").font(.title2.weight(.bold))
            Text("版本 \(Self.versionText)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("菜单栏录屏与截图工具——按下即录，定格即存。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("© 2026 蜂鸟录屏 · 本地运行，不上传任何内容")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
            Button("关闭") { onClose() }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 360)
        .background(OmiStyle.panelBackground)
    }

    /// 版本串（CFBundleShortVersionString + CFBundleVersion；缺省 "1.0"）。
    private static var versionText: String {
        let bundle = Bundle.main
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let build, build != short {
            return "\(short)（\(build)）"
        }
        return short
    }
}

/// 关于窗口（装配层持有；`isReleasedWhenClosed = false` 懒建单例复用惯例同偏好设置）。
@MainActor
final class AboutWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 330), // 简化版内容尺寸
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false)
            window.title = "关于 蜂鸟录屏"
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.contentView = NSHostingView(rootView: AboutView(
            onClose: { [weak self] in self?.window?.close() }))
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
