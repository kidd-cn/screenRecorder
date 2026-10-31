import AppKit
import Combine
import CoreGraphics
import KeyboardShortcuts
import SwiftUI

/// App 装配容器（修复轮 1 Important #1）：整条有状态装配链（settings / fileStore /
/// coordinator / notifier / controller / 浮条面板）收敛在单个 `@StateObject` 持有的对象里。
/// SwiftUI 不保证 App struct 只 init 一次——若散装为 App 的普通 `let`，重跑 init 会造出
/// 第二个浮条面板（双浮条叠影）与孤儿 coordinator/fileStore（菜单经 #2 取 URL、controller
/// 收尾 #1）。`@StateObject` 保证 wrappedValue 只构造一次并随 App 生命周期存活。
@MainActor
final class AppAssembly: ObservableObject {
    let settings: SettingsStore
    let controller: CaptureController
    /// 输出目录可随偏好设置变更（T17）：值语义结构体按需整只替换（`updateOutputDirectory`
    /// 是唯一换装点，并同步换入控制器）。菜单/快捷键的开始路径在点击时刻读本值，保证
    /// 「改输出目录后新文件落新目录」。
    private(set) var fileStore: RecordingFileStore
    /// 面板自持 controller.$state 订阅驱动显隐；装配层只需持有保活。
    private let floatingBarPanel: FloatingControlBarPanel
    /// 倒计时覆盖层（T12）：同样自持 $state 订阅驱动 show/hide；装配层持有保活
    /// （修复轮 1 装配纪律：有状态/持窗对象一律进本容器）。
    private let countdownOverlay: CountdownOverlayController
    /// 摄像头画中画装配单元（T15，持浮窗 NSPanel + 摄像头控制器，跨场录制复用）：
    /// 所有权进本容器（装配红线）；运行时生命周期由 RecordingSessionCoordinator 的
    /// begin/finish（既有 stop 路径）驱动，启动失败内部降级纯屏幕。
    private let cameraPiP: CameraPiPWindowController
    /// 点击高亮跟踪器（T16）：所有权进本容器（装配红线）；初值取设置快照，enabled 真源
    /// 由 CaptureController 在录制开始时以 config 快照重对齐（外部 defaults 改动自下一场
    /// 录制生效），start/stop 由录制生命周期钩子驱动。
    private let clickHighlightTracker: ClickHighlightTracker
    /// 源丢失监视器（T18）：所有权进本容器（装配红线），命中经 `handleSessionFailure`
    /// 自动保存；start/stop 由录制生命周期钩子驱动（同 tracker 形状）。
    private let sourceLossMonitor: SourceLossMonitor
    /// 麦克风路由观察器（T18）：所有权进本容器（装配红线），命中经 coordinator 转发混音器
    /// 自愈重建（裁定 5，无 UI）；start/stop 由录制生命周期钩子驱动。
    private let microphoneRouteWatcher: MicrophoneRouteWatcher
    /// 边录边标记开关（P2 计划代定）：**会话态，不持久化**——不进 defaults，每场录制开始
    /// 复位为关（避免「上次开着这次忘了」把标记误烧入成片）；画布同步清空，笔画不跨场存活。
    @Published var markingEnabled = false
    /// 标记画布（P2，Task 4）：每场录制 clear()（fresh-per-begin 语义——画布除笔画栈无
    /// 他态，clear 后与新实例等价），装配层持有，覆盖层与工具条共用。
    private let markingCanvas = MarkingCanvas()
    /// 笔画快照桥（P2）：MainActor 画布 → video 队列合成取数缝的锁保护过河（装配层订阅
    /// `$strokes` 灌入，coordinator 经它装配 recorder.strokeOverlayProvider）。
    private let markingStore = MarkingStrokeStore()
    /// 键帽聚合状态机（P4，Task 8）：监听层只写事件；装配层持有（装配红线），UI 可观测。
    private let keyboardOverlayState: KeyboardOverlayState
    /// 键帽快照桥（P4）：MainActor 状态机 → video 队列合成取数缝的锁保护过河
    /// （KeyboardMonitor 是唯一写入方，coordinator 经它装配 recorder.keyboardOverlayProvider）。
    private let keyboardOverlayStore: KeyboardOverlaySnapshotStore
    /// 键盘监听器（P4）：所有权进本容器（装配红线）；enabled 开关以设置快照在每场开录
    /// 重对齐（startRecording），装机/摘除由录制生命周期订阅驱动（$state；recording/paused
    /// 都保持监听——暂停不是生命周期事件，输出侧已有暂停段剔除）。授权判定是 start 内的
    /// 只读预检（缺授权降级仅本地监听，无弹窗）——弹窗只归 PermissionOnboardingView 引导。
    private let keyboardMonitor: KeyboardMonitor
    /// 键盘装配订阅保活（$state 生命周期驱动）。
    private var keyboardCancellables: Set<AnyCancellable> = []
    /// 标记覆盖层控制器（P2）：面板/事件泵/显隐，init 末段装配（闭包捕获 self）。
    private lazy var markingOverlayController = MarkingOverlayController(
        canvas: markingCanvas,
        modeProvider: { [weak self] in self?.settings.lastCaptureMode },
        stateProvider: { [weak self] in self?.controller.state ?? .idle },
        markingEnabledProvider: { [weak self] in self?.markingEnabled ?? false },
        geometryProvider: { [weak self] in self?.markingGeometry })
    /// 标记工具条面板（P2）：浮条宿主同款 nonactivating 面板，init 末段装配。
    private lazy var markingToolbarPanel = MarkingToolbarPanel(
        controller: markingOverlayController,
        barFrameProvider: { [weak self] in
            guard let self, controller.state == .recording || controller.state == .paused else { return nil }
            return floatingBarPanel.screenFrame
        },
        onClose: { [weak self] in self?.setMarkingEnabled(false) })
    /// 覆盖层坐标换算用的当次采集几何（P2）：标记开启时刻现场解析（模式随场变、窗口可
    /// 跨屏移动，现场解析最准）；解析未落地前覆盖层已可见，换算 nil 丢弃极早期点。
    private var markingGeometry: PiPCaptureGeometry?
    /// 几何解析去重闸：一次开启期至多解析一次（disable 复位，re-enable 再解析）。
    private var needsMarkingGeometryResolve = false
    /// 标记装配订阅保活（$strokes 灌桥 / state×开关显隐重估）。
    private var markingCancellables: Set<AnyCancellable> = []
    /// 偏好设置窗口控制器（T17）：窗口与控制器归装配容器（装配红线），懒建单例复用。
    private var preferencesWindowController: NSWindowController?
    /// 文件列表窗口控制器（T18）：窗口与控制器归装配容器（装配红线），懒建单例复用；
    /// 列表模型经 store 取数缝读当前 `fileStore`（换输出目录后刷新即见新目录）。
    private var recordingListWindowController: NSWindowController?

