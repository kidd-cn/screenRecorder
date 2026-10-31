import AppKit
import SwiftUI

// MARK: - 标记工具条视图（色二选 黑/红、粗细二档 细/粗、撤销、清空、关闭；简体中文）

/// 边录边标记工具条内容视图（Task 5）：样式对齐浮条（胶囊 regularMaterial + 图标按钮）。
/// 工具态（色/宽）与笔画栈（撤销/清空可用性）直接订阅 `MarkingOverlayController` 与
/// `MarkingCanvas`；关闭出口由装配层注入（AppAssembly 接 `markingEnabled = false`）。
struct MarkingToolbarView: View {
    @ObservedObject var controller: MarkingOverlayController
    @ObservedObject var canvas: MarkingCanvas
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            colorDot(MarkingColor.black, help: "黑色")
            colorDot(MarkingColor.red, help: "红色")
            divider
            widthDot(thick: false, help: "细线")
            widthDot(thick: true, help: "粗线")
            divider
            Button {
                canvas.undoLast()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 18, height: 18)
            }
            .disabled(canvas.strokes.isEmpty)
            .help("撤销上一笔")
            .accessibilityLabel("撤销上一笔")
            Button {
                canvas.clear()
            } label: {
                Image(systemName: "eraser.fill")
                    .frame(width: 18, height: 18)
            }
            .disabled(canvas.strokes.isEmpty)
            .help("清空全部笔画")
            .accessibilityLabel("清空全部笔画")
            divider
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 18, height: 18)
            }
            .help("关闭边录边标记")
            .accessibilityLabel("关闭边录边标记")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Capsule().fill(.regularMaterial).shadow(radius: 3))
    }

    private var divider: some View {
        Divider().frame(height: 18)
    }

    /// 色选按钮：实心圆点，选中时描边环。
    private func colorDot(_ color: MarkingColor, help: String) -> some View {
        Button {
            controller.toolColor = color
        } label: {
            Circle()
                .fill(Color(red: color.red, green: color.green, blue: color.blue))
                .frame(width: 14, height: 14)
                .padding(3)
                .overlay(
                    Circle().strokeBorder(
                        controller.toolColor == color ? Color.accentColor : .clear,
                        lineWidth: 2)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    /// 宽选按钮：小/大圆点示意线宽，选中时描边框。
    private func widthDot(thick: Bool, help: String) -> some View {
        Button {
            controller.isThickWidth = thick
        } label: {
            Circle()
                .fill(Color.primary)
                .frame(width: thick ? 12 : 5, height: thick ? 12 : 5)
                .frame(width: 20, height: 20)
                .overlay(
                    RoundedRectangle(cornerRadius: 4).strokeBorder(
                        controller.isThickWidth == thick ? Color.accentColor : .clear,
                        lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - MarkingToolbarPanel（浮条宿主同款：nonactivating borderless NSPanel）

/// 标记工具条的 NSPanel 承载（浮条面板机制同款，FloatingControlBarPanel 姊妹）：
/// `styleMask: [.borderless, .nonactivatingPanel]`、`level: .floating`、透明胶囊、
/// `orderFrontRegardless` 不夺焦点；`canJoinAllSpaces + fullScreenAuxiliary`。
/// 显隐条件与覆盖层一致（`markingEnabled && recording/paused`），由装配层在状态/开关
/// 变化时调 `setVisible`；首次显示定位在浮条下方居中（避让浮条），此后保留用户感知位置。
/// 窗口 identifier 供点击系抑制缝识别（工具条上的按下同样不得画环/触发缩放与音效）。
@MainActor
final class MarkingToolbarPanel {
    static let panelWindowIdentifier = NSUserInterfaceItemIdentifier(rawValue: "com.screenrecorder.marking-toolbar")

    private let panel: NSPanel
    /// 浮条当前 frame 取数缝（定位避让用；nil = 浮条不在场，按可视区顶部兜底）。
    private let barFrameProvider: () -> NSRect?
    private var isShowing = false

    init(controller: MarkingOverlayController,
         barFrameProvider: @escaping () -> NSRect?,
         onClose: @escaping () -> Void) {
        self.barFrameProvider = barFrameProvider
        let hostingView = NSHostingView(rootView: MarkingToolbarView(
            controller: controller,
            canvas: controller.canvas,
            onClose: onClose))
        let contentSize = hostingView.fittingSize
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = Self.panelWindowIdentifier
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hostingView
    }

    /// 显隐（幂等：重复 show 不重定位/重前置，重复 hide 不重复 orderOut）。
    func setVisible(_ visible: Bool) {
        if visible {
            if !isShowing {
                positionBelowBar()
            }
            panel.orderFrontRegardless()
            isShowing = true
        } else if isShowing {
            panel.orderOut(nil)
            isShowing = false
        }
    }

    /// 浮条下方居中；浮条不在场时退可视区顶部下方 48pt。主屏取不到（极早期）不定位，
    /// 面板按默认 frame 显示（下一次显隐周期重定位兜底）。
    private func positionBelowBar() {
        guard let screen = NSScreen.main else { return }
        let size = panel.frame.size
        let visible = screen.visibleFrame
        let y: CGFloat
        if let bar = barFrameProvider() {
            y = bar.minY - size.height - 12
        } else {
            y = visible.maxY - size.height - 48
        }
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: y))
    }
}
