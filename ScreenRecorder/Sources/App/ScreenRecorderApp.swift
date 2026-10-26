import AppKit
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
    /// 偏好设置窗口控制器（T17）：窗口与控制器归装配容器（装配红线），懒建单例复用。
    private var preferencesWindowController: NSWindowController?
    /// 文件列表窗口控制器（T18）：窗口与控制器归装配容器（装配红线），懒建单例复用；
    /// 列表模型经 store 取数缝读当前 `fileStore`（换输出目录后刷新即见新目录）。
    private var recordingListWindowController: NSWindowController?

    /// 全局快捷键已挂载的进程级闸（T17 裁定 4）：KeyboardShortcuts 的 onKeyUp 把动作
    /// 追加进包内静态注册表，重挂（assembly init 重跑）会双触发——挂载恰好一次。
    private static var globalShortcutsMounted = false

    init() {
        let settings = SettingsStore()
        let fileStore = RecordingFileStore(baseDirectory: settings.outputDirectory)
        let cameraPiP = CameraPiPWindowController()
        let clickHighlightTracker = ClickHighlightTracker(enabled: settings.clickHighlightEnabled)
        let coordinator = RecordingSessionCoordinator(
            cameraPiP: cameraPiP,
            clickHighlightTracker: clickHighlightTracker)
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
        let sourceLossMonitor = SourceLossMonitor { [weak controller] in
            Task { @MainActor in controller?.handleSessionFailure(SourceLossError(removedDisplayID: nil)) }
        }
        controller.sourceLossMonitor = sourceLossMonitor
        // 麦克风路由观察器（T18）：命中 → coordinator 转发当前混音器自愈重建（主队列保证，
        // 见 MicrophoneRouteWatcher 裁定 4 注释）。
        let microphoneRouteWatcher = MicrophoneRouteWatcher { [weak coordinator] in
            coordinator?.rebuildAudioRoute()
        }
        controller.microphoneRouteWatcher = microphoneRouteWatcher
        // 磁盘监控 / 流失败出口 → 状态机（DiskSpaceMonitor 与 onStreamFailure 均主队列保证）
        coordinator.onInterruption = { error in
            Task { @MainActor in controller.handleSessionFailure(error) }
        }
        coordinator.onDiskSpaceWarning = {
            Task { @MainActor in controller.showDiskSpaceWarning() }
        }

        self.settings = settings
        self.controller = controller
        self.fileStore = fileStore
        self.sourceLossMonitor = sourceLossMonitor
        self.microphoneRouteWatcher = microphoneRouteWatcher
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
        mountGlobalShortcutsIfNeeded()
    }

    // MARK: 录制入口（T17：菜单与全局快捷键共用，配置装配单点化）

    /// 菜单「开始录制（全屏）」入口：主显示器全屏。
    func startFullScreenRecording() {
        startRecording(mode: .display(CGMainDisplayID()))
    }

    /// 唯一的开始装配点：持久化「上次使用的模式」（裁定 2：每次开始都记）→ 建输出目录 →
    /// 从 SettingsStore 快照装配 config → 进入控制器状态机（快照语义：录制中途改设置
    /// 不影响进行中的录制）。控制器自守卫（非 `.idle` 一律 no-op），此处不重复判态。
    private func startRecording(mode: CaptureMode) {
        settings.lastCaptureMode = mode
        try? fileStore.ensureDirectory()
        let config = RecordingConfiguration(
            mode: mode,
            captureSystemAudio: settings.captureSystemAudio,
            captureMicrophone: settings.captureMicrophone,
            micVolume: settings.micVolume,
            includeCamera: settings.pipEnabled,
            fps: settings.fps,
            codec: settings.videoCodec,
            outputURL: fileStore.nextFileURL(),
            clickHighlightEnabled: settings.clickHighlightEnabled
        )
        Task { await controller.start(mode: mode, config: config) }
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
    /// 发现的固定拷贝缺陷在此封堵）。LSUIElement 应用需激活再前置（同偏好设置窗口）。
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
            recordingListWindowController = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        recordingListWindowController?.showWindow(nil)
        recordingListWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    /// 全局快捷键订阅（⇧⌘R / ⇧⌘P）：App 启动（装配）时挂载恰好一次。动作经主 actor
    /// 跳转进入装配层开关方法；包内 `onKeyUp` 把动作追加进静态注册表（无需持有返回值），
    /// 故以 `globalShortcutsMounted` 进程级闸防重挂双触发（裁定 4）。
    private func mountGlobalShortcutsIfNeeded() {
        guard !Self.globalShortcutsMounted else { return }
        Self.globalShortcutsMounted = true
        KeyboardShortcuts.onKeyUp(for: .startStopRecording) { [weak self] in
            Task { @MainActor in self?.toggleStartStopRecording() }
        }
        KeyboardShortcuts.onKeyUp(for: .pauseResumeRecording) { [weak self] in
            Task { @MainActor in self?.togglePauseResumeRecording() }
        }
    }
}

@main
struct ScreenRecorderApp: App {
    @StateObject private var assembly: AppAssembly

    init() {
        _assembly = StateObject(wrappedValue: AppAssembly())
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                controller: assembly.controller,
                onStartFullScreen: { assembly.startFullScreenRecording() },
                onOpenRecordingList: { assembly.openRecordingList() },
                onOpenPreferences: { assembly.openPreferences() }
            )
        } label: {
            Image(systemName: "record.circle")
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
