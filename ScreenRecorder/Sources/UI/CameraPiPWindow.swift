import AppKit
import AVFoundation
import ImageIO

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
    /// P5：同场装配预览跟背景覆盖层（预览层之上，初始隐藏——off/idle 露原始预览）。
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
        let overlay = CALayer()
        overlay.frame = content.bounds
        // aspect-fill 与成片摆放同语义（窗内所见即成片所得；帧宽高比随机型可 ≠ 窗口）。
        overlay.contentsGravity = .resizeAspectFill
        overlay.isHidden = true
        content.layer?.addSublayer(overlay)
        previewOverlayLayer = overlay
        // T5 对调态屏幕缩略图层：**顶层**子层（最后添加 = 盖过预览层与背景覆盖层，免去其
        // 显隐状态腾挪）；黑底占位（首帧缩略图未到即黑，不透出底下摄像头预览）；aspect-fill
        // 与成片摆放同语义；圆角由 content 层既有 masksToBounds+cornerRadius 12 统一裁切。
        // 跨场 begin 的 installPreviewLayer 重建 content——本层随之重建并复位隐藏（会话
        // 复位全链的窗口侧机制，配合 beginRecording 显式 setScreenThumbnailMode(false)）。
        let thumbnail = CALayer()
        thumbnail.frame = content.bounds
        thumbnail.contentsGravity = .resizeAspectFill
        thumbnail.backgroundColor = NSColor.black.cgColor
        thumbnail.isHidden = true
        content.layer?.addSublayer(thumbnail)
        screenThumbnailLayer = thumbnail
        contentView = content
    }

    // MARK: 预览跟背景覆盖层（P5：录制中呈现处理后帧）

    private var previewOverlayLayer: CALayer?

    /// 覆盖层显隐（录制中 + 背景开 = 显示；off/idle/收尾 = 隐藏，露出原始预览层——
    /// 首帧处理完成前的过渡画面即原始预览，无黑窗跳变）。
    func setPreviewOverlayVisible(_ visible: Bool) {
        previewOverlayLayer?.isHidden = !visible
    }

    /// 贴处理后帧的镜像小图（主线程调用；nil = 清空）。未装配覆盖层时静默忽略。
    func updatePreviewOverlayImage(_ image: CGImage?) {
        previewOverlayLayer?.contents = image
    }

    /// 覆盖层状态（internal 只读，无头测试断言装配/收起）。
    var isPreviewOverlayVisible: Bool { previewOverlayLayer?.isHidden == false }

    // MARK: 对调态屏幕缩略图层（T5：浮窗换装 = 摄像头预览 ↔ 屏幕缩略图）

    private var screenThumbnailLayer: CALayer?

    /// 对调态浮窗内容切换（主线程）：true = 屏幕缩略图层置顶显示（黑底占位，首帧缩略图
    /// 未到即黑）；false = 恢复摄像头预览。窗内所见即成片所得——contentsGravity 与成片
    /// inset 同为 aspect-fill；圆角由 content 层既有 masksToBounds+cornerRadius 12 统一
    /// 裁切。未装配层（无头测试/装配前）静默忽略，幂等。
    func setScreenThumbnailMode(_ active: Bool) {
        screenThumbnailLayer?.isHidden = !active
    }

    /// 贴屏幕缩略图（主线程调用；nil = 清空回黑底占位）。未装配层时静默忽略。
    func updateScreenThumbnailImage(_ image: CGImage?) {
        screenThumbnailLayer?.contents = image
    }

    /// 缩略图态（internal 只读，无头测试断言换装）。
    var isScreenThumbnailActive: Bool { screenThumbnailLayer?.isHidden == false }

    /// 当前贴图层图像（internal 只读测试缝，无头测试断言贴图落地）。CGImage 是 CF 型：
    /// `as?` 恒成功被判错、`as!` 又被判恒非 nil 而告警、`as` 从 Any 不可转换——按
    /// PreferencesView 同款纪律先 CFTypeID 显式判型，再 unsafeDowncast（无运行时检查
    /// 强转，不产生 as! 告警）。contents 唯一写入方是 `updateScreenThumbnailImage`
    /// （只喂 CGImage/nil），判型恒过；失配防御返回 nil。
    var windowThumbnailImage: CGImage? {
        guard let contents = screenThumbnailLayer?.contents else { return nil }
        let cf = contents as CFTypeRef
        guard CFGetTypeID(cf) == CGImage.typeID else { return nil }
        return unsafeDowncast(cf, to: CGImage.self)
    }
}

