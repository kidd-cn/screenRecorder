import AVFoundation
import CoreMedia
import Foundation

/// 双路混音器：系统声音（SCStream PCM → `AVAudioSourceNode` 环形缓冲）与麦克风（inputNode
/// tap → `AVAudioConverter` → mic 环形缓冲 → 第二 `AVAudioSourceNode`）汇入 `AVAudioEngine`
/// mainMixer → 输出 tap → `AVAudioConverter` 转 masterFormat → 打包 CMSampleBuffer 交给上层
/// 写单条 AAC 音轨。
///
/// 麦克风路径（Task 9）：inputNode tap 回调（渲染线程）只做格式转换 + 串行队列投递，与系统声
/// 路径同构；micNode 先连入 mainMixer 占 input bus 0，`micVolume` 增益施加在该连接上（现代
/// SDK 的 `AVAudioMixing.volume`——mixer per-input 音量，简报 `setValue(_:forInputBus:)` 机制
/// 在本 SDK 的等价物，实测 macOS 27 该旧签名不存在）；静音（浮条按钮语义）= 摘除 inputNode
/// tap（`setMicMuted`），摘/回装转换时排空 mic ring 防陈旧音频泄漏。
///
/// 音画对齐机制：混音器输出样本的 PTS 取自 engine tap 的 host time（与 SCStream 视频 PTS 同
/// mach 时基）。writer 会话锚点由视频首帧确定（AssetWriterSession 首个到轨样本），锚点之前的
/// 系统声音属录制前内容——混音器经 `setGatePTS`（视频锚定后由上层设置）做帧级裁剪：锚点前的
/// 整段丢弃、跨界样本裁掉头部、其余原样输出；gate 生效前已在途的样本由上层按锚点兜底丢弃。
/// 麦克风与系统声在 mainMixer 混合后共用同一输出 tap 与 gate，无需单独对齐。
///
/// 监听静音与增益（实测裁决，probe 实验）：engine 的 mainMixer 默认直连输出硬件，且 mixer 节点上
/// 的 tap 在 fader 之后——`mainMixer.outputVolume = 0` 会把录制内容一并静音。故在 mainMixer 下游
/// 插入一个音量 0 的静音 mixer 接通输出硬件：录制链路满幅、外放无声。`masterGain`（0.8，简报
/// 削波封顶）同样施加在 mainMixer 上：它是增益——同时缩放两路录制冷平，监听仍被下游归零。
///
/// 线程模型：`enqueueSystemAudio` 在 SCStream audio 队列、系统 tap 与 mic tap 回调在 engine
/// 渲染线程——实时线程只做格式转换与入队（零锁获取、闭包只捕获不可变量）；gate 裁剪、
/// CMSampleBuffer 打包、上层 append 全部在 `deliveryQueue` 串行队列执行（单消费者、样本顺序
/// 保持），mic 转换段的 ring 写入在 `micDeliveryQueue` 串行队列执行（同构）。`stop()` 先停
/// engine 再围栏排空两个队列，保证上层收尾 writer 时无 append 在途或排队。共享状态经
/// `stateLock` 串行化。
final class SystemAudioMixer {
    enum SystemAudioMixerError: LocalizedError {
        case cannotCreateConverter(from: AVAudioFormat, to: AVAudioFormat)
        case cannotCreateMasterFormatDescription(OSStatus)

        var errorDescription: String? {
            switch self {
            case .cannotCreateConverter(let from, let to):
                return "AVAudioConverter 创建失败（\(from) → \(to)）"
            case .cannotCreateMasterFormatDescription(let status):
                return "masterFormat 的 CMFormatDescription 创建失败（status=\(status)）"
            }
        }
    }

    /// 混音目标格式（写入轨的 PCM 口径；brief 默认 48k/2ch 标准格式）。
    let masterFormat: AVAudioFormat

    /// 环形缓冲容量：1s（帧）。溢出丢最旧——实时录制语义永远保留最新内容。
    private let ring: RingBuffer
    private let stateLock = NSLock()
    /// 打包与交付专用串行队列：单消费者，保证样本与时间轴顺序；stop() 围栏排空。
    private let deliveryQueue = DispatchQueue(label: "screenRecorder.SystemAudioMixer.delivery", qos: .userInitiated)
    /// 麦克风转换段交付专用串行队列：mic tap（渲染线程）只转换 + 入队，ring 写入（ring 自带锁）
    /// 在此执行——与 deliveryQueue 同构；stop()/setMicMuted 围栏排空。
    private let micDeliveryQueue = DispatchQueue(label: "screenRecorder.SystemAudioMixer.micDelivery", qos: .userInitiated)

    /// 混音总增益封顶（简报 Step 3 削波封顶）：mainMixer tap 在 fader 之后，该值同时缩放系统声
    /// 与麦克风的录制冷平；监听静音由下游音量 0 的 silencer 负责，与本增益无关（T8 裁决）。
    static let masterGain: Float = 0.8

