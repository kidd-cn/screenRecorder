import AppKit
import Combine
import SwiftUI

/// 浮动控制条（T11 Step 5）：红点（录制中呼吸动画）、elapsed（mm:ss）、暂停/恢复、停止、
/// 丢弃（二次点击确认，tooltip 与 OmniRecorder 一致）。仅承载语义与交互，窗口挂载见
/// `FloatingControlBarPanel`；数据直接读 `CaptureController`（elapsed 已排除暂停时长）。
struct FloatingControlBar: View {
    @ObservedObject var controller: CaptureController
    @State private var discardArmed = false
    @State private var disarmTask: Task<Void, Never>?
    @State private var breathing = false

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .scaleEffect(breathing ? 1.35 : 1.0)
                .opacity(controller.state == .paused ? 0.35 : (breathing ? 0.7 : 0.9))
            Text(Self.elapsedText(controller.elapsed))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .frame(minWidth: 46, alignment: .center)
                .help("已录制时长（不含暂停）")
            Button {
                if controller.state == .paused {
                    controller.resume()
                } else {
                    controller.pause()
                }
            } label: {
                Image(systemName: controller.state == .paused ? "play.fill" : "pause.fill")
                    .frame(width: 18, height: 18)
            }
            .help(controller.state == .paused ? "恢复录制" : "暂停录制")
            .accessibilityLabel(controller.state == .paused ? "恢复录制" : "暂停录制")
            Button {
                controller.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .foregroundStyle(.red)
                    .frame(width: 18, height: 18)
            }
            .help("停止并保存录制")
            .accessibilityLabel("停止并保存录制")
            Button {
                handleDiscardTap()
            } label: {
                if discardArmed {
                    Text("再次点击确认")
                        .font(.callout)
                        .foregroundStyle(.red)
                } else {
                    Image(systemName: "trash")
                        .frame(width: 18, height: 18)
                }
            }
            .help("取消录制会丢弃已录制的内容，再次点击确认")
            .accessibilityLabel("丢弃录制")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Capsule().fill(.regularMaterial).shadow(radius: 3))
        .onAppear { updateBreathing() }
        .onChange(of: controller.state) { newState in
            updateBreathing()
            // 修复轮 1 Minor #5：离开录制/暂停（浮条即将隐藏或收尾）即解除丢弃武装，
            // 防止「武装后浮条隐藏 → 新录制重现浮条」时一击即丢。
            if newState != .recording && newState != .paused {
                disarmDiscard()
            }
        }
    }

    private func handleDiscardTap() {
        if discardArmed {
            disarmDiscard()
            controller.cancelAndDiscard()
        } else {
            discardArmed = true
            disarmTask?.cancel()
            disarmTask = Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if !Task.isCancelled { discardArmed = false }
            }
        }
    }

    private func disarmDiscard() {
        disarmTask?.cancel()
        disarmTask = nil
        discardArmed = false
    }

    private func updateBreathing() {
        let shouldBreath = controller.state == .recording
        guard breathing != shouldBreath else { return }
        withAnimation(shouldBreath
            ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
            : .easeOut(duration: 0.2)) {
            breathing = shouldBreath
        }
    }

    /// mm:ss（分钟可超 59，长录制不换制式）。
    static func elapsedText(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded(.down))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// 浮条的 NSPanel 承载（简报：`styleMask: [.borderless, .nonactivatingPanel]`、
/// `level: .floating`、默认屏幕顶部居中、可拖动）。由 ScreenRecorderApp 装配点创建并持有；
/// 显隐随 `CaptureController.state`：`.recording`/`.paused` 显示，其余（idle/countdown/
/// finishing）隐藏。附加裁定：`canJoinAllSpaces + fullScreenAuxiliary`——全屏应用录制时浮条
/// 仍可见且不抢占全屏空间；`orderFrontRegardless` 不夺焦点（配合 nonactivatingPanel）。
@MainActor
final class FloatingControlBarPanel {
    private let panel: NSPanel
    private var stateObservation: AnyCancellable?
    private var isShowing = false

    init(controller: CaptureController) {
        let hostingView = NSHostingView(rootView: FloatingControlBar(controller: controller))
        let contentSize = hostingView.fittingSize
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hostingView

        // @Published state 在主线程发布；Task 主 actor 跳转保序，显隐操作全部回到主 actor。
        stateObservation = controller.$state.sink { [weak self] state in
            Task { @MainActor in self?.apply(state) }
        }
    }

    private func apply(_ state: CaptureState) {
        switch state {
        case .recording, .paused:
            guard !isShowing else { return }
            positionTopCenter()
            panel.orderFrontRegardless()
            isShowing = true
        case .idle, .countdown, .finishing:
            guard isShowing else { return }
            panel.orderOut(nil)
            isShowing = false
        }
    }

    /// 主屏可视区顶部居中；App 启动极早期 NSScreen.main 可能为 nil，显示时兜底重定位。
    private func positionTopCenter() {
        guard let screen = NSScreen.main else { return }
        let frame = panel.frame
        let visible = screen.visibleFrame
        panel.setFrameOrigin(
            NSPoint(x: visible.midX - frame.width / 2,
                    y: visible.maxY - frame.height - 12)
        )
    }
}
