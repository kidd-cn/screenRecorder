import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

/// 离线缩放导出参数（P9）：nil = 沿用源（fps 沿用源全帧直通；maxHeight 沿用源分辨率）。
/// 钳制在渲染时进行（`fps <= 0` 视同沿用源全帧；maxHeight 经
/// `ExportCore.scaledRenderSize` 只降不升、宽取偶）——本结构不做构造期钳制
///（与 GIFExportOptions 的差异：brief 只钉字段面，档位语义由渲染侧收敛）。
struct ExportVideoOptions: Equatable {
    /// 目标帧率（nil = 沿用源；设定 > 0 时按源时间轴等隔丢帧——PTS 原样保留，时长不动）。
    var fps: Int?
    /// 输出最大高度（nil = 沿用源分辨率；设定且源更高时等比只降不升、宽取偶——
    /// `ExportCore.scaledRenderSize` 同一缩放真源）。
    var maxHeight: Int?
    var codec: VideoCodec
}

/// 离线缩放渲染引擎（P9 核心）：AVAssetReader 逐帧 → 该时刻所在 segment 的
/// `ZoomTransforms.contentTransform`（与实时合成**同一变换真源**——Task 1/17 钉定，
/// 离线侧零复制零变体）→ CI 重投影 → AVAssetWriter 写 MP4。几何与实时
/// `PiPCompositor` 同一 CI 画布口径（CIImage y 向上、bounds = 底帧像素空间）。
///
/// 时间线纪律（「音画时间线不动」）：
/// - 视频逐帧**同 PTS 回写**；音轨经 reader PCM 解码 → writer AAC 重编码（采样率/
///   声道按源、与一期 `AssetWriterSession.addAudioInput` 同档口径），PTS 原样透传
///   ——重编码不改 PTS；两条轨首个到轨样本锚定 `startSession`（同款纪律）；
/// - fps 档丢帧只删视频帧、不动 PTS（等隔采样，时长不变）。
///
/// 写盘纪律（控制器裁定）：导出派生物**不走 .claim**（claim 是录制现场的排他面，
/// 与 T15 GIF/压缩一致无此需求；并发由 T16 导出单飞门防）——直用 AVAssetWriter，
/// 目标经冲突惯例命名保证不覆盖既有文件；失败路径删除半截成片不留垃圾。
/// `expectsMediaDataInRealTime = true` + isReady 轮询后追加：macOS 27 实测非实时档
/// 多轨写入会被跨轨配速饿死（isReadyForMoreMediaData 永不复位）；离线**无丢帧**
/// 由「轮询到受理再追加」保证（与实时「宁丢帧不阻塞」相反——离线丢帧即时间线缺帧）。
///
/// 进度契约（对齐 T15 消费惯例）：0…1、单调到顶恰一次 1.0、主线程外调用（async
/// 主体在协作池线程），经 `ExportCore.deduplicatedProgress` 去重；帧推进按源时间
/// 占比推到 0.95，finishWriting 完成恰推一次 1.0。
/// 真实渲染链路（GPU CI、长片吞吐）归批次真机验收；headless 测试经 `context:` 缝
/// 注入软件渲染上下文（PiPCompositorTests 同纪律）。
///
/// R1 修复（审阅 F1/F2/F3）：
/// - **会话锚点 = 双轨首样本最小 PTS**（F1）——外部文件形态「某轨首样本晚于另一轨」
///   下，锚单轨首样本会让早到轨的样本以早于会话起点的 PTS 追加：macOS 27 静默钳到
///   成片起点压扁片头时间线，旧平台直接追加失败。锚点在装配期（startWriting 前）
///   一次性确定；appenders 兜底跳过早于锚点的病态样本（B 帧源解码序首个样本 PTS
///   未必最小——正常源零行为变化）；
/// - **isReady 有界看门狗**（F2）——轮询 30s 不复位转类型化错误，不无限挂起
///   （`AssetWriterSession.finish` 有界等待同纪律）；
/// - **零可解码样本防线**（F3）——双轨均无可解码样本在 startWriting 前抛
///   `.noRenderableSamples`（损坏源不触达「未 startWriting 的 finishWriting」
///   ObjC 异常路径）；视频轨在但零帧解出（音轨在、视频零帧）在收尾前防线拦截。
enum OfflineZoomRenderer {
    /// 缓入窗口（秒）= 实时 attack 时长——`AutoZoomState.attackDuration` 单一真源
    ///（Task 17 钉定：离线侧不复制常量，与实时同窗）。
    static let easingInWindow: TimeInterval = AutoZoomState.attackDuration
    /// 缓出窗口（秒）= 实时 release 时长——`AutoZoomState.releaseDuration` 单一真源。
    static let easingOutWindow: TimeInterval = AutoZoomState.releaseDuration