    private var isRunning = false
    private var engine: AVAudioEngine?
    private var silencer: AVAudioMixerNode?
    private var sourceNode: AVAudioSourceNode?
    /// start() 时交付闭包（T18 路由自愈重建输出 tap 时复用；stop 清理）。
    private var outputHandler: ((CMSampleBuffer) -> Void)?
    /// 麦克风第二路节点/缓冲/转换器（start 装配 mic 路径时非 nil，stop 清理）。
    private var micNode: AVAudioSourceNode?
    private var micRing: RingBuffer?
    /// mic 硬件格式 → masterFormat 的转换器（start 装配时创建，运行期不变——tap 闭包捕获用）。
    private var micConverter: AVAudioConverter?
    /// inputNode tap 是否在位（setMicMuted 摘除后为 false）。
    private var micTapInstalled = false
    /// 音画锚点（视频首帧 PTS；`.invalid` = 未设置，不裁剪）。
    private var gatePTS: CMTime = .invalid
    /// SCStream 音频源格式 → masterFormat 的转换器（格式不变则复用）。
    private var sourceConverter: AVAudioConverter?
    private var sourceConverterFormat: AVAudioFormat?
    /// 登记的麦克风输入格式（recorder 在 start 前从 engine.inputNode 硬件格式登记）。
    private(set) var microphoneFormat: AVAudioFormat?
    /// 麦克风增益 0…1（缺省 1）：施加在 micNode → mainMixer 输入连接上的 per-input 音量。
    private(set) var micVolume: Float = 1.0
    /// 麦克风静音（浮条按钮语义 = 摘除 inputNode tap）。
    private(set) var isMicMuted = false

    init(masterFormat: AVAudioFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!) {
        self.masterFormat = masterFormat
        self.ring = RingBuffer(channels: Int(masterFormat.channelCount),
                               capacityFrames: Int(masterFormat.sampleRate))
    }

    // MARK: - 生命周期

