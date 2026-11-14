import AppKit
import AVFoundation

/// 摄像头预览窗（2026-11-14，用户目验预期「仅摄像头录制要能看到画面」）：仅
/// cameraOnly 场显示——`CaptureController.cameraPreviewSession` 非 nil 即挂
/// `AVCaptureVideoPreviewLayer`（只读引用，会话生命周期归 recorder）。
/// 层级与浮条/画中画浮窗同族：`.floating` 非激活 NSPanel、跨空间 + 全屏辅助可见、
/// `sharingType = .none` 显式采集排除（悬浮 UI 第五类）。**不设连接镜像**——对运行中
/// 会话的连接置 `isVideoMirrored` 会死锁主线程（c76ab70 教训），预览与成片同为
/// 「他人视角」，语义自洽。
@MainActor
final class CameraPreviewWindow {
    /// 预览窗尺寸（4:3，与 PiP 惯例档同族）。
    static let size = NSSize(width: 320, height: 240)
    /// 距可视区边缘留边。
    static let edgeMargin: CGFloat = 24

    private let panel: NSPanel
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private let contentView: PreviewContentView
    private var attachedSession: AVCaptureSession?
    /// 用户拖动后保留位置（会话内）；首次显示定位右下角。
    private var hasShownOnce = false

    init() {
        let contentView = PreviewContentView(frame: NSRect(origin: .zero, size: Self.size))
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.black.cgColor
        contentView.layer?.cornerRadius = 10
        contentView.layer?.masksToBounds = true
        self.contentView = contentView

        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isMovableByWindowBackground = false // 显式拖动（浮条同款：borderless 面板该属性不可靠）
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none // 第五类悬浮 UI 显式采集排除——预览窗绝不入成片/截图
        panel.contentView = contentView

        // 预览层跟随容器尺寸（CALayer 不随 setFrame 自动拉伸——二期教训，显式 autoresizing）。
        previewLayer.frame = contentView.bounds
        previewLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        previewLayer.videoGravity = .resizeAspect
        contentView.layer?.addSublayer(previewLayer)

        contentView.onDragged = { [weak self] event in
            self?.panel.performDrag(with: event)
        }
        contentView.onDoubleClick = { [weak self] in
            self?.hide()
        }
    }

    /// 挂会话并显示（会话未变时仅重新显示）。
    func show(session: AVCaptureSession) {
        if attachedSession !== session {
            previewLayer.session = session
            attachedSession = session
        }
        if !hasShownOnce, let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.maxX - Self.size.width - Self.edgeMargin,
                y: visible.minY + Self.edgeMargin))
            hasShownOnce = true
        }
        panel.orderFrontRegardless()
    }

    /// 隐藏（会话摘除——recorder 收尾后会话不再运行）。
    func hide() {
        panel.orderOut(nil)
        if panel.isVisible == false, previewLayer.session != nil {
            previewLayer.session = nil
            attachedSession = nil
        }
    }
}

/// 预览容器视图：拖动窗口 + 双击收起（borderless 面板显式拖动，浮条同款执法）。
@MainActor
private final class PreviewContentView: NSView {
    var onDragged: ((NSEvent) -> Void)?
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        onDragged?(event)
    }
}
