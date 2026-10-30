import Combine
import CoreGraphics
import Foundation
import ScreenCaptureKit

// MARK: - 状态与协议（brief Produces 逐字）

/// 录制会话状态机状态。
enum CaptureState: Equatable {
    case idle
    case countdown(secondsLeft: Int)
    case recording
    case paused
    case finishing
}

/// 采集会话抽象：真实实现 `RecordingSessionCoordinator` 包
/// SCStreamRecorder + DiskSpaceMonitor + PowerAssertionKeeper；测试注入 FakeSession。
protocol CaptureSessionManaging {
    func begin(_ config: RecordingConfiguration) async throws
    func pause()
    func resume()
    func finish() async -> URL?
}

/// 通知出口抽象（本任务新增的注入缝）：生产实现 `UNRecordingNotifier`（App 层），
/// 测试注入 spy——UNUserNotificationCenter 在无头测试进程不可用，必须可替换。
@MainActor
protocol RecordingNotifying: AnyObject {
    func notifySaved(fileURL: URL)
    func notifyFailure(message: String)
    func notifyDiskSpaceWarning()
}

/// 会话级领域错误：begin 前置磁盘检查与磁盘停阈值中断（区别于采集管线原始错误，
/// 后者原样透传给 `CaptureController.handleSessionFailure` 做文案归类）。
enum CaptureSessionError: Equatable, LocalizedError {
    /// begin 前置检查失败：空间不足，不开录（T5 派发指针）。
    case insufficientDiskSpace(freeBytes: Int64, requiredBytes: Int64)
    /// 录制中跌破 stop 阈值：自动收尾保存。
    case diskSpaceCritical

    var errorDescription: String? {
        switch self {
        case .insufficientDiskSpace(let free, let required):
            let freeText = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
            let requiredText = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
            return "磁盘剩余空间不足（剩 \(freeText)，低于安全阈值 \(requiredText)），无法开始录制"
        case .diskSpaceCritical:
            return "磁盘剩余空间严重不足"
        }
    }
}

// MARK: - RecordingSessionCoordinator

/// 真实采集会话（brief：包 SCStreamRecorder + writer + monitor + keeper；writer 会话在
/// SCStreamRecorder 内部创建）。职责只有装配与生命周期：begin 里即时磁盘检查 + 启动
/// DiskSpaceMonitor + activate 电源断言 + 建 recorder 接失败通道；finish 里 stopMonitoring +
/// deactivate + recorder.stop 收尾。单会话实例：一次 begin/finish 对应一场录制。
///
/// 磁盘监控接线（T5 携带指针）：轮询 timer 首触发在 pollInterval 之后，启动时的即时检查由
/// begin 直接读 provider（低于 stop 阈值抛 `insufficientDiskSpace`，不开录）；录制中
/// onStop → `onInterruption(diskSpaceCritical)`、onWarn → `onDiskSpaceWarning`，
/// 均由 DiskSpaceMonitor 保证主队列投递，装配层接至 CaptureController。
/// 「stop-supersedes-warn」：warn 出口只通知不改状态，收尾优先级与去重由控制器状态机
/// 把守（见 `CaptureController.showDiskSpaceWarning` / `handleSessionFailure`）。
final class RecordingSessionCoordinator: CaptureSessionManaging {
    /// 会话中断出口（流失败 / 磁盘停阈值），主队列保证。
    /// 装配层接至 `CaptureController.handleSessionFailure`（onStreamFailure 的 T18 台账指针）。
    var onInterruption: ((Error) -> Void)?
    /// 低空间警告出口（warn 阈值），主队列保证。装配层接至 `showDiskSpaceWarning`。
    var onDiskSpaceWarning: (() -> Void)?