    /// 挂接 engine：[micNode → mainMixer bus 0] + [sourceNode → mainMixer]（tap 在此）→
    /// 静音 mixer → 输出硬件，并启动 engine。mic 路径仅在 `setMicrophoneInput` 已登记且
    /// converter 可建时装配；`micVolume` 增益施加在 micNode 的 mixer 连接上。
    /// `output` 在 delivery 串行队列回调，交付 masterFormat 的 CMSampleBuffer（host time PTS）。
    /// engine 由本类持有并在 `stop()` 中停机；engine.start 失败时回滚全部装配再上抛。
    func start(engine: AVAudioEngine, output: @escaping (CMSampleBuffer) -> Void) throws {
        let running: Bool = stateLock.withStateLock { isRunning }
        guard !running else { return }
        // 装配期快照（register-then-start 由调用方串行化，锁快照仅为纪律一致）。
        let (micFormat, micGain, micMuted) = stateLock.withStateLock { (microphoneFormat, micVolume, isMicMuted) }

        let source = AVAudioSourceNode(format: masterFormat) { [weak self] _, _, frameCount, audioBufferList in
            guard let self else { return noErr }
            return self.renderFromRing(audioBufferList, frameCount: Int(frameCount), from: self.ring)
        }
        engine.attach(source)
        let mainMixer = engine.mainMixerNode
        // 麦克风第二路：micNode 先连入 mainMixer 占 input bus 0；converter 把可能的单声道/
        // 异采样率硬件格式统一为 masterFormat（mixer 只做混合，不再承担逐路格式归一）。
        var assembledMic: (node: AVAudioSourceNode, ring: RingBuffer, converter: AVAudioConverter)?
        if let micFormat, let converter = AVAudioConverter(from: micFormat, to: masterFormat) {
            let ring = RingBuffer(channels: Int(masterFormat.channelCount),
                                  capacityFrames: Int(masterFormat.sampleRate))
            let node = AVAudioSourceNode(format: masterFormat) { [weak self] _, _, frameCount, audioBufferList in
                guard let self else { return noErr }
                return self.renderFromRing(audioBufferList, frameCount: Int(frameCount), from: ring)
            }
            engine.attach(node)
            engine.connect(node, to: mainMixer, format: masterFormat)
            node.volume = micGain // AVAudioMixing.volume：mixer per-input 音量（0…1）
            assembledMic = (node, ring, converter)
        }
        engine.connect(source, to: mainMixer, format: masterFormat)
        // 监听静音（T8 裁决）：tap 在 mainMixer 输出 bus（fader 之后），不能靠归零 mainMixer
        // 音量静音；下游插入音量 0 的静音 mixer 接通输出硬件。masterGain 是录制冷平封顶
        //（增益，缩放两路），与监听静音无关。
        let silencer = AVAudioMixerNode()
        engine.attach(silencer)
        engine.connect(mainMixer, to: silencer, format: nil)
        engine.connect(silencer, to: engine.outputNode, format: nil)
        silencer.outputVolume = 0
        mainMixer.outputVolume = Self.masterGain
        // 实时线程闭包只捕获不可变量（converter/desc/handler/队列），零锁获取：
        // 格式转换后逐段入 delivery 串行队列，gate 裁剪 + 打包 + append 全部离开渲染线程。
        // 输出 converter/desc 建不出 → 上抛（此刻尚未装任何 tap；回滚已挂接的全部节点）。
        do {
            try installMainMixerTap(engine: engine, output: output)
        } catch {
            engine.detach(silencer)
            if let assembledMic { engine.detach(assembledMic.node) }
            engine.detach(source)
            throw error
        }
        // 麦克风 inputNode tap（静音态不装配——setMicMuted(false) 时回装）。
        var didInstallMicTap = false
        if let mic = assembledMic, !micMuted {
            let handler = makeMicTapHandler(ring: mic.ring, converter: mic.converter)
            engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
                handler(buffer)
            }
            didInstallMicTap = true
        }
        do {
            engine.prepare() // 简报 Step 1：prepare 后 start，预载渲染管线
            try engine.start()
        } catch {
            mainMixer.removeTap(onBus: 0)
            if didInstallMicTap {
                engine.inputNode.removeTap(onBus: 0)
            }
            engine.detach(silencer)
            if let assembledMic { engine.detach(assembledMic.node) }
            engine.detach(source)
            throw error
        }
        stateLock.withStateLock {
            isRunning = true
            self.engine = engine
            self.silencer = silencer
            self.sourceNode = source
            self.outputHandler = output
            micNode = assembledMic?.node
            micRing = assembledMic?.ring
            micConverter = assembledMic?.converter
            micTapInstalled = didInstallMicTap
        }
    }

    /// 停机并回滚 engine 装配（幂等）。先停 engine 终止新入队（含摘除双 tap），再围栏排空
    /// delivery 与 micDelivery 两个串行队列——本方法返回时，已入队/在途的打包、append 与
    /// mic ring 写入全部完成（上层收尾 writer 前必须先调本方法），最后才清理共享状态并摘除节点。
    func stop() {
        let teardown: (engine: AVAudioEngine, silencer: AVAudioMixerNode, source: AVAudioSourceNode, micNode: AVAudioSourceNode?, micTapInstalled: Bool)? = stateLock.withStateLock {
            guard isRunning else { return nil }
            isRunning = false
            guard let engine, let silencer, let sourceNode else { return nil }
            self.engine = nil
            self.silencer = nil
            self.sourceNode = nil
            outputHandler = nil
            let mic = micNode
            micNode = nil
            let installed = micTapInstalled
            micTapInstalled = false
            micRing = nil
            micConverter = nil
            isMicMuted = false
            return (engine, silencer, sourceNode, mic, installed)
        }
        guard let teardown else { return }
        teardown.engine.mainMixerNode.removeTap(onBus: 0)
        if teardown.micTapInstalled {
            teardown.engine.inputNode.removeTap(onBus: 0)
        }
        teardown.engine.stop()
        deliveryQueue.sync { } // 围栏：串行队列单消费者，sync 返回即在途/排队工作全部完成
        micDeliveryQueue.sync { } // 围栏：mic 转换段全部落 ring（ring 状态随后清理）
        stateLock.withStateLock {
            gatePTS = .invalid
            sourceConverter = nil
            sourceConverterFormat = nil
        }
        teardown.engine.detach(teardown.silencer)
        if let mic = teardown.micNode {
            teardown.engine.detach(mic)
        }
        teardown.engine.detach(teardown.source)
    }

    // MARK: - 输入 / 输出装配

    /// SCStream 系统声音入口：设备格式 PCM → `AVAudioConverter` 转 masterFormat → 环形缓冲
    /// （容量 1s，溢出丢最旧）。audio 队列调用；混音未启动时静默丢弃。
    func enqueueSystemAudio(_ pcm: AVAudioPCMBuffer) {
        guard pcm.frameLength > 0 else { return }
        enum SourceRoute { case direct, convert(AVAudioConverter), drop }
        let route: SourceRoute = stateLock.withStateLock {
            if sourceConverterFormat != pcm.format {
                if pcm.format == masterFormat {
                    sourceConverter = nil // 同格式直写环形缓冲，无需转换
                    sourceConverterFormat = pcm.format
                } else if let created = AVAudioConverter(from: pcm.format, to: masterFormat) {
                    sourceConverter = created
                    sourceConverterFormat = pcm.format
                } else {
                    sourceConverter = nil
                    sourceConverterFormat = nil // 转换不可用：该格式样本丢弃，后续样本重试
                }
            }
            if sourceConverterFormat == nil { return .drop }
            if let sourceConverter { return .convert(sourceConverter) }
            return .direct
        }
        switch route {
        case .drop:
            return
        case .direct:
            ring.write(from: pcm)
        case .convert(let converter):
            drainConverter(converter, from: pcm, startPTS: .invalid) { converted, _ in
                self.ring.write(from: converted)
            }
        }
    }

    /// 登记麦克风输入格式与增益（上层在 start 前从 `engine.inputNode` 硬件格式登记；start 据
    /// 此装配 inputNode tap → converter → mic ring → micNode → mainMixer bus 0 的第二路）。
    /// volume 为 0…1 增益，越界值收敛；缺省 1.0。
    func setMicrophoneInput(_ format: AVAudioFormat, volume: Float = 1.0) {
        stateLock.withStateLock {
            microphoneFormat = format
            micVolume = min(max(volume, 0), 1)
        }
    }

    /// 麦克风静音（简报 `setMicMuted`，浮条静音按钮消费）：直接摘除/回装 inputNode tap。
    /// 摘除与回装时都排空 mic ring——摘除排空在途段与已缓冲内容，回装排空 tap 手术间隙可能
    /// 迟到的旧段（宁丢不旧）。engine 未运行时仅记录状态（start 据此决定是否装配 tap）。
    /// 与 `stop()` 并发的窗口内可能对已停机 engine 做节点手术：tap 摘除/回装幂等且 engine
    /// 随会话丢弃，竞态后果至多为一次无效果手术。
    func setMicMuted(_ muted: Bool) {
        let snapshot: (engine: AVAudioEngine, ring: RingBuffer, converter: AVAudioConverter, installed: Bool)? = stateLock.withStateLock {
            guard muted != isMicMuted else { return nil }
            isMicMuted = muted
            guard isRunning, let engine, let ring = micRing, let converter = micConverter else { return nil }
            return (engine, ring, converter, micTapInstalled)
        }
        guard let snapshot else { return }
        if muted, snapshot.installed {
            snapshot.engine.inputNode.removeTap(onBus: 0)
            micDeliveryQueue.sync { snapshot.ring.reset() }
            stateLock.withStateLock { micTapInstalled = false }
        } else if !muted, !snapshot.installed {
            let handler = makeMicTapHandler(ring: snapshot.ring, converter: snapshot.converter)
            snapshot.engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
                handler(buffer)
            }
            micDeliveryQueue.sync { snapshot.ring.reset() }
            stateLock.withStateLock { micTapInstalled = true }
        }
    }

    /// 设置音画锚点（视频首帧 PTS）。此后输出内容时间裁剪到锚点起；
    /// `.invalid` 取消裁剪。上层在 writer 锚定后调用。
    func setGatePTS(_ pts: CMTime) {
        stateLock.withStateLock { gatePTS = pts }
    }

    /// 麦克风增益实时更新（终审 F2 偏好滑杆拖动）：状态驱动——同值重复应用为 no-op
    ///（快速连拖不重复做节点属性写入）；运行中即时施加在 micNode 的 mixer 连接 per-input
    /// 音量上（`AVAudioMixing.volume` 属性写入实时生效，无需重启 engine——与 start() 装配
    /// 时施加的是同一机制）。未运行时仅记录登记值，start() 装配时按登记值施加（与
    /// `setMicMuted` 空闲态同纪律）。越界值收敛到 0…1。
    func setMicVolume(_ volume: Float) {
        let clamped = min(max(volume, 0), 1)
        let node: AVAudioSourceNode? = stateLock.withStateLock {
            guard micVolume != clamped else { return nil }
            micVolume = clamped
            return isRunning ? micNode : nil
        }
        node?.volume = clamped
    }

    // MARK: - 路由自愈（T18，裁定 5）

    /// 麦克风路重建决策（纯逻辑，无头可测）：`.AVAudioEngineConfigurationChange` 后重读
    /// inputNode 硬件格式的处置。`registeredFormat` nil = 开录时无 mic 路径。
    enum MicRebuildDecision {
        /// 格式未变：converter 沿用，仅按需回装 tap（engine 配置变化可能已摘 tap）。
        case keep
        /// 格式已变且可转换：换装新 converter（渲染热路径闭包只捕获不可变量——新 converter
        /// 不可变，旧 tap 闭包随摘除失效），此后以新设备格式继续录制。
        case reconvert(AVAudioConverter)
        /// 无已登记 mic 路径 / 新格式不可转换（设备全拔等）：不装 tap，录无声，不阻断录制。
        case drop
    }

    /// 决策函数（internal 供无头钉测）。
    static func micRebuildDecision(registeredFormat: AVAudioFormat?,
                                   currentInputFormat: AVAudioFormat,
                                   masterFormat: AVAudioFormat) -> MicRebuildDecision {
        guard registeredFormat != nil else { return .drop }
        if currentInputFormat == registeredFormat { return .keep }
        if let converter = AVAudioConverter(from: currentInputFormat, to: masterFormat) {
            return .reconvert(converter)
        }
        return .drop
    }

    /// `.AVAudioEngineConfigurationChange` 后的自愈重建（MicrophoneRouteWatcher 主队列回调
    /// ——非渲染线程、与其余 tap 手术同队列串行，裁定 4）。engine 因配置变化自动停机：本方法
    /// 显式停机（幂等）后重读输入硬件格式、按 `micRebuildDecision` 换装 mic converter 与
    /// inputNode tap（宁丢不旧：回装时排空 mic ring）；mainMixer 输出 tap 同步重装（输出设备
    /// 采样率可能已变，converter 按当前总线格式重建，建不出则输出降级无声）；最后重启 engine
    ///（失败降级为无声：视频轨不受影响，录制继续）。混音器未运行（stop 后/尚未 start）为
    /// no-op。与 `stop()` 并发的窗口内可能对已停机 engine 做手术：幂等且 engine 随会话丢弃
    ///（与 `setMicMuted` 的既有接受度一致）。
    func rebuildAfterConfigurationChange() {
        let snapshot: (engine: AVAudioEngine,
                       micRing: RingBuffer?,
                       micConverter: AVAudioConverter?,
                       micFormat: AVAudioFormat?,
                       micMuted: Bool,
                       micTapInstalled: Bool,
                       output: ((CMSampleBuffer) -> Void)?)? = stateLock.withStateLock {
            guard isRunning, let engine else { return nil }
            return (engine, micRing, micConverter, microphoneFormat, isMicMuted, micTapInstalled, outputHandler)
        }
        guard let snapshot else { return }
        snapshot.engine.stop() // 配置变化后 engine 已自停；显式停机幂等，保证手术在停机态进行

        // 1) 麦克风路：重读硬件输入格式 → 决策 → 锁内换装登记（纯赋值）。
        let inputFormat = snapshot.engine.inputNode.inputFormat(forBus: 0)
        let decision = Self.micRebuildDecision(
            registeredFormat: snapshot.micFormat,
            currentInputFormat: inputFormat,
            masterFormat: masterFormat)
        var activeConverter = snapshot.micConverter
        switch decision {
        case .keep:
            break
        case .reconvert(let converter):
            activeConverter = converter
            stateLock.withStateLock {
                microphoneFormat = inputFormat
                micConverter = converter
            }
        case .drop:
            activeConverter = nil
            if snapshot.micFormat != nil {
                stateLock.withStateLock { micConverter = nil }
                NSLog("SystemAudioMixer: 路由变化后输入格式不可转换（\(inputFormat)），本次录制麦克风降级为无声")
            }
        }

        // 2) inputNode tap 重建（手术在锁外；旧 tap 闭包持有旧 converter，必须摘除重装）。
        //    静音态保持摘除（setMicMuted 语义——setMicMuted(false) 时才回装）。
        snapshot.engine.inputNode.removeTap(onBus: 0)
        var didInstallMicTap = false
        if !snapshot.micMuted, let ring = snapshot.micRing, let converter = activeConverter {
            let handler = makeMicTapHandler(ring: ring, converter: converter)
            snapshot.engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
                handler(buffer)
            }
            didInstallMicTap = true
        }
        stateLock.withStateLock { micTapInstalled = didInstallMicTap }
        micDeliveryQueue.sync { snapshot.micRing?.reset() } // 宁丢不旧（与 setMicMuted 同纪律）

        // 3) 系统声/输出路：mainMixer 输出 tap 重装（converter 按当前总线格式重建）。
        snapshot.engine.mainMixerNode.removeTap(onBus: 0)
        if let output = snapshot.output {
            do {
                try installMainMixerTap(engine: snapshot.engine, output: output)
            } catch {
                NSLog("SystemAudioMixer: 路由自愈输出 tap 重建失败，输出降级为无声：\(error)")
            }
        }

        // 4) 重启（失败降级为无声：视频轨不受影响，录制继续）。
        do {
            try snapshot.engine.start()
        } catch {
            NSLog("SystemAudioMixer: 路由自愈重启 engine 失败，本次录制降级为无声：\(error)")
        }

        // 5) 终审 F2：engine 配置变化可能重置 per-input 音量——重启成功后重施登记增益
        //    （与 live 滑杆链同一机制；无 mic 路 / 已收尾时 node 缺位 no-op）。
        let (volume, node) = stateLock.withStateLock { (micVolume, isRunning ? micNode : nil) }
        node?.volume = volume
    }

    // MARK: - 内部：装配

    /// masterFormat 的 CMFormatDescription 工厂（start 与路由自愈共用）。
    private func makeMasterFormatDescription() throws -> CMFormatDescription {
        var asbd = masterFormat.streamDescription.pointee
        var descOut: CMFormatDescription?
        let descStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &descOut
        )
        guard descStatus == noErr, let desc = descOut else {
            throw SystemAudioMixerError.cannotCreateMasterFormatDescription(descStatus)
        }
        return desc
    }

    /// 装配 mainMixer 输出 tap（start 与路由自愈共用）：按当前 mixer 输出总线格式建
    /// converter 与 masterFormat 描述；tap 回调（渲染线程）只做格式转换 + delivery 串行
    /// 队列投递——零锁获取、闭包只捕获不可变量。converter/描述建不出时上抛
    ///（start 侧回滚节点装配；自愈侧降级为无声输出）。
    private func installMainMixerTap(engine: AVAudioEngine, output: @escaping (CMSampleBuffer) -> Void) throws {
        let mainMixer = engine.mainMixerNode
        let mixerOutFormat = mainMixer.outputFormat(forBus: 0)
        guard let outputConverter = AVAudioConverter(from: mixerOutFormat, to: masterFormat) else {
            throw SystemAudioMixerError.cannotCreateConverter(from: mixerOutFormat, to: masterFormat)
        }
        let desc = try makeMasterFormatDescription()
        mainMixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, when in
            guard let self, when.isHostTimeValid else { return }
            let startPTS = CMClock.convertSystemUnitsToHostTime(when.hostTime)
            let deliveryQueue = self.deliveryQueue
            self.drainConverter(outputConverter, from: buffer, startPTS: startPTS) { segment, segmentPTS in
                deliveryQueue.async { [weak self] in
                    self?.deliver(segment, pts: segmentPTS, formatDescription: desc, handler: output)
                }
            }
        }
    }

    // MARK: - 内部：渲染与打包

    /// mic tap 回调工厂：闭包只捕获不可变量（converter/ring/队列；self 仅为读取 `let`
    /// masterFormat 的 drainConverter）——渲染线程零锁获取、零跨对象可变状态读取；转换后逐段
    /// 投递 micDelivery 串行队列，ring 写入（ring 自带锁）在队列侧执行，与系统声路径同构。
    /// PTS 不经此路径：mic 与系统声在 mainMixer 混合，输出 PTS 由 mainMixer tap 统一赋予。
    func makeMicTapHandler(ring: RingBuffer, converter: AVAudioConverter) -> (AVAudioPCMBuffer) -> Void {
        let queue = micDeliveryQueue
        return { [weak self] buffer in
            guard let self, buffer.frameLength > 0 else { return }
            self.drainConverter(converter, from: buffer, startPTS: .invalid) { segment, _ in
                queue.async { ring.write(from: segment) }
            }
        }
    }

    /// 测试专用围栏：等待 mic 串行队列在途 ring 写入完成（生产路径由 stop()/setMicMuted 围栏）。
    func flushMicDeliveryForTesting() {
        micDeliveryQueue.sync { }
    }

    /// sourceNode 渲染回调（engine 实时线程）：从指定环形缓冲取数，欠载补零（静音）。
    private func renderFromRing(_ audioBufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int, from ring: RingBuffer) -> OSStatus {
        let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let filled = ring.readInto(abl: abl, frameCount: frameCount)
        for buffer in abl {
            guard let base = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for index in filled..<frameCount {
                base[index] = 0
            }
        }
        return noErr
    }

    /// delivery 串行队列（单消费者）：gate 裁剪 → CMSampleBuffer 打包 → 交上层 append。
    /// 锁获取与内存分配全部离开渲染线程；串行执行保证样本与时间轴顺序。
    private func deliver(_ pcm: AVAudioPCMBuffer, pts: CMTime, formatDescription: CMFormatDescription, handler: @escaping (CMSampleBuffer) -> Void) {
        let gate: CMTime = stateLock.withStateLock { gatePTS }
        guard let decision = AudioSampleBridge.trimDecision(
            bufferPTS: pts,
            frameCount: Int(pcm.frameLength),
            sampleRate: masterFormat.sampleRate,
            gate: gate
        ) else { return }
        guard let sample = AudioSampleBridge.makeSampleBuffer(
            pcm: pcm,
            skipFrames: decision.skipFrames,
            pts: decision.outputPTS,
            formatDescription: formatDescription
        ) else { return }
        handler(sample)
    }

    /// AVAudioConverter 泵：单输入缓冲反复 convert 直到输入耗尽（转换器内部可能残留
    /// 重采样缓冲），每段输出回调一次；`startPTS` 非零时逐段推进并交付段起始 PTS。
    private func drainConverter(_ converter: AVAudioConverter, from input: AVAudioPCMBuffer, startPTS: CMTime, emit: (AVAudioPCMBuffer, CMTime) -> Void) {
        var delivered = false
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if delivered {
                status.pointee = .noDataNow
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return input
        }
        let ratio = masterFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + AVAudioFrameCount(masterFormat.sampleRate / 10)
        var nextPTS = startPTS
        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: masterFormat, frameCapacity: capacity) else { return }
            var error: NSError?
            let status = converter.convert(to: out, error: &error, withInputFrom: inputBlock)
            guard status != .error, error == nil else { return }
            if out.frameLength > 0 {
                emit(out, nextPTS)
                nextPTS = CMTimeAdd(nextPTS, CMTime(value: CMTimeValue(Int(out.frameLength)), timescale: CMTimeScale(masterFormat.sampleRate)))
            }
            if status != .haveData { return } // .inputRanDry / .endOfStream：输入耗尽
        }
    }
}

