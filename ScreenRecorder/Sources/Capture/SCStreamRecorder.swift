import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// SCStream 采集 → `AssetWriterSession` 落盘的录制会话。
/// 视频路径：首帧装配 writer 输入并 startWriting → 逐帧合成（仅 PiP / 点击高亮开启，T15/T16；
/// 合成在暂停平移判定之后、append 之前，PTS 原样透传）→ append；双效果全关时为逐帧直通
/// （合成器 nil，零开销）。
/// 音频路径（Task 9，captureSystemAudio 或 captureMicrophone 时）：`SystemAudioMixer` 双路混音
/// ——系统声：SCStream audio 队列样本；麦克风：engine inputNode tap（SCStream 的 `.microphone`
/// 输出 macOS 15+ 才有，维持丢弃）——混音为单条 AAC 轨，混音器启动失败时降级为纯视频轨继续录制。
/// 生命周期：`start()`（解析目标 + 建流 + 开采集）→ video 队列首帧装配 writer（视频 + 有则音频
/// 输入）→ 逐路 append → `stop()`（停流 + 停混音 + 收尾成片）。
///
/// 失败通道：append 失败与 `stream(_:didStopWithError:)` 经 `onStreamFailure`（主队列保证）
/// 上报，首次失败生效；上层收到后负责调用 `stop()` 完成安全收尾（本类不自动停流）。
/// `stop()` 后读 `finishedFileURL`（nil = 无成片）与 `lastError`（首个失败原因）。
///
/// 暂停/恢复（Task 10，浮条 T11 消费）：`pause()` / `resume()` 任意线程可调；暂停中
/// 视频帧与音频包在各自队列上下文（video 队列 / 混音 delivery 队列）丢弃——不入 writer、
/// 不补静音；恢复后所有 append 的 PTS 经 `PauseMediaClock`（内含 `PauseTimeTracker`，
/// 视频与音频共用同一平移量）统一去除暂停段，音画同步不受暂停影响。暂停时点取
/// `CMClock.hostTimeClock.time`（与帧 PTS 同 mach 时基），不依赖暂停期间有帧到达
/// （SCStream 静止画面不发帧）。生命周期边界：录制未开始（start() 未完成）或已 stop()
/// 后调用 pause/resume 一律 no-op（不抛错——上层无需跟踪录制生命周期）；重复
/// pause/resume 幂等；`stop()` 在暂停态可直接调用，成片按已 append 内容正常收尾
///（全程暂停零样本时按既有 nothingWritten 语义无成片）；暂停不影响失败通道——
/// `onStreamFailure` 与 `didStopWithError` 照常触发（T18 依赖：失败必须仍能触发 stop）。
///
/// 单次生命周期实例：一个 recorder 只承载一次录制，不支持 stop 后复用。
final class SCStreamRecorder: NSObject {
    enum SCStreamRecorderError: LocalizedError {
        case displayNotFound(CGDirectDisplayID)
        case windowNotFound(CGWindowID)

        var errorDescription: String? {
            switch self {
            case .displayNotFound(let id):
                return "SCShareableContent 中找不到显示器 id=\(id)"
            case .windowNotFound(let id):
                return "SCShareableContent 中找不到窗口 id=\(id)（窗口可能已关闭）"
            }
        }
    }

    /// 流失败回调（主队列保证）。Task 18 的 CaptureController 据此走自动保存路径。
    var onStreamFailure: ((Error) -> Void)?

    /// Task 15 PiP 注入缝：最新摄像头帧取数（begin 前由装配层设置；录制中只读）。
    /// nil（未注入或 includeCamera=false）= 纯直通路径，与 T8–T13 已验收行为逐字节一致。
    /// 仅 video 队列调用（闭包内部锁保护，见 CameraPiPController/PiPFrameStore）。
    var pipPixelBufferProvider: (() -> CVPixelBuffer?)?
    /// Task 15 PiP 注入缝：PiP 位置取数（捕获像素空间，浮窗拖动时逐帧变化）。
    var pipFrameProvider: (() -> PiPFrame?)?
    /// T16 点击高亮注入缝：当帧点击叠加态取数（捕获像素空间，tracker 已回填衰减 alpha）。
    /// nil（未注入或 clickHighlightEnabled=false）= 点击路全关，热路径与今日逐字节一致。
    /// 仅 video 队列调用（tracker 内部锁保护快照）。
    var clickOverlayProvider: (() -> ClickOverlayState?)?