    private let keeper = PowerAssertionKeeper()
    private let diskProvider: DiskFreeSpaceProviding
    private let warnBelow: Int64
    private let stopBelow: Int64
    private var recorder: SCStreamRecorder?
    private var monitor: DiskSpaceMonitor?
    /// PiP 装配单元（T15，AppAssembly 注入；nil = 无 PiP 能力，录制照常纯屏幕）。
    /// 运行时生命周期挂在 begin/finish（既有 stop 路径），失败内部降级不阻断录制。
    private let cameraPiP: CameraPiPWindowController?
    /// 点击高亮跟踪器（T16，AppAssembly 注入；nil = 未装配，点击路全关）。所有权归装配层；
    /// 开关重对齐与 start/stop 由 CaptureController 生命周期钩子驱动，本层只负责把
    /// 屏坐标 → 捕获像素的取数闭包装进 recorder（begin 时按当次几何一次性组装）。
    private let clickHighlightTracker: ClickHighlightTracker?

    init(diskProvider: DiskFreeSpaceProviding = VolumeFreeSpaceProvider(),
         warnBelow: Int64 = 2_000_000_000,
         stopBelow: Int64 = 500_000_000,
         cameraPiP: CameraPiPWindowController? = nil,
         clickHighlightTracker: ClickHighlightTracker? = nil) {
        self.diskProvider = diskProvider
        self.warnBelow = warnBelow
        self.stopBelow = stopBelow
        self.cameraPiP = cameraPiP
        self.clickHighlightTracker = clickHighlightTracker
    }