// MARK: - 环形缓冲

extension SystemAudioMixer {
    /// Float32 非交错定容环形缓冲（frame 环）。写满丢最旧，永远保留最新内容；
    /// 读欠载返回实际帧数（调用方补零）。锁内只做内存拷贝，实时线程安全。
    final class RingBuffer {
        let channels: Int
        let capacityFrames: Int
        private var storage: [[Float]]
        private var writePosition = 0
        private var bufferedFrames = 0
        private let lock = NSLock()

        init(channels: Int, capacityFrames: Int) {
            let channelCount = max(1, channels)
            let frameCapacity = max(1, capacityFrames)
            self.channels = channelCount
            self.capacityFrames = frameCapacity
            self.storage = (0..<channelCount).map { _ in Array(repeating: 0, count: frameCapacity) }
        }

        /// 当前缓冲帧数。
        var bufferedCount: Int {
            lock.withStateLock { bufferedFrames }
        }

        /// 清空缓冲并把写指针归零（静音转换排空用）。内存不清零——写指针归位后旧内容不可达。
        func reset() {
            lock.lock()
            defer { lock.unlock() }
            writePosition = 0
            bufferedFrames = 0
        }

        /// 写入 AVAudioPCMBuffer（非交错 Float32）；格式声道不匹配时整段丢弃。
        func write(from pcm: AVAudioPCMBuffer) {
            guard let channelData = pcm.floatChannelData, Int(pcm.format.channelCount) == channels else { return }
            let frames = Int(pcm.frameLength)
            lock.lock()
            defer { lock.unlock() }
            let skip = max(0, frames - capacityFrames)
            let usable = frames - skip
            guard usable > 0 else { return }
            var offset = skip
            repeat {
                let count = min(frames - offset, capacityFrames - writePosition)
                for channel in 0..<channels {
                    _ = storage[channel].withUnsafeMutableBufferPointer { destination in
                        memcpy(destination.baseAddress! + writePosition,
                               channelData[channel] + offset,
                               count * MemoryLayout<Float>.size)
                    }
                }
                writePosition = (writePosition + count) % capacityFrames
                offset += count
            } while offset < frames
            bufferedFrames = min(capacityFrames, bufferedFrames + usable)
        }