    /// `stop()` 完成后的成片 URL；nil 表示本次无产出（启动失败 / 流失败 / 零样本）。
    private(set) var finishedFileURL: URL?

    /// 首个失败的原因（诊断用）。
    private(set) var lastError: Error?

    private let config: RecordingConfiguration
    private let videoQueue = DispatchQueue(label: "screenRecorder.SCStreamRecorder.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "screenRecorder.SCStreamRecorder.audio", qos: .userInitiated)
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var writerSession: AssetWriterSession?
    /// 系统声音混音器（captureSystemAudio 且启动成功时非 nil；engine 由混音器持有）。
    private var mixer: SystemAudioMixer?
    /// 仅 videoQueue 触碰：writer 输入是否已在首帧装配完毕。
    private var writerArmed = false
    /// 仅 videoQueue 触碰（start() 在 startCapture 前发布，回调建立即天然的内存序栅栏）：
    /// includeCamera 且注入缝在位时创建的合成器；nil = 直通路径。
    private var pipCompositor: PiPCompositor?
    /// 暂停媒体时钟（Task 10）：门控 + 平移 + 每轨单调护栏，所有访问经 stateLock。
    private var mediaClock = PauseMediaClock()
    /// 暂停丢弃计数的收尾快照（修复轮 2）：stop()/start 失败回滚复位 `mediaClock` 前
    /// 把活动计数并入（`+=`，复位后的新时钟计数恒 0，重复复位不覆盖），只读属性读
    /// 「活动 + 快照」保证 stop 后诊断读数仍是终值（T11 成片归因在收尾之后读）。
    /// internal 供测试注入以无头验证快照存活；生产路径只在上述两个临界区写入。
    var finalPausedDroppedVideoFrameCount = 0
    var finalPausedDroppedAudioPacketCount = 0

    init(config: RecordingConfiguration) {
        self.config = config
        super.init()
    }

    /// 按模式构造 `SCContentFilter` 与 `SCStream` 并开始采集。
    /// writer 会话在本方法内创建（输出文件排他占位，冲突即刻抛错）；
    /// 输入装配推迟到首帧（需要首帧格式描述做 sourceFormatHint）。
    func start() async throws {
        let target = try await resolveTarget()
        let session = try AssetWriterSession(config: config, pixelSize: target.pixelSize)
        // T15/T16：合成器按需装配——PiP 开启（摄像头 + 位置注入缝在位）或点击高亮开启
        //（取数注入缝在位）时建（CIContext/CVPixelBufferPool 均惰性持有，未走到合成不产生
        // 缓冲分配）。两者都关时保持 nil = 直通路径零开销。
        let pipActive = config.includeCamera && pipPixelBufferProvider != nil && pipFrameProvider != nil
        let clickActive = config.clickHighlightEnabled && clickOverlayProvider != nil
        if pipActive || clickActive {
            pipCompositor = PiPCompositor(pixelSize: target.pixelSize)
        }
        // 混音器在开流前启动：engine 先热起来，两路音频从第一刻起就不缺位；仅开麦克风关系统声
        // 时混音器同样在位（系统声源节点持续渲染静音，与麦克风混合）。启动失败（如无输出设备
        // 的极端环境）降级为纯视频轨，不阻断录制。
        var activeMixer: SystemAudioMixer?
        if config.captureSystemAudio || config.captureMicrophone {
            let engine = AVAudioEngine()
            let mixer = SystemAudioMixer()
            if config.captureMicrophone {
                registerMicrophone(on: mixer, engine: engine)
            }
            do {
                try mixer.start(engine: engine) { [weak self] sampleBuffer in
                    self?.handleMixedAudio(sampleBuffer)
                }
                activeMixer = mixer
            } catch {
                NSLog("SCStreamRecorder: 混音器启动失败，本次录制仅视频轨：\(error)")
            }
        }
        do {
            let streamConfig = SCStreamConfiguration()
            streamConfig.width = Int(target.pixelSize.width.rounded())
            streamConfig.height = Int(target.pixelSize.height.rounded())
            streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(config.fps, 1)))
            streamConfig.queueDepth = 3
            streamConfig.showsCursor = true
            streamConfig.pixelFormat = kCVPixelFormatType_32BGRA // 与 adaptor 的像素格式声明一致
            if let sourceRect = target.sourceRect {
                streamConfig.sourceRect = sourceRect // points，显示器逻辑坐标系
            }
            streamConfig.capturesAudio = config.captureSystemAudio
            streamConfig.excludesCurrentProcessAudio = true // 不把本 App 自己触发的提示音录进去
            streamConfig.sampleRate = 48000
            streamConfig.channelCount = 2

            let stream = SCStream(filter: target.filter, configuration: streamConfig, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
            if config.captureSystemAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            }
            stateLock.withStateLock {
                self.stream = stream
                self.writerSession = session
                self.mixer = activeMixer
            }
            try await stream.startCapture()
        } catch {
            // 采集没跑起来：不会有任何帧到达。先撤销已发布的会话引用（修复轮 1 Minor #1：
            // 引用不清会让 pause() 在 start() 失败后被接受，违背「start() 未完成一律 no-op」
            // 契约；同时复位暂停时钟，封住发布→撤销竞态窗口内进入的暂停），再停混音 +
            // 清理排他占位文件后上抛。计数先并入快照（修复轮 2，与 stop 同一模式）。
            stateLock.withStateLock {
                finalPausedDroppedVideoFrameCount += mediaClock.pausedDroppedVideoFrameCount
                finalPausedDroppedAudioPacketCount += mediaClock.pausedDroppedAudioPacketCount
                writerSession = nil
                mediaClock = PauseMediaClock()
            }
            activeMixer?.stop()
            session.discardIfNoContent()
            throw error
        }
    }

    /// 登记麦克风输入（Task 9）：SCStream 的 `.microphone` 输出 macOS 15+ 才有（维持丢弃），
    /// 麦克风统一走 engine inputNode tap。无音频输入设备的极端环境访问 inputNode 会抛 ObjC
    /// 异常（Swift 侧接不住），先以 AVCaptureDevice 预检降级为不含麦克风的混音；设备在位但
    /// TCC 未授权时 inputNode 输出静音（录出无声人声轨，成片仍有效可播）。
    private func registerMicrophone(on mixer: SystemAudioMixer, engine: AVAudioEngine) {
        guard AVCaptureDevice.default(for: .audio) != nil else {
            NSLog("SCStreamRecorder: 无音频输入设备，本次录制不含麦克风")
            return
        }
        mixer.setMicrophoneInput(engine.inputNode.inputFormat(forBus: 0), volume: Float(config.micVolume))
        // 终审 F2：开录时的静音快照（config.micMuted）——状态驱动幂等（false 为 no-op）；
        // start() 装配据此决定是否预装 inputNode tap（录制中翻转走 setMicMuted live 链）。
        mixer.setMicMuted(config.micMuted)
    }

    /// 麦克风静音（浮条静音按钮语义，Task 11 消费）：转发混音器摘除/回装 inputNode tap；
    /// 无混音器（纯视频轨 / 混音器未启动）时为 no-op。
    func setMicMuted(_ muted: Bool) {
        let mixer: SystemAudioMixer? = stateLock.withStateLock { mixer }
        mixer?.setMicMuted(muted)
    }

    /// 麦克风增益实时更新（终审 F2 偏好滑杆拖动）：转发混音器施加 per-input 音量（运行中
    /// 即时生效，无需重启 engine）；无混音器（纯视频轨 / 混音器未启动）时为 no-op。
    func setMicVolume(_ volume: Float) {
        let mixer: SystemAudioMixer? = stateLock.withStateLock { mixer }
        mixer?.setMicVolume(volume)
    }

    /// 路由自愈触发（T18，MicrophoneRouteWatcher 主队列回调）：快照当前混音器执行
    /// `.AVAudioEngineConfigurationChange` 后的重建（engine 停机/格式重读/tap 重装/重启，
    /// 详见 `SystemAudioMixer.rebuildAfterConfigurationChange`）。无混音器（纯视频轨/
    /// 混音器未启动）no-op。
    func rebuildAudioAfterConfigurationChange() {
        let mixer: SystemAudioMixer? = stateLock.withStateLock { mixer }
        mixer?.rebuildAfterConfigurationChange()
    }

    // MARK: - 暂停 / 恢复（Task 10）

    /// 是否暂停中（任意线程可读；T11 浮条按钮态）。
    var isPaused: Bool {
        stateLock.withStateLock { mediaClock.isPaused }
    }

    /// 暂停录制（Task 10，T11 浮条消费）：此后视频帧与音频包在各自队列上下文丢弃
    /// （不入 writer、不补静音），engine 与 SCStream 保持运行（恢复零重启开销）。
    /// 录制未开始或已 stop() 后为 no-op（不抛错，见类注释生命周期边界）；幂等。
    func pause() {
        stateLock.withStateLock {
            guard writerSession != nil, !mediaClock.isPaused else { return }
            mediaClock.pause(at: CMClock.hostTimeClock.time)
        }
    }

    /// 恢复录制：此后 append 的 PTS 统一平移去除暂停段（`PauseTimeTracker`），
    /// 成片时长不含暂停间隙。未暂停时 no-op（幂等）。
    func resume() {
        stateLock.withStateLock {
            guard mediaClock.isPaused else { return }
            mediaClock.resume(at: CMClock.hostTimeClock.time)
        }
    }

    /// 暂停期间丢弃的视频帧数（诊断只读，修复轮 1 Minor #2）：与
    /// `AssetWriterSession.droppedVideoFrameCount`（编码器未就绪丢弃）互斥可区分，
    /// T11 真机验收「成片时长 ≈ 预期」偏差时的归因依据；回跳丢弃与非数值 PTS 不计入。
    /// 读数 = 活动计数 + 收尾快照（修复轮 2：两者互斥非零，stop 后活动侧恒 0，读数为终值）。
    var pausedDroppedVideoFrameCount: Int {
        stateLock.withStateLock {
            mediaClock.pausedDroppedVideoFrameCount + finalPausedDroppedVideoFrameCount
        }
    }

    /// 暂停期间丢弃的音频包数（诊断口径同上）。
    var pausedDroppedAudioPacketCount: Int {
        stateLock.withStateLock {
            mediaClock.pausedDroppedAudioPacketCount + finalPausedDroppedAudioPacketCount
        }
    }

    /// 停采集并收尾成片。幂等（重复调用 no-op）；完成后 `finishedFileURL` 反映结果，
    /// 失败原因记入 `lastError`（不触发 `onStreamFailure`——主动收尾时调用方就在现场）。
    func stop() async {
        let stream: SCStream? = stateLock.withStateLock {
            let owned = self.stream
            self.stream = nil
            return owned
        }
        if let stream {
            // 先摘输出再停流：终止回调派发后再收尾混音与 writer。
            try? stream.removeStreamOutput(self, type: .screen)
            if config.captureSystemAudio {
                try? stream.removeStreamOutput(self, type: .audio)
            }
            try? await stream.stopCapture()
        }
        let mixer: SystemAudioMixer? = stateLock.withStateLock {
            let owned = self.mixer
            self.mixer = nil
            return owned
        }
        mixer?.stop()
        let session: AssetWriterSession? = stateLock.withStateLock {
            let owned = self.writerSession
            self.writerSession = nil
            // 暂停态随会话一并终结：此刻起 isPaused 恒 false（pause() 以会话在位为前提，
            // 此前竞态窗口内进入的暂停也一并复位），收尾不受暂停门控影响。
            // 暂停丢弃计数先并入收尾快照（修复轮 2）：复位不得清零诊断读数，成片归因
            // 在 stop 之后读。`+=` 对复位后的新时钟恒加 0，重复 stop 不覆盖快照。
            finalPausedDroppedVideoFrameCount += mediaClock.pausedDroppedVideoFrameCount
            finalPausedDroppedAudioPacketCount += mediaClock.pausedDroppedAudioPacketCount
            mediaClock = PauseMediaClock()
            return owned
        }
        guard let session else { return } // start() 从未成功：无会话可收尾
        do {
            let url = try await session.finish()
            stateLock.withStateLock { finishedFileURL = url }
        } catch {
            stateLock.withStateLock { if lastError == nil { lastError = error } }
        }
    }

    // MARK: - 捕获目标解析

    private struct ResolvedTarget {
        let filter: SCContentFilter
        /// 输出像素尺寸：display=显示器物理像素；window=窗口 frame（points）；region=rect 尺寸。
        let pixelSize: CGSize
        /// 区域模式（macOS 12.3+ sourceRect）的采样子集；nil = 全量采样。
        let sourceRect: CGRect?
    }

    private func resolveTarget() async throws -> ResolvedTarget {
        switch config.mode {
        case .display(let displayID):
            let display = try await findDisplay(displayID)
            return ResolvedTarget(
                filter: SCContentFilter(display: display, excludingWindows: []),
                pixelSize: pixelSize(ofDisplay: displayID),
                sourceRect: nil
            )
        case .window(let windowID):
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw SCStreamRecorderError.windowNotFound(windowID)
            }
            return ResolvedTarget(
                filter: SCContentFilter(desktopIndependentWindow: window),
                pixelSize: window.frame.size,
                sourceRect: nil
            )
        case .region(let rect, let displayID):
            let display = try await findDisplay(displayID)
            return ResolvedTarget(
                filter: SCContentFilter(display: display, excludingWindows: []),
                pixelSize: rect.size,
                sourceRect: rect
            )
        }
    }

    private func findDisplay(_ displayID: CGDirectDisplayID) async throws -> SCDisplay {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw SCStreamRecorderError.displayNotFound(displayID)
        }
        return display
    }

    /// 显示器物理像素尺寸（Retina 下 = 点数 × 缩放系数），取自当前显示模式。
    private func pixelSize(ofDisplay displayID: CGDirectDisplayID) -> CGSize {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return .zero }
        return CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
    }
}