    func begin(_ config: RecordingConfiguration) async throws {
        // 即时磁盘检查：空间不足直接失败，不开录（T5 指针：轮询首触发在 pollInterval 后）
        if let free = diskProvider.freeBytes(at: config.outputURL), free < stopBelow {
            throw CaptureSessionError.insufficientDiskSpace(freeBytes: free, requiredBytes: stopBelow)
        }
        let monitor = DiskSpaceMonitor(
            provider: diskProvider,
            url: config.outputURL,
            warnBelow: warnBelow,
            stopBelow: stopBelow
        )
        monitor.onWarn = { [weak self] in self?.onDiskSpaceWarning?() }
        monitor.onStop = { [weak self] in self?.onInterruption?(CaptureSessionError.diskSpaceCritical) }
        monitor.startMonitoring()
        self.monitor = monitor

        keeper.activate(reason: "屏幕录制进行中")

        // T15：PiP 随录制启动（includeCamera 时）——摄像头 + 浮窗先热，首帧起 PiP 就位。
        // 几何解析失败 / 授权拒绝 / 无摄像头在内部降级为纯屏幕（T8 混音降级精神），不阻断。
        // （begin 本体非主 actor；浮窗/摄像头装配全主线程，MainActor.run 跳转。）
        // T16：采集几何同场复用——PiP 摆放、点击换算与缩放中心换算共用一次 resolve
        //（nil = 解析失败，各效果内部降级纯屏幕）。
        // 裁定 6（零告警恢复）：resolve 结果一次性定为 let——var 捕获在 @Sendable 闭包
        //（MainActor.run / clickOverlayProvider）下触发 Swift 6 并发告警；行为不变
        //（两者均不开启时 resolve 原本就被跳过，nil 直通）。
        let wantsPiP = config.includeCamera && cameraPiP != nil
        let wantsClick = config.clickHighlightEnabled && clickHighlightTracker != nil
        // P1a：自动缩放骑同一点击源（tracker 的 onClick），几何同样用于点击中心换算。
        let wantsZoom = config.autoZoomEnabled && clickHighlightTracker != nil
        let geometry: PiPCaptureGeometry? = if wantsPiP || wantsClick || wantsZoom {
            await PiPCaptureGeometry.resolve(for: config.mode)
        } else {
            nil
        }
        if wantsPiP, let cameraPiP {
            await MainActor.run { cameraPiP.beginRecording(geometry: geometry) }
        }

        let recorder = SCStreamRecorder(config: config)
        // PiP 注入缝（T15）：合成器逐帧取最新摄像头帧与浮窗位置；都取不到时合成器直返
        // 原 buffer，与直通路径等价。
        recorder.pipPixelBufferProvider = cameraPiP?.latestPixelBuffer
        recorder.pipFrameProvider = cameraPiP?.currentPiPFrame
        // 点击高亮 + 自动缩放取数缝（T16 / P1a）：两者共用一次几何解析与主屏翻转高度。
        // 转换器按当次几何与主屏翻转入口一次性组装；tracker 未启动/未衰减窗口内
        // currentState 返回 nil，合成器按无高亮直通。几何解析失败（nil）不装缝 = 对应
        // 效果整体降级关闭。
        if let clickHighlightTracker, let geometry, wantsClick || wantsZoom {
            let flipHeight = await MainActor.run { ClickHighlightTracker.primaryScreenHeight() }
            if config.clickHighlightEnabled {
                recorder.clickOverlayProvider = { [weak clickHighlightTracker] in
                    clickHighlightTracker?.currentState { cocoaPoint in
                        let cgPoint = ClickHighlightTracker.cgGlobalPoint(
                            fromCocoaGlobal: cocoaPoint,
                            primaryScreenHeight: flipHeight)
                        return geometry.capturePixelPoint(fromCGPoint: cgPoint)
                    }
                }
            }
            // P1a 自动缩放接线：点击 → 归一化中心 → AutoZoomState.click；缩放仿射经
            // zoomStateProvider 逐帧进合成器。换算链与点击环完全同源（Cocoa 全局 →
            // CG 全局 → capturePixelPoint，同一几何与翻转入口），只补两步归一化：
            // ÷ 画布尺寸；y 翻转为 CI 画布 y 向上口径（合成器 placeClickOverlay 的
            // `bounds.height - y` 同一翻转）——缩放中心与环落在同一画面位置。
            // zoomState 为本场新建（config 快照档位：录制中途改设置不影响进行中的录制；
            // 时间线随 recorder 生命周期存亡，无需跨场 reset）。provider 缝强持有它
            //（生命周期 = recorder = 单场录制）；onClick 弱引用防 tracker 跨场滞留。
            if config.autoZoomEnabled {
                await MainActor.run {
                    let zoomState = AutoZoomState(level: CGFloat(config.autoZoomLevel))
                    let canvasBounds = CGRect(origin: .zero, size: geometry.capturePixelSize)
                    clickHighlightTracker.onClick = { [weak zoomState] cocoaPoint, _ in
                        // tracker 回调主线程契约（类注释钉定）：assumeIsolated 直进主
                        // actor，零调度延迟，时间线起点贴合点击帧。
                        MainActor.assumeIsolated {
                            guard let zoomState,
                                  canvasBounds.width > 0, canvasBounds.height > 0 else { return }
                            let cgPoint = ClickHighlightTracker.cgGlobalPoint(
                                fromCocoaGlobal: cocoaPoint,
                                primaryScreenHeight: flipHeight)
                            let pixel = geometry.capturePixelPoint(fromCGPoint: cgPoint)
                            zoomState.click(
                                atNormalizedPoint: CGPoint(x: pixel.x / canvasBounds.width,
                                                           y: 1 - pixel.y / canvasBounds.height),
                                now: ProcessInfo.processInfo.systemUptime)
                        }
                    }
                    recorder.zoomStateProvider = {
                        // video 队列逐帧读（非隔离缝，锁保护锚点快照）；时钟 = 系统运行
                        // 时长（与 CaptureController.monotonicNow 同口径，不受改时间影响）。
                        // **强持有** zoomState：provider 缝是它唯一的宿主，生命周期 =
                        // recorder = 单场录制（finish 收走 recorder 即释放）。
                        zoomState.frameTransform(in: canvasBounds,
                                                 now: ProcessInfo.processInfo.systemUptime)
                    }
                }
            }
        }
        // 失败通道（T18 台账指针）：recorder 首失败经此上报，上层负责 stop 保存路径
        recorder.onStreamFailure = { [weak self] error in self?.onInterruption?(error) }
        self.recorder = recorder
        do {
            try await recorder.start()
        } catch {
            // 回滚：停监控 + 释放断言 + 摘除失败 recorder + 收 PiP（若已激活，幂等）；
            // 占位/claim 清理由 recorder 内部完成
            await MainActor.run { cameraPiP?.endRecording() }
            self.recorder = nil
            monitor.stopMonitoring()
            self.monitor = nil
            keeper.deactivate()
            throw error
        }
    }