        /// 写入测试友好的通道数组（block[channel] 长度 ≥ frameCount）；超容丢最旧。
        func write(_ block: [[Float]], frameCount: Int) {
            lock.lock()
            defer { lock.unlock() }
            let skip = max(0, frameCount - capacityFrames)
            let usable = frameCount - skip
            guard usable > 0 else { return }
            var offset = skip
            repeat {
                let count = min(frameCount - offset, capacityFrames - writePosition)
                for channel in 0..<channels {
                    _ = block[channel].withUnsafeBufferPointer { source in
                        storage[channel].withUnsafeMutableBufferPointer { destination in
                            memcpy(destination.baseAddress! + writePosition,
                                   source.baseAddress! + offset,
                                   count * MemoryLayout<Float>.size)
                        }
                    }
                }
                writePosition = (writePosition + count) % capacityFrames
                offset += count
            } while offset < frameCount
            bufferedFrames = min(capacityFrames, bufferedFrames + usable)
        }

        /// 读至多 frameCount 帧到 block（block[channel] 长度须 ≥ frameCount），返回实际帧数。
        @discardableResult
        func read(into block: inout [[Float]], frameCount: Int) -> Int {
            lock.lock()
            defer { lock.unlock() }
            let count = min(frameCount, bufferedFrames)
            guard count > 0 else { return 0 }
            var readPosition = (writePosition - bufferedFrames + capacityFrames) % capacityFrames
            var offset = 0
            repeat {
                let chunk = min(count - offset, capacityFrames - readPosition)
                for channel in 0..<channels {
                    _ = storage[channel].withUnsafeBufferPointer { source in
                        block[channel].withUnsafeMutableBufferPointer { destination in
                            memcpy(destination.baseAddress! + offset,
                                   source.baseAddress! + readPosition,
                                   chunk * MemoryLayout<Float>.size)
                        }
                    }
                }
                readPosition = (readPosition + chunk) % capacityFrames
                offset += chunk
            } while offset < count
            bufferedFrames -= count
            return count
        }