    /// 全局快捷键已挂载的进程级闸（T17 裁定 4）：KeyboardShortcuts 的 onKeyUp 把动作
    /// 追加进包内静态注册表，重挂（assembly init 重跑）会双触发——挂载恰好一次。
    private static var globalShortcutsMounted = false
    /// 终审 F2：麦克风设置 live 下发链的订阅保活（与容器同寿）。快照链（开始时刻读
    /// config）与 live 链并存：初值由快照负责，live 只发变化。
    private var liveMicCancellables: Set<AnyCancellable> = []
    /// 开机自启装配单元（P6a）：所有权进本容器（装配红线）。开关变化经其内部 Combine
    /// sink 消费（接线裁定：副作用不进 SettingsStore didSet——sink 内的失败回翻若改走
    /// didSet 接线即自赋值重入；sink 侧重入护栏闩见 LaunchAtLoginCoordinator），失败回翻
    /// + 通知都收在该单元。
    private let launchAtLoginCoordinator: LaunchAtLoginCoordinator

    init() {
        let settings = SettingsStore()
        let fileStore = RecordingFileStore(baseDirectory: settings.outputDirectory)
        let cameraPiP = CameraPiPWindowController()
        let clickHighlightTracker = ClickHighlightTracker(enabled: settings.clickHighlightEnabled)
        // P4 键帽链：状态机 + 快照桥 + 监听器（样式/停留时长是 live 语义——provider 逐拍
        // 读当前设置，偏好改动即时生效；enabled 初值取设置快照，开录由 startRecording 重对齐）。
        let keyboardOverlayState = KeyboardOverlayState()
        let keyboardOverlayStore = KeyboardOverlaySnapshotStore()
        let keyboardMonitor = KeyboardMonitor(
            state: keyboardOverlayState,
            store: keyboardOverlayStore,
            enabled: settings.keyboardOverlayEnabled,
            // live 读缝强捕获 settings 局部量（两段式初始化：此处 self 尚未构造完成，
            // 不得捕获 self；settings 单例与容器同寿，闭包持之无环）。
            styleProvider: {
                KeyboardOverlayStyle(
                    colorAlternate: settings.keyboardOverlayColorIsAlternate,
                    fontSize: settings.keyboardOverlayFontSize)
            },
            lingerProvider: { settings.keyboardOverlayLingerSeconds })
        let coordinator = RecordingSessionCoordinator(
            cameraPiP: cameraPiP,
            clickHighlightTracker: clickHighlightTracker,
            strokeSnapshotProvider: markingStore.currentSnapshot,
            keyboardSnapshotProvider: keyboardOverlayStore.currentSnapshot)
        let notifier = UNRecordingNotifier()
        let controller = CaptureController(
            session: coordinator,
            store: fileStore,
            countdownSeconds: settings.countdownSeconds,
            onFinishedFile: { url in
                Task { @MainActor in notifier.notifySaved(fileURL: url) }
            }
        )
        controller.notifier = notifier
        // 点击高亮跟踪器（T16）：装配层持有，控制器按录制生命周期驱动（见 CaptureController 边界 8）
        controller.clickHighlightTracker = clickHighlightTracker
        // 源丢失监视器（T18）：命中 → 失败通道自动保存（onSourceLost 主线程保证，闭包内跳
        // 主 actor；「录制已自动保存」通知由 handleSessionFailure 的收尾路径发出）。
        // brief 回调签名无 payload（`onSourceLost: () -> Void`），断连 displayID 不透传。
        // P3a：按当前模式归类文案——App 模式为「窗口全部关闭」，其余为显示器断连
        //（startRecording 先持久化 lastCaptureMode，录制期间读它即当次模式）。
        let sourceLossMonitor = SourceLossMonitor { [weak controller] in
            Task { @MainActor in
                if case .app(let bundleID) = settings.lastCaptureMode {
                    controller?.handleSessionFailure(AppSourceLostError(bundleID: bundleID))
                } else {
                    controller?.handleSessionFailure(SourceLossError(removedDisplayID: nil))
                }
            }
        }
        controller.sourceLossMonitor = sourceLossMonitor
        // 麦克风路由观察器（T18）：命中 → coordinator 转发当前混音器自愈重建（主队列保证，
        // 见 MicrophoneRouteWatcher 裁定 4 注释）。
        let microphoneRouteWatcher = MicrophoneRouteWatcher { [weak coordinator] in
            coordinator?.rebuildAudioRoute()
        }
        controller.microphoneRouteWatcher = microphoneRouteWatcher
        // 磁盘监控 / 流失败出口 → 状态机（DiskSpaceMonitor 与 onStreamFailure 均主队列保证）。
        // 终审 F4（保留环）：两闭包改 [weak controller]（与同文件 SourceLossMonitor /
        // CountdownOverlayController 闭包同风格）——coordinator 经 controller.session 被控制器
        // 强持有，闭包再强持控制器即成环，两者同寿但永不释放。
        coordinator.onInterruption = { [weak controller] error in
            Task { @MainActor in controller?.handleSessionFailure(error) }
        }
        coordinator.onDiskSpaceWarning = { [weak controller] in
            Task { @MainActor in controller?.showDiskSpaceWarning() }
        }

        // P6a 开机自启：装配单元在两段式初始化内构造（self 尚不可用，只捕局部量），
        // sink 消费开关变化（重入护栏在 coordinator 内）；失败通知走 UNRecordingNotifier
        // → UNUserNotificationCenter（请求授权被拒/失败静默跳过，不弹窗）。闭包强捕获
        // notifier 局部量（controller.onFinishedFile 同款，与容器同寿，无环）；设置赋值
        // 都在主线程，sink 同步消费无需队列跳转。
        let launchAtLoginCoordinator = LaunchAtLoginCoordinator(
            settings: settings,
            service: SMAppLoginItemService(),
            onRegistrationFailure: { message in
                notifier.notifyLaunchAtLoginFailure(message: message)
            })
        self.settings = settings
        self.controller = controller
        self.fileStore = fileStore
        self.sourceLossMonitor = sourceLossMonitor
        self.microphoneRouteWatcher = microphoneRouteWatcher
        self.launchAtLoginCoordinator = launchAtLoginCoordinator
        self.floatingBarPanel = FloatingControlBarPanel(controller: controller)
        // PiP 拖动锚点（T15）：浮窗初始摆放避让浮条（浮条 frame 单向喂数，无反向依赖）
        cameraPiP.controlBarFrameProvider = { [weak floatingBarPanel] in
            floatingBarPanel.map { $0.screenFrame }
        }
        // 倒计时覆盖层：ESC/点击出口接 cancelAndDiscard（回 idle 且不 begin）——覆盖层不自行改状态，
        // hide 由状态离开 .countdown 收束。
        self.countdownOverlay = CountdownOverlayController(
            controller: controller,
            onCancelAction: { [weak controller] in
                Task { @MainActor in controller?.cancelAndDiscard() }
            }
        )
        self.cameraPiP = cameraPiP
        self.clickHighlightTracker = clickHighlightTracker
        self.keyboardOverlayState = keyboardOverlayState
        self.keyboardOverlayStore = keyboardOverlayStore
        self.keyboardMonitor = keyboardMonitor
        // P4 键盘监听生命周期（record-only，与 ClickHighlightTracker start/stop 对称）：
        // recording/paused 装机、其余态摘除。@Published 在 willSet 阶段同步发射：进入
        // .recording 的 start() 发生在 begin 完成、流未出帧之前——键帽自首帧可用；离开
        // 录制的 stop() 清状态机（残影防御：收尾前最后一击不得淡入下一场开头）。
        controller.$state
            .sink { state in
                if state == .recording || state == .paused {
                    keyboardMonitor.start()
                } else {
                    keyboardMonitor.stop()
                }
            }
            .store(in: &keyboardCancellables)
        // 终审 F1：装配容器向退出保护登记（弱引用——容器由 App 的 @StateObject 强持有，
        // AppDelegate 不得反向持强）。登记时序与装配单例的论证见 AppDelegate.registeredAssembly。
        AppDelegate.registeredAssembly = self
        // 终审 F2：麦克风设置 live 下发（录制中改动即时生效；无活动会话时 coordinator 侧
        // recorder 缺位 → no-op）。receive(on: main) 把 tap 手术收敛到主队列（与
        // MicrophoneRouteWatcher 主队列跳转同一纪律）。注意 mic 是 live 语义，勿与
        // pipEnabled 的「下一场快照」链混用——两条链在此并存。
        settings.$micMuted
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak coordinator] muted in coordinator?.setMicMuted(muted) }
            .store(in: &liveMicCancellables)
        settings.$micVolume
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak coordinator] volume in coordinator?.setMicVolume(Float(volume)) }
            .store(in: &liveMicCancellables)
        mountMarkingIfNeeded()
        mountGlobalShortcutsIfNeeded()
    }

    // MARK: 录制入口（T17：菜单与全局快捷键共用，配置装配单点化）

    /// 菜单「开始录制 → 全屏」入口（T19）：按用户在显示器列表子菜单里选的显示器全屏开录。
    func startDisplayRecording(on displayID: CGDirectDisplayID) {
        startRecording(mode: .display(displayID))
    }

    /// 菜单「开始录制 → 区域…」入口（T19）：RegionSelector 拖拽选区后按 `.region` 开录。
    /// 选区交互（遮罩/拖拽/ESC 取消/点击无拖动按取消）全部归 T12 `RegionSelector`，此处只
    /// 做目标屏裁决与开录：遮罩落在**当前鼠标所在的显示器**（用户把指针挪到哪块屏就能在哪块
    /// 屏上拖框，多屏场景无需额外选屏步骤），取不到时回退主显示器。返回 nil（ESC/误触取消/
    /// 目标屏不在位）→ 静默放弃，状态机未进入过倒计时/录制。
    func startRegionRecording() {
        Task { @MainActor in
            // 菜单项已按状态置灰，此 guard 兜非菜单路径：选区遮罩不得在录制中途弹出。
            guard controller.state == .idle else {
                NSLog("RegionMenu: 忽略区域录制入口（当前状态非 idle：\(controller.state)）")
                return
            }
            let displayID = Self.regionAnchorDisplayID() ?? CGMainDisplayID()
            guard let rect = await RegionSelector.selectRegion(on: displayID) else { return }
            startRecording(mode: .region(rect: rect, displayID: displayID))
        }
    }

    /// 区域选择的目标屏裁决：包含当前鼠标位置的显示器（Cocoa 全局坐标命中 `NSScreen.frame`）。
    private static func regionAnchorDisplayID() -> CGDirectDisplayID? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) }.flatMap { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }
    }

    /// 唯一的开始装配点：持久化「上次使用的模式」（裁定 2：每次开始都记）→ 建输出目录 →
    /// 从 SettingsStore 快照装配 config → 进入控制器状态机（快照语义：录制中途改设置
    /// 不影响进行中的录制）。控制器自守卫（非 `.idle` 一律 no-op），此处不重复判态。
    private func startRecording(mode: CaptureMode) {
        settings.lastCaptureMode = mode
        // 标记会话态复位（计划钉定「每次录制重新开关」——非持久化、跨录制不保留）：
        // 关闭开关（显隐订阅随之收起覆盖层/工具条）+ 画布清空（新录制从空白开始，
        // 笔画不跨录制留存）+ 几何缓存失效（下次开启时现场重解析）。
        setMarkingEnabled(false)
        markingCanvas.clear()
        markingGeometry = nil
        // P4 键帽 enabled 快照语义：开录时刻以设置重对齐（录制中途改设置不影响本场；
        // 与 clickHighlightEnabled 同纪律）。装机由 $state 订阅在进入 recording 时驱动，
        // 此处只对齐开关（监听中翻 false 立即摘除，KeyboardMonitor.setEnabled 自理）。
        keyboardMonitor.setEnabled(settings.keyboardOverlayEnabled)
        try? fileStore.ensureDirectory()
        let config = Self.makeConfiguration(
            settings: settings,
            mode: mode,
            outputURL: fileStore.nextFileURL())
        Task { await controller.start(mode: mode, config: config) }
    }

    /// 开始时刻的 config 快照（唯一装配点的纯函数抽取，internal 供无头钉测）：从
    /// SettingsStore 逐字段入照。终审 F2 复审残余：`micMuted` 必须随快照入照——
    /// registerMicrophone 据此决定开录是否预装 mic tap，漏带则持久化静音被每场开录
    /// 静默忽略（live 下发链只覆盖录制中的翻转，兜不了开录初值）。P1b：点击音效开关
    /// 同为快照字段（开录时刻入照，录制中途改设置不影响进行中的录制）。P5：摄像头背景
    /// 同为快照字段（coordinator.begin 据此装配背景处理器，off = 帧路径零开销旁路）。
    static func makeConfiguration(settings: SettingsStore, mode: CaptureMode, outputURL: URL) -> RecordingConfiguration {
        RecordingConfiguration(
            mode: mode,
            captureSystemAudio: settings.captureSystemAudio,
            captureMicrophone: settings.captureMicrophone,
            micVolume: settings.micVolume,
            micMuted: settings.micMuted,
            includeCamera: settings.pipEnabled,
            cameraBackground: settings.cameraBackground, // P5：开录快照（下一场录制生效）
            fps: settings.fps,
            codec: settings.videoCodec,
            outputURL: outputURL,
            clickHighlightEnabled: settings.clickHighlightEnabled,
            autoZoomEnabled: settings.autoZoomEnabled,
            autoZoomLevel: settings.autoZoomLevel,
            clickSoundEnabled: settings.clickSoundEnabled
        )
    }

    /// ⇧⌘R 开关（裁定 2）：idle/倒计时 → 按上次使用的模式开始；录制/暂停 → 停止；
    /// `.finishing` 是控制器去抖闸位，忽略。
    func toggleStartStopRecording() {
        switch controller.state {
        case .recording, .paused:
            controller.stop()
        case .idle, .countdown:
            // 倒计时态：controller.start 自守卫为定义好的 no-op——此处不取消/不重启倒计时（取消走覆盖层 ESC/点击）
            startRecording(mode: settings.lastCaptureMode)
        case .finishing:
            break
        }
    }

    /// ⇧⌘P 开关（裁定 2）：录制中 → 暂停，暂停中 → 恢复；其余状态 no-op（控制器自守卫）。
    func togglePauseResumeRecording() {
        switch controller.state {
        case .recording:
            controller.pause()
        case .paused:
            controller.resume()
        case .idle, .countdown, .finishing:
            break
        }
    }

    /// 偏好设置改输出目录（T17 验收）：settings 真源更新 + 换装 fileStore + 同步换入
    /// 控制器 store（此后 discard 删除作用于新目录成片）。
    func updateOutputDirectory(to url: URL) {
        settings.outputDirectory = url
        let newStore = RecordingFileStore(baseDirectory: url)
        fileStore = newStore
        controller.updateStore(newStore)
    }

    // MARK: 偏好设置窗口

    /// 打开偏好设置窗口（菜单「偏好设置…」入口）：懒建单实例、复用；LSUIElement 应用
    /// 需激活再前置，避免窗口落在其他应用后面。
    func openPreferences() {
        if preferencesWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "偏好设置"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: PreferencesView(
                settings: settings,
                onOutputDirectoryChange: { [weak self] url in
                    self?.updateOutputDirectory(to: url)
                },
                onPickWindowTarget: { [weak self] in
                    // 偏好设置入口：选定只持久化、不开录（简报「选定持久化；取消不动现有值」）
                    self?.openWindowPicker(startsRecordingOnSelection: false)
                }
            ))
            window.center()
            preferencesWindowController = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        preferencesWindowController?.showWindow(nil)
        preferencesWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    /// 打开文件列表窗口（菜单「文件列表…」入口，T18）：懒建单实例复用（窗口关闭仅隐藏，
    /// `isReleasedWhenClosed = false`）。列表模型经 store 取数缝读当前 `fileStore`——
    /// 懒建时捕获装配容器弱引用，`updateOutputDirectory` 换装后刷新即见新目录（T17 审查
    /// 发现的固定拷贝缺陷在此封堵）。刷新通道（审查修复轮 1）：首开 `.task` + 复用窗口
    /// 每次激活即刷新（didBecomeKeyNotification，见 `RecordingListWindowController`）。
    /// LSUIElement 应用需激活再前置（同偏好设置窗口）。
    func openRecordingList() {
        if recordingListWindowController == nil {
            let viewModel = RecordingListViewModel(storeProvider: { [weak self] in
                // 装配容器与 App 同生命周期；nil 仅在容器已释放的理论窗口出现，退避临时目录
                self?.fileStore ?? RecordingFileStore(baseDirectory: FileManager.default.temporaryDirectory)
            })
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "文件列表"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: RecordingListView(viewModel: viewModel))
            window.center()
            recordingListWindowController = RecordingListWindowController(window: window, viewModel: viewModel)
        }
        NSApp.activate(ignoringOtherApps: true)
        recordingListWindowController?.showWindow(nil)
        recordingListWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    /// 全局快捷键订阅（⇧⌘R / ⇧⌘P / ⇧⌘W / ⇧⌘M）：App 启动（装配）时挂载恰好一次。动作经主 actor
    /// 跳转进入装配层开关方法；包内 `onKeyUp` 把动作追加进静态注册表（无需持有返回值），
    /// 故以 `globalShortcutsMounted` 进程级闸防重挂双触发（裁定 4，T17 一次挂载门沿用）。
    private func mountGlobalShortcutsIfNeeded() {
        guard !Self.globalShortcutsMounted else { return }
        Self.globalShortcutsMounted = true
        KeyboardShortcuts.onKeyUp(for: .startStopRecording) { [weak self] in
            Task { @MainActor in self?.toggleStartStopRecording() }
        }
        KeyboardShortcuts.onKeyUp(for: .pauseResumeRecording) { [weak self] in
            Task { @MainActor in self?.togglePauseResumeRecording() }
        }
        KeyboardShortcuts.onKeyUp(for: .startWindowRecording) { [weak self] in
            Task { @MainActor in self?.startWindowRecordingShortcut() }
        }
        KeyboardShortcuts.onKeyUp(for: .toggleMarkingTools) { [weak self] in
            Task { @MainActor in self?.toggleMarkingTools() }
        }
    }

    // MARK: 边录边标记装配与开关（P2）

    /// 标记链路装配（init 末段调用一次；lazy 面板在首次访问时构造）：画布→快照桥灌入、
    /// 显隐重估订阅（state × 开关任一变化）、浮条画笔按钮接线、点击系抑制缝。
    private func mountMarkingIfNeeded() {
        // 画布笔画 → 快照桥：装配层唯一的灌入点（video 队列经锁保护读，零分配过河）。
        markingCanvas.$strokes
            .sink { [weak self] strokes in
                self?.markingStore.update(MarkingStrokeSnapshot(strokes: strokes))
            }
            .store(in: &markingCancellables)
        // 显隐重估（显隐条件：markingEnabled && recording/paused，见 MarkingOverlayController）：
        // 覆盖层拉取式重估 + 工具条显隐 + 开启时刻的几何现场解析。
        Publishers.CombineLatest(controller.$state, $markingEnabled)
            .dropFirst()
            .sink { [weak self] state, enabled in
                self?.refreshMarkingSurfaces(state: state, enabled: enabled)
            }
            .store(in: &markingCancellables)
        // 浮条画笔按钮（录制/暂停态工具条与浮条并存——按钮在浮条上）。
        floatingBarPanel.attachMarkingToggle(
            provider: { [weak self] in self?.markingEnabled ?? false },
            toggle: { [weak self] in self?.toggleMarkingTools() })
        // 点击系抑制（spec §5 P2：绘图拖拽不得触发点击高亮/缩放/音效）。调查结论（钉进
        // 代码注释与验收清单）：标记面板是本 App 自己的窗口，其按下事件不达 tracker 的
        // **全局** monitor（计划钉定假设成立）；但**本地** monitor 收得到本 App 窗口的
        // mouseDown——按窗口 identifier 显式过滤（覆盖层与工具条一并抑制）。
        clickHighlightTracker.isLocalClickSuppressed = { event in
            let identifier = event.window?.identifier
            return identifier == MarkingOverlayController.overlayWindowIdentifier
                || identifier == MarkingToolbarPanel.panelWindowIdentifier
        }
    }

    /// 标记显隐面重估（state / markingEnabled 任一变化时；含几何解析去重闸）。全部显隐/
    /// 换装判定只消费 CombineLatest 的**发射值**——sink 在 @Published willSet 阶段同步
    /// 执行，此刻属性与 provider 回拉都是旧值（T5 修复轮2 Critical 1），一处都不回拉。
    private func refreshMarkingSurfaces(state: CaptureState, enabled: Bool) {
        markingOverlayController.refreshVisibility(enabled: enabled, state: state)
        markingToolbarPanel.setVisible(enabled && (state == .recording || state == .paused))
        // 画笔按钮换装（发射值直传，修复轮2 Important 2：不并刷则图标/help/a11y 冻结在
        // attach 时刻的初态）。
        floatingBarPanel.refreshMarkingToggle(enabled: enabled)
        // 开启时刻现场解析采集几何（覆盖层换算用）；disable 复位闸，re-enable 再解析。
        if enabled {
            if state == .recording || state == .paused,
               !needsMarkingGeometryResolve, markingGeometry == nil {
                needsMarkingGeometryResolve = true
                resolveMarkingGeometry()
            }
        } else {
            needsMarkingGeometryResolve = false
        }
    }

    /// 现场解析标记几何（主 actor Task 内 await；失败留在 nil = 换算丢弃全部点，
    /// 与点击系「几何失败降级纯屏幕」同一降级精神）。
    private func resolveMarkingGeometry() {
        let mode = settings.lastCaptureMode
        Task { [weak self] in
            let geometry = await PiPCaptureGeometry.resolve(for: mode)
            self?.markingGeometry = geometry
        }
    }

    /// 标记开关唯一写入口（画笔按钮 / ⇧⌘M / 工具条关闭共用）；显隐重估在订阅里统一走。
    func setMarkingEnabled(_ enabled: Bool) {
        guard markingEnabled != enabled else { return }
        markingEnabled = enabled
    }

    /// ⇧⌘M 开关（Task 5）：录制/暂停中切换标记工具；其余状态 no-op（覆盖层只在录制期
    /// 存在——同 ⇧⌘W 的自守卫纪律）。
    func toggleMarkingTools() {
        switch controller.state {
        case .recording, .paused:
            setMarkingEnabled(!markingEnabled)
        case .idle, .countdown, .finishing:
            NSLog("MarkingShortcut: 忽略 ⇧⌘M（当前状态非录制/暂停：\(controller.state)）")
        }
    }

    // MARK: 窗口捕获（T20：⇧⌘W + 选择器接线，T14 WindowPicker 组件接入）

    /// 窗口选择器窗口控制器：窗口归装配容器（装配红线），懒建单实例复用。每次打开重建
    /// 内容视图——候选列表随之重新枚举（复用窗口不重触发 `.task`，同 T18 文件列表的
    /// 教训），失效提示横幅按打开场景注入。
    private var windowPickerWindowController: NSWindowController?
    /// 本次打开的选择器「选定后是否立即开录」：⇧⌘W 路径 true（选定即持久化并开始，简报
    /// 行为规格 1/2）；偏好设置「选择窗口…」路径 false（只持久化）。onSelect 闭包捕获容器
    /// 弱引用，在选定时刻读取本标记（同一次打开内确定）。**旗标对纪律（P3b 修复轮 1）**：
    /// 本标记与 `pendingWindowPickerAnchorsRegion` 构成互斥旗标对，每个入口点必须整体换装
    ///（先清对另一枚，再置自己那一枚）——选择器的取消路径是直接关窗（无回调），旗标残留
    /// 不可避免；下一次打开自愈的前提是入口点不遗漏整装。选定回调与 `dismissWindowPicker`
    /// 成对清除是第二道防线。
    private var pendingWindowPickerStartsRecording = false
    /// 本次打开的选择器是否为「窗口区域」入口（P3b）：选定后不直接开录，改为窗口内拖框
    ///（窗口相对 rect）再按 `.windowRegion` 开录。与 startsRecording 互斥（区域路径不写
    /// `windowCaptureTarget`——它的持久化是 `startRecording` 里的 `lastCaptureMode`）。
    /// 旗标对纪律见上（入口点整体换装，取消路径残留自愈）。
    private var pendingWindowPickerAnchorsRegion = false

    /// 打开窗口选择器（⇧⌘W 无目标/失效兜底，或偏好设置「选择窗口…」入口）。`showsStaleNotice`
    /// 为 true 时在列表上方显示「上次选择的窗口不可用，请重新选择」（简报行为规格 2 的用户
    /// 通知——与选择器同窗呈现，用户正位于操作现场，比系统通知更直接）。取消路径 = 直接
    /// 关窗，不经选定回调，既有目标不动（简报行为规格 3）。
    func openWindowPicker(startsRecordingOnSelection: Bool, showsStaleNotice: Bool = false) {
        // 旗标对整体换装（修复轮 1）：取消关窗残留的区域锚定旗标在此自愈，防后续选定
        // 被劫持进窗口区域流程（同 startWindowRegionRecording / openAppPicker）。
        pendingWindowPickerAnchorsRegion = false
        pendingWindowPickerStartsRecording = startsRecordingOnSelection
        presentPicker(
            scope: .windows,
            bannerText: showsStaleNotice ? "上次选择的窗口不可用，请重新选择" : nil)
    }

    /// 菜单「开始录制 → App…」入口（P3a）：App 范围的选择器，选定 bundleID 即开始录制
    ///（「选定即开始」语义与「窗口…」一致；复用同一窗口与 idle 预检/成对收起纪律）。
    func openAppPicker() {
        // 旗标对整体换装（修复轮 1，同 openWindowPicker）。
        pendingWindowPickerAnchorsRegion = false
        pendingWindowPickerStartsRecording = true
        presentPicker(scope: .apps, bannerText: nil)
    }

    /// 菜单「开始录制 → 窗口区域…」入口（P3b）：先开窗口选择器（窗口范围），选定后在所选
    /// 窗口内拖框，按所选窗口 + 窗口相对 rect 开录。idle 预检/成对收起纪律与「窗口…」一致
    ///（菜单项已按状态置灰，选定回调另有同款守卫）。
    func startWindowRegionRecording() {
        // 旗标对整体换装（修复轮 1，同 openWindowPicker）：清掉可能残留的直录旗标——
        // 否则区域取消后改走「窗口…」选定会先命中区域分支（残留劫持，审阅 Important 1）。
        pendingWindowPickerStartsRecording = false
        pendingWindowPickerAnchorsRegion = true
        presentPicker(scope: .windows, bannerText: nil)
    }

    /// 选择器呈现的共同出口（P3a 从 openWindowPicker 抽取）：窗口归装配容器（装配红线），
    /// 懒建单实例复用，每次打开重建内容视图（复用窗口不重触发 `.task`，同 T18 文件列表的
    /// 教训；`scope` 决定初始范围，重建同时换窗口标题）。
    private func presentPicker(scope: WindowPickerView.Scope, bannerText: String?) {
        if windowPickerWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.center()
            windowPickerWindowController = NSWindowController(window: window)
        }
        windowPickerWindowController?.window?.title = scope == .apps ? "选择 App" : "选择窗口"
        windowPickerWindowController?.window?.contentView = NSHostingView(rootView: WindowPickerHostView(
            scope: scope,
            bannerText: bannerText,
            onSelect: { [weak self] windowID in self?.windowPickerSelected(windowID) },
            onAppSelect: { [weak self] bundleID in self?.appPickerSelected(bundleID) }
        ))
        NSApp.activate(ignoringOtherApps: true)
        windowPickerWindowController?.showWindow(nil)
        windowPickerWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    /// App 选定回调（P3a，`WindowPickerView` App 行双击触发）：idle 预检（同窗口选定纪律，
    /// 非 idle 拒绝并成对收起）→ 开录 `.app(bundleID)`。持久化走 `startRecording` 的统一
    /// 入口——`lastCaptureMode` 随之记为 App 模式，⇧⌘R 上次使用模式自动包含。
    private func appPickerSelected(_ bundleID: String) {
        guard controller.state == .idle else {
            NSLog("WindowPicker: 忽略选定 App \(bundleID)（当前状态非 idle：\(controller.state)）")
            dismissWindowPicker()
            return
        }
        let startsRecording = pendingWindowPickerStartsRecording
        dismissWindowPicker()
        NSLog("WindowPicker: 已选定 App 捕获目标（\(bundleID)）")
        if startsRecording {
            startRecording(mode: .app(bundleID: bundleID))
        }
    }

    /// 选定回调（主 actor，`WindowPickerView` 双击触发）：关窗 → 单窗所有者快照组装稳定
    /// 标识（裁定 1：PID → bundle id，ownerName 兜底）→ 持久化 → 按打开场景决定是否立即
    /// 开始（⇧⌘W 路径 `.window` 随之成为上次使用模式，同 ⇧⌘R 惯例）。P3b「窗口区域」入口
    /// 在持久化之前分流：选定后转窗口内拖框（`beginWindowRegionSelection`），不写
    /// `windowCaptureTarget`。快照/标识取不到（选中间隙窗口关闭）记日志后放弃：不持久化、
    /// 不开录（死 windowID 开录必败）。审查修复轮 1：非 `.idle`（录制/倒计时/收尾中）整体
    /// 拒绝——即使未来出现绕过 idle 预检的路径，也不允许选定动作在录制中途覆写
    /// `windowCaptureTarget`。
    private func windowPickerSelected(_ windowID: CGWindowID) {
        guard controller.state == .idle else {
            NSLog("WindowPicker: 忽略选定窗口 \(windowID)（当前状态非 idle：\(controller.state)），不覆写捕获目标")
            // T20 停放项（终审裁量批准折入 T19）：拒绝路径同样收起选择器并清标记——滞留的
            // 失效列表无事可做，残留 true 标记还可能污染下一次打开（成对纪律见 dismissWindowPicker）。
            dismissWindowPicker()
            return
        }
        let anchorsRegion = pendingWindowPickerAnchorsRegion
        let startsRecording = pendingWindowPickerStartsRecording
        dismissWindowPicker()
        if anchorsRegion {
            beginWindowRegionSelection(windowID: windowID)
            return
        }
        guard let snapshot = WindowTargetResolver.windowOwnerSnapshot(windowID: windowID),
              let target = WindowTargetResolver.makeTarget(windowID: windowID, snapshot: snapshot) else {
            NSLog("WindowPicker: 选定窗口 \(windowID) 的所有者信息读取失败（可能已关闭），未持久化目标")
            return
        }
        settings.windowCaptureTarget = target
        NSLog("WindowPicker: 已持久化窗口捕获目标（\(target.ownerAppIdentifier) — \(target.windowTitle)）")
        if startsRecording {
            startRecording(mode: .window(windowID))
        }
    }

    /// 窗口内拖框（P3b）：现场解析所选窗口的当前 frame（选中间隙已关/已最小化不可见 →
    /// 记日志放弃——死 windowID 开录必败，同 windowPickerSelected 纪律）→ 遮罩锚定该窗口
    /// → 拖拽产出窗口相对 rect → 开录 `.windowRegion`。ESC / 亚点拖动 / 遮罩中途被关 =
    /// 取消，静默放弃不开录（同区域录制取消语义）。持久化走 startRecording 统一入口
    ///（`lastCaptureMode` 随之记为 windowRegion，⇧⌘R 上次使用模式自动包含）。
    private func beginWindowRegionSelection(windowID: CGWindowID) {
        Task { @MainActor in
            let windows: [ShareableWindow]
            do {
                windows = try await WindowPicker.enumeratedWindows()
            } catch {
                NSLog("WindowRegion: 窗口枚举失败，放弃窗口区域选择：\(error)")
                return
            }
            guard let frame = windows.first(where: { $0.windowID == windowID })?.frame else {
                NSLog("WindowRegion: 所选窗口 \(windowID) 已不可见或已关闭，放弃窗口区域选择")
                return
            }
            // SCWindow.frame 为 CG 全局（左上原点）→ 遮罩 NSWindow 需 Cocoa 全局 frame
            //（主屏高翻 Y；多屏通用——两全局系共享主屏原点，同 ClickHighlightTracker 口径）。
            let primaryHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height ?? 0
            let cocoaFrame = RegionSelectorMath.cocoaRect(fromCGRect: frame, primaryScreenHeight: primaryHeight)
            guard let rect = await RegionSelector.selectWindowRegion(anchorFrame: cocoaFrame) else { return }
            startRecording(mode: .windowRegion(window: windowID, rect: rect))
        }
    }

    /// 收起残留的选择器窗口并清「选定即开录」标记（审查修复轮 1）：两个动作必须成对——
    /// 只收窗不清标记，窗口重建前的旧 onSelect 仍会带 true；只清标记不收窗，用户会在
    /// 已失效的列表里二次选定。直录分支（`.start`）与选定回调共用。P3b 起同清区域锚定
    /// 标记（同款成对纪律）。
    private func dismissWindowPicker() {
        pendingWindowPickerStartsRecording = false
        pendingWindowPickerAnchorsRegion = false
        windowPickerWindowController?.window?.orderOut(nil)
    }

    /// ⇧⌘W（简报行为规格 1-3）：非 `.idle` 一律 no-op（同 ⇧⌘R/P 的控制器自守卫纪律——
    /// 选择器/提示不该在录制中途弹出）。现场枚举 → 三分支决策（裁定 5 纯函数，装配层只做
    /// 执行）：命中直接开录该窗口；无目标开选择器；失效先提示再开选择器。枚举失败（权限
    /// 失效/枚举错）同样退选择器——错误文案与重试由选择器内呈现（T14 失败 UI）。
    func startWindowRecordingShortcut() {
        guard controller.state == .idle else {
            NSLog("WindowShortcut: 忽略 ⇧⌘W（当前状态非 idle：\(controller.state)）")
            return
        }
        Task { @MainActor in
            let windows: [ShareableWindow]
            do {
                windows = try await WindowPicker.enumeratedWindows()
            } catch {
                NSLog("WindowShortcut: ⇧⌘W 窗口枚举失败，退回选择器呈现错误：\(error)")
                openWindowPicker(startsRecordingOnSelection: true)
                return
            }
            switch WindowStartDecision.resolve(target: settings.windowCaptureTarget, candidates: windows) {
            case .start(let windowID):
                // 审查修复轮 1：直录前收起可能残留的选择器（此前停留的失效列表 frontmost、
                // 标记仍 true，录制开始后二次选定会空开录一次并覆写目标）。
                dismissWindowPicker()
                startRecording(mode: .window(windowID))
            case .openPicker:
                openWindowPicker(startsRecordingOnSelection: true)
            case .staleNotifyThenPicker:
                NSLog("WindowShortcut: 已存窗口目标现场解析不命中（已关/改名），转选择器重选")
                openWindowPicker(startsRecordingOnSelection: true, showsStaleNotice: true)
            }
        }
    }
}

