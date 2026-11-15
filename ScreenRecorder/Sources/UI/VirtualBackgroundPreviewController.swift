import AppKit
import AVFoundation
import Combine
import CoreImage
import CoreVideo
import SwiftUI

// MARK: - VirtualBackgroundPreviewController（2026-11-15 Omi 虚拟背景页复刻）

/// 虚拟背景页摄像头预览：圆角预览区 = 原始预览层（AVCaptureVideoPreviewLayer 打底，
/// 系统前置镜像）+ 处理帧覆盖层（aspect-fill，off 场隐藏）。复用录制同一条处理链
///（`CameraPiPController` + `CameraBackgroundProcessor`）——预览所见即录制所得。
/// 装配纪律：控制器归 AppAssembly，页面 onAppear/onDisappear 驱动 start/stop；
/// 所选背景经 `setMode` 实时换装（处理器重建，录制快照链不受影响）。
@MainActor
final class VirtualBackgroundPreviewController: ObservableObject {
    /// 预览宿主视图（NSViewRepresentable 原样包装同一实例进 SwiftUI）。
    let previewView = PreviewView()

    private let camera = CameraPiPController()
    private let backgroundStore: CustomBackgroundStore
    /// 渲染上下文（处理帧 CVPixelBuffer → CGImage，协作线程渲染、主线程贴层）。
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    /// 当前预览模式（页面状态；录制快照链不受影响）。
    private(set) var mode: CameraBackgroundMode = .off
    /// 预览会话在跑（防重复 start/stop）。
    private var isRunning = false
    /// 启动失败提示（授权拒绝/无相机等；nil = 正常）。视图占位文本消费。
    @Published private(set) var statusMessage: String?

    init(backgroundStore: CustomBackgroundStore = CustomBackgroundStore()) {
        self.backgroundStore = backgroundStore
        // 处理帧呈现缝（CameraPiPController 契约：仅已入库帧回调，协作线程）——
        // 本线程渲染 CGImage，主线程贴层（CALayer 只在主线程触碰）。
        camera.previewFramePresenter = { [weak self] buffer in
            self?.presentProcessedFrame(buffer)
        }
    }

    /// 开启预览（幂等；相机启停在后台队列——startRunning 阻塞式）。失败降级为
    /// 占位提示文案（页面可用，仅无画面），不打断偏好设置。
    func start() {
        guard !isRunning else { return }
        isRunning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try self?.camera.start()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.previewView.installPreviewLayer(self.camera.previewLayer)
                    self.statusMessage = nil
                    self.previewView.setOverlayVisible(self.mode != .off)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.previewView.installPreviewLayer(nil)
                    self.previewView.setOverlayVisible(false)
                    self.statusMessage = error.localizedDescription
                }
            }
        }
        rebuildProcessor()
    }

    /// 停止预览（幂等）：摘处理器（帧路径回归旁路）→ 停会话 → 收层。
    func stop() {
        guard isRunning else { return }
        isRunning = false
        camera.backgroundProcessor = nil
        camera.stop()
        previewView.installPreviewLayer(nil)
        previewView.setOverlayVisible(false)
    }

    /// 换背景模式（实时）：处理器重建（Vision 单例复用，无逐帧冷启动），覆盖层随
    /// off 显隐。会话未跑也记录（下次 start 装机即新值）。
    func setMode(_ newMode: CameraBackgroundMode) {
        mode = newMode
        previewView.setOverlayVisible(newMode != .off)
        rebuildProcessor()
    }

    /// 重建背景处理器（模式/自定义目录变更入口）。
    private func rebuildProcessor() {
        camera.backgroundProcessor = CameraBackgroundProcessor(
            mode: mode, segmenter: VisionPersonSegmenter.shared,
            backgroundDirectory: backgroundStore.directory)
    }

    /// 处理帧呈现（协作线程入参）：CI 渲染 CGImage 后主线程贴层（nil 渲染失败静默跳帧
    /// ——下一帧即恢复，不重试不丢面）。
    private func presentProcessedFrame(_ buffer: CVPixelBuffer) {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.previewView.updateOverlayImage(cgImage)
        }
    }
}

// MARK: - 预览视图（层宿主）

/// 预览宿主 NSView：黑底圆角（12，与 PiP 浮窗同值）+ 原始预览层（aspect-fill）+
/// 处理帧覆盖层（aspect-fill，顶层）。层帧随视图布局走（resizedLayout）。
final class PreviewView: NSView {
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let overlay = CALayer()
    private let placeholder = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.black.cgColor
        overlay.contentsGravity = .resizeAspectFill
        overlay.isHidden = true
        layer?.addSublayer(overlay)
        placeholder.textColor = .secondaryLabelColor
        placeholder.font = .systemFont(ofSize: 12)
        placeholder.lineBreakMode = .byWordWrapping
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
        ])
    }

    required init?(coder: NSCoder) { fatalError("PreviewView 仅代码装配") }

    /// 占位文案（nil = 隐藏）。启动失败提示经控制器发布。
    var statusText: String? {
        get { placeholder.stringValue.isEmpty ? nil : placeholder.stringValue }
        set {
            placeholder.stringValue = newValue ?? ""
            placeholder.isHidden = (newValue ?? "").isEmpty
        }
    }

    /// 安装/撤除原始预览层（层帧 = 视图界；nil = 撤除，露黑底）。
    func installPreviewLayer(_ layer: AVCaptureVideoPreviewLayer?) {
        previewLayer?.removeFromSuperlayer()
        previewLayer = layer
        if let layer {
            layer.videoGravity = .resizeAspectFill
            layer.frame = bounds
            layer.masksToBounds = true
            // 预览层插在覆盖层之下（index 0）——处理后帧盖住原始画面（背景生效时）。
            self.layer?.insertSublayer(layer, at: 0)
        }
    }

    /// 覆盖层显隐（off 场露原始预览）。
    func setOverlayVisible(_ visible: Bool) {
        overlay.isHidden = !visible
    }

    /// 贴处理后帧（主线程调用；nil 语义 = 静默跳过）。
    func updateOverlayImage(_ image: CGImage?) {
        overlay.contents = image
    }

    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
        overlay.frame = bounds
    }
}

// MARK: - SwiftUI 桥（NSViewRepresentable，同实例直通）

/// 预览 SwiftUI 桥：`makeNSView` 直返控制器自持的同一视图实例（重复进入页面不重建，
/// 相机会话与层状态跨页保留）。
struct VirtualBackgroundPreview: NSViewRepresentable {
    let controller: VirtualBackgroundPreviewController

    func makeNSView(context: Context) -> NSView {
        controller.previewView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? PreviewView else { return }
        view.statusText = controller.statusMessage
    }
}