        /// 渲染热路径读取：直接写入 AudioBufferList（非交错，每 buffer 单通道）。
        @discardableResult
        func readInto(abl: UnsafeMutableAudioBufferListPointer, frameCount: Int) -> Int {
            guard abl.count >= channels else { return 0 }
            lock.lock()
            defer { lock.unlock() }
            let count = min(frameCount, bufferedFrames)
            guard count > 0 else { return 0 }
            var readPosition = (writePosition - bufferedFrames + capacityFrames) % capacityFrames
            var offset = 0
            repeat {
                let chunk = min(count - offset, capacityFrames - readPosition)
                for channel in 0..<channels {
                    guard let base = abl[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    _ = storage[channel].withUnsafeBufferPointer { source in
                        memcpy(base + offset, source.baseAddress! + readPosition, chunk * MemoryLayout<Float>.size)
                    }
                }
                readPosition = (readPosition + chunk) % capacityFrames
                offset += chunk
            } while offset < count
            bufferedFrames -= count
            return count
        }
    }
}

// MARK: - 采样桥接

/// AVAudioPCMBuffer ↔ CMSampleBuffer 互转与 gate 裁剪决策（纯逻辑，可无头单测）。
enum AudioSampleBridge {
    /// gate 裁剪决策：缓冲内容时间区间 [bufferPTS, bufferPTS + frameCount/sampleRate)。
    /// 返回 nil = 整段丢弃（完全早于 gate）；否则（应跳过的头部帧数, 输出 PTS）。
    /// 跳帧数经整数运算向上取整，保证输出 PTS ≥ gate（过上层锚点兜底校验），误差 ≤ 1 样本。
    static func trimDecision(bufferPTS: CMTime, frameCount: Int, sampleRate: Double, gate: CMTime) -> (skipFrames: Int, outputPTS: CMTime)? {
        guard frameCount > 0 else { return nil }
        guard gate.isNumeric, bufferPTS.isNumeric else { return (0, bufferPTS) }
        let bufferEnd = CMTimeAdd(bufferPTS, CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(sampleRate)))
        if CMTimeCompare(bufferEnd, gate) <= 0 { return nil }
        if CMTimeCompare(bufferPTS, gate) >= 0 { return (0, bufferPTS) }
        // 整数 ceil(delta.value * sampleRate / delta.timescale)：无浮点漂移
        let delta = CMTimeSubtract(gate, bufferPTS)
        guard delta.value > 0, delta.timescale > 0 else { return nil }
        let scale = Int64(delta.timescale)
        let rate = Int64(sampleRate)
        guard delta.value < Int64.max / rate else { return nil } // 巨型 CMTime：必然整段早于 gate
        let skip = min(Int64(frameCount), (delta.value * rate + scale - 1) / scale)
        guard skip > 0, skip < Int64(frameCount) else { return nil }
        return (Int(skip), CMTimeAdd(bufferPTS, CMTime(value: CMTimeValue(skip), timescale: CMTimeScale(sampleRate))))
    }