/// 窗口选择器宿主（T20）：T14 `WindowPickerView` + 可选的失效提示横幅。不改选择器的
/// 选择回调语义（`onSelect`/`onAppSelect` 原样透传，P3a 增 App 范围与初始范围注入）；
/// 横幅仅由装配层按打开场景注入（⇧⌘W 失效重选）。
private struct WindowPickerHostView: View {
    let scope: WindowPickerView.Scope
    let bannerText: String?
    let onSelect: (CGWindowID) -> Void
    let onAppSelect: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let bannerText {
                Label(bannerText, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
            }
            WindowPickerView(
                onSelect: onSelect,
                onAppSelect: onAppSelect,
                initialScope: scope)
        }
    }
}

/// 文件列表窗口控制器（审查修复轮 1 #1）：复用窗口（`isReleasedWhenClosed = false`）使
/// SwiftUI `.task` 只在窗口生命周期首帧执行——关闭后再前置（makeKeyAndOrderFront）不会
/// 重触发；以窗口 `didBecomeKeyNotification`（仅本窗口为 object，主队列投递）补「每次
/// 激活即刷新」，与视图内 `.task` 首开刷新及内容区底部刷新栏互补（首次激活与 `.task`
/// 各刷一次，refresh 幂等无害）。通知观察者形状与 MicrophoneRouteWatcher 一致
///（NSWindowController 对 NSWindowDelegate 可选要求的 Swift 隔离桥接在此工具链不可用）。
private final class RecordingListWindowController: NSWindowController {
    private let viewModel: RecordingListViewModel
    private var didBecomeKeyObserver: NSObjectProtocol?