// MARK: - CameraFullscreenPreviewWindow（对调态全屏摄像头视图，spec §3.3 二次修订）

/// 对调态全屏摄像头实时预览（NSPanel，2026-11-11 用户拍板）：盖住摄像头浮窗所在屏、
/// 镜像自视图（预览特权，自拍观感——成片仍「他人视角」不镜像，P7b 同口径）、aspect-fill
/// 铺满（预览特权——裁剪边界不入成片故无碍）。采集排除不入成片：`sharingType = .none`
///（spec 钉定）+ ScreenCaptureKit 对采集进程自有窗口的隐式排除（浮窗/浮条不入成片的同一
/// 机制，真机验收已证）。窗口纪律（浮窗 `CameraPiPWindow` 口径照抄）：
/// - level = 浮窗（`.floating`）**下一档**——小浮窗与浮条（同 `.floating`）悬浮其上保持
///   可点（换回/暂停/停止可达），正常窗在其之下（盖桌）；
/// - collectionBehavior 同浮窗（canJoinAllSpaces + fullScreenAuxiliary，全屏应用之上也在）；
/// - 非激活（nonactivatingPanel + orderFrontRegardless，不抢 key——录制不能被打断）。
/// 生命周期由 `CameraPiPWindowController` 管辖：只随 `setLayoutSwapped(true)` 进场、
/// false/end/begin 收（幂等）；预览层每次进场重装（跨场 stop→start 后 previewLayer 重建，
/// 重装一并重钉镜像与重力，杜绝连接重建后的钉定丢失）。
final class CameraFullscreenPreviewWindow: NSPanel {
    /// level：浮窗（`.floating`）下一档（浮条与浮窗同层——三者相对次序全由本值钉定）。
    static let level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)

    /// 默认全屏视图：1×1 占位起窗（frame 由进场时的所在屏 bounds 覆写），窗口纪律见类注释。
    static func makeDefault() -> CameraFullscreenPreviewWindow {
        let panel = CameraFullscreenPreviewWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = Self.level
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isMovableByWindowBackground = false // 背景幕布不可拖——拖动语义在小浮窗（拖=挪小图）
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary] // 同浮窗
        panel.sharingType = .none // 采集排除（spec §3.3 钉定；与浮窗同机制并存，纵深防御）
        panel.hasShadow = false // 全屏幕布无影
        return panel
    }

    /// 安装摄像头预览层（同一 capture session 的**新**预览实例——浮窗侧持有系统建的那只，
    /// CALayer 单父约束下全屏视图另建一层）。layer nil（摄像头未启动/无头测试）时仅铺黑底
    /// ——装配路径不因预览缺位而失败。进场时序：setFrame（所在屏 bounds）先行，本方法随后，
    /// 预览层 frame 恰为整屏。
    func installPreviewLayer(_ layer: AVCaptureVideoPreviewLayer?) {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor // 首帧未到 = 诚实黑幕布
        if let layer {
            layer.videoGravity = .resizeAspectFill // aspect-fill 铺满（spec §3.3 钉定）
            layer.frame = content.bounds
            Self.ensureMirroredSelfView(on: layer) // 镜像自视图（预览特权，见缝注释）
            content.layer?.addSublayer(layer)
        }
        contentView = content
    }

    /// 镜像自视图钉定（internal 缝，无头钉测可断言跳过路径；exposureAnchoringPlan 同款
    /// 「决策缝」先例）。macOS API 台账（brief 写的 `connection isMirrored` 为 iOS 名）：
    /// macOS 连接属性是 `videoMirrored`（getter `isVideoMirrored`，10.7+），而
    /// `automaticallyAdjustsVideoMirroring` 是 **iOS 专属**（macOS 不可读不可写）——「先关
    /// 自动镜像再显式钉定」的 iOS 形在 macOS 不存在，且文档钉明自动调整在位时置位
    /// `videoMirrored` 抛 NSInvalidArgumentException。故 macOS 口径**读优先**：连接已镜像
    ///（macOS 前置预览的系统自动镜像——浮窗同款真机 observed 行为，同一 session 的全屏
    /// 层同享）直接放行零置位（零异常风险）；未镜像时支持性守卫 + 显式置位（自拍观感，
    /// 预览特权——成片仍「他人视角」不镜像，P7b 同口径）。无连接（会话未运行/无头测试）
    /// 安全跳过返回 false——黑底装配不失败。
    /// - Returns: 调用后连接是否处于镜像态（无头恒 false；真机 = true）。
    @discardableResult
    static func ensureMirroredSelfView(on layer: AVCaptureVideoPreviewLayer) -> Bool {
        guard let connection = layer.connection else { return false }
        if connection.isVideoMirrored { return true } // 已镜像（系统自动镜像在位）：零置位
        guard connection.isVideoMirroringSupported else { return false }
        connection.isVideoMirrored = true
        return true
    }
}