    /// 非交错 PCM → CMSampleBuffer：各通道数据按序拼接进 CMBlockBuffer；
    /// PCM 恒定包尺寸可传 nil packetDescriptions。`skipFrames` 跳过头部帧（gate 裁剪用）。
    static func makeSampleBuffer(pcm: AVAudioPCMBuffer, skipFrames: Int, pts: CMTime, formatDescription: CMFormatDescription) -> CMSampleBuffer? {
        guard let channelData = pcm.floatChannelData else { return nil }
        let frames = Int(pcm.frameLength) - skipFrames
        guard frames > 0 else { return nil }
        let channels = Int(pcm.format.channelCount)
        let bytesPerFrame = Int(pcm.format.streamDescription.pointee.mBytesPerFrame)
        let totalBytes = frames * bytesPerFrame * channels

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalBytes,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalBytes,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else { return nil }
        for channel in 0..<channels {
            let status = CMBlockBufferReplaceDataBytes(
                with: channelData[channel] + skipFrames,
                blockBuffer: blockBuffer,
                offsetIntoDestination: channel * frames * bytesPerFrame,
                dataLength: frames * bytesPerFrame
            )
            guard status == noErr else { return nil }
        }
        var sampleBuffer: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: frames,
            presentationTimeStamp: pts,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr else { return nil }
        return sampleBuffer
    }