    init(window: NSWindow, viewModel: RecordingListViewModel) {
        self.viewModel = viewModel
        super.init(window: window)
        didBecomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.viewModel.refresh() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let didBecomeKeyObserver {
            NotificationCenter.default.removeObserver(didBecomeKeyObserver)
        }
    }
}

// MARK: - 退出保护（终审 F1：录制中退出不再丢数据）

/// 退出决策接缝（纯逻辑，无头可测）：控制器状态 → 退出动作。
/// - `.idle` → 直接终止（无弹窗）；
/// - `.finishing` → 静默等待收尾完成（同保存路径，不再询问）；
/// - `.countdown`/`.recording`/`.paused` → 三键询问（退出并保存录制 / 退出并丢弃 / 取消）。
enum QuitGuard {
    enum Action: Equatable {
        case terminateNow
        case waitQuietly
        case askUser
    }

    static func action(for state: CaptureState) -> Action {
        switch state {
        case .idle:
            return .terminateNow
        case .finishing:
            return .waitQuietly
        case .countdown, .recording, .paused:
            return .askUser
        }
    }

    /// 有界等待回到 `.idle`（主 actor 轮询；上限与步长注入，无头可测——不读真实时钟，
    /// 以累计步长近似计时）。返回 true = 已回 idle；false = 到时仍未 idle，调用方必须
    /// 放行退出（宁可截断收尾，不无限挂住退出流）。
    @MainActor
    static func waitForIdle(maxSeconds: TimeInterval,
                            pollInterval: TimeInterval,
                            provider: () -> CaptureState) async -> Bool {
        var waited: TimeInterval = 0
        while provider() != .idle {
            guard waited < maxSeconds else { return false }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            waited += pollInterval
        }
        return true
    }
}

