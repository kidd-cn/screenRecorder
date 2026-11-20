import AppKit
import Combine
import CoreGraphics
import KeyboardShortcuts
import ScreenCaptureKit
import SwiftUI
import UserNotifications

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
    /// 已移出列表条目账本（Q4）：生产缝接 UserDefaults（`RemovedListStore.key` 下存
    /// `[String]` 路径集），同一实例传入 fileStore 与列表 VM——过滤/自愈在 store.contents()
    /// 读此账本，记账入口在 VM.removeFromList；换装输出目录（`updateOutputDirectory`）
    /// 时同一实例跟随新 store，记账跨目录存续。
    private let removedListStore: RemovedListStore
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
    /// 键帽预览（2026-11-15 Omi「开启预览」复刻）：与录制合成同源快照桥的悬浮预览窗。
    /// 装配层编排：开预览临时装机监听器（enabled true + start），停预览/开录还原设置
    /// 快照语义（仅空闲时还原，录制中不摘）。init 尾段构造（闭包捕获局部 store，
    /// 不触 self——两段式初始化纪律同 keyboardMonitor）。
    private(set) var keyboardPreview: KeyboardPreviewController!
    /// 自定义虚拟背景库（2026-11-15 Omi 页复刻）：偏好设置瓦片网格与处理器帧路径
    /// 共用的文件真源（App Support/Hummingbird/Backgrounds）。
    let customBackgroundStore = CustomBackgroundStore()
    /// 虚拟背景页摄像头预览（复用录制同一条 CameraPiP 处理链——预览所见即录制所得）。
    /// 页面 onAppear/onDisappear 驱动启停；窗口关闭由 prefsWindowCloser 兜底停机。
    private(set) var virtualBackgroundPreview: VirtualBackgroundPreviewController!
    /// 偏好设置窗口关闭收尾（预览停机 + 单实例控制控制器复位——下次打开重建 SwiftUI
    /// 层级，页签 onAppear 语义可靠）。
    private var prefsWindowCloser: PreferencesWindowCloser?
    /// 启动条（2026-11-15 Omi 49.png 复刻）：Dock 图标点击 / 应用启动 / 菜单入口的
    /// 主界面——7 录制模式横条。窗口归装配容器（装配红线），懒建单例复用。
    private var launchBarController: LaunchBarWindowController?

    /// 打开启动条（幂等重入 = 前置）：模式回调与菜单栏磁贴同源（同一批 start 方法），
    /// 点击后收条由 LaunchBarWindowController 自理。
    func openLaunchBar() {
        if launchBarController == nil {
            launchBarController = LaunchBarWindowController { [weak self] mode in
                guard let self else { return }
                switch mode {
                case .fullscreen:
                    self.startDisplayRecording(on: CGMainDisplayID())
                case .region:
                    self.startRegionRecording()
                case .windowRegion:
                    self.startWindowRegionRecording()
                case .window:
                    self.openWindowPicker(startsRecordingOnSelection: true)
                case .app:
                    self.openAppPicker()
                case .camera:
                    self.startCameraOnlyRecording()
                case .audio:
                    self.startAudioOnlyRecording()
                }
            }
        }
        // 不主动 activate（Dock 点击/启动本身已激活；LSUIElement 场 activate 会扰动
        // 空间与菜单面板状态——2026-11-15 实测 occlusion 异常的嫌疑点）。
        launchBarController?.show()
    }

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
    /// 摄像头预览窗（2026-11-14）：仅 cameraOnly 场显示（state 订阅驱动，装配红线归本容器）。
    private let cameraPreviewWindow = CameraPreviewWindow()
    /// 关于窗（2026-11-14）：自建内容窗替代系统标准面板（后者信息量过低）。
    private let aboutWindow = AboutWindowController()
    /// 预览窗订阅保活（与容器同寿）。
    private var cameraPreviewCancellables: Set<AnyCancellable> = []

    /// 全局快捷键已挂载的进程级闸（T17 裁定 4）：KeyboardShortcuts 的 onKeyUp 把动作
    /// 追加进包内静态注册表，重挂（assembly init 重跑）会双触发——挂载恰好一次。
    private static var globalShortcutsMounted = false
    /// 终审 F2：麦克风设置 live 下发链的订阅保活（与容器同寿）。快照链（开始时刻读
    /// config）与 live 链并存：初值由快照负责，live 只发变化。
    private var liveMicCancellables: Set<AnyCancellable> = []
    /// P5 验收裁定：摄像头背景 live 下发链的订阅保活（与容器同寿）。快照链（begin 读
    /// config）与 live 链并存：初值由快照负责，live 只发变化（F2 mic 同款两链语义）。
    private var liveBackgroundCancellables: Set<AnyCancellable> = []
    /// 开机自启装配单元（P6a）：所有权进本容器（装配红线）。开关变化经其内部 Combine
    /// sink 消费（接线裁定：副作用不进 SettingsStore didSet——sink 内的失败回翻若改走
    /// didSet 接线即自赋值重入；sink 侧重入护栏闩见 LaunchAtLoginCoordinator），失败回翻
    /// + 通知都收在该单元。
    private let launchAtLoginCoordinator: LaunchAtLoginCoordinator
    /// 定时录制调度器（P6b，P6a 同款装配红线）：所有权进本容器；菜单/状态图标经
    /// @ObservedObject 直读 `active`（装配层 Combine sink 教训：能直绑不 sink）。
    /// 懒建（同 markingOverlayController 先例）：起录缝要捕获 self 走 startRecording
    /// 统一入口，两段式初始化内不可得；首次访问 = App 首帧菜单栏/菜单装配（即生产接线
    /// 时点），错过通知的 category 注册与 UNUserNotificationCenter delegate 挂载一并在此
    /// 完成（装配层接线，真机验收）。
    private(set) lazy var scheduler: RecordingScheduler = makeScheduledRecorder()
    /// 错过通知「开始录制」动作的路由宿主（UNUserNotificationCenter delegate）：delegate
    /// 按系统语义弱引用，必须由容器强持有（属性默认值在 init 前构造，懒建调度器闭包可引）。
    private let scheduledMissedDelegate = ScheduledMissedNotifyDelegate()
    /// 定时录制面板窗口控制器（P6b）：窗口归装配容器（装配红线），懒建单例复用
    ///（isReleasedWhenClosed = false，同偏好设置/文件列表窗口）。
    private var scheduledPanelWindowController: NSWindowController?
    /// 通知器（P6b 起提升为容器成员，构造仍归 init 局部量段）：控制器的 `notifier` 注入
    /// 与定时录制调度器的跳过通知缝共用同一实例（UNUserNotificationCenter 单例通道）。
    private let notifier: UNRecordingNotifier

    init() {
        let settings = SettingsStore()
        // Q4 移出列表记账：账本缝接 UserDefaults（读 stringArray 归 Set，写 set(Array)），
        // 同一实例传入 fileStore 与列表 VM（见 removedListStore 属性注释）。
        let removedListStore = RemovedListStore(
            read: { Set(UserDefaults.standard.stringArray(forKey: RemovedListStore.key) ?? []) },
            write: { UserDefaults.standard.set(Array($0), forKey: RemovedListStore.key) })
        let fileStore = RecordingFileStore(
            baseDirectory: settings.outputDirectory, removedList: removedListStore)
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
                    combosOnly: settings.keyboardOverlayCombosOnly,
                    fontSize: settings.keyboardOverlayFontSize,
                    panelColor: settings.keyboardOverlayPanelColor,
                    textColor: settings.keyboardOverlayTextColor)
            },
            lingerProvider: { settings.keyboardOverlayLingerSeconds },
            wrapDelayProvider: { settings.keyboardOverlayWrapDelaySeconds },
            fadeSecondsProvider: { settings.keyboardOverlayFadeSeconds })
        keyboardPreview = KeyboardPreviewController(
            snapshotProvider: { [keyboardOverlayStore] in keyboardOverlayStore.currentSnapshot() })
        virtualBackgroundPreview = VirtualBackgroundPreviewController(
            backgroundStore: customBackgroundStore)
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
        self.removedListStore = removedListStore
        self.notifier = notifier
        self.sourceLossMonitor = sourceLossMonitor
        self.microphoneRouteWatcher = microphoneRouteWatcher
        self.launchAtLoginCoordinator = launchAtLoginCoordinator
        self.floatingBarPanel = FloatingControlBarPanel(controller: controller)
        // PiP 拖动锚点（T15）：浮窗初始摆放避让浮条（浮条 frame 单向喂数，无反向依赖）
        cameraPiP.controlBarFrameProvider = { [weak floatingBarPanel] in
            floatingBarPanel.map { $0.screenFrame }
        }
        // 摄像头断源（Task 3，用户裁决 (a)）：命中 → 会话失败自动保存（同屏幕丢源收场
        // 语义：成片保留 +「录制中断」通知）。控制器侧保证主线程投递，闭包内跳主 actor
        //（同文件 SourceLossMonitor 闭包同风格）；[weak controller] 防 controller → session
        //（coordinator）→ cameraPiP → 闭包保留环（终审 F4 同款纪律）。
        cameraPiP.onCameraSourceLost = { [weak controller] in
            Task { @MainActor in controller?.handleSessionFailure(CameraSourceLostError()) }
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
        // 摄像头预览窗（2026-11-14）：cameraOnly 场 recording/paused 显示（source 是
        // 摄像头，预览会话由控制器透出——屏幕类场 nil → 隐藏），其余态隐藏。
        // 注：sink 在 @Published willSet 同步回拉可能读旧值——预览会话此时已由 begin
        // 装配完成（state 置 recording 晚于 recorder.start 返回），回拉安全。
        controller.$state
            .sink { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    if state == .recording || state == .paused,
                       let session = self.controller.cameraPreviewSession {
                        self.cameraPreviewWindow.show(session: session)
                    } else {
                        self.cameraPreviewWindow.hide()
                    }
                }
            }
            .store(in: &cameraPreviewCancellables)
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
        // P5 验收裁定：摄像头背景 live 下发（录制中改动实时生效；非录制中 controller 会话
        // 闸静默 no-op——降级纯屏幕/场次外均无消费面）。off → nil = 帧路径零开销旁路；
        // blur/builtin → 新处理器实例（Vision 分割单例复用，无逐场冷启动）。receive(on: main)
        // 与 mic 链同一纪律（浮窗覆盖层重接全主线程）。
        settings.$cameraBackground
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak cameraPiP] mode in
                let processor: CameraBackgroundProcessor? = mode == .off
                    ? nil
                    : CameraBackgroundProcessor(mode: mode, segmenter: VisionPersonSegmenter.shared)
                cameraPiP?.switchBackgroundProcessor(to: processor)
            }
            .store(in: &liveBackgroundCancellables)
        mountMarkingIfNeeded()
        mountGlobalShortcutsIfNeeded()
        // Q3 重录按钮接线（attachMarkingToggle 先例同款装配缝）：两击确认后走 restartRecording
        // 编排（丢弃 + 有界等待 idle + 绕倒计时重开，全在装配层）。
        floatingBarPanel.attachRestartRecording { [weak self] in self?.restartRecording() }
        // 沙盒首次启动：无输出目录书签（用户尚未选择保存位置）→ 引导选择（2026-11-14
        // 上架适配）。非沙盒构建（开发调试）不打扰——历史路径照常可用。
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if OutputDirectoryAccess.resolve() == nil {
                    self.presentOutputDirectoryPicker()
                }
            }
        }
        // T5 pip-swap 对调按钮接线（attachRestartRecording 装配行旁）：provider 供 attach
        // 时刻初值（此后可见性/对调态一律 refreshPipSwapSurfaces 发射值直传）；toggle 翻转
        // 对调态（旗标 + 浮窗换装一体）并全面重估。
        floatingBarPanel.attachPipSwap(
            provider: { [weak self] in
                (self?.isPipSwapSurfaceAvailable ?? false, self?.cameraPiP.isLayoutSwapped ?? false)
            },
            toggle: { [weak self] in self?.togglePipSwap() })
        // 录制完成后显示文件列表（Omi 同款能力，2026-11-15）：成片回调在 init 早期无法
        // 捕获 self（controller 尚未入库），挂到 init 尾部——此处全部存储属性已就绪。
        controller.onRecordingCompletedToFile = { [weak self] url in
            if self?.settings.recordCompletedShowList == true {
                self?.openRecordingList()
            }
        }
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

    /// 菜单「开始录制 → 仅声音」入口（P7a）：不采集任何视频内容，落盘纯音轨 `.m4a`
    ///（输出扩展名与 SCStream 仅音频装配均由 `startRecording` / config 快照按模式分流）。
    func startAudioOnlyRecording() {
        startRecording(mode: .audioOnly)
    }

    /// 菜单「开始录制 → 仅摄像头」入口（P7b）：录制源是前置摄像头 AVCaptureSession，
    /// 落盘 mp4 视频文件（PiP 叠加/缩放/点击高亮/音效/系统声经 makeConfiguration 强制关；
    /// 输出扩展名沿用既有分流——audioOnly 之外的分支缺省 mp4，无需改动）。
    func startCameraOnlyRecording() {
        startRecording(mode: .cameraOnly)
    }

    // MARK: 截图（Q1：区域拖框 / 整屏，PNG 落输出目录+通知，不入列表）

    /// 菜单「截图 → 区域截图…」入口：屏解析与选区交互照抄区域录制入口（遮罩落在当前
    /// 鼠标所在显示器、回退主屏；RegionSelector 产出显示器全局 points rect 或 nil）。
    /// nil（ESC / 点击无拖动 / 目标屏不在位）= 静默放弃——无文件、无通知。
    func takeRegionScreenshot() {
        Task { @MainActor in
            // 菜单项已按状态置灰，此 guard 兜非菜单路径：选区遮罩不得在录制中途弹出
            //（同 startRegionRecording 纪律）。
            guard controller.state == .idle else {
                NSLog("ScreenshotMenu: 忽略区域截图入口（当前状态非 idle：\(controller.state)）")
                return
            }
            let displayID = Self.regionAnchorDisplayID() ?? CGMainDisplayID()
            guard let rect = await RegionSelector.selectRegion(on: displayID) else { return }
            await takeScreenshot(displayID: displayID, regionInGlobalPoints: rect)
        }
    }

    /// 菜单「截图 → 全屏截图」入口（显示器列表子菜单项，数据源与命名同「开始录制 → 全屏」）。
    func takeFullScreenScreenshot(on displayID: CGDirectDisplayID) {
        Task { @MainActor in
            await takeScreenshot(displayID: displayID, regionInGlobalPoints: nil)
        }
    }

    /// 截图编排（Q1 Produces）：ScreenCaptureKit 取帧（2026-11-14 废弃 API 迁移）→
    /// ScreenshotCore 裁剪 → PNG
    /// 写盘（`截图_yyyy-MM-dd_HH-mm-ss.png`，冲突 " (2)"；截图不入文件列表——contents()
    /// 只列 mp4/m4a，无需改动）→ 成功通知。`regionInGlobalPoints` nil = 整屏（显示器
    /// bounds 作 region，经同一裁剪路径零特判）。
    /// 失败纪律：取帧/裁剪/编码/写盘任何一步失败只 NSLog 静默（截图是尽力而为副通道，
    /// 不弹窗不打断），仅成功发通知。取帧时机：`selectRegion` 返回时覆盖层已 orderOut
    ///（session finish 先摘窗再回调），此处再留一次短暂让步（brief 认可的工程缓解）——
    /// 防窗口服务器合成滞后把遮罩残影拍进整屏图（全屏路径无遮罩，让步无害）。
    func takeScreenshot(displayID: CGDirectDisplayID, regionInGlobalPoints: CGRect?) async {
        // 沙盒兜底：保存目录无访问权时引导重选（截图写盘同样受沙盒约束）。
        guard ensureOutputAccess() else { return }
        // 菜单项已按状态置灰，此 guard 兜非菜单路径：截图不与录制会话并发。
        guard controller.state == .idle else {
            NSLog("Screenshot: 忽略截图入口（当前状态非 idle：\(controller.state)）")
            return
        }
        let bounds = CGDisplayBounds(displayID)
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else {
            NSLog("Screenshot: 显示器 %u bounds 不可得，放弃截图", displayID)
            return
        }
        let region = regionInGlobalPoints ?? bounds
        try? await Task.sleep(nanoseconds: 150_000_000)
        // 审查 Minor#2（fail-safe 一行）：settle 等待窗口内用户可能经全局热键/定时起录
        //——取帧前复检状态，截图绝不与录制会话并发（菜单置灰 + 入口守卫之外第三道闸）。
        guard controller.state == .idle else {
            NSLog("Screenshot: settle 后状态已非 idle（被并发起录抢先），放弃截图")
            return
        }
        // SCK 取帧（替代废弃的 CGDisplayCreateImage）：显示器像素尺寸作配置，
        // 与 ScreenshotCore 的点→像素比例尺一致。
        let frame: CGImage
        do {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false),
                let display = content.displays.first(where: { $0.displayID == displayID })
            else {
                NSLog("Screenshot: SCShareableContent 中找不到显示器 %u，放弃截图", displayID)
                return
            }
            // Retina 修正（2026-11-14）：SCK 配置按点口径的显示器尺寸出图会掉到
            // 逻辑分辨率（实测 1512×982）——乘 backingScaleFactor 恢复原生像素
            // （3024×1964），与旧 CGDisplayCreateImage 同清晰度。
            let scaleFactor = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                    .uint32Value == displayID
            }?.backingScaleFactor ?? 2
            let pointBounds = CGDisplayBounds(displayID)
            let config = SCStreamConfiguration()
            config.width = Int(pointBounds.width * scaleFactor)
            config.height = Int(pointBounds.height * scaleFactor)
            config.showsCursor = false
            config.capturesAudio = false
            let filter = SCContentFilter(display: display, excludingWindows: [])
            frame = try await ScreenFrameCapture.capture(filter: filter, configuration: config)
        } catch {
            NSLog("Screenshot: 显示器 %u 取帧失败（\(error)），放弃截图", displayID)
            return
        }
        guard let cropped = ScreenshotCore.crop(
            frame,
            displayOrigin: bounds.origin,
            displayPointSize: bounds.size,
            regionInGlobalPoints: region)
        else {
            NSLog("Screenshot: 裁剪失败（region=\(String(describing: regionInGlobalPoints)) bounds=\(bounds)），放弃截图")
            return
        }
        guard let png = ScreenshotCore.pngData(cropped) else {
            NSLog("Screenshot: PNG 编码失败，放弃截图")
            return
        }
        try? fileStore.ensureDirectory()
        let url = fileStore.nextFileURL(extension: "png", prefix: NSLocalizedString("截图", comment: "Screenshot file prefix"))
        do {
            try png.write(to: url)
        } catch {
            NSLog("Screenshot: 截图写盘失败（\(url.path)）：\(error)")
            return
        }
        NSLog("Screenshot: 截图已保存 \(url.lastPathComponent)")
        notifier.notifyScreenshotSaved(fileURL: url)
    }

    /// 唯一的开始装配点：持久化「上次使用的模式」（裁定 2：每次开始都记）→ 建输出目录 →
    /// 从 SettingsStore 快照装配 config → 进入控制器状态机（快照语义：录制中途改设置
    /// 不影响进行中的录制）。控制器自守卫（非 `.idle` 一律 no-op），此处不重复判态。
    /// P6b：`bypassCountdown` 仅供定时到点起录（简报钉定：定时起录不走倒计时，无论
    /// 倒计时设置为何）；手动路径默认 false 形状不变。R1：返回控制器 start Task 供
    /// `startScheduledRecording` await 真实 begin 结果（其余调用方 @discardableResult 不变）。
    @discardableResult
    private func startRecording(mode: CaptureMode, bypassCountdown: Bool = false) -> Task<Void, Never> {
        // 沙盒兜底（2026-11-14）：保存目录无访问权时引导重选，而非静默起录失败。
        guard ensureOutputAccess() else { return Task {} }
        settings.lastCaptureMode = mode
        // 标记会话态复位（计划钉定「每次录制重新开关」——非持久化、跨录制不保留）：
        // 关闭开关（显隐订阅随之收起覆盖层/工具条）+ 画布清空（新录制从空白开始，
        // 笔画不跨录制留存）+ 几何缓存失效（下次开启时现场重解析）。
        setMarkingEnabled(false)
        markingCanvas.clear()
        markingGeometry = nil
        // 键帽预览随开录收起（Omi 语义：预览只在空闲态演示；录制画面自带键帽，悬浮
        // 预览窗与录制并存只会双显）。监听器保持既有快照语义（下面 setEnabled 不变）。
        if keyboardPreview.isActive { keyboardPreview.stop() }
        // P4 键帽 enabled 快照语义：开录时刻以设置重对齐（录制中途改设置不影响本场；
        // 与 clickHighlightEnabled 同纪律）。装机由 $state 订阅在进入 recording 时驱动，
        // 此处只对齐开关（监听中翻 false 立即摘除，KeyboardMonitor.setEnabled 自理）。
        keyboardMonitor.setEnabled(settings.keyboardOverlayEnabled)
        try? fileStore.ensureDirectory()
        // P7a：仅声音输出 .m4a（纯音轨容器）；其余模式缺省 mp4（既有调用形状不变）。
        let outputExtension: String = if case .audioOnly = mode { "m4a" } else { "mp4" }
        // 2026-11-20 Omi 文件列表页：成片名带类型前缀（屏幕/窗口/区域/App/摄像头/声音），
        // 列表「类型」列据此展示；截图前缀「截图」由截图入口自理。
        let config = Self.makeConfiguration(
            settings: settings,
            mode: mode,
            outputURL: fileStore.nextFileURL(
                extension: outputExtension,
                prefix: NSLocalizedString(mode.filePrefixKey, comment: "Recording file prefix")))
        return Task { await controller.start(mode: mode, config: config, bypassCountdown: bypassCountdown) }
    }

    /// 开始时刻的 config 快照（唯一装配点的纯函数抽取，internal 供无头钉测）：从
    /// SettingsStore 逐字段入照。终审 F2 复审残余：`micMuted` 必须随快照入照——
    /// registerMicrophone 据此决定开录是否预装 mic tap，漏带则持久化静音被每场开录
    /// 静默忽略（live 下发链只覆盖录制中的翻转，兜不了开录初值）。P1b：点击音效开关
    /// 同为快照字段（开录时刻入照，录制中途改设置不影响进行中的录制）。P5：摄像头背景
    /// 同为快照字段（coordinator.begin 据此装配背景处理器，off = 帧路径零开销旁路）。
    /// P7a 仅声音装配裁定：系统声恒开（该模式的定义性音源——用户关掉系统声的偏好只对
    /// 视频模式生效，否则一场仅声音录制零音源、必走 nothingWritten 无成片）；摄像头画中画
    /// 恒关（无视频轨可叠，开着只会凭空弹摄像头浮窗）。
    /// P7b 仅摄像头装配裁定（规格钉定「效果不可用」）：PiP 叠加/缩放/点击高亮/点击音效
    /// 恒关（画面无屏幕内容可叠可缩可高亮；音效骑点击高亮同一点击源的效果族，随门一并关）
    /// ——规格允许「置灰或忽略」，本处取「忽略」语义（入口保持可翻，开录快照强制关）；
    /// 系统声恒关（系统声唯一采集通道是 SCStream，cameraOnly 不建流——强制 true 只会空转
    /// 一个无源混音器）；麦克风照常（用户偏好，经 recorder 内部 AVAudioEngine mixer 可混）。
    /// 录制源摄像头不经 includeCamera——那是画中画叠加开关。Q2：鼠标光标显示开关
    /// 同为快照字段（SCStreamRecorder 据此设 showsCursor，仅 SCStream 视频路径消费）。
    /// Q5：长录提醒间隔同为快照字段（控制器 start 消费，录制中改偏好不影响本场；
    /// 全模式透传不门控——净录时长与画面模式无关，audioOnly/cameraOnly 同样提醒）。
    static func makeConfiguration(settings: SettingsStore, mode: CaptureMode, outputURL: URL) -> RecordingConfiguration {
        let audioOnly: Bool = if case .audioOnly = mode { true } else { false }
        let cameraOnly: Bool = if case .cameraOnly = mode { true } else { false }
        let systemAudio = cameraOnly ? false : (audioOnly || settings.captureSystemAudio)
        return RecordingConfiguration(
            mode: mode,
            captureSystemAudio: systemAudio,
            captureMicrophone: settings.captureMicrophone,
            micVolume: settings.micVolume,
            micMuted: settings.micMuted,
            includeCamera: !(audioOnly || cameraOnly) && settings.pipEnabled,
            cameraBackground: settings.cameraBackground, // P5：初值快照（录制中改动走 live 下发链实时生效）
            fps: settings.fps,
            codec: settings.videoCodec,
            outputURL: outputURL,
            clickHighlightEnabled: !cameraOnly && settings.clickHighlightEnabled,
            autoZoomEnabled: !cameraOnly && settings.autoZoomEnabled,
            autoZoomLevel: settings.autoZoomLevel,
            clickSoundEnabled: !cameraOnly && settings.clickSoundEnabled,
            captureMouseCursor: settings.captureMouseCursor, // Q2：开录快照（SCStream 视频路径消费，audioOnly/cameraOnly 分支不设该键）
            recordingReminderIntervalHours: settings.recordingReminderIntervalHours, // Q5：开录快照（全模式透传，elapsed 模式无关）
            captureQuality: settings.captureQuality // 录制清晰度：开录快照（像素尺寸上限）
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

    /// 保存目录可用性检查（沙盒兜底）：非沙盒恒 true；沙盒内目录/其父目录不可写
    /// （无书签或书签失效）→ 弹目录选择并返回 false（调用方放弃本次操作）。
    @discardableResult
    private func ensureOutputAccess() -> Bool {
        guard ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil else {
            return true
        }
        let fm = FileManager.default
        let dir = settings.outputDirectory
        if fm.fileExists(atPath: dir.path) {
            if fm.isWritableFile(atPath: dir.path) { return true }
        } else {
            let parent = dir.deletingLastPathComponent()
            if fm.fileExists(atPath: parent.path), fm.isWritableFile(atPath: parent.path) {
                return true
            }
        }
        NSLog("Hummingbird: 保存目录不可写（沙盒未授权），引导重选：\(dir.path)")
        presentOutputDirectoryPicker()
        return false
    }

    /// 沙盒首次启动的输出目录引导（NSOpenPanel，仅目录）：选定后登记书签并换装
    /// fileStore/控制器（`updateOutputDirectory` 同一出口）；取消则维持默认路径，
    /// 后续起录/截图会因权限失败——设置页可随时重选。
    private func presentOutputDirectoryPicker() {
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("选择录制保存位置", comment: "Choose output folder title")
        panel.message = NSLocalizedString(
            "「蜂鸟录屏」需要在您选择的文件夹中保存录像与截图。", comment: "Choose output folder message")
        panel.prompt = NSLocalizedString("选择", comment: "Choose")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        if let movies { panel.directoryURL = movies }
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.updateOutputDirectory(to: url) }
        }
    }

    /// 偏好设置改输出目录（T17 验收）：settings 真源更新 + 换装 fileStore + 同步换入
    /// 控制器 store（此后 discard 删除作用于新目录成片）。
    func updateOutputDirectory(to url: URL) {
        // 沙盒：经 SettingsStore 登记 security-scoped bookmark（访问权真源）。
        settings.setOutputDirectory(url)
        // Q4：换装 store 携带同一只移出账本（记账按绝对路径跨目录存续——旧目录的已移出
        // 记录不因换目录丢失或重现）。
        let newStore = RecordingFileStore(baseDirectory: url, removedList: removedListStore)
        fileStore = newStore
        controller.updateStore(newStore)
    }

    // MARK: 重新录制（Q3：丢弃已录内容 + 立即重开同模式，两击确认 + 绕过倒计时）

    /// 浮条重录按钮 / 菜单「重新录制」编排（Q3 Produces）：guard 录制/暂停 →
    /// `cancelAndDiscard()`（既有丢弃语义：收尾删片、不回调 onFinishedFile——重录绝不把
    /// 旧场写盘）→ `RestartOrchestrator` 有界等待 idle（50 × 0.1s = 5s；收尾落盘是异步
    /// Task，`.finishing` → `.idle` 到达时机不定）→ `startRecording(lastCaptureMode,
    /// bypassCountdown: true)`（定时到点起录同一接线形状）。
    /// 配置语义钉定：重录 = **新一轮设置快照**（走既有起录入口，`startRecording` 起录时刻
    /// 重照 SettingsStore——非上一场 runtime 配置的逐字拷贝）。超时纪律：预算耗尽 → 不重开、
    /// 不通知、不循环（仅 NSLog 留排查痕，截图副通道同款静默精神）。定时会话内手动重录无
    /// 新调度器机制——既有调度器语义照旧（排程/停录等待不受影响）。
    /// 0.1s 让步收在本装配 poll 闭包内（「含等待」归 poll，编排本身零时钟依赖、无头可测）；
    /// 主 actor 全程（Task 继承 AppAssembly 隔离，poll 读 state 免跳转）。
    func restartRecording() {
        guard controller.state == .recording || controller.state == .paused else { return }
        controller.cancelAndDiscard()
        Task { @MainActor in
            let started = await RestartOrchestrator.run(
                poll: { [weak self] in
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    return self?.controller.state == .idle
                },
                start: { [weak self] in
                    guard let self else { return }
                    NSLog("RestartRecording: idle 已回，重开模式 \(self.settings.lastCaptureMode)")
                    self.startRecording(mode: self.settings.lastCaptureMode, bypassCountdown: true)
                })
            if !started {
                NSLog("RestartRecording: 5s 预算内未回 idle（收尾未完成），放弃重开")
            }
        }
    }

    // MARK: 定时录制（P6b：调度器缝接线 / 面板 / 错过补通知）

    /// 调度器缝接线（懒建，见 `scheduler` 属性注释）：起录走 `startScheduledRecording`
    ///（last-used 模式 + 绕过倒计时）；停录转发 `controller.stop`（自守卫：非录制/暂停
    /// no-op——上限到点时会话已空闲则无声落地）；忙/锁屏跳过通知走 UNRecordingNotifier
    ///（Task 11 先例：新通知类型进 notifier，强捕获局部量与容器同寿无环）；错过补通知走
    /// 独立带动作缝——动作闭包挂到 delegate（UNUserNotificationCenter「开始录制」按钮的
    /// 真实派发通道），投递走 category 内容（装配层接线，无头不可钉，真机验收）。锁屏判定
    /// 生产默认 CGSessionCopyCurrentDictionary（测试绝不触真——调度器钉测注入假值）；忙 =
    /// 控制器非 idle（录制/暂停/收尾/倒计时都算——已有一场将启，定时起录让位并通知）。
    /// 闭包 [weak controller]（终审 F4 保留环同款纪律）、[weak self]（懒建闭包持有容器弱
    /// 引，容器与进程同寿故弱引永不悬空释放为 no-op）。
    private func makeScheduledRecorder() -> RecordingScheduler {
        // 闭包捕局部量（notifier 强捕获 = controller.onFinishedFile 同款，与容器同寿无环；
        // delegate 同理——通知中心对其弱引用，容器强持有）。
        let notifier = self.notifier
        let missedDelegate = scheduledMissedDelegate
        UNUserNotificationCenter.current().delegate = missedDelegate
        Self.registerScheduledMissedCategory()
        return RecordingScheduler(
            now: { Date() },
            timerFactory: { body in
                // 主 run loop 每秒一拍（common mode：菜单拖拽等 UI 事件循环中也心跳）；
                // 仅排程/停录等待期保活（调度器 settleTimer 沉降摘除）。sink 闭包继承
                // @MainActor 装配语境，body 直调 tick 与调度器隔离一致。
                var tickCount = 0
                return Timer.publish(every: 1, on: .main, in: .common)
                    .autoconnect()
                    .sink { _ in
                        tickCount += 1
                        // 首拍日志（每次武装恰一条）：计时器投递链（run loop→Combine）的
                        // 存活证据，武装窗口外不产生任何输出。
                        if tickCount == 1 {
                            NSLog("ScheduledRecording: 心跳首拍（计时器投递正常）")
                        }
                        body()
                    }
            },
            start: { [weak self] in await self?.startScheduledRecording() ?? false },
            stop: { [weak controller] in controller?.stop() },
            notify: { title, body in
                notifier.notifyScheduledRecordingSkipped(title: title, body: body)
            },
            notifyMissed: { title, body, startAction in
                missedDelegate.startAction = startAction
                Self.postMissedNotification(title: title, body: body)
            },
            isLocked: { RecordingScheduler.isScreenLocked() },
            isBusy: { [weak controller] in controller?.state != .idle })
    }

    /// 定时到点起录（调度器 start 缝的生产接线）：走既有 startRecording 装配路径
    ///（last-used 模式持久化、标记复位、输出目录、config 快照一条不落），仅绕过倒计时
    ///（简报钉定：定时起录不走倒计时，无论倒计时设置为何）。R1（Important 1 会话存活闩）：
    /// 返回语义收紧为「定时会话真的开了」——await 控制器 start 落地后按状态判定；false =
    /// 空闲预检失败 / begin 失败 / 开录即被停，调度器据此撤销停录等待（残留 deadline 会
    /// 误停用户后续手动场）。begin 失败的失败通知由控制器既有路径发出（含权限引导文案），
    /// 此处不重复。
    func startScheduledRecording() async -> Bool {
        guard controller.state == .idle else { return false }
        let task = startRecording(mode: settings.lastCaptureMode, bypassCountdown: true)
        await task.value
        let accepted = controller.state == .recording || controller.state == .paused
        NSLog("ScheduledRecording: 起录出口 state=%@ 受理=%@",
              String(describing: controller.state), accepted ? "是" : "否")
        return accepted
    }

    /// 打开定时录制面板（菜单「定时录制…」入口）：窗口归装配容器（装配红线），懒建单例
    /// 复用（`isReleasedWhenClosed = false`）；LSUIElement 应用需激活再前置（同偏好设置
    /// 窗口）。每次打开重建内容视图（R1 Minor 3 ①：面板 @State 归零，复用窗口不留上次
    /// 敞开期的陈旧开始时刻——同 presentPicker 重建纪律）。排定回调 = 调度器 schedule
    ///（重复排定整只替换）+ 收起面板；取消回调只收起（撤销既有排程走菜单「取消定时录制」）。
    func openScheduledRecordingPanel() {
        NSLog("ScheduledRecording: 定时面板打开")
        if scheduledPanelWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = NSLocalizedString("定时录制", comment: "Scheduled panel title")
            window.isReleasedWhenClosed = false
            window.center()
            scheduledPanelWindowController = NSWindowController(window: window)
        }
        scheduledPanelWindowController?.window?.contentView = NSHostingView(rootView: ScheduledRecordingPanelView(
            onSchedule: { [weak self] schedule in
                self?.scheduler.schedule(schedule)
                self?.scheduledPanelWindowController?.window?.orderOut(nil)
            },
            onClose: { [weak self] in
                self?.scheduledPanelWindowController?.window?.orderOut(nil)
            }))
        NSApp.activate(ignoringOtherApps: true)
        scheduledPanelWindowController?.showWindow(nil)
        scheduledPanelWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    /// 错过补通知的投递（装配层接线，无头不可钉）：带 category（「开始录制」动作按钮挂在
    /// category 上），授权尽力申请，被拒/失败静默——UNRecordingNotifier.post 同纪律。
    private static func postMissedNotification(title: String, body: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        if let body {
            content.body = body
        }
        content.categoryIdentifier = ScheduledMissedNotifyDelegate.categoryID
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            try? await center.add(request)
        }
    }

    /// 错过通知 category 注册（「开始录制」动作按钮挂在 category 上）：`setNotification
    /// Categories` 是整体替换语义——App 既有通知均无 category，替换无既有影响。
    private static func registerScheduledMissedCategory() {
        let startAction = UNNotificationAction(
            identifier: ScheduledMissedNotifyDelegate.startActionID,
            title: "开始录制",
            options: [])
        let category = UNNotificationCategory(
            identifier: ScheduledMissedNotifyDelegate.categoryID,
            actions: [startAction],
            intentIdentifiers: [],
            options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    // MARK: 偏好设置窗口

    /// 打开偏好设置窗口（菜单「偏好设置…」入口）：懒建单实例、复用；LSUIElement 应用
    /// 需激活再前置，避免窗口落在其他应用后面。
    /// 菜单「关于」入口：自建关于窗（图标/名称/版本/功能清单/快捷键/版权）。
    func openAbout() {
        aboutWindow.show()
    }

    /// 开启键帽预览（偏好设置「开启预览」）：监听器临时装机（enabled true + start；
    /// 幂等——录制中监听器已在装，start 自守卫），预览窗开跑。授权缺失降级仅本地
    /// 监听（与录制同口径：其他应用的按键不进预览）。
    func startKeyboardPreview() {
        keyboardMonitor.setEnabled(true)
        keyboardMonitor.start()
        keyboardPreview.start()
    }

    /// 停止键帽预览：预览窗收起；监听器仅在空闲态还原设置快照语义（stop 清状态机
    /// 残影 + setEnabled 回设置值）——录制中不摘（录制键帽照常）。
    func stopKeyboardPreview() {
        keyboardPreview.stop()
        guard controller.state == .idle else { return }
        keyboardMonitor.stop()
        keyboardMonitor.setEnabled(settings.keyboardOverlayEnabled)
    }

    func openPreferences() {
        if preferencesWindowController == nil {
            // 520×560（2026-11-14 用户目验：原 480×320 装不下录制源页全部设置项；
            // 三页已各自加 ScrollView，窗口按内容主档放大）。
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = NSLocalizedString("偏好设置", comment: "Preferences window title")
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: PreferencesView(
                settings: settings,
                keyboardPreview: keyboardPreview,
                virtualBackgroundPreview: virtualBackgroundPreview,
                customBackgroundStore: customBackgroundStore,
                onOutputDirectoryChange: { [weak self] url in
                    self?.updateOutputDirectory(to: url)
                },
                onPickWindowTarget: { [weak self] in
                    // 偏好设置入口：选定只持久化、不开录（简报「选定持久化；取消不动现有值」）
                    self?.openWindowPicker(startsRecordingOnSelection: false)
                },
                onToggleKeyboardPreview: { [weak self] in
                    guard let self else { return }
                    // 开/停互翻：预览活跃即停（含监听器还原），否则开（临时装机）。
                    if self.keyboardPreview.isActive {
                        self.stopKeyboardPreview()
                    } else {
                        self.startKeyboardPreview()
                    }
                }
            ))
            window.center()
            // 关闭收尾（2026-11-15 虚拟背景预览兜底停机）：预览相机停机 + 控制器复位
            //（下次打开重建 SwiftUI 层级，页签 onAppear/onDisappear 语义可靠）。
            let closer = PreferencesWindowCloser { [weak self, weak window] in
                self?.virtualBackgroundPreview.stop()
                if self?.preferencesWindowController?.window === window {
                    self?.preferencesWindowController = nil
                }
            }
            window.delegate = closer
            prefsWindowCloser = closer
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
    /// P8：导出通知缝（ExportNotifying）接容器通知器。LSUIElement 应用需激活再前置
    ///（同偏好设置窗口）。
    func openRecordingList() {
        if recordingListWindowController == nil {
            let viewModel = RecordingListViewModel(storeProvider: { [weak self] in
                // 装配容器与 App 同生命周期；nil 仅在容器已释放的理论窗口出现，退避临时目录
                self?.fileStore ?? RecordingFileStore(baseDirectory: FileManager.default.temporaryDirectory)
            },
            // P8：导出完成/失败通知接容器通知器（ExportNotifying 缝；T11 通知类型进
            // notifier 同款装配点）。notifier 与容器同寿，viewModel 持有强引用无环
            //（viewModel 归列表窗口控制器，先于容器释放）。
            notifier: notifier,
            // Q4：移出记账缝与 fileStore 共用同一只账本实例（过滤/自愈与记账读同一账本）。
            removedList: removedListStore,
            // Q6 编辑导出后动作三缝（仅编辑器导出挂钩，均在导出完成时刻执行）：
            postExportPrefs: { [weak self] in
                // 偏好**导出事件时刻**live 读（非开录快照——两次导出之间改偏好即时生效）。
                (self?.settings.editorPostExportRevealInFinder ?? false,
                 self?.settings.editorPostExportDeleteOriginal ?? false)
            },
            revealInFinder: { url in
                // Finder 定位并选中（reveal 恒指向新成片；顺序钉定 reveal 先于删除执行
                // ——Finder 焦点绝不被删除动作抢走）。
                NSWorkspace.shared.activateFileViewerSelecting([url])
            },
            deleteOriginalAndDraft: { original, draft in
                // 删除缝 = 纵深防御第二道闸（第一道在 PostExportActions.plan）：存在 +
                // 字节 > 0 校验过了才动手删——反目标「任何校验不通过场景误删原始文件」
                // 在执行侧独立成立。返回是否真删了原始（完成通知 originalDeleted 真源）。
                let fm = FileManager.default
                guard fm.fileExists(atPath: original.path) else { return false }
                guard let attributes = try? fm.attributesOfItem(atPath: original.path),
                      let size = attributes[.size] as? Int64, size > 0 else { return false }
                do {
                    try fm.removeItem(at: original)
                } catch {
                    NSLog("PostExport: 原始文件删除失败（\(original.path)）：\(error)")
                    return false
                }
                // 草稿尽力而为随删（原始的派生物，不留孤儿草稿；删除失败绝不影响
                // originalDeleted 语义——已删的原始是既成事实，草稿残留无害且下次编辑
                // 会覆写）。
                if let draft {
                    try? fm.removeItem(at: draft)
                }
                return true
            })
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = NSLocalizedString("文件列表", comment: "Recording list window title")
            // 2026-11-20 Omi 47.png 文件列表页：整窗深色（行/表头/缩略图观感基准同 Omi）。
            window.appearance = NSAppearance(named: .darkAqua)
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
        // 逐操作快捷键（2026-11-14）：全部复用面板/菜单同一入口——idle 预检、倒计时、
        // 装配编排单点不变（非 idle 时各入口内建守卫会拒绝/静默）。
        KeyboardShortcuts.onKeyUp(for: .startFullScreenRecording) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.startDisplayRecording(on: CGMainDisplayID())
            }
        }
        KeyboardShortcuts.onKeyUp(for: .startAppRecording) { [weak self] in
            Task { @MainActor in self?.openAppPicker() }
        }
        KeyboardShortcuts.onKeyUp(for: .startRegionRecordingShortcut) { [weak self] in
            Task { @MainActor in self?.startRegionRecording() }
        }
        KeyboardShortcuts.onKeyUp(for: .startWindowRegionRecordingShortcut) { [weak self] in
            Task { @MainActor in self?.startWindowRegionRecording() }
        }
        KeyboardShortcuts.onKeyUp(for: .startAudioOnlyRecordingShortcut) { [weak self] in
            Task { @MainActor in self?.startAudioOnlyRecording() }
        }
        KeyboardShortcuts.onKeyUp(for: .startCameraOnlyRecordingShortcut) { [weak self] in
            Task { @MainActor in self?.startCameraOnlyRecording() }
        }
        KeyboardShortcuts.onKeyUp(for: .takeRegionScreenshotShortcut) { [weak self] in
            Task { @MainActor in self?.takeRegionScreenshot() }
        }
        KeyboardShortcuts.onKeyUp(for: .takeFullScreenScreenshotShortcut) { [weak self] in
            Task { @MainActor in self?.takeFullScreenScreenshot(on: CGMainDisplayID()) }
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
        // T5：sink 末尾附带对调面重估——state 变化即重估 ⇄ 按钮可见性（含 finishing/idle
        // 收按钮），发射值直传（refreshPipSwapSurfaces(state:)）。
        Publishers.CombineLatest(controller.$state, $markingEnabled)
            .dropFirst()
            .sink { [weak self] state, enabled in
                self?.refreshMarkingSurfaces(state: state, enabled: enabled)
                self?.refreshPipSwapSurfaces(state: state)
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

    /// 标记显隐面重估（state / markingEnabled 任一变化时；含几何解析去重闸）。只消费
    /// CombineLatest **发射值**，一处不回拉（sink 在 @Published willSet 阶段同步执行——
    /// T5 修复轮2 Critical 1）；无视频画布模式（`CaptureMode.hasVideoCanvas`）标记面
    /// 整体不唤出（P7b，覆盖层激活门同谓词）；`lastCaptureMode` 开录时刻定格、会话期
    /// 内稳定，非发射值时序敏感读，与直传纪律不冲突。
    private func refreshMarkingSurfaces(state: CaptureState, enabled: Bool) {
        let modeHasCanvas = settings.lastCaptureMode.hasVideoCanvas
        markingOverlayController.refreshVisibility(enabled: enabled, state: state)
        markingToolbarPanel.setVisible(enabled && modeHasCanvas && (state == .recording || state == .paused))
        // 画笔按钮换装（发射值直传，修复轮2 Important 2：不并刷则图标/help/a11y 冻结在
        // attach 时刻的初态）。
        floatingBarPanel.refreshMarkingToggle(enabled: enabled && modeHasCanvas)
        // 开启时刻现场解析采集几何（覆盖层换算用）；disable 复位闸，re-enable 再解析。
        if enabled {
            if state == .recording || state == .paused, modeHasCanvas,
               !needsMarkingGeometryResolve, markingGeometry == nil {
                needsMarkingGeometryResolve = true
                resolveMarkingGeometry()
            }
        } else {
            needsMarkingGeometryResolve = false
        }
    }

    /// 现场解析标记几何（主 actor Task 内 await；失败留在 nil = 换算丢弃全部点，
    /// 与点击系「几何失败降级纯屏幕」同一降级精神）。落地守卫：解析期间会话已止
    /// （开录 `setMarkingEnabled(false)` 复位闸）则陈值不落地——否则跨会话晚到的几何
    /// 占住 `markingGeometry == nil` 闸，下一场错误地免于重解析（停放缺陷修复）。
    private func resolveMarkingGeometry() {
        let mode = settings.lastCaptureMode
        Task { [weak self] in
            let geometry = await PiPCaptureGeometry.resolve(for: mode)
            guard let self, self.needsMarkingGeometryResolve else { return }
            self.markingGeometry = geometry
        }
    }

    /// 标记开关唯一写入口（画笔按钮 / ⇧⌘M / 工具条关闭共用）；显隐重估在订阅里统一走。
    func setMarkingEnabled(_ enabled: Bool) {
        guard markingEnabled != enabled else { return }
        markingEnabled = enabled
    }

    /// ⇧⌘M 开关（Task 5）：录制/暂停中切换标记工具；其余状态 no-op（覆盖层只在录制期
    /// 存在——同 ⇧⌘W 的自守卫纪律）。P7b（T13 停放 Minor 同门收口）：无视频画布模式
    ///（audioOnly/cameraOnly，共享判定 hasVideoCanvas）标记入口忽略——覆盖层/工具条/
    /// 画笔按钮已在 refreshMarkingSurfaces 整面不唤出，此处兜快捷键/画笔按钮直呼。
    func toggleMarkingTools() {
        switch controller.state {
        case .recording, .paused:
            guard settings.lastCaptureMode.hasVideoCanvas else {
                NSLog("MarkingShortcut: 忽略 ⇧⌘M（当前模式无视频画布：\(settings.lastCaptureMode)）")
                return
            }
            setMarkingEnabled(!markingEnabled)
        case .idle, .countdown, .finishing:
            NSLog("MarkingShortcut: 忽略 ⇧⌘M（当前状态非录制/暂停：\(controller.state)）")
        }
    }

    // MARK: pip-swap 对调（T5）

    /// 对调按钮可见性（attach 初值 / toggle 闸的 live 读缝）：recording/paused × 本场 PiP
    /// 会话闸（判定真源 `FloatingControlBar.isPipSwapVisible`）。**订阅路径不得用本缝**——
    /// sink 在 @Published willSet 阶段同步执行，此处读 `controller.state` 是旧值（修复轮2
    /// Critical 1 同款约束），订阅路径走 `refreshPipSwapSurfaces(state:)` 直传发射值。
    private var isPipSwapSurfaceAvailable: Bool {
        FloatingControlBar.isPipSwapVisible(
            state: controller.state,
            pipRecordingActive: cameraPiP.isPiPRecordingActive)
    }

    /// 对调唯一入口（浮条 ⇄ 按钮）：翻对调态（旗标 + 浮窗换装一体，见
    /// `CameraPiPWindowController.setLayoutSwapped`——video 队列下一帧即按新布局合成）并
    /// 全面重估（tooltip/a11y 文案随对调态翻转）。可见性闸兜非按钮直呼路径——非
    /// recording/paused 一律 no-op。
    func togglePipSwap() {
        guard isPipSwapSurfaceAvailable else { return }
        cameraPiP.setLayoutSwapped(!cameraPiP.isLayoutSwapped)
        refreshPipSwapSurfaces(state: controller.state)
    }

    /// 对调面重估（发射值直传——state 用参数、不回拉 `controller.state`，willSet 旧值
    /// 纪律见 refreshMarkingSurfaces 同款约束；togglePipSwap 路径传当前 state——已由可见
    /// 性闸钉在 recording/paused）：panel.refreshPipSwap 幂等换装 + 面板尺寸重测（⇄ 按钮
    /// 出现/消失改变面板宽）。
    private func refreshPipSwapSurfaces(state: CaptureState) {
        floatingBarPanel.refreshPipSwap(
            available: FloatingControlBar.isPipSwapVisible(
                state: state,
                pipRecordingActive: cameraPiP.isPiPRecordingActive),
            swapped: cameraPiP.isLayoutSwapped)
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
            bannerText: showsStaleNotice ? NSLocalizedString("上次选择的窗口不可用，请重新选择", comment: "Stale window banner") : nil)
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
    /// 教训；`scope` 决定初始范围，重建同时换窗口标题）。2026-11-16 Omi 55.png 复刻：
    /// 窗口放大到 900×640（4 列大缩略图网格装得下），整窗钉死深色外观（Omi 恒深色页，
    /// 网格白标签/下一步按钮的观感基准）。
    private func presentPicker(scope: WindowPickerView.Scope, bannerText: String?) {
        if windowPickerWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.center()
            windowPickerWindowController = NSWindowController(window: window)
        }
        windowPickerWindowController?.window?.title = scope == .apps
            ? NSLocalizedString("选择 App", comment: "App picker title")
            : NSLocalizedString("选择窗口", comment: "Window picker title")
        windowPickerWindowController?.window?.contentView = NSHostingView(rootView: WindowPickerHostView(
            scope: scope,
            bannerText: bannerText,
            onSelect: { [weak self] windowID in self?.windowPickerSelected(windowID) },
            onAppSelect: { [weak self] bundleID in self?.appPickerSelected(bundleID) },
            onConfirm: { [weak self] windowIDs in self?.windowPickerConfirmed(windowIDs) },
            onConfirmApps: { [weak self] bundleIDs in self?.appPickerConfirmed(bundleIDs) }
        ))
        NSApp.activate(ignoringOtherApps: true)
        windowPickerWindowController?.showWindow(nil)
        windowPickerWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    /// App「下一步」确认（2026-11-20 Omi 38.png 多选补齐）：单选 = 既有 `.app` 语义
    ///（`onAppSelect` 同一条路）；多选 = `.apps` 多应用合成录制。偏好设置入口多选无
    /// 落点（同窗口流程纪律：多选只在「选定即开始」场景有意义）。
    private func appPickerConfirmed(_ bundleIDs: [String]) {
        guard controller.state == .idle else {
            NSLog("WindowPicker: 忽略选定 App 集（当前状态非 idle：\(controller.state)）")
            dismissWindowPicker()
            return
        }
        guard !bundleIDs.isEmpty else { return }
        if bundleIDs.count == 1 {
            appPickerSelected(bundleIDs[0])
            return
        }
        let startsRecording = pendingWindowPickerStartsRecording
        dismissWindowPicker()
        NSLog("WindowPicker: 多 App 录制启动（\(bundleIDs.count) 个应用）")
        if startsRecording {
            startRecording(mode: .apps(bundleIDs))
        }
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
        persistAndMaybeStart(windowID: windowID, startsRecording: startsRecording)
    }

    /// 单窗目标的持久化 + 可选直录（windowPickerSelected 与「下一步」单选路径共用）：
    /// 单窗所有者快照组装稳定标识（裁定 1）→ 持久化 → 按场景决定立即开始。快照/标识
    /// 取不到（选中间隙窗口关闭）记日志后放弃：不持久化、不开录（死 windowID 开录必败）。
    private func persistAndMaybeStart(windowID: CGWindowID, startsRecording: Bool) {
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

    /// 「下一步」确认回调（2026-11-16 Omi 55.png 多选补齐）：网格选中集按流程分流——
    /// 窗口区域流程单选 = 既有单窗拖框；多选 = union 包围盒拖框（新能力 `.windowsRegion`）；
    /// 窗口录制流程单选 = 既有单窗直录（持久化目标）；多选 = 多窗口合成录制（新能力
    /// `.windows`，union 画布，不经单窗目标持久化）。偏好设置入口（startsRecording=false）
    /// 多选无落点——只持久化单窗目标，多选静默忽略（该入口的语义就是「选一个默认目标」）。
    private func windowPickerConfirmed(_ windowIDs: [CGWindowID]) {
        guard controller.state == .idle else {
            NSLog("WindowPicker: 忽略「下一步」（当前状态非 idle：\(controller.state)）")
            dismissWindowPicker()
            return
        }
        let anchorsRegion = pendingWindowPickerAnchorsRegion
        let startsRecording = pendingWindowPickerStartsRecording
        dismissWindowPicker()
        guard !windowIDs.isEmpty else { return }
        if anchorsRegion {
            if windowIDs.count == 1 {
                beginWindowRegionSelection(windowID: windowIDs[0])
            } else {
                beginWindowsRegionSelection(windowIDs: windowIDs)
            }
            return
        }
        if windowIDs.count == 1 {
            persistAndMaybeStart(windowID: windowIDs[0], startsRecording: startsRecording)
        } else if startsRecording {
            NSLog("WindowPicker: 多窗口录制启动（\(windowIDs.count) 个窗口，union 画布）")
            startRecording(mode: .windows(windowIDs))
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

    /// 多窗口 union 区域拖框（2026-11-16 Omi 55.png 多选补齐，「下一步」多选路径）：
    /// 现场枚举所选窗口的 union 包围盒为锚（选中间隙部分/全部关闭——全部关闭放弃；
    /// 部分关闭按存活集），拖拽产出 union 相对 rect → 开录 `.windowsRegion`。取消语义
    /// 与单窗区域一致（ESC/亚点拖动/遮罩被关 = 静默放弃）。持久化走 startRecording
    /// 统一入口（`lastCaptureMode` 记 windowRegion 模式，⇧⌘R 上次使用模式自动包含）。
    private func beginWindowsRegionSelection(windowIDs: [CGWindowID]) {
        Task { @MainActor in
            let windows: [ShareableWindow]
            do {
                windows = try await WindowPicker.enumeratedWindows()
            } catch {
                NSLog("WindowRegion: 窗口枚举失败，放弃多窗口区域选择：\(error)")
                return
            }
            let idSet = Set(windowIDs)
            let frames = windows.filter { idSet.contains($0.windowID) }.map(\.frame)
            guard !frames.isEmpty else {
                NSLog("WindowRegion: 所选窗口均已不可见或已关闭，放弃多窗口区域选择")
                return
            }
            let canvas = frames.reduce(CGRect.null) { $0.union($1) }
            // union 包围盒 CG 全局（左上原点）→ 遮罩 Cocoa 全局 frame（同单窗区域换算口径）。
            let primaryHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height ?? 0
            let cocoaFrame = RegionSelectorMath.cocoaRect(fromCGRect: canvas, primaryScreenHeight: primaryHeight)
            guard let rect = await RegionSelector.selectWindowRegion(anchorFrame: cocoaFrame) else { return }
            startRecording(mode: .windowsRegion(windows: windowIDs, rect: rect))
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
    let onConfirm: ([CGWindowID]) -> Void
    let onConfirmApps: ([String]) -> Void

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
                onConfirm: onConfirm,
                onConfirmApps: onConfirmApps,
                initialScope: scope)
        }
    }
}

/// 定时录制错过通知的 UNUserNotificationCenter delegate（P6b 装配层接线，无头不可钉，
/// 真机验收）：唯一职责是把通知上的「开始录制」动作派发到挂载的闭包（调度器 notifyMissed
/// 缝在投递时刻挂载，闭包内部路由 start 缝 → `startScheduledRecording`）。R1（Minor 2）：
/// 类标 `@MainActor`、协议符合亦随类隔离（`@MainActor UNUserNotificationCenterDelegate`
/// ——编译器裁定的主 actor 隔离符合，消除 conformance crossing 告警），`startAction` 的读
/// 与调移进主 actor Task——delegate 回调无主线程保证，属性读写不能裸奔在回调线程；
/// completionHandler 保持同步调用（时序不变，系统不等待派发）。按系统语义 delegate 被弱
/// 引用，由 AppAssembly 强持有（`scheduledMissedDelegate`）。
@MainActor
private final class ScheduledMissedNotifyDelegate: NSObject, @MainActor UNUserNotificationCenterDelegate {
    /// 错过通知的 category 标识（内容侧 `categoryIdentifier` 与此对齐）。
    static let categoryID = "hummingbird.scheduledMissed"
    /// 「开始录制」动作标识。
    static let startActionID = "hummingbird.scheduledMissed.start"
    /// 最近一条错过通知挂载的「开始录制」动作（主 actor 内挂载与调用；后投递覆盖前投递——
    /// 两动作同源同语义，覆盖无行为差异）。
    var startAction: (() -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        completionHandler()
        guard response.actionIdentifier == Self.startActionID else { return }
        Task { @MainActor in
            self.startAction?()
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

    /// Dock 图标点击 / Finder 重开（2026-11-15 用户反馈「dock app图标点击没有界面」）：
    /// 打开启动条（Omi 主界面——7 录制模式横条）。LSUIElement 常态无 Dock 图标；
    /// 用户关掉「隐藏 Dock 图标」后 Dock 点击即落到本入口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.registeredAssembly?.openLaunchBar()
        return true
    }

    /// 全新启动（Finder/Dock 双击 / 登录项）：打开启动条——与 Omi 启动行为对齐
    ///（启动即见主界面；× 可收，菜单栏入口照常）。MenuBarExtra App 生命周期下本回调
    /// 可能先于 `App.init`（装配登记未就位），就绪短轮询兜住竞态（3s 上界）。
    func applicationDidFinishLaunching(_ notification: Notification) {
        showLaunchBarWhenAssemblyReady()
    }

    /// 装配登记就绪轮询（`registeredAssembly` 由 `AppAssembly.init` 在 `App.init` 内
    /// 写入；就绪即开启动条，60×50ms 未就位放弃——装配本身失败是另一级故障）。
    private func showLaunchBarWhenAssemblyReady(attempt: Int = 0) {
        guard attempt < 60 else { return }
        if let assembly = Self.registeredAssembly {
            assembly.openLaunchBar()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.showLaunchBarWhenAssemblyReady(attempt: attempt + 1)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {        guard let assembly = Self.registeredAssembly else { return .terminateNow }
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
        alert.messageText = NSLocalizedString("正在录制中，确定退出吗？", comment: "Quit confirm title")
        alert.informativeText = NSLocalizedString("「退出并保存录制」将停止录制并保留成片；「退出并丢弃」将停止录制并删除未保存的内容。", comment: "Quit confirm detail")
        alert.addButton(withTitle: NSLocalizedString("退出并保存录制", comment: "Quit save"))
        alert.addButton(withTitle: NSLocalizedString("退出并丢弃", comment: "Quit discard"))
        alert.addButton(withTitle: NSLocalizedString("取消", comment: "Cancel"))
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
struct HummingbirdApp: App {
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
                scheduler: assembly.scheduler,
                onStartDisplay: { assembly.startDisplayRecording(on: $0) },
                onStartWindowPicker: { assembly.openWindowPicker(startsRecordingOnSelection: true) },
                onStartAppPicker: { assembly.openAppPicker() },
                onStartRegion: { assembly.startRegionRecording() },
                onStartWindowRegion: { assembly.startWindowRegionRecording() },
                onStartAudioOnly: { assembly.startAudioOnlyRecording() },
                onStartCameraOnly: { assembly.startCameraOnlyRecording() },
                onRestartRecording: { assembly.restartRecording() },
                onTakeRegionScreenshot: { assembly.takeRegionScreenshot() },
                onTakeFullScreenScreenshot: { assembly.takeFullScreenScreenshot(on: $0) },
                onOpenRecordingList: { assembly.openRecordingList() },
                onOpenScheduledPanel: { assembly.openScheduledRecordingPanel() },
                onCancelScheduled: { assembly.scheduler.cancel() },
                onOpenPreferences: { assembly.openPreferences() },
                onOpenAbout: { assembly.openAbout() }
            )
        } label: {
            // T19：状态图标（idle/countdown/recording/paused/finishing 逐态换装），
            // 独立视图自持 @ObservedObject，状态变化不经 App body 重跑直达菜单栏。
            // P6b：排程等待期 idle 用倒计时态（timer），故 label 同持调度器。
            MenuBarStatusIcon(controller: assembly.controller, scheduler: assembly.scheduler)
        }
        // Omi 化面板（2026-11-14）：NSMenu 式菜单 → 卡片窗口面板（MenuBarView 头注）。
        .menuBarExtraStyle(.window)
        Window(NSLocalizedString("授权设置", comment: "Permission window title"), id: "permission-onboarding") {
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

/// 偏好设置窗口关闭收尾桥（2026-11-15 虚拟背景预览兜底停机）：windowWillClose 主线程
/// 回调装配层闭包（停预览相机 + 控制器复位）。装配层持强引用防释放。
final class PreferencesWindowCloser: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
