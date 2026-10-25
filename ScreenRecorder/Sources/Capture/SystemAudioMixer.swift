import AVFoundation
import CoreMedia
import Foundation

/// 系统声音混音器：SCStream 的 PCM → `AVAudioSourceNode` 环形缓冲 → `AVAudioEngine`
/// mainMixer → tap → `AVAudioConverter` 转 masterFormat → 打包 CMSampleBuffer 交给上层写轨。
/// Task 8 仅接系统声音一路；Task 9 经 `setMicrophoneInput` + inputNode tap 加入第二路混音。
///
/// 音画对齐机制：混音器输出样本的 PTS 取自 engine tap 的 host time（与 SCStream 视频 PTS 同
/// mach 时基）。writer 会话锚点由视频首帧确定（AssetWriterSession 首个到轨样本），锚点之前的
/// 系统声音属录制前内容——混音器经 `setGatePTS`（视频锚定后由上层设置）做帧级裁剪：锚点前的
/// 整段丢弃、跨界样本裁掉头部、其余原样输出；gate 生效前已在途的样本由上层按锚点兜底丢弃。
///
/// 监听静音（实测裁决，probe 实验）：engine 的 mainMixer 默认直连输出硬件，且 mixer 节点上的
/// tap 在 fader 之后——`mainMixer.outputVolume = 0` 会把录制内容一并静音。故在 mainMixer 下游
/// 插入一个音量 0 的静音 mixer 接通输出硬件：录制链路满幅、外放无声。
///
/// 线程模型：`enqueueSystemAudio` 在 SCStream audio 队列、tap 回调在 engine 渲染线程——
/// 实时线程只做格式转换与入队；gate 裁剪、CMSampleBuffer 打包、上层 append 全部在
/// `deliveryQueue` 串行队列执行（单消费者、样本顺序保持）。`stop()` 先停 engine 再围栏排空
/// 该队列，保证上层收尾 writer 时无 append 在途或排队。共享状态经 `stateLock` 串行化。
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

    private var isRunning = false
    private var engine: AVAudioEngine?
    private var silencer: AVAudioMixerNode?
    private var sourceNode: AVAudioSourceNode?
    /// 音画锚点（视频首帧 PTS；`.invalid` = 未设置，不裁剪）。
    private var gatePTS: CMTime = .invalid
    /// SCStream 音频源格式 → masterFormat 的转换器（格式不变则复用）。
    private var sourceConverter: AVAudioConverter?
    private var sourceConverterFormat: AVAudioFormat?
    /// Task 9 用：登记的麦克风输入格式（Task 8 仅登记不接线）。
    private(set) var microphoneFormat: AVAudioFormat?

    init(masterFormat: AVAudioFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!) {
        self.masterFormat = masterFormat
        self.ring = RingBuffer(channels: Int(masterFormat.channelCount),
                               capacityFrames: Int(masterFormat.sampleRate))
    }

    // MARK: - 生命周期

    /// 挂接 engine：sourceNode → mainMixer（tap 在此）→ 静音 mixer → 输出硬件，并启动 engine。
    /// `output` 在 delivery 串行队列回调，交付 masterFormat 的 CMSampleBuffer（host time PTS）。
    /// engine 由本类持有并在 `stop()` 中停机；engine.start 失败时回滚全部装配再上抛。
    func start(engine: AVAudioEngine, output: @escaping (CMSampleBuffer) -> Void) throws {
        let running: Bool = stateLock.withStateLock { isRunning }
        guard !running else { return }

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

        let source = AVAudioSourceNode(format: masterFormat) { [weak self] _, _, frameCount, audioBufferList in
            guard let self else { return noErr }
            return self.renderFromRing(audioBufferList, frameCount: Int(frameCount))
        }
        engine.attach(source)
        let mainMixer = engine.mainMixerNode
        engine.connect(source, to: mainMixer, format: masterFormat)
        // 监听静音：tap 在 mainMixer 输出 bus（fader 之后），不能靠归零 mainMixer 音量静音；
        // 下游插入音量 0 的静音 mixer 接通输出硬件（engine 要求 graph 触达 i/o 单元）。
        let silencer = AVAudioMixerNode()
        engine.attach(silencer)
        engine.connect(mainMixer, to: silencer, format: nil)
        engine.connect(silencer, to: engine.outputNode, format: nil)
        silencer.outputVolume = 0
        let mixerOutFormat = mainMixer.outputFormat(forBus: 0)
        guard let outputConverter = AVAudioConverter(from: mixerOutFormat, to: masterFormat) else {
            engine.detach(source)
            engine.detach(silencer)
            throw SystemAudioMixerError.cannotCreateConverter(from: mixerOutFormat, to: masterFormat)
        }
        // 实时线程闭包只捕获不可变量（converter/desc/handler/队列），零锁获取：
        // 格式转换后逐段入 delivery 串行队列，gate 裁剪 + 打包 + append 全部离开渲染线程。
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
        do {
            try engine.start()
        } catch {
            mainMixer.removeTap(onBus: 0)
            engine.detach(source)
            engine.detach(silencer)
            throw error
        }
        stateLock.withStateLock {
            isRunning = true
            self.engine = engine
            self.silencer = silencer
            self.sourceNode = source
        }
    }

    /// 停机并回滚 engine 装配（幂等）。先停 engine 终止新入队，再围栏排空 delivery 队列——
    /// 本方法返回时，已入队/在途的打包与 append 全部完成（上层收尾 writer 前必须先调本方法），
    /// 最后才清理共享状态并摘除节点。
    func stop() {
        let teardown: (AVAudioEngine, AVAudioMixerNode, AVAudioSourceNode)? = stateLock.withStateLock {
            guard isRunning else { return nil }
            isRunning = false
            guard let engine, let silencer, let sourceNode else { return nil }
            self.engine = nil
            self.silencer = nil
            self.sourceNode = nil
            return (engine, silencer, sourceNode)
        }
        guard let (engine, silencer, source) = teardown else { return }
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.stop()
        deliveryQueue.sync { } // 围栏：串行队列单消费者，sync 返回即在途/排队工作全部完成
        stateLock.withStateLock {
            gatePTS = .invalid
            sourceConverter = nil
            sourceConverterFormat = nil
        }
        engine.detach(silencer)
        engine.detach(source)
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

    /// 登记麦克风输入格式（Task 9 据此接 inputNode tap；Task 8 仅登记）。
    func setMicrophoneInput(_ format: AVAudioFormat) {
        stateLock.withStateLock { microphoneFormat = format }
    }

    /// 设置音画锚点（视频首帧 PTS）。此后输出内容时间裁剪到锚点起；
    /// `.invalid` 取消裁剪。上层在 writer 锚定后调用。
    func setGatePTS(_ pts: CMTime) {
        stateLock.withStateLock { gatePTS = pts }
    }

    // MARK: - 内部：渲染与打包

    /// sourceNode 渲染回调（engine 实时线程）：从环形缓冲取数，欠载补零（静音）。
    private func renderFromRing(_ audioBufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) -> OSStatus {
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