    /// 以新 PTS 复制 CMSampleBuffer（Task 10 暂停平移用）：数据块与样本时长原样保留，
    /// 仅替换时间信息（decodeTimeStamp 置 `.invalid`，音轨无独立解码时间）。复制为浅拷贝
    ///（共享底层 block buffer），失败返回 nil（调用方丢弃该包）。
    static func sampleBuffer(copying original: CMSampleBuffer, presentationTimeStamp pts: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(original),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: original,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy
        )
        guard status == noErr, let copy else { return nil }
        return copy
    }

    /// SCStream 音频 CMSampleBuffer → AVAudioPCMBuffer：格式取自样本自带格式描述，
    /// 数据经 AudioBufferList 原样拷贝（交错/非交错通吃）。失败返回 nil（丢样本）。
    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else { return nil }
        var asbd = asbdPointer.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }
        let channelCount = Int(asbd.mChannelsPerFrame)
        let ablSize = MemoryLayout<AudioBufferList>.size + max(0, channelCount - 1) * MemoryLayout<AudioBuffer>.size
        let ablPointer = UnsafeMutableRawPointer.allocate(byteCount: ablSize, alignment: MemoryLayout<AudioBuffer>.alignment)
        defer { ablPointer.deallocate() }
        var retainedBlock: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablPointer.assumingMemoryBound(to: AudioBufferList.self),
            bufferListSize: ablSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &retainedBlock
        )
        guard status == noErr,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return nil }
        pcm.frameLength = AVAudioFrameCount(frameCount)
        let source = UnsafeMutableAudioBufferListPointer(ablPointer.assumingMemoryBound(to: AudioBufferList.self))
        let destination = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }
        for index in 0..<source.count {
            let bytes = Int(source[index].mDataByteSize)
            guard let sourceBytes = source[index].mData, let destinationBytes = destination[index].mData else { return nil }
            memcpy(destinationBytes, sourceBytes, bytes)
            destination[index].mDataByteSize = UInt32(bytes)
        }
        return pcm
    }
}