    /// 渲染失败的可呈现错误（T16 导出面同族——文案简体中文）。
    enum RenderError: LocalizedError {
        case cannotAddVideoInput
        case cannotAddAudioInput
        case readerFailed(status: AVAssetReader.Status, underlying: Error?)
        case writerFailed(status: AVAssetWriter.Status, underlying: Error?)
        case appendFailedVideo(underlying: Error?)
        case appendFailedAudio(underlying: Error?)
        case cannotCreateOutputBuffer
        /// R1 F2：编码器输入长时间未就绪（isReady 看门狗超时——导出中止而非挂起）
        case appendInputStalled(mediaType: String)
        /// R1 F3：源不含可解码的媒体样本（视频轨在但零可解码帧等损坏源——
        /// 不产出无视频的半残成片，也不触达未启动会话的 finishWriting）
        case noRenderableSamples

        var errorDescription: String? {
            switch self {
            case .cannotAddVideoInput:
                return NSLocalizedString("缩放导出失败：编码器视频输入装配被拒绝", comment: "msg")
            case .cannotAddAudioInput:
                return NSLocalizedString("缩放导出失败：音频输入装配被拒绝", comment: "msg")
            case .readerFailed(let status, let underlying):
                return String(format: NSLocalizedString("缩放导出失败：读取源失败（status=%lld）：%@", comment: "msg"), status.rawValue, underlying.map(String.init(describing:)) ?? NSLocalizedString("无底层错误", comment: "msg"))
            case .writerFailed(let status, let underlying):
                return String(format: NSLocalizedString("缩放导出失败：写入成片失败（status=%lld）：%@", comment: "msg"), status.rawValue, underlying.map(String.init(describing:)) ?? NSLocalizedString("无底层错误", comment: "msg"))
            case .appendFailedVideo(let underlying):
                return String(format: NSLocalizedString("缩放导出失败：视频帧写入失败：%@", comment: "msg"), underlying.map(String.init(describing:)) ?? NSLocalizedString("未知原因", comment: "msg"))
            case .appendFailedAudio(let underlying):
                return String(format: NSLocalizedString("缩放导出失败：音频样本写入失败：%@", comment: "msg"), underlying.map(String.init(describing:)) ?? NSLocalizedString("未知原因", comment: "msg"))
            case .cannotCreateOutputBuffer:
                return NSLocalizedString("缩放导出失败：无法创建输出像素缓冲", comment: "msg")
            case .appendInputStalled(let mediaType):
                return String(format: NSLocalizedString("缩放导出失败：%@编码器长时间未就绪，导出已中止", comment: "msg"), mediaType)
            case .noRenderableSamples:
                return NSLocalizedString("缩放导出失败：源不含可解码的媒体样本", comment: "msg")
            }
        }
    }

    /// segment 内部缩放进度 0…1（线性相位位置；easeInOut 由
    /// `ZoomTransforms.contentTransform` 内部施加——与实时 `AutoZoomState.progress`
    /// 同构：入点缓入、中段满档位、出点缓出、段外/端点 0（= 原始画面，对应
    /// contentTransform 的 progress 0 → nil 口径））。窗口与段长冲突（段短于缓入+
    /// 缓出之和）时窗口各收敛到段长一半：effIn = min(缓入窗, 段长/2)、
    /// effOut = min(缓出窗, 段长 − effIn)——两窗恒不重叠且恰铺满或短于段长。
    static func zoomProgress(for segment: ZoomSegment, at time: TimeInterval) -> Double {
        guard time >= segment.start, time < segment.end else { return 0 } // 半开区间
        let duration = segment.end - segment.start
        let effectiveIn = min(easingInWindow, duration / 2)
        let effectiveOut = min(easingOutWindow, duration - effectiveIn)
        let fromStart = time - segment.start
        if fromStart < effectiveIn { return fromStart / effectiveIn }
        let toEnd = segment.end - time
        if toEnd < effectiveOut { return toEnd / effectiveOut }
        return 1
    }

    // MARK: - 输出命名（nextFileURL 冲突惯例，与 ExportCore 对齐）