    func pause() { recorder?.pause() }

    func resume() { recorder?.resume() }

    func finish() async -> URL? {
        monitor?.stopMonitoring()
        monitor = nil
        keeper.deactivate()
        guard let recorder else { return nil } // begin 未成功：无会话可收尾
        self.recorder = nil
        await recorder.stop()
        // Task 15：PiP 收尾挂在既有 stop 路径（流已停、video 队列在途帧已排空——
        // removeStreamOutput 栅栏保证），无新停止竞态；摄像头停与浮窗收起幂等。
        await MainActor.run { cameraPiP?.endRecording() }
        // 暂停丢弃诊断（T10 交付：stop 后快照仍可读）——有丢弃时留日志供成片时长归因
        let droppedVideo = recorder.pausedDroppedVideoFrameCount
        let droppedAudio = recorder.pausedDroppedAudioPacketCount
        if droppedVideo > 0 || droppedAudio > 0 {
            NSLog("RecordingSessionCoordinator: 暂停期间丢弃 video 帧 %d / audio 包 %d（成片时长归因）", droppedVideo, droppedAudio)
        }
        if let lastError = recorder.lastError {
            NSLog("RecordingSessionCoordinator: 本次录制失败原因：\(lastError)")
        }
        return recorder.finishedFileURL
    }

    /// 麦克风路由自愈（T18，MicrophoneRouteWatcher 主队列回调）：转发当前 recorder 的混音器
    /// 配置变化重建（engine 停机/格式重读/tap 重装/重启——裁定 5 自愈，无 UI）。无进行中
    /// 录制（begin 未成功/已收尾）recorder 为 nil，no-op。
    func rebuildAudioRoute() {
        recorder?.rebuildAudioAfterConfigurationChange()
    }

    /// 麦克风静音实时下发（终审 F2，偏好「录制中静音麦克风」翻转 / live 链）：转发当前
    /// recorder 的混音器摘/回装 inputNode tap。无进行中录制 recorder 为 nil，no-op
    ///（持久化值自下一场开录的 config 快照生效）。
    func setMicMuted(_ muted: Bool) {
        recorder?.setMicMuted(muted)
    }

    /// 麦克风增益实时下发（终审 F2，偏好「麦克风音量」滑杆拖动）：转发当前 recorder 的
    /// 混音器 per-input 音量施加。无进行中录制 recorder 为 nil，no-op（同上，快照链兜底）。
    func setMicVolume(_ volume: Float) {
        recorder?.setMicVolume(volume)
    }
}

// MARK: - CaptureController