// MARK: - PiPPreviewFramePresenter（P5 预览跟背景：处理后帧 → 浮窗覆盖层）

/// 处理完成线程渲染镜像小图、经 `applyOnMain` 交主线程贴覆盖层。水平镜像对齐预览层的
/// 系统自动镜像（自拍观感）——数据输出帧是「他人视角」，不镜像则开录瞬间画面横向跳变。
/// 渲染按 ≤2× 浮窗点尺寸等比缩到全幅（覆盖层 aspect-fill 再裁切），全分辨率逐帧渲染是
/// 无谓的 GPU/内存开销。`@unchecked Sendable`：context 单实例复用（CIContext 线程安全，
/// CameraBackgroundProcessor 同款），applyOnMain 由装配侧保证主线程投递。
final class PiPPreviewFramePresenter: @unchecked Sendable {
    /// 渲染宽度上限（160×120pt 浮窗 @2x=320px 的 2 倍采样余量）。
    static let maxRenderWidth: CGFloat = 640

    private let context: CIContext
    private let applyOnMain: (CGImage) -> Void

    /// - Parameters:
    ///   - context: 渲染上下文（测试缝——软渲染确定性出图；生产默认 GPU）。
    ///   - applyOnMain: 贴图回调（装配侧闭包内投递主线程；测试可直接断言收到的图）。
    init(context: CIContext = CIContext(options: [.useSoftwareRenderer: false]),
         applyOnMain: @escaping (CGImage) -> Void) {
        self.context = context
        self.applyOnMain = applyOnMain
    }

    /// 渲染一帧（水平镜像 + 等比缩限宽 + createCGImage）并回调。mask 不可得的直通帧
    /// 同样呈现——处理失败在帧路径已回退，呈现面无额外分支。
    func present(_ frame: CVPixelBuffer) {
        let image = CIImage(cvPixelBuffer: frame).oriented(.upMirrored)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return }
        let scale = min(1, Self.maxRenderWidth / extent.width)
        let display = scale < 1
            ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : image
        guard let cg = context.createCGImage(display, from: display.extent) else { return }
        applyOnMain(cg)
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