    /// 输出 URL：源同目录 `<原名>_缩放.mp4`，同名冲突追加 " (n)" 自 2 递增
    /// （复用 `ExportCore.conflictFreeURL`——冲突惯例单一事实源；不创建文件）。
    static func zoomedDestinationURL(for sourceURL: URL) -> URL {
        let target = sourceURL.deletingLastPathComponent().appendingPathComponent(
            "\(sourceURL.deletingPathExtension().lastPathComponent)\(NSLocalizedString("_缩放", comment: "Zoom export suffix")).mp4")
        return ExportCore.conflictFreeURL(for: target)
    }

    /// 剪辑输出 URL：源同目录 `<原名>_剪辑.mp4`（2026-11-21 剪辑 v1——文档含剪除段
    /// 时走本命名；纯缩放段维持 `_缩放.mp4` 既有惯例，裁决见编辑器导出命名）。
    static func editedDestinationURL(for sourceURL: URL) -> URL {
        let target = sourceURL.deletingLastPathComponent().appendingPathComponent(
            "\(sourceURL.deletingPathExtension().lastPathComponent)\(NSLocalizedString("_剪辑", comment: "Edit export suffix")).mp4")
        return ExportCore.conflictFreeURL(for: target)
    }

    /// 重写样本 PTS（音轨 PTS 平移专用——视频走 adaptor 的 presentationTime 直传）：
    /// 保留原 duration/decodeTime，仅换 presentationTimeStamp。
    static func sampleBuffer(_ sample: CMSampleBuffer, withPresentationTime pts: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
        guard CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing) == noErr else { return nil }
        timing.presentationTimeStamp = pts
        var output: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &output) == noErr
        else { return nil }
        return output
    }

    // MARK: - 轨道缩略图（剪映对齐·批次 3：时间线 filmstrip 的抽帧真源）

    /// 抽帧产物（进程级缓存载体；@unchecked Sendable——CGImage 不可变，跨线程只读）。
    struct Filmstrip: @unchecked Sendable {
        /// 相邻缩略图的时间间隔（秒；槽位网格锚定源时间，随缩放重排宽度）。
        let interval: TimeInterval
        /// 请求时间 → 抽帧（请求时间为键——actualTime 有容差漂移，不作为键）。
        let images: [TimeInterval: CGImage]
    }

    /// 槽位间隔（纯函数）：默认 0.5s 下限；超长片按 ≤240 张自适应放大间隔
    ///（240 × 128×72×4B ≈ 8.8MB 内存上限）。
    static func filmstripInterval(forDuration duration: TimeInterval) -> TimeInterval {
        guard duration.isFinite, duration > 0 else { return 1 }
        return max(duration / 240, 0.5)
    }

    /// 离线抽帧：[0, duration) 按 interval 网格逐时间点抽帧（±半间隔容差换速度）。
    /// 失败/无视频轨 → nil。逐张生成（调用方后台任务驱动；渐进上屏由调用方裁夺）。
    static func sampleFilmstrip(sourceURL: URL, interval: TimeInterval,
                                maxSize: CGSize) async -> Filmstrip? {
        guard interval.isFinite, interval > 0 else { return nil }
        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        _ = videoTrack // 抽帧经 generator（track 存在性闸）
        let durationSeconds = (try? await asset.load(.duration).seconds) ?? 0
        guard durationSeconds.isFinite, durationSeconds > 0 else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maxSize
        let tolerance = CMTime(seconds: interval / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        var images: [TimeInterval: CGImage] = [:]
        var time: TimeInterval = 0
        while time < durationSeconds {
            if let result = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)) {
                images[time] = result.image
            }
            time += interval
        }
        return images.isEmpty ? nil : Filmstrip(interval: interval, images: images)
    }

    // MARK: - 波形数据（剪映对齐·批次 2：音频波形轨的采样真源）

    /// 波形采样配置（每 bucket 的最小/最大 RMS 对；bucketSeconds 由调用方按目标像素率定）。
    struct WaveformBucket: Equatable {
        /// bucket 起始时间（秒）。
        let start: TimeInterval
        /// 该 bucket 内样本绝对值的最大值（0…1 归一化；静音 bucket = 0）。
        let minimum: Float
        let maximum: Float
    }

    /// 从 PCM 样本缓冲提取 min/max（16-bit 整型或 32-bit 浮点 interleaved；
    /// CoreAudio Float32 的 ±1 口径即归一化）。返回 nil = 格式不支持/无载荷。
    static func waveformExtremes(of sample: CMSampleBuffer) -> (minimum: Float, maximum: Float)? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var length = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                         totalLengthOut: &length, dataPointerOut: &dataPointer) == kCMBlockBufferNoErr,
              let rawPointer = dataPointer, length > 0 else { return nil }
        let pointer = UnsafeMutableRawPointer(rawPointer)
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { return nil }
        var minimum = Float.greatestFiniteMagnitude
        var maximum = -Float.greatestFiniteMagnitude
        let channels = max(Int(asbd.mChannelsPerFrame), 1)
        switch asbd.mFormatID {
        case kAudioFormatLinearPCM where asbd.mBitsPerChannel == 16:
            // 16-bit 整型：归一化除以 32768（interleaved 按首声道取样）。
            let stride = channels * 2
            let usable = length - length % stride
            let typed = pointer.bindMemory(to: Int16.self, capacity: usable / 2)
            let frames = usable / stride
            for frame in 0..<frames {
                let value = Float(typed[frame * channels]) / 32768.0
                minimum = min(minimum, value)
                maximum = max(maximum, value)
            }
        case kAudioFormatLinearPCM where asbd.mBitsPerChannel == 32 && asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0:
            let stride = channels * 4
            let usable = length - length % stride
            let typed = pointer.bindMemory(to: Float.self, capacity: usable / 4)
            let frames = usable / stride
            for frame in 0..<frames {
                let value = typed[frame * channels]
                minimum = min(minimum, value)
                maximum = max(maximum, value)
            }
        default:
            return nil // 其他位深/格式暂不支持（波形尽力而为副通道）
        }
        guard minimum <= maximum else { return nil }
        // 钳进归一化口径：minimum ∈ [-1, 0]、maximum ∈ [0, 1]（正半周样本 min 恒 0 起画）。
        return (max(min(minimum, 0), -1), min(max(maximum, 0), 1))
    }

    /// 波形采样（离线全曲一次）：AVAssetReader PCM 解码 → 按 bucketSeconds 聚合
    /// min/max → 桶数组。失败/无音轨 → 空数组（调用方显示空波形或占位）。
    /// 两遍法（2026-11-21）：解码器会合并出 8192 帧大包（PTS 步进 0.186s/包）——
    /// 一遍法按 PTS 打戳会把整包数据全落进第一个桶；先收包（PTS+时长+极值），再按
    /// 桶网格双指针扫掠聚合，包的时长跨越多少桶就喂多少桶。
    /// - parameter bucketSeconds: 每桶时长（秒）——采样一次按最细桶采（0.02s），
    ///   缩放时聚合，避免重复解码。
    static func sampleWaveform(sourceURL: URL, bucketSeconds: TimeInterval = 0.02) async -> [WaveformBucket] {
        guard bucketSeconds > 0 else { return [] }
        let asset = AVURLAsset(url: sourceURL)
        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        do {
            reader = try AVAssetReader(asset: asset)
            output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            output.alwaysCopiesSampleData = false
            reader.add(output)
        } catch {
            return []
        }
        guard reader.startReading() else { return [] }
        // 第一遍：收包（纯 copyNextSampleBuffer 驱动——macOS 上 reader.status 会提前翻
        // .completed，带状态门的循环被掐断只剩首包数据）。
        struct Packet {
            let start: TimeInterval
            let duration: TimeInterval
            let minimum: Float
            let maximum: Float
        }
        var packets: [Packet] = []
        while let sample = output.copyNextSampleBuffer() {
            let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            guard seconds.isFinite, seconds >= 0, CMSampleBufferIsValid(sample) else { continue }
            var duration = CMTimeGetSeconds(CMSampleBufferGetDuration(sample))
            if !(duration.isFinite) || duration <= 0 { duration = bucketSeconds }
            if let extremes = waveformExtremes(of: sample) {
                packets.append(Packet(
                    start: seconds, duration: duration,
                    minimum: extremes.minimum, maximum: extremes.maximum))
            }
        }
        guard let last = packets.last else { return [] }
        let bucketCount = max(Int(((last.start + last.duration) / bucketSeconds).rounded(.up)), 1)
        // 第二遍：桶网格 × 双指针扫掠（包按 PTS 升序——reader 产出序即时间序）。
        var buckets: [WaveformBucket] = []
        buckets.reserveCapacity(bucketCount)
        var packetIndex = 0
        for index in 0..<bucketCount {
            let start = TimeInterval(index) * bucketSeconds
            let end = start + bucketSeconds
            while packetIndex < packets.count,
                  packets[packetIndex].start + packets[packetIndex].duration <= start {
                packetIndex += 1 // 完全在本桶之前的包淘汰
            }
            var minimum = Float(1)
            var maximum = Float(-1)
            var scan = packetIndex
            while scan < packets.count, packets[scan].start < end {
                let packet = packets[scan]
                if packet.start + packet.duration > start { // 与本桶相交
                    minimum = min(minimum, packet.minimum)
                    maximum = max(maximum, packet.maximum)
                }
                scan += 1
            }
            if maximum >= minimum {
                buckets.append(WaveformBucket(start: start, minimum: minimum, maximum: maximum))
            } else {
                buckets.append(WaveformBucket(start: start, minimum: 0, maximum: 0)) // 空桶 = 静音
            }
        }
        reader.cancelReading()
        return buckets
    }

    // MARK: - R1 F2 有界看门狗（appenders 共用；timeout/poll 提参为无头钉测缝）

    /// 等输入受理（离线无丢帧轮询）：isReady 翻真即返回；取消感知、writer 失败即抛
    /// 类型化 `writerFailed`——不吞错误空转；isReady 长时间不复位（编码器停摆/
    /// macOS 27 跨轨饿死形态）超时转 `appendInputStalled`，不无限挂起
    /// （AssetWriterSession.finish 有界等待同纪律）。timeout/poll 提参（生产默认
    /// 30s / 5ms）供 headless 毫秒级档钉测。
    static func waitForInputReady(
        mediaType: String,
        isReady: () -> Bool,
        writerStatus: () -> AVAssetWriter.Status,
        writerError: () -> Error?,
        timeout: TimeInterval = 30,
        pollIntervalNanoseconds: UInt64 = 5_000_000
    ) async throws {
        var waited: TimeInterval = 0
        while !isReady() {
            if Task.isCancelled { throw CancellationError() }
            guard writerStatus() != .failed else {
                throw RenderError.writerFailed(status: writerStatus(), underlying: writerError())
            }
            guard waited < timeout else {
                throw RenderError.appendInputStalled(mediaType: mediaType)
            }
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            waited += TimeInterval(pollIntervalNanoseconds) / 1_000_000_000
        }
    }

    // MARK: - 渲染

    /// 录像 → 缩放/剪辑成片 MP4。`segments`/`cuts` 各先经 validate 规整（排序/钳制/
    /// 去重叠）；段表双空 = 全程恒等直通转码。折叠语义（剪辑 v1，2026-11-21）：全部段
    /// 在**源时间轴**上——剪除段内的帧/音频样本直接跳过（不进输出），其后样本 PTS 平移
    /// −其前剪除总量（`EditTimeline.outputSeconds` 折叠真源）；缩放段照常在源时间轴上
    /// 查找变换，「剔除优先」由跳帧自然成立（交集帧不存在即被剪；完全落入的缩放段自然
    /// 作废）。剪除段非空 → 输出命名 `_剪辑.mp4`，否则 `_缩放.mp4`。`context` 供
    /// headless 测试注入软件渲染上下文（缺省 GPU——与实时 PiPCompositor 同口径）。
    static func render(sourceURL: URL, segments: [ZoomSegment], cuts: [CutSegment] = [],
                       options: ExportVideoOptions,
                       progress: @escaping (Double) -> Void,
                       context: CIContext = CIContext(options: [.useSoftwareRenderer: false])) async throws -> URL {
        let timeline = ZoomSegment.validate(segments)
        let cutRanges = CutSegment.validate(cuts)
        let push = ExportCore.deduplicatedProgress(progress)
        let asset = AVURLAsset(url: sourceURL)

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.emptySource
        }
        let durationSeconds = CMTimeGetSeconds(try await asset.load(.duration))
        guard durationSeconds.isFinite, durationSeconds > 0 else { throw ExportError.emptySource }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        // 输出画布：源可视尺寸（preferredTransform 归位后）为准；maxHeight 只降不升
        //（ExportCore.scaledRenderSize 同一缩放真源，宽取偶）。旋转归位做平移补偿
        //（本应用成片恒 identity——ScreenCaptureKit/AVCaptureSession 出帧即横正向；
        // 归位链为外部文件兜底）。
        let orientedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let orientedSize = CGSize(width: abs(orientedRect.width), height: abs(orientedRect.height))
        let outputSize = ExportCore.scaledRenderSize(
            sourceSize: orientedSize, maxHeight: options.maxHeight) ?? orientedSize
        var orientedTransform = preferredTransform
        orientedTransform.tx -= orientedRect.minX
        orientedTransform.ty -= orientedRect.minY
        let canvasScale = CGAffineTransform(
            scaleX: outputSize.width / orientedSize.width,
            y: outputSize.height / orientedSize.height)
        let outputWidth = Int(outputSize.width.rounded())
        let outputHeight = Int(outputSize.height.rounded())

        // reader：视频 BGRA 像素缓冲；音轨 PCM 解码（AAC 重编码的源口径）
        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)
        var audioOutput: AVAssetReaderAudioMixOutput?
        if let audioTrack = audioTracks.first {
            let output = AVAssetReaderAudioMixOutput(audioTracks: [audioTrack], audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            reader.add(output)
            audioOutput = output
        }

        // writer（不 claim；冲突惯例命名保证目标不存在）。剪辑命名分流（含剪除段
        // → `_剪辑`；纯缩放段 → 既有 `_缩放`）。
        let destinationURL = cutRanges.isEmpty
            ? zoomedDestinationURL(for: sourceURL)
            : editedDestinationURL(for: sourceURL)
        let writer = try AVAssetWriter(url: destinationURL, fileType: .mp4)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: options.codec.avCodecKey,
            AVVideoWidthKey: outputWidth,
            AVVideoHeightKey: outputHeight,
        ])
        videoInput.expectsMediaDataInRealTime = true // macOS 27 非实时档跨轨配速饿死坑（类注释）
        guard writer.canAdd(videoInput) else { throw RenderError.cannotAddVideoInput }
        writer.add(videoInput)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outputWidth,
                kCVPixelBufferHeightKey as String: outputHeight,
            ])

        push(0)

        // 音频输入须在 startWriting 前装配（AVAssetWriter 硬约束）——首个 PCM 样本
        // 在 reader.startReading 后拉取取解码格式建 AAC 输入（copyNextSampleBuffer
        // 须待 reader 进入 reading；该样本暂存）。视频首样本同步装配期拉取：会话锚点
        // 须取**双轨最小首 PTS**（R1 F1——见类注释）。音轨存在但零样本时 audioInput
        // 保持 nil：音轨侧拉到 nil 即收尾，按纯视频装配。
        var audioInput: AVAssetWriterInput?
        var pendingVideoSample: CMSampleBuffer?
        var pendingAudioSample: CMSampleBuffer?
        /// 会话锚点（双轨最小首 PTS——**折叠后**口径；appenders 据此兜底跳过早于锚点的
        /// 病态样本）
        var sessionAnchor: CMTime = .invalid
        /// 已写入视频帧数（R1 F3 零可解码视频帧防线）
        var appendedVideoFrames = 0

        // MARK: 折叠缝（剪辑 v1）：源时间轴 → 输出时间轴（EditTimeline 折叠真源）
        /// 源时间是否落在剪除段内（剪除段已 validate：有序无重叠——线性扫描即正确）。
        func inCut(_ t: Double) -> Bool {
            cutRanges.contains { $0.start <= t && t < $0.end }
        }
        /// 源时间 → 输出 PTS（剪除段内调用方先跳；此处折叠平移，60000 网格误差 ≤8µs）。
        func outputPTS(_ t: Double) -> CMTime {
            CMTime(seconds: EditTimeline.outputSeconds(forSourceSeconds: t, cuts: cutRanges) ?? t,
                   preferredTimescale: 60000)
        }
        /// 装配期拉取首个**存活**样本（剪除段内的样本逐个跳过；轨耗尽 → nil）。
        func firstKeptSample(from output: AVAssetReaderOutput) -> CMSampleBuffer? {
            while let sample = output.copyNextSampleBuffer() {
                let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                guard t.isFinite, !inCut(t) else { continue }
                return sample
            }
            return nil
        }

        /// 离线无丢帧：轮询到受理再追加（取消感知、writer 失败即抛——不吞错误空转）。
        /// 看门狗主体在 `waitForInputReady`（R1 F2 有界等待；timeout/poll 测试缝
        /// 单一事实源，生产默认 30s / 5ms）。
        func waitForReady(_ input: AVAssetWriterInput, mediaType: String) async throws {
            try await OfflineZoomRenderer.waitForInputReady(
                mediaType: mediaType,
                isReady: { input.isReadyForMoreMediaData },
                writerStatus: { writer.status },
                writerError: { writer.error })
        }

        /// 输出像素缓冲（逐帧直建——离线非热路径，池化优化归真机验收注记）。
        func makeOutputBuffer() throws -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault, outputWidth, outputHeight,
                kCVPixelFormatType_32BGRA, nil, &buffer)
            guard status == kCVReturnSuccess, let buffer else {
                throw RenderError.cannotCreateOutputBuffer
            }
            return buffer
        }

        var lastKeptTick: Int?
        var videoDone = false
        var audioDone = audioOutput == nil
        do {
            guard reader.startReading() else {
                throw RenderError.readerFailed(status: reader.status, underlying: reader.error)
            }
            // 拉首个**存活** PCM 样本装配 AAC 输入（writer 尚未 startWriting——装配窗口
            // 合法；剪除段内的样本跳过——剪辑 v1）
            if let audioOutput, let first = firstKeptSample(from: audioOutput) {
                guard let description = CMSampleBufferGetFormatDescription(first),
                      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
                else { throw RenderError.cannotAddAudioInput }
                let channels = Int(asbd.mChannelsPerFrame)
                let input = AVAssetWriterInput(
                    mediaType: .audio,
                    outputSettings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: asbd.mSampleRate,
                        AVNumberOfChannelsKey: channels,
                        AVEncoderBitRateKey: channels >= 2 ? 128_000 : 96_000,
                        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                    ],
                    sourceFormatHint: description)
                input.expectsMediaDataInRealTime = true
                guard writer.canAdd(input) else { throw RenderError.cannotAddAudioInput }
                writer.add(input)
                audioInput = input
                pendingAudioSample = first
            }
            // 视频首样本装配期拉取（存活样本；锚点取双轨折叠后最小 PTS）
            if let first = firstKeptSample(from: videoOutput) {
                pendingVideoSample = first
            }

            // 会话锚点 = 双轨首存活样本**折叠后** PTS 的最小值（剪辑 v1 改口径——锚点
            // 与 appends 同一折叠缝，「早于锚点兜底跳过」语义不变）；双轨均无存活样本
            //（全片被剪/损坏源）→ R1 F3 防线抛类型化错误，不触达未启动会话的
            // finishWriting
            let videoFirst = pendingVideoSample.map {
                outputPTS(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp($0)))
            }
            let audioFirst = pendingAudioSample.map {
                outputPTS(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp($0)))
            }
            switch (videoFirst, audioFirst) {
            case let (v?, a?):
                sessionAnchor = CMTimeCompare(v, a) <= 0 ? v : a
            case let (v?, nil):
                sessionAnchor = v
            case let (nil, a?):
                sessionAnchor = a
            default:
                throw RenderError.noRenderableSamples
            }
            writer.startWriting()
            writer.startSession(atSourceTime: sessionAnchor)

            // 双轨首样本按折叠后 PTS 序入轨（均 ≥ 锚点）
            switch (pendingVideoSample, pendingAudioSample) {
            case let (v?, a?):
                if CMTimeCompare(
                    outputPTS(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(v))),
                    outputPTS(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(a)))) <= 0 {
                    try await appendVideo(v)
                    try await appendAudio(a)
                } else {
                    try await appendAudio(a)
                    try await appendVideo(v)
                }
            case let (v?, nil):
                try await appendVideo(v)
            case let (nil, a?):
                try await appendAudio(a)
            default:
                break
            }
            pendingVideoSample = nil
            pendingAudioSample = nil

            while !videoDone || !audioDone {
                if Task.isCancelled { throw CancellationError() }

                if !videoDone {
                    if let sample = videoOutput.copyNextSampleBuffer() {
                        try await appendVideo(sample)
                    } else {
                        videoDone = true
                    }
                }
                if !audioDone, let audioOutput {
                    if let sample = audioOutput.copyNextSampleBuffer() {
                        try await appendAudio(sample)
                    } else {
                        audioDone = true
                    }
                }
            }
        } catch {
            reader.cancelReading()
            try? FileManager.default.removeItem(at: destinationURL) // 不留半截成片
            throw error
        }
        guard reader.status == .completed else {
            try? FileManager.default.removeItem(at: destinationURL)
            throw RenderError.readerFailed(status: reader.status, underlying: reader.error)
        }
        guard appendedVideoFrames > 0 else {
            // 零可解码视频帧防线（R1 F3）：视频轨在但一帧都解不出（无音轨的损坏源
            // 已在装配期锚点防线拦截；此处拦「音轨在、视频零帧」形态）——不产出
            // 无视频的半残成片
            try? FileManager.default.removeItem(at: destinationURL)
            throw RenderError.noRenderableSamples
        }

        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: destinationURL)
            throw RenderError.writerFailed(status: writer.status, underlying: writer.error)
        }
        push(1.0)
        return destinationURL

        // MARK: 逐帧处理（闭包内嵌，共享 reader/writer/时间线状态）

        func appendVideo(_ sample: CMSampleBuffer) async throws {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let t = CMTimeGetSeconds(pts)
            // 剪除段内的帧直接跳过（剪辑 v1 折叠——该帧不进输出）
            guard !inCut(t) else { return }
            // 早于会话锚点的病态样本兜底跳过（R1 F1——B 帧源解码序首个样本 PTS 未必
            // 最小；不给「早于会话起点的追加」留门。正常源零行为变化）
            let outPTS = outputPTS(t)
            guard CMTimeCompare(outPTS, sessionAnchor) >= 0 else { return }
            guard let sourceBuffer = CMSampleBufferGetImageBuffer(sample) else { return } // 无像素载荷：跳过

            // fps 档（nil/≤0 = 沿用源全帧）：按**源时间轴**等隔丢帧——同一 tick 只保留
            // 首帧，输出 PTS 折叠平移；首帧恒保留。
            if let fps = options.fps, fps > 0 {
                let tick = Int((t * Double(fps)).rounded(.down))
                if tick == lastKeptTick {
                    pushFrameProgress(t)
                    return
                }
                lastKeptTick = tick
            }

            // 缩放变换（与实时同一真源）：该时刻所在 segment 的进度 → contentTransform
            //（CI 画布空间 y 向上，bounds = 源可视尺寸——PiPCompositor 同口径）。
            let zoomTransform = timeline.first(where: { $0.start <= t && t < $0.end }).flatMap { segment in
                ZoomTransforms.contentTransform(
                    center: segment.center,
                    level: CGFloat(segment.level),
                    progress: zoomProgress(for: segment, at: t),
                    in: CGRect(origin: .zero, size: orientedSize))
            }
            let total = orientedTransform
                .concatenating(zoomTransform ?? .identity)
                .concatenating(canvasScale)

            let outputBuffer: CVPixelBuffer
            if total == .identity {
                outputBuffer = sourceBuffer // 无缩放且画布同尺寸：零渲染直通（同 PiPCompositor 全缺省直返）
            } else {
                let rendered = try makeOutputBuffer()
                context.render(CIImage(cvPixelBuffer: sourceBuffer).transformed(by: total), to: rendered)
                outputBuffer = rendered
            }

            try await waitForReady(videoInput, mediaType: "视频")
            guard adaptor.append(outputBuffer, withPresentationTime: outPTS) else {
                throw RenderError.appendFailedVideo(underlying: writer.error)
            }
            appendedVideoFrames += 1
            pushFrameProgress(t)
        }

        func appendAudio(_ sample: CMSampleBuffer) async throws {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let t = CMTimeGetSeconds(pts)
            // 剪除段内的样本直接跳过（剪辑 v1 折叠——音轨跟随视频同缝剪除）
            guard !inCut(t) else { return }
            let outPTS = outputPTS(t)
            guard CMTimeCompare(outPTS, sessionAnchor) >= 0 else { return } // 同 appendVideo 兜底
            guard let input = audioInput else { throw RenderError.cannotAddAudioInput }
            try await waitForReady(input, mediaType: "音频")
            // PTS 折叠平移（保留原 duration/decodeTime，仅换 presentationTimeStamp）；
            // 重写失败转类型化错误（正常源不可达）。
            guard let remapped = OfflineZoomRenderer.sampleBuffer(sample, withPresentationTime: outPTS) else {
                throw RenderError.appendFailedAudio(underlying: writer.error)
            }
            guard input.append(remapped) else {
                throw RenderError.appendFailedAudio(underlying: writer.error)
            }
        }

        func pushFrameProgress(_ t: Double) {
            push(max(0, min(0.95, 0.95 * t / durationSeconds)))
        }
    }
}