/// 应用代理（终审 F1）：唯一职责是退出保护——`applicationShouldTerminate` 按 QuitGuard
/// 决策分流：idle 直接终止；finishing 静默有界等待；录制/暂停/倒计时弹三键询问（保存为
/// default），保存与丢弃都经有界等待回到 `.idle` 再 `reply(toApplicationShouldTerminate: true)`。
/// 其余生命周期一律透传默认行为。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 装配容器登记缝：`@NSApplicationDelegateAdaptor` 的实例化先于/并行于 `App.init`，
    /// delegate 无法在自身 init 拿到装配容器。装配侧（`AppAssembly.init`，由 @StateObject
    /// 保证恰好构造一次——见 AppAssembly 类注释的装配红线）登记弱引用；退出必然晚于
    /// App.init（菜单/快捷键需应用已运行），届时静态登记必已就位。弱引用方向：容器由
    /// App 强持有，delegate 不反向持强（避免环，delegate 与进程同寿）。
    static weak var registeredAssembly: AppAssembly?
    /// 退出流闸（防重入）：terminateLater 期间（模态询问/有界等待中）再次触发 terminate
    /// 一律 `.terminateCancel`——首个退出流仍在负责 reply，重入会造成嵌套模态/双 reply。
    private var quitFlowActive = false
    /// 退出收场的有界等待上限（秒）：到点即放行终止（裁定 1：不可无限挂住退出）。
    private static let terminationWaitLimit: TimeInterval = 10
    /// 等待轮询步长（秒）。
    private static let terminationPollInterval: TimeInterval = 0.05

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let assembly = Self.registeredAssembly else { return .terminateNow }
        let controller = assembly.controller
        switch QuitGuard.action(for: controller.state) {
        case .terminateNow:
            return .terminateNow
        case .waitQuietly:
            guard !quitFlowActive else { return .terminateCancel }
            quitFlowActive = true
            Task { @MainActor in
                _ = await QuitGuard.waitForIdle(
                    maxSeconds: Self.terminationWaitLimit,
                    pollInterval: Self.terminationPollInterval,
                    provider: { controller.state })
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        case .askUser:
            guard !quitFlowActive else { return .terminateCancel }
            quitFlowActive = true
            presentQuitConfirmation(controller: controller)
            return .terminateLater
        }
    }

    /// 三键退出询问（App 模态，裁定 1 文案）：「退出并保存录制」（default）→ stop 并有界
    /// 等待回 idle；「退出并丢弃」→ cancelAndDiscard 同样有界等待；「取消」→ terminateCancel。
    private func presentQuitConfirmation(controller: CaptureController) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "正在录制中，确定退出吗？"
        alert.informativeText = "「退出并保存录制」将停止录制并保留成片；「退出并丢弃」将停止录制并删除未保存的内容。"
        alert.addButton(withTitle: "退出并保存录制")
        alert.addButton(withTitle: "退出并丢弃")
        alert.addButton(withTitle: "取消")
        let response = alert.runModal()
        Task { @MainActor in
            switch response {
            case .alertFirstButtonReturn:
                // 倒计时（begin 未发出）无内容可保存：保存键退化为收场取消——stop 在
                // .countdown 是定义好的 no-op，直接调用会空耗等待上限。
                if case .countdown = controller.state {
                    NSLog("QuitGuard: 倒计时态选「退出并保存录制」，无内容可保存，退化为收场取消后退出")
                    controller.cancelAndDiscard()
                } else {
                    controller.stop()
                }
                await Self.finishTerminationAfterIdle(controller: controller)
            case .alertSecondButtonReturn:
                controller.cancelAndDiscard()
                await Self.finishTerminationAfterIdle(controller: controller)
            default:
                quitFlowActive = false
                NSApplication.shared.reply(toApplicationShouldTerminate: false)
            }
        }
    }

    /// 有界等待回 `.idle` 后放行终止（保存/丢弃共用出口；到点未 idle 也 reply 终止）。
    private static func finishTerminationAfterIdle(controller: CaptureController) async {
        _ = await QuitGuard.waitForIdle(
            maxSeconds: terminationWaitLimit,
            pollInterval: terminationPollInterval,
            provider: { controller.state })
        NSApplication.shared.reply(toApplicationShouldTerminate: true)
    }
}