/// 录制状态机（@MainActor ObservableObject）：菜单开始录制 → 倒计时（可打断）→ 录制/暂停 →
/// 收尾；浮条（`.recording`/`.paused` 显示）与失败自动保存均由本类驱动。所有状态转换与
/// 收尾任务都在主 actor 上串行——session.begin/finish 不存在并发调用。
///
/// 生命周期边界（本任务裁定，简报留白处）：
/// 1. `start` 仅 `.idle` 可发起，且全程持 `startInFlight` 同步闩（guard 与首个 await 之间
///    state 仍为 `.idle`，并发第二次 start 在同步段即被拒绝）；其余状态 no-op（单会话语义）。
/// 2. `pause`/`resume`/`stop`/`cancelAndDiscard` 只在语义合法状态生效，非法一律 no-op
///    （与 SCStreamRecorder 的 no-op 契约同风格，调用方无需跟踪内部生命周期）。
/// 3. `.finishing` 为去抖闸位：`stop`/`cancelAndDiscard`/`handleSessionFailure` 入口先同步置位
///    再派收尾 Task，重复触发（含失败通道重入）在同步段即被拒绝，收尾恰好一次。
/// 4. 倒计时期间 `cancelAndDiscard` → 静默取消回 `.idle`（begin 未发）；begin 已发出后
///    （`hasBegun`）则记 `pendingDiscard`，begin 返回后立即走丢弃收尾——begin/finish 经主
///    actor 串行化，永不并发。
/// 5. 失败通道在 `.countdown` 且 begin 在途到达时记 `pendingFailure`，begin 返回后按失败
///    路径收尾；begin 自身失败（如磁盘不足）直接回 `.idle` 并通知，无会话可收尾。
/// 6. `onFinishedFile` 回调约定：在主队列（主 actor）同步调用——`finalize` 内先置 `.idle`
///    再回调，二者之间无挂起点，观察者看到 `.idle` 时回调必然已完成。
/// 7. 失败自动保存语义：`handleSessionFailure` 走 stop 保存路径，成片保留并回调
///    `onFinishedFile`，同时通知失败原因（权限类失败引导重启/重授权，见 failureMessage）。
/// 8. 点击高亮跟踪器（T16）：`start` 时以 config 快照重对齐 enabled（opt-in 真源），
///    `enterRecordingPhase` 启动监听、两条 finalize 出口摘除——倒计时与收尾期不监听；
///    tracker nil（未装配）全链路 no-op，不影响录制。
/// 9. 源丢失监视器与路由观察器（T18）：同边界 8 的装配缝形状（AppAssembly 持有注入，
///    nil = 未装配 no-op），`enterRecordingPhase` 启动、两条 finalize 出口摘除。源丢失
///    监视按捕获模式取 displayID（display/region 匹配该显示器；window = 采集全台语义
///    nil，任一移除触发——裁定 2），命中经装配层接 `handleSessionFailure` 自动保存；
///    路由观察命中经装配层接 `RecordingSessionCoordinator.rebuildAudioRoute`（混音器
///    自愈，无 UI）。无锁屏出口（裁定 3：锁屏不构成中断）。
@MainActor
final class CaptureController: ObservableObject {
    @Published private(set) var state: CaptureState = .idle
    /// 录制累计时长（秒，不含暂停段）：`.recording` 时经 Task 计时器每 0.5s 刷新。
    @Published private(set) var elapsed: TimeInterval = 0

    /// 通知出口（App 装配点注入；测试默认不注入时失败/警告静默）。
    var notifier: RecordingNotifying?

    /// 点击高亮跟踪器（T16 装配缝）：AppAssembly 持有，控制器仅驱动生命周期。nil = 未装配。
    var clickHighlightTracker: ClickHighlightTracker?

    /// 源丢失监视器（T18 装配缝）：AppAssembly 持有，控制器仅驱动生命周期（同边界 8 形状）。
    /// nil = 未装配，全链路 no-op。
    var sourceLossMonitor: SourceLossMonitor?
    /// 麦克风路由观察器（T18 装配缝）：录制期观察 engine 配置变化，回调装配层做混音器自愈
    /// 重建（无 UI）。nil = 未装配，全链路 no-op。
    var microphoneRouteWatcher: MicrophoneRouteWatcher?