// MARK: - 采样回调

extension SCStreamRecorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            handleVideoSample(sampleBuffer)
        case .audio:
            handleStreamAudio(sampleBuffer)
        default:
            break // .microphone（macOS 15+）及未来新增类型：麦克风走 engine inputNode tap，维持丢弃
        }
    }

    /// audio 队列串行执行：CMSampleBuffer → AVAudioPCMBuffer → 混音器环形缓冲。
    private func handleStreamAudio(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let pcm = AudioSampleBridge.pcmBuffer(from: sampleBuffer) else { return }
        let mixer: SystemAudioMixer? = stateLock.withStateLock { mixer }
        mixer?.enqueueSystemAudio(pcm)
    }

    /// delivery 串行队列回调：混音器输出的 masterFormat CMSampleBuffer → 平移 → appendAudio。
    /// 暂停丢弃判定在本队列上下文执行（Task 10，非渲染线程）：暂停中整包丢弃，恢复后
    /// 平移换时再落盘。锚点兜底门控用文件基（平移后）PTS 比较——早于锚点的样本不被
    /// writer 可靠拒绝（macOS 27 实测被静默钳到成片起点），有暂停时原始 PTS 与成片时间轴
    /// 相差累计暂停量，直接用原始 PTS 校验会漏放录制前内容；时钟层的音频轨单调护栏则
    /// 挡住暂停边界在途的回跳包（两者互补，先护栏后锚点兜底）。
    private func handleMixedAudio(_ sampleBuffer: CMSampleBuffer) {
        let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard let shiftedPTS = stateLock.withStateLock({ mediaClock.shiftedPTS(rawPTS, for: .audio) }) else { return }
        let session: AssetWriterSession? = stateLock.withStateLock { writerSession }
        guard let session else { return } // stop() 已收走会话：丢弃尾部样本
        let anchor = session.isReadyForVideoMediaTime
        guard anchor.isValid, anchor.isNumeric else { return } // 视频未锚定：录制尚未开始，丢弃
        guard CMTimeCompare(shiftedPTS, anchor) >= 0 else { return } // 文件基：不得早于锚点
        // 平移落盘：换时浅拷贝（数据与时长保真，仅 PTS 置为平移值）；打包失败丢包
        guard let retimed = AudioSampleBridge.sampleBuffer(copying: sampleBuffer, presentationTimeStamp: shiftedPTS) else { return }
        do {
            try session.appendAudio(retimed)
        } catch {
            // stop() 先围栏排空混音 delivery 队列再收尾 writer，finish 期间不可能有 append——
            // 本分支纯防御。仅当 stop 已开始（会话已被收走）才吞 writerNotWriting 一类错误；
            // 录制中途真正的 writer 故障仍必须 recordFailure → onStreamFailure。
            let stopHasBegun: Bool = stateLock.withStateLock { writerSession == nil }
            if !stopHasBegun {
                recordFailure(error)
            }
        }
    }

    /// video 队列串行执行：首帧装配 writer（addVideoInput + 有混音器则 addAudioInput +
    /// startWriting，需首帧格式描述），之后逐帧 append；首帧 append 确立锚点后，把首帧
    /// 原始采集 PTS 交给混音器做音频初筛。
    /// 暂停丢弃判定在本队列上下文执行（Task 10，非渲染线程）：暂停中的帧不入 writer、
    /// 不装配也不平移——首帧装配顺延到恢复后的首个内容帧，成片锚点从真实内容起算。
    /// Task 15 合成管线：合成插在暂停平移判定**之后**、append **之前**——合成不改变
    /// 时间轴，PTS 原样透传（append 仍用 shiftedPTS）；无 PiP（合成器 nil 或当帧取不到
    /// 摄像头帧/位置）时直返原 buffer，语义与 T8–T13 已验收的直通路径一致。
    private func handleVideoSample(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let session: AssetWriterSession? = stateLock.withStateLock { writerSession }
        guard let session else { return } // stop() 已收走会话：丢弃尾部帧
        let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        // 暂停门控 + 平移 + 视频轨单调护栏（clock 决策 nil = 丢弃，含暂停中的全部帧）
        guard let shiftedPTS = stateLock.withStateLock({ mediaClock.shiftedPTS(rawPTS, for: .video) }) else { return }
        do {
            let didArm = !writerArmed
            if didArm {
                let formatHint = CMSampleBufferGetFormatDescription(sampleBuffer)
                try session.addVideoInput(with: formatHint)
                let mixer: SystemAudioMixer? = stateLock.withStateLock { mixer }
                if let mixer {
                    try session.addAudioInput(with: mixer.masterFormat)
                }
                session.startWriting()
                writerArmed = true
            }
            // T15/T16：逐帧合成（任一效果开启时到达此处；合成器内部对缺省输入各自零渲染
            // 直通，双缺省直返原 buffer）——合成不改变时间轴，PTS 原样透传（append 仍用
            // shiftedPTS）；合成器 nil 时直通路径零开销（同 T8–T14 行为）。
            let outputBuffer: CVPixelBuffer
            if let pipCompositor {
                outputBuffer = pipCompositor.composite(
                    screenFrame: pixelBuffer,
                    pip: pipPixelBufferProvider?(),
                    pipFrame: pipFrameProvider?(),
                    clickOverlay: clickOverlayProvider?(),
                    at: shiftedPTS,
                    into: pipCompositor.context)
            } else {
                outputBuffer = pixelBuffer // 直通路径：零开销（同 T8–T14 行为）
            }
            try session.appendVideo(outputBuffer, at: shiftedPTS)
            if didArm {
                // gate 用首帧原始采集 PTS（host 时基，与混音器输出 PTS 同基）：混音侧初筛
                // 「录制前的系统声」；文件基（平移后）的锚点兜底由 handleMixedAudio 负责
                //（有暂停时两者相差累计暂停量，gate 只做初筛不承担最终裁决）。
                let mixer: SystemAudioMixer? = stateLock.withStateLock { mixer }
                mixer?.setGatePTS(rawPTS)
            }
        } catch {
            recordFailure(error)
        }
    }
}

extension SCStreamRecorder: SCStreamDelegate {
    /// 流异常终止（正常 stopCapture 不触发）。
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        recordFailure(error)
    }
}

extension SCStreamRecorder {
    /// 首次失败生效：记录原因 + 主队列上报 `onStreamFailure`；上层负责 `stop()` 安全收尾。
    private func recordFailure(_ error: Error) {
        let shouldNotify: Bool = stateLock.withStateLock {
            guard lastError == nil else { return false }
            lastError = error
            return true
        }
        guard shouldNotify else { return }
        let callback = onStreamFailure
        if Thread.isMainThread {
            callback?(error)
        } else {
            DispatchQueue.main.async { callback?(error) }
        }
    }
}
