import AppKit
import SwiftUI

/// 关于窗内容（2026-11-14，用户反馈「点关于无任何内容」——系统标准面板只有名称/
/// 版本，信息量过低）：Omi 风格卡片——图标、名称、版本、一句话定位、功能清单、
/// 快捷键速查、版权。
struct AboutView: View {
    /// 关闭出口（由窗口控制器注入）。
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            header
            OmiCard { featureList }
            OmiCard { shortcutList }
            footer
        }
        .padding(20)
        .frame(width: 420)
        .background(OmiStyle.panelBackground)
    }

    private var header: some View {
        VStack(spacing: 8) {
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
        }
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("功能").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            featureRow("display", .blue, "全屏 / 窗口 / App / 区域 / 窗口区域录制")
            featureRow("waveform", .purple, "仅声音（m4a）与仅摄像头录制")
            featureRow("viewfinder", .green, "区域截图与整屏截图")
            featureRow("person.crop.rectangle", .indigo, "摄像头画中画、点击高亮、自动缩放、按键可视化")
            featureRow("calendar", .orange, "定时录制、暂停续录、重新录制、边录边标记")
            featureRow("scissors", .teal, "缩放分段编辑器、压缩、GIF 导出")
        }
    }

    private var shortcutList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("快捷键").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                shortcutPair("⇧⌘R", "开始/停止")
                shortcutPair("⇧⌘P", "暂停/恢复")
            }
            HStack(spacing: 16) {
                shortcutPair("⇧⌘W", "窗口录制")
                shortcutPair("⇧⌘M", "标记工具")
            }
            Text("每个录制模式与截图操作均有独立快捷键（⇧⌃ 系列），见偏好设置 → 快捷键。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Text("© 2026 蜂鸟录屏 · 本地运行，不上传任何内容")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Button("关闭") { onClose() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func featureRow(_ icon: String, _ tint: OmiStyle.TileTint, _ text: String) -> some View {
        HStack(spacing: 8) {
            OmiRowIcon(icon: icon, tint: tint)
            Text(text).font(.callout)
        }
    }

    private func shortcutPair(_ key: String, _ action: String) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.14)))
            Text(action).font(.caption).foregroundStyle(.secondary)
        }
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
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
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