    /// 测试缝：会话内等待（倒计时步进 1s / elapsed 计时器 0.5s）。生产 = `Task.sleep`，
    /// 所在 Task 被取消时抛错打断；测试注入受控推进。
    var waitForTick: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
    /// 测试缝：单调时钟（秒）。生产 = 系统运行时长（不受用户改时间影响）。
    var monotonicNow: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// 测试缝：屏幕录制 TCC 预检。生产 = `CGPreflightScreenCaptureAccess()`。
    var screenPermissionProbe: @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() }

    private let session: CaptureSessionManaging
    private var store: RecordingFileStore
    private let countdownSeconds: Int
    private let onFinishedFile: (URL) -> Void

    private var countdownTask: Task<Bool, Never>?
    private var elapsedTimerTask: Task<Void, Never>?
    private var accumulatedActive: TimeInterval = 0
    private var segmentStartUptime: TimeInterval?
    /// 倒计时结束后 begin 已发出（此后 cancelAndDiscard 退化为收尾丢弃而非静默取消）。
    private var hasBegun = false
    /// start 全程同步闩（guard 与首个 await 之间的窗口里，state 仍是 .idle——并发第二次
    /// start 必须在同步段即被拒绝，否则可能双 begin）。defer 覆盖 start 整个执行期。
    private var startInFlight = false
    /// begin 在途期间的丢弃/失败意图：begin 返回后立即执行（边界 4/5）。
    private var pendingDiscard = false
    private var pendingFailure: Error?
    /// 当前会话被采集的显示器（T18 源丢失匹配语义；nil = 采集全台语义——任一显示器移除触发）。
    private var sourceDisplayID: CGDirectDisplayID?

    init(session: CaptureSessionManaging,
         store: RecordingFileStore,
         countdownSeconds: Int,
         onFinishedFile: @escaping (URL) -> Void) {
        self.session = session
        self.store = store
        self.countdownSeconds = countdownSeconds
        self.onFinishedFile = onFinishedFile
    }

    /// 输出目录在偏好设置中变更后由装配层换入新 store（T17；值语义结构体，整只替换）。
    /// 此后 discard 路径 `store.delete` 作用于新目录内的成片；既有测试不受影响（默认不换）。
    func updateStore(_ newStore: RecordingFileStore) {
        store = newStore
    }

    // MARK: 启动

    /// 启动录制：`countdownSeconds > 0` 时先走逐秒倒计时（每步可被 `cancelAndDiscard` 打断回
    /// `.idle`），随后 begin 并进入 `.recording`。倒计时只是状态机（视觉覆盖层为 Task 12）。
    func start(mode: CaptureMode, config: RecordingConfiguration) async {
        guard state == .idle, !startInFlight else { return }
        startInFlight = true
        defer { startInFlight = false }
        var config = config
        config.mode = mode // start 的 mode 参数为准（简报签名 mode 与 config 并列）
        // T16：enabled 真源是录制开始的 config 快照（外部 defaults 改动自下一场录制生效）；
        // 监听中关闭时 tracker 内部立即摘除 monitor。
        // P1a：自动缩放骑同一点击源——只开缩放（高亮关）时 tracker 仍需监听点击；
        // 环渲染由 coordinator 侧 clickOverlayProvider 装配缝独立门控（关高亮不画环）。
        clickHighlightTracker?.setEnabled(config.clickHighlightEnabled || config.autoZoomEnabled)
        // T18：源丢失匹配目标随捕获模式确定（裁定 2）。
        sourceDisplayID = Self.capturedDisplayID(of: config.mode)
        hasBegun = false
        pendingDiscard = false
        pendingFailure = nil
        if countdownSeconds > 0 {
            let task = Task { await self.runCountdown(totalSeconds: countdownSeconds) }
            countdownTask = task
            let completed = await task.value
            countdownTask = nil
            // 打断路径已把状态改走（.idle / .finishing），此处不得再进 begin
            guard completed, case .countdown = state else { return }
        }
        await beginAndEnterRecording(config)
    }

    /// 逐秒递减展示；返回 false = 被打断（取消或状态被外部改走）。
    private func runCountdown(totalSeconds: Int) async -> Bool {
        for left in stride(from: max(totalSeconds, 1), through: 1, by: -1) {
            state = .countdown(secondsLeft: left)
            do { try await waitForTick(1) } catch { return false }
            if Task.isCancelled { return false }
            guard case .countdown = state else { return false }
        }
        return true
    }

    private func beginAndEnterRecording(_ config: RecordingConfiguration) async {
        hasBegun = true
        do {
            try await session.begin(config)
        } catch {
            // begin 失败：无会话可收尾（占位/claim 清理由 recorder 内部完成），回 idle 并通知
            state = .idle
            notifier?.notifyFailure(message: failureMessage(for: error, savedFile: nil, didStart: false))
            return
        }
        if pendingDiscard {
            await finalize(discard: true)
            return
        }
        if let failure = pendingFailure {
            pendingFailure = nil
            state = .recording
            enterRecordingPhase()
            handleSessionFailure(failure)
            return
        }
        enterRecordingPhase()
    }

    private func enterRecordingPhase() {
        accumulatedActive = 0
        segmentStartUptime = monotonicNow()
        elapsed = 0
        state = .recording
        startElapsedTimer()
        clickHighlightTracker?.start() // T16：点击监听随录制启动（disabled 未装机为 no-op）
        sourceLossMonitor?.start(displayID: sourceDisplayID) // T18：源丢失监视随录制启动
        microphoneRouteWatcher?.start() // T18：路由变化观察随录制启动（混音器自愈，无 UI）
    }

    /// 源丢失匹配语义（裁定 2）：display/region 模式监视其所在显示器；window 模式无定
    /// 显示器（窗口可移动/跨屏）→ nil = 采集全台语义，任一显示器移除即源丢失。
    private static func capturedDisplayID(of mode: CaptureMode) -> CGDirectDisplayID? {
        switch mode {
        case .display(let displayID): return displayID
        case .region(_, let displayID): return displayID
        case .window: return nil
        }
    }

    // MARK: 浮条动作

    /// 暂停：仅 `.recording` 生效；elapsed 冻结（暂停段不累计）。
    func pause() {
        guard state == .recording else { return }
        session.pause()
        accumulatedActive = computedElapsed
        segmentStartUptime = nil
        refreshElapsed()
        state = .paused
    }

    /// 恢复：仅 `.paused` 生效。
    func resume() {
        guard state == .paused else { return }
        session.resume()
        segmentStartUptime = monotonicNow()
        state = .recording
    }

    /// 停止并保存：仅 `.recording`/`.paused` 生效；`.finishing` 期间重复触发为 no-op（边界 3）。
    func stop() {
        guard state == .recording || state == .paused else { return }
        state = .finishing
        Task { await finalize(discard: false) }
    }

    /// 丢弃（浮条二次确认后调用）：倒计时（begin 前）→ 静默取消回 `.idle`；录制/暂停 → 收尾
    /// 并删除成片、不回调 `onFinishedFile`；begin 在途 → 记 `pendingDiscard`（边界 4）；
    /// `.idle`/`.finishing` → no-op。
    func cancelAndDiscard() {
        switch state {
        case .countdown:
            guard !hasBegun else {
                pendingDiscard = true
                state = .finishing
                return
            }
            countdownTask?.cancel()
            state = .idle
        case .recording, .paused:
            state = .finishing
            Task { await finalize(discard: true) }
        case .idle, .finishing:
            break
        }
    }

    /// 失败通道（T18 台账指针）：`onStreamFailure`（主队列保证）/ 磁盘停阈值到达时自动走
    /// stop 保存路径——成片保留、回调 `onFinishedFile`、通知失败原因；不弹崩溃。
    /// `.finishing` 重入 no-op（防重复收尾，与「stop-supersedes-warn」一致）。
    func handleSessionFailure(_ error: Error) {
        switch state {
        case .recording, .paused:
            state = .finishing
            Task { await finalizeAfterFailure(error) }
        case .countdown:
            // begin 在途（流刚起即停等竞态窗口）：begin 返回后按失败路径收尾（边界 5）
            if hasBegun { pendingFailure = error }
        case .idle, .finishing:
            break
        }
    }

    /// 低空间警告（warn 阈值）：仅活动会话提示；不触碰状态。「stop-supersedes-warn」：
    /// 收尾中/已收尾（`.finishing`/`.idle`）不再警告——用户或磁盘 stop 已接管，警告路径
    /// 既不阻塞收尾也不重复收尾。
    func showDiskSpaceWarning() {
        guard state == .recording || state == .paused else { return }
        notifier?.notifyDiskSpaceWarning()
    }

    // MARK: 收尾

    private func finalize(discard: Bool) async {
        guard state == .finishing else { return }
        stopElapsedTimer()
        clickHighlightTracker?.stop() // T16：点击监听随收尾停止（幂等）
        sourceLossMonitor?.stop() // T18：源丢失监视随收尾摘除（幂等）
        microphoneRouteWatcher?.stop() // T18：路由观察随收尾摘除（幂等）
        sourceDisplayID = nil
        let url = await session.finish()
        resetElapsed()
        state = .idle
        if let url {
            if discard {
                store.delete(url)
            } else {
                onFinishedFile(url) // 边界 6：主队列同步回调
            }
        } else if !discard {
            // 修复轮 1 Minor #1：正常停止但未产出成片（零样本 nothingWritten 等）不再静默；
            // 丢弃路径无产出即本意，保持安静。
            notifier?.notifyFailure(message: "录制已停止，但本次未能保存成片（可能未捕获到任何内容）。")
        }
    }

    private func finalizeAfterFailure(_ error: Error) async {
        guard state == .finishing else { return }
        stopElapsedTimer()
        clickHighlightTracker?.stop() // T16：失败自动保存路径同样摘除监听（幂等）
        sourceLossMonitor?.stop() // T18：源丢失监视随收尾摘除（幂等）
        microphoneRouteWatcher?.stop() // T18：路由观察随收尾摘除（幂等）
        sourceDisplayID = nil
        let url = await session.finish()
        resetElapsed()
        state = .idle
        if let url {
            onFinishedFile(url) // 失败自动保存：成片保留
        }
        notifier?.notifyFailure(message: failureMessage(for: error, savedFile: url))
    }

    // MARK: elapsed（不含暂停时长）

    private var computedElapsed: TimeInterval {
        accumulatedActive + (segmentStartUptime.map { max(0, monotonicNow() - $0) } ?? 0)
    }

    private func refreshElapsed() {
        let value = computedElapsed
        if elapsed != value { elapsed = value } // 等值守卫：暂停期间不空发 objectWillChange
    }

    private func resetElapsed() {
        accumulatedActive = 0
        segmentStartUptime = nil
        elapsed = 0
    }

    private func startElapsedTimer() {
        elapsedTimerTask?.cancel()
        elapsedTimerTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                do { try await self.waitForTick(0.5) } catch { break }
                if Task.isCancelled { break }
                self.refreshElapsed()
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimerTask?.cancel()
        elapsedTimerTask = nil
    }

    // MARK: 失败文案（TCC 失效引导，T6 台账指针）

    /// 失败通知文案：权限类失败（TCC 授权失效 / 进程陈旧，常见于重编译后签名失配）引导
    /// 重启 App + 重新授权，不与普通失败混文案。`didStart = false`（begin 失败，从未开始）
    /// 用「未能开始」语义，不写「录制中断」（修复轮 1 Minor #3）。
    func failureMessage(for error: Error, savedFile: URL?, didStart: Bool = true) -> String {
        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        guard didStart else {
            if isPermissionRelated(error) {
                return "未能开始录制：屏幕录制权限未就绪，请退出并重启本应用；若重启后仍失败，请在系统设置中重新授权屏幕录制。原因：\(reason)"
            }
            return "未能开始录制。原因：\(reason)"
        }
        let savedNote = savedFile != nil ? "已录制内容已自动保存。" : "本次未能保存成片。"
        if isPermissionRelated(error) {
            return "屏幕录制权限已失效：请退出并重启本应用；若重启后仍失败，请在系统设置中重新授权屏幕录制。\(savedNote)原因：\(reason)"
        }
        return "录制中断。\(savedNote)原因：\(reason)"
    }

    /// 权限类失败判定：SCStream 权限族错误码，或运行时预检已无屏幕录制授权。
    /// 预检 true 不代表能力完好（陈旧授权场景以错误码为准，T6 实测：预检与实际捕获能力可能不一致）。
    func isPermissionRelated(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain, Self.permissionRelatedSCCodes.contains(nsError.code) {
            return true
        }
        return !screenPermissionProbe()
    }

    /// SCStream 权限族错误码（SCError.h）：userDeclined=-3801 / failedToStart=-3802 /
    /// missingEntitlements=-3803。
    private static let permissionRelatedSCCodes: Set<Int> = [
        SCStreamError.Code.userDeclined.rawValue,
        SCStreamError.Code.failedToStart.rawValue,
        SCStreamError.Code.missingEntitlements.rawValue,
    ]
}