@main
struct ScreenRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var assembly: AppAssembly

    init() {
        _assembly = StateObject(wrappedValue: AppAssembly())
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                controller: assembly.controller,
                settings: assembly.settings,
                onStartDisplay: { assembly.startDisplayRecording(on: $0) },
                onStartWindowPicker: { assembly.openWindowPicker(startsRecordingOnSelection: true) },
                onStartAppPicker: { assembly.openAppPicker() },
                onStartRegion: { assembly.startRegionRecording() },
                onStartWindowRegion: { assembly.startWindowRegionRecording() },
                onOpenRecordingList: { assembly.openRecordingList() },
                onOpenPreferences: { assembly.openPreferences() }
            )
        } label: {
            // T19：状态图标（idle/countdown/recording/paused/finishing 逐态换装），
            // 独立视图自持 @ObservedObject，状态变化不经 App body 重跑直达菜单栏。
            MenuBarStatusIcon(controller: assembly.controller)
        }
        Window("授权设置", id: "permission-onboarding") {
            PermissionOnboardingWindowContent()
        }
    }
}

/// 权限引导窗口的薄容器：三项权限全部就绪即关闭窗口。
/// 启动时已全绿则首帧闪现后立即自动关闭（已裁决可接受的外观瑕疵）。
private struct PermissionOnboardingWindowContent: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PermissionOnboardingView(onAllGranted: { dismiss() })
    }
}