    /// 摄像头断源接线缝（Task 3，用户裁决 (a)；装配层 init 注入一次，**应用级接线、会话间
    /// 永不清**——场次语义在控制器侧 `camera.onSourceLost`）：beginRecording 装配会话级
    /// 转发，endRecording 摘除控制器侧转发（window 侧若随场次置 nil，第二场起投递落空
    /// ——检测死锁、成片冻结在最后帧，审查 Critical）。end 后在途投递的吸收闸链：armed 闸
    ///（stop 已摘武装）→ camera.onSourceLost 已 nil（投递时读空）→ `handleSessionFailure`
    /// `.idle`/`.finishing` 重入 no-op；亚秒 stop+rebegin 拥塞下的残余竞态与既有
    /// SourceLossMonitor 同型存在，不在本批修。
    var onCameraSourceLost: (() -> Void)?

    private let camera: CameraPiPController
    private let windowFactory: () -> CameraPiPWindow
    private let startCamera: (CameraPiPController) throws -> Void
    private let stopCamera: (CameraPiPController) -> Void
    private let frameStore = PiPFrameStore()
    private var window: CameraPiPWindow?
    /// 对调态全屏摄像头视图（spec §3.3 二次修订）：懒创建跨场录制复用（与浮窗同款纪律）；
    /// nil = 从未对调进场。
    private var fullscreenWindow: CameraFullscreenPreviewWindow?
    /// PiP 会话闸（P5 实时换背景）：begin 成功装配（浮窗已显示）置 true、end 复位。
    /// 降级纯屏幕（几何缺位/摄像头失败）不置位——无 PiP 场的设置变化无消费面，下一场
    /// begin 快照按当时设置装配。
    private var isRecordingActive = false

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
        // 全屏摄像头视图安全收（spec §3.3：begin 幂等收起——防上一场异常残留：降级路径
        // （geometry 缺位/摄像头失败）也收，几何守卫前置不妨碍清场）。
        fullscreenWindow?.orderOut(nil)
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
        // 断源转发缝接线（Task 3）：camera.onSourceLost → 装配层 onCameraSourceLost
        //（window 侧由装配层 init 注入一次、本方法只装配**会话级转发**）。控制器侧投递
        // 契约保证主线程，`MainActor.assumeIsolated` 直进主 actor 读缝（CaptureController
        // click tracker 回调同款桥接）；start 失败降级路径不接线（无会话无断源），会话级
        // 转发每场 begin 重挂、end 摘除。
        camera.onSourceLost = { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.onCameraSourceLost?()
            }
        }
        frameStore.setGeometry(geometry)
        // 每场开始复位屏幕为主（spec §3.1 会话级布尔）：上一场遗留的对调态不得带进新场。
        frameStore.setLayoutSwapped(false)
        let panel = ensureWindow()
        let visibleFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(
            PiPLacementAnchor.defaultFrame(visibleFrame: visibleFrame, controlBarFrame: controlBarFrameProvider?()),
            display: true)
        panel.installPreviewLayer(camera.previewLayer)
        installPreviewOverlay(panel, backgroundProcessor: backgroundProcessor)
        // T5 跨场残留清零：对调态缩略图随场复位（installPreviewLayer 重建 content 时缩略
        // 图层已随之重建并隐藏，此处显式复位为双保险——幂等）。
        panel.setScreenThumbnailMode(false)
        publishFrame(panel)
        panel.orderFrontRegardless() // 不夺焦点（nonactivatingPanel）
        isRecordingActive = true
    }

    /// 录制结束（coordinator.finish 调用，幂等；begin 失败回滚同走此路）：收浮窗 +
    /// 停摄像头 + 清拖动锚点（video 队列侧立即回到纯屏幕直通）。
    func endRecording() {
        isRecordingActive = false
        // 断源会话级转发摘除（Task 3，审查 Critical）：只摘控制器侧 camera.onSourceLost——
        // window 侧 onCameraSourceLost 是装配层 init 注入的应用级接线，永不清（误摘则第二
        // 场起投递落空、成片冻结在最后帧）。在途投递吸收闸链见 onCameraSourceLost 缝注释。
        camera.onSourceLost = nil
        camera.previewFramePresenter = nil
        window?.setPreviewOverlayVisible(false)
        window?.updatePreviewOverlayImage(nil)
        frameStore.setScreenRect(nil, screenFrame: .zero, cgDisplayOrigin: .zero)
        frameStore.setGeometry(nil)
        frameStore.setLayoutSwapped(false) // 幂等复位（与 begin 复位互为双保险）
        // 对调态缩略图 contents 清 nil（Ruling 16① 收口）：setScreenThumbnailMode(false)
        // 仅隐藏层不清 contents——最后一张缩略图 CGImage（~230KB）随浮窗跨场滞留，同场
        // 换回（对调 → 换回 → 再对调）还会闪 ≤0.5s 陈旧预览。经既有更新路径清（黑底占位）。
        window?.updateScreenThumbnailImage(nil)
        window?.orderOut(nil)
        fullscreenWindow?.orderOut(nil) // 对调态全屏视图幂等收起（spec §3.3：end 收）
        stopCamera(camera)
    }

    /// 拖动锚点（SCStream video 队列逐帧读取，锁保护）。
    nonisolated func currentPiPFrame() -> PiPFrame? {
        frameStore.currentPiPFrame()
    }

    // MARK: 对调状态桥（spec §3.1：会话级 layoutSwapped 布尔）

    /// 对调画面主入口（浮条按钮经装配层调用）：翻 PiPFrameStore 旗标 + 浮窗内容切换
    ///（**旗标写在前**——video 队列下一帧即按新布局合成；浮窗换装随后，摄像头预览 ↔
    /// 屏幕缩略图层）+ 全屏摄像头视图开收（spec §3.3 二次修订：true 进场盖住浮窗所在屏、
    /// false 换回即收）。window nil（降级纯屏/装配前）时仅旗标生效（无浮窗即无对调现场，
    /// 全屏视图也不开——无所在屏可锚）。
    func setLayoutSwapped(_ swapped: Bool) {
        frameStore.setLayoutSwapped(swapped)
        window?.setScreenThumbnailMode(swapped)
        if swapped {
            showFullscreenCameraPreview()
        } else {
            fullscreenWindow?.orderOut(nil)
        }
    }

    /// 对调进场（主线程）：全屏摄像头视图盖住浮窗所在屏（兜底主屏，spec §3.3 摆位钉定）。
    /// 预览层每次进场重装——跨场 stop→start 后 camera.previewLayer 重建（同一 session
    /// 实例），重装一并重钉镜像与重力，杜绝连接重建后的钉定丢失；每次进场一次，非逐帧
    /// 成本。orderFrontRegardless 不夺焦点（nonactivatingPanel，录制不能被打断）。
    private func showFullscreenCameraPreview() {
        guard let window else { return }
        let fullscreen = ensureFullscreenWindow()
        let screen = window.screen ?? NSScreen.main
        fullscreen.setFrame(screen?.frame ?? window.frame, display: true)
        fullscreen.installPreviewLayer(makeFullscreenPreviewLayer())
        fullscreen.orderFrontRegardless()
    }

    /// 全屏预览层取数：同一 capture session 的新预览实例（camera.previewLayer 只在 lifecycle
    /// 队列写，此处主线程只读 `session` 引用转装新层——不触碰 CameraPiPController 内部）。
    /// 摄像头未启动/无头测试（previewLayer nil）返回 nil = 全屏视图铺黑底（装配不失败）。
    private func makeFullscreenPreviewLayer() -> AVCaptureVideoPreviewLayer? {
        guard let session = camera.previewLayer?.session else { return nil }
        return AVCaptureVideoPreviewLayer(session: session)
    }

    /// 全屏视图懒创建（跨场录制复用）。
    private func ensureFullscreenWindow() -> CameraFullscreenPreviewWindow {
        if let fullscreenWindow { return fullscreenWindow }
        let panel = CameraFullscreenPreviewWindow.makeDefault()
        fullscreenWindow = panel
        return panel
    }

    /// 当前对调态（video 队列可读：`layoutSwappedProvider` 逐帧取数的取数缝）。
    nonisolated var isLayoutSwapped: Bool { frameStore.isLayoutSwapped }

    /// 本场 PiP 会话闸（@MainActor 只读，T5 装配层可见性真源）：begin 成功装配才置位
    ///——cameraOnly/audioOnly/纯屏幕场（含几何缺位/摄像头失败降级）恒 false，对调按钮
    /// 自然不出现，无需另查捕获模式。
    var isPiPRecordingActive: Bool { isRecordingActive }

    /// 对调态屏幕缩略图入口（SCStreamRecorder `screenThumbnailConsumer` 缝，video 队列
    /// 调用，nonisolated）：渲染完成的 CGImage 跳主 actor 贴浮窗缩略图层。window nil
    ///（降级纯屏/场外残余投递）静默丢弃；≤0.5s/张节流在 recorder 侧。
    nonisolated func updateScreenThumbnail(_ cg: CGImage) {
        Task { @MainActor in
            self.window?.updateScreenThumbnailImage(cg)
        }
    }

    // MARK: P5 实时换背景（验收裁定：录制中改动实时生效）

    /// 录制中热切换背景处理器（主线程）：换处理器 + 重接预览覆盖层——installPreviewOverlay
    /// 与 begin 同一句法（presenter 重挂、覆盖层显隐随背景开合）。会话闸 = `isRecordingActive`
    ///：非录制中（含 begin 降级纯屏幕）静默 no-op——初值由 begin 快照链负责，live 链只发
    /// 变化（F2 快照/live 两链并存同语义）。在途帧仍持旧处理器完成并按序号守卫入库：切换
    /// 后 ≤1 帧按旧背景落画，属可接受过渡；帧序守卫在控制器侧，与处理器实例无关。
    func switchBackgroundProcessor(to processor: CameraBackgroundProcessor?) {
        guard isRecordingActive else { return }
        camera.backgroundProcessor = processor
        if let window {
            installPreviewOverlay(window, backgroundProcessor: processor)
        }
    }

    /// 当前生效的背景处理器（internal 只读，无头测试断言热切换落位）。
    var activeBackgroundProcessor: CameraBackgroundProcessor? {
        camera.backgroundProcessor
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

    /// P5 预览跟背景装配（主线程）：背景场把「处理完成 → 渲染镜像小图 → 主线程贴覆盖层」
    /// 的呈现链装机并显示覆盖层；off 场只隐藏覆盖层（原始预览直出，与一期一致）。呈现器
    /// 随呈现缝持有（end 置 nil 即释放——渲染上下文逐场一个，不逐帧）。
    private func installPreviewOverlay(_ panel: CameraPiPWindow,
                                       backgroundProcessor: CameraBackgroundProcessor?) {
        if backgroundProcessor != nil {
            let presenter = PiPPreviewFramePresenter { [weak panel] cg in
                DispatchQueue.main.async { panel?.updatePreviewOverlayImage(cg) }
            }
            camera.previewFramePresenter = { presenter.present($0) }
            panel.setPreviewOverlayVisible(true)
        } else {
            camera.previewFramePresenter = nil
            panel.setPreviewOverlayVisible(false)
        }
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

    /// 预览跟背景覆盖层可见性（internal 只读，测试断言装配/收起）。
    var isPreviewOverlayVisible: Bool { window?.isPreviewOverlayVisible ?? false }

    /// 对调态全屏摄像头视图（internal 只读，无头测试断言开收与窗口纪律：sharingType/
    /// level/frame）。nil = 从未对调进场。
    var fullscreenCameraPreviewWindow: CameraFullscreenPreviewWindow? { fullscreenWindow }

    /// 以真实 setFrame 路径移动浮窗（触发 didMove/didResize 通知 → 拖动锚点全链）。
    func moveWindowForTesting(to frame: NSRect) {
        window?.setFrame(frame, display: true)
    }
}
