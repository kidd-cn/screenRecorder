import AppKit
import SwiftUI

/// Omi 设计语言令牌（2026-11-14 界面改版）：对照 OmniRecorder（Omi录屏专家）引导卡与
/// 窗口族（RecordingStatusBarVC / RecordingControlPanel / RecordedMediaList）提炼——
/// 白色圆角卡片表面、彩色磁贴图标（浅底色块 + 符号）、绿色药丸主操作、灰色次级文本、
/// 大留白。全部取系统语义色（深浅色模式自适应），不引入自定义色值。
enum OmiStyle {
    /// 主操作色（Omi 绿药丸）。
    static let accent = Color(nsColor: .systemGreen)
    static let accentNS = NSColor.systemGreen
    /// 面板底 / 卡片面（浅色=白卡，深色= elevated 深灰）。
    static let panelBackground = Color(nsColor: .windowBackgroundColor)
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    /// 圆角：卡片 14 / 磁贴 9。
    static let cardRadius: CGFloat = 14
    static let tileRadius: CGFloat = 9
    /// 卡内边距 / 区块间距。
    static let cardPadding: CGFloat = 12
    static let sectionSpacing: CGFloat = 12

    /// 磁贴色板（Omi 引导卡：摄像头蓝 / 麦克风紫 / 屏幕蓝；扩展到全操作面）。
    static func tintNS(_ tint: TileTint) -> NSColor {
        switch tint {
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .teal: return .systemTeal
        case .orange: return .systemOrange
        case .red: return .systemRed
        case .green: return .systemGreen
        case .indigo: return .systemIndigo
        case .gray: return .systemGray
        }
    }

    enum TileTint {
        case blue, purple, teal, orange, red, green, indigo, gray
    }
}

/// Omi 磁贴按钮（宫格用）：浅底色块圆角方形 + 符号 + 底部小字标题。控件激活通道
/// （Button）——本库手建窗手势层红线不涉及。
struct OmiTileButton: View {
    let title: String
    let icon: String
    let tint: OmiStyle.TileTint
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                tileIcon(icon: icon, tint: tint, size: 40)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .opacity(isEnabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

/// 磁贴图标（浅底色块 + 符号；OmiTileButton 与菜单面板头卡共用）。
struct OmiTileIcon: View {
    let icon: String
    let tint: OmiStyle.TileTint
    var tileSize: CGFloat = 44
    var symbolSize: CGFloat = 17

    var body: some View {
        tileIcon(icon: icon, tint: tint, size: tileSize, symbolSize: symbolSize)
    }
}

private func tileIcon(icon: String, tint: OmiStyle.TileTint, size: CGFloat, symbolSize: CGFloat = 17)
    -> some View
{
    Image(systemName: icon)
        .font(.system(size: symbolSize, weight: .medium))
        .foregroundStyle(Color(nsColor: OmiStyle.tintNS(tint)))
        .frame(width: size, height: size * 0.9)
        .background(
            RoundedRectangle(cornerRadius: OmiStyle.tileRadius)
                .fill(Color(nsColor: OmiStyle.tintNS(tint)).opacity(0.14)))
}

/// Omi 卡片容器（区块统一表面）。
struct OmiCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(OmiStyle.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: OmiStyle.cardRadius)
                    .fill(OmiStyle.cardBackground))
    }
}

/// 表格行视觉（Omi 化）：选中高亮 = 主绿柔光圆角块（替代系统蓝），悬停不加装饰。
/// 供文件列表 / 分段列表的 NSTableView delegate `rowViewForRow` 返回。
@MainActor
final class OmiTableRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        NSColor.systemGreen.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 2), xRadius: 6, yRadius: 6).fill()
    }
}
