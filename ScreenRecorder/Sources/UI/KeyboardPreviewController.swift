import AppKit
import Combine

/// 键帽预览窗（2026-11-15 Omi 键盘事件页「开启预览」复刻）：无边框悬浮小窗贴主屏
/// 底部居中，0.1s 轮询快照桥逐拍重绘键帽——与录制合成消费**同一份**
/// `KeyboardOverlaySnapshot`（样式/合行/淡出透明度全一致），预览所见即录制所得。
/// 装配纪律（同 PreferencesView）：窗口所有权归本控制器，装配层只 start/stop；
/// 监听器的临时装机（setEnabled(true)+start）与还原由装配层编排（录制开始先停预览）。
@MainActor
final class KeyboardPreviewController: ObservableObject {
    /// 预览开关（偏好设置按钮据此换文案「开启预览/停止预览」）。
    @Published private(set) var isActive = false

    /// 快照读缝（与录制合成同源：KeyboardOverlaySnapshotStore.currentSnapshot）。
    private let snapshotProvider: () -> KeyboardOverlaySnapshot?
    private var window: NSWindow?
    private var keycapView: KeycapPreviewView?
    private var pollTask: Task<Void, Never>?

    init(snapshotProvider: @escaping () -> KeyboardOverlaySnapshot?) {
        self.snapshotProvider = snapshotProvider
    }

    /// 开启预览（幂等）：建窗 + 轮询。窗不接鼠标、不参与采集（sharingType .none，
    /// 录制画面不得出现预览窗自身），浮层跟随所有空间。
    func start() {
        guard !isActive else { return }
        let view = KeycapPreviewView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.sharingType = .none
        window.contentView = view
        keycapView = view
        self.window = window
        isActive = true
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.refresh()
                try? await Task.sleep(nanoseconds: UInt64(0.1 * 1_000_000_000))
            }
        }
        refresh()
    }

    /// 停止预览（幂等；监听器还原由装配层自理，本类只管窗与轮询）。
    func stop() {
        guard isActive else { return }
        pollTask?.cancel()
        pollTask = nil
        window?.orderOut(nil)
        window = nil
        keycapView = nil
        isActive = false
    }

    /// 逐拍刷新：取快照 → 重绘 → 窗尺寸贴键帽 → 主屏底部居中；快照 nil（无输入/
    /// 停留到期/安全输入）或透明度归零即隐窗，不空绘。
    private func refresh() {
        guard let window, let keycapView else { return }
        guard let snapshot = snapshotProvider(), snapshot.opacity > 0, !snapshot.text.isEmpty else {
            if window.isVisible { window.orderOut(nil) }
            return
        }
        keycapView.update(snapshot: snapshot)
        let size = keycapView.fittingSize
        window.setContentSize(size)
        if let screen = NSScreen.main {
            let origin = NSPoint(
                x: screen.visibleFrame.midX - size.width / 2,
                y: screen.visibleFrame.minY + 60)
            window.setFrameOrigin(origin)
        }
        if !window.isVisible { window.orderFrontRegardless() }
    }
}

    /// 键帽绘制视图：视图边界 = 键帽位图（update 即换尺寸），绘制参数与合成器
    /// `makeKeycapCGImage` 同源——水平内边距 0.7×字号、垂直 0.45×字号、圆角 0.28×键帽高，
    /// 面板/文字色与淡出透明度按快照原样。
    private final class KeycapPreviewView: NSView {
        private var snapshot: KeyboardOverlaySnapshot?
        private var capSize: NSSize = .zero

        /// 换快照并按文本量测重定视图尺寸（父层经 fittingSize 让窗贴合）。
        func update(snapshot: KeyboardOverlaySnapshot) {
            self.snapshot = snapshot
            let fontSize = max(1, CGFloat(snapshot.style.fontSize))
            let font = NSFont.systemFont(ofSize: fontSize)
            let attributes: [NSAttributedString.Key: Any] = [.font: font]
            let textSize = NSAttributedString(string: snapshot.text, attributes: attributes).size()
            let padX = fontSize * 0.7
            let padY = fontSize * 0.45
            capSize = NSSize(
                width: ceil(textSize.width + padX * 2),
                height: ceil(textSize.height + padY * 2))
            needsDisplay = true
            invalidateIntrinsicContentSize()
        }

        override var intrinsicContentSize: NSSize { capSize }

        override func draw(_ dirtyRect: NSRect) {
            guard let snapshot, capSize.width > 0, capSize.height > 0 else { return }
            let opacity = CGFloat(max(0, min(1, snapshot.opacity)))
            let panel = snapshot.style.panelColor
            let text = snapshot.style.textColor
            let radius = capSize.height * 0.28
            let capPath = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
            NSColor(deviceRed: CGFloat(panel.red), green: CGFloat(panel.green),
                    blue: CGFloat(panel.blue), alpha: CGFloat(panel.alpha) * opacity).setFill()
            capPath.fill()

            let fontSize = max(1, CGFloat(snapshot.style.fontSize))
            let font = NSFont.systemFont(ofSize: fontSize)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor(deviceRed: CGFloat(text.red), green: CGFloat(text.green),
                                          blue: CGFloat(text.blue), alpha: CGFloat(text.alpha) * opacity),
                .paragraphStyle: paragraph,
            ]
            let lineRect = NSRect(
                x: 0, y: (bounds.height - fontSize) / 2, width: bounds.width, height: fontSize)
            NSAttributedString(string: snapshot.text, attributes: attributes)
                .draw(in: lineRect)
        }
    }
