import AppKit
import AVFoundation

// MARK: - CameraPiPWindow（简报 Produces：圆角摄像头预览浮窗，录制中可拖动）

/// 摄像头画中画浮窗（NSPanel）：nonactivating 不抢焦点、`.floating` 层、可全屏应用之上
/// 显示（与浮条同款纪律）。拖动锚点机制：浮窗移动/缩放通知（`CameraPiPWindowController`
/// 观察）实时进 `PiPFrameStore`，合成器逐帧读取，成片里位置实时跟随（验收项：录制中拖动小窗）。
final class CameraPiPWindow: NSPanel {
    /// 默认浮窗：尺寸取 PiP 锚点约定的 160×120（前置摄像头 4:3）。
    static func makeDefault() -> CameraPiPWindow {
        let panel = CameraPiPWindow(
            contentRect: NSRect(origin: .zero, size: PiPLacementAnchor.pipSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isMovableByWindowBackground = true // 整窗拖动（简报：录制中可拖动）
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = true
        return panel
    }

    /// 安装摄像头预览层（圆角裁切 + 自适应填充）。layer 为 nil（摄像头未启动/无头测试）
    /// 时仅铺深色底——浮窗装配路径不因预览缺位而失败。
    func installPreviewLayer(_ layer: AVCaptureVideoPreviewLayer?) {
        let content = NSView(frame: NSRect(origin: .zero, size: PiPLacementAnchor.pipSize))
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        content.layer?.cornerRadius = 12
        content.layer?.backgroundColor = NSColor.black.cgColor
        if let layer {
            layer.frame = content.bounds
            content.layer?.addSublayer(layer)
        }
        contentView = content
    }
}

// MARK: - CameraPiPWindowController（装配单元：摄像头 + 浮窗 + 拖动锚点桥）

/// PiP 装配单元：持有 `CameraPiPController`（摄像头）与 `CameraPiPWindow`（浮窗，懒创建
/// 跨场录制复用），所有权进 AppAssembly（装配红线）；运行时生命周期挂在
/// `RecordingSessionCoordinator.begin/finish`（既有 stop 路径，不造新停止竞态）。
///
/// 降级语义：geometry 缺位（窗口模式枚举失败等）或摄像头启动失败（授权/无设备）→ 记
/// 诊断日志、不显示浮窗，录制本体照常（纯屏幕，T8 混音降级同精神）。
@MainActor
final class CameraPiPWindowController {
    /// 浮条避让锚点数据源（装配层喂数；nil = 无浮条信息，不做避让）。
    var controlBarFrameProvider: (() -> CGRect?)?

    private let camera: CameraPiPController
    private let windowFactory: () -> CameraPiPWindow
    private let startCamera: (CameraPiPController) throws -> Void
    private let stopCamera: (CameraPiPController) -> Void
    private let frameStore = PiPFrameStore()
    private var window: CameraPiPWindow?

    /// - Parameters:
    ///   - camera: 摄像头控制器（跨场录制复用单实例）。
    ///   - windowFactory: 测试缝——无头测试注入可构造的浮窗（同 RegionSelector/Countdown 模式）。
    ///   - startCamera/stopCamera: 测试缝——生产默认：start 切后台队列（`startRunning` 阻塞，
    ///     不得占主线程）、stop 主线程直接提交（控制器内部异步化，提交保序，见 stopAsynchronously）。
    init(camera: CameraPiPController = CameraPiPController(),
         windowFactory: @MainActor @escaping () -> CameraPiPWindow = { CameraPiPWindow.makeDefault() },
         startCamera: ((CameraPiPController) throws -> Void)? = nil,
         stopCamera: ((CameraPiPController) -> Void)? = nil) {
        self.camera = camera
        self.windowFactory = windowFactory
        self.startCamera = startCamera ?? { try CameraPiPWindowController.startOnBackground($0) }
        self.stopCamera = stopCamera ?? { CameraPiPWindowController.stopAsynchronously($0) }
    }

    /// 录制开始（coordinator.begin 调用）：启动摄像头 + 显示浮窗 + 发布拖动锚点。
    /// geometry nil 或摄像头失败 → 降级纯屏幕（不抛错，不阻断录制）。
    /// P5：`backgroundProcessor` 随本场开录快照装配（off → nil），**先于 start** 装机——
    /// 帧回调自首帧起即走正确路径（nil = 一期旁路，blur/builtin = 处理流水线）。
    func beginRecording(geometry: PiPCaptureGeometry?,
                        backgroundProcessor: CameraBackgroundProcessor? = nil) {
        guard let geometry else {
            NSLog("CameraPiP: 本模式无可用的 PiP 换算几何，本次录制为纯屏幕")
            return
        }
        camera.backgroundProcessor = backgroundProcessor
        do {
            try startCamera(camera)
        } catch {
            NSLog("CameraPiP: \(error.localizedDescription)")
            return
        }
        frameStore.setGeometry(geometry)
        let panel = ensureWindow()
        let visibleFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(
            PiPLacementAnchor.defaultFrame(visibleFrame: visibleFrame, controlBarFrame: controlBarFrameProvider?()),
            display: true)
        panel.installPreviewLayer(camera.previewLayer)
        publishFrame(panel)
        panel.orderFrontRegardless() // 不夺焦点（nonactivatingPanel）
    }

    /// 录制结束（coordinator.finish 调用，幂等；begin 失败回滚同走此路）：收浮窗 +
    /// 停摄像头 + 清拖动锚点（video 队列侧立即回到纯屏幕直通）。
    func endRecording() {
        frameStore.setScreenRect(nil, screenFrame: .zero, cgDisplayOrigin: .zero)
        frameStore.setGeometry(nil)
        window?.orderOut(nil)
        stopCamera(camera)
    }

    /// 拖动锚点（SCStream video 队列逐帧读取，锁保护）。
    nonisolated func currentPiPFrame() -> PiPFrame? {
        frameStore.currentPiPFrame()
    }

    /// 最新摄像头帧（SCStream video 队列逐帧读取；锁保护直通摄像头控制器）。
    nonisolated func latestPixelBuffer() -> CVPixelBuffer? {
        camera.latestPixelBuffer
    }

    // MARK: 内部装配

    /// 浮窗懒创建（跨场录制复用）；移动/缩放通知（拖动锚点）只挂一次。
    /// NSWindow 拖动全程连发 `didMoveNotification`（resize 同理 `didResizeNotification`）
    /// ——位置实时跟随的数据源。selector 观察随 self 释放自动注销，观察回调恒在主线程
    ///（AppKit 窗口通知主线程投递）。
    private func ensureWindow() -> CameraPiPWindow {
        if let window { return window }
        let panel = windowFactory()
        panel.installPreviewLayer(nil) // 占位底色；正式预览层在摄像头启动后安装
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidMoveOrResize(_:)),
            name: NSWindow.didMoveNotification, object: panel)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidMoveOrResize(_:)),
            name: NSWindow.didResizeNotification, object: panel)
        window = panel
        return panel
    }

    /// 拖动锚点：窗口移动/缩放通知 → 发布最新位置（主线程）。
    @objc private func windowDidMoveOrResize(_ notification: Notification) {
        guard let panel = notification.object as? CameraPiPWindow, panel === window else { return }
        publishFrame(panel)
    }

    /// 拖动锚点写入（主线程）：浮窗 frame（Cocoa 屏坐标）→ 以浮窗当前所在屏为锚换算
    /// CG 全系（RegionSelectorMath 口径）。拖到未录制屏时换算结果落在采集区外，
    /// 合成器按不相交直返——PiP 自然不进成片。
    private func publishFrame(_ panel: NSPanel) {
        let screen = panel.screen ?? NSScreen.main
        frameStore.setScreenRect(
            panel.frame,
            screenFrame: screen?.frame ?? panel.frame,
            cgDisplayOrigin: screen.map { RegionSelector.cgDisplayOrigin(of: $0) } ?? .zero)
    }

    /// 摄像头启停路径：start 的 `startRunning` 阻塞式（~百毫秒），切后台队列 sync，主线程
    /// 不阻塞；stop 在控制器内部已收敛为「向 lifecycle 串行队列异步提交」（非阻塞），这里在
    /// 主线程直接调用——提交序即主线程程序序，与后续 begin 的 start 构成 FIFO happens-before
    /// （修复轮 Important #1 的形式化：旧 stop 的执行必在新 start 之前；若把提交也丢上并发
    /// 队列，到达序失守，修复形同虚设）。
    private static func startOnBackground(_ camera: CameraPiPController) throws {
        try DispatchQueue.global(qos: .userInitiated).sync { try camera.start() }
    }

    private static func stopAsynchronously(_ camera: CameraPiPController) {
        camera.stop() // 仅向 lifecycle 串行队列提交（非阻塞）；主线程提交保序
    }

    // MARK: 无头测试缝

    /// 浮窗可见性（internal 只读，测试断言装配/收起）。
    var isWindowVisible: Bool { window?.isVisible ?? false }

    /// 以真实 setFrame 路径移动浮窗（触发 didMove/didResize 通知 → 拖动锚点全链）。
    func moveWindowForTesting(to frame: NSRect) {
        window?.setFrame(frame, display: true)
    }
}
