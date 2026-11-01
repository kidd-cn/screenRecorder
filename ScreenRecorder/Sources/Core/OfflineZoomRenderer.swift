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

        var errorDescription: String? {
            switch self {
            case .cannotAddVideoInput:
                return "缩放导出失败：编码器视频输入装配被拒绝"
            case .cannotAddAudioInput:
                return "缩放导出失败：音频输入装配被拒绝"
            case .readerFailed(let status, let underlying):
                return "缩放导出失败：读取源失败（status=\(status.rawValue)）：\(underlying.map(String.init(describing:)) ?? "无底层错误")"
            case .writerFailed(let status, let underlying):
                return "缩放导出失败：写入成片失败（status=\(status.rawValue)）：\(underlying.map(String.init(describing:)) ?? "无底层错误")"
            case .appendFailedVideo(let underlying):
                return "缩放导出失败：视频帧写入失败：\(underlying.map(String.init(describing:)) ?? "未知原因")"
            case .appendFailedAudio(let underlying):
                return "缩放导出失败：音频样本写入失败：\(underlying.map(String.init(describing:)) ?? "未知原因")"
            case .cannotCreateOutputBuffer:
                return "缩放导出失败：无法创建输出像素缓冲"
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
    /// （`RecordingFileStore.nextFileURL` 同款惯例；不创建文件）。
    static func zoomedDestinationURL(for sourceURL: URL) -> URL {
        let target = sourceURL.deletingLastPathComponent().appendingPathComponent(
            "\(sourceURL.deletingPathExtension().lastPathComponent)_缩放.mp4")
        let stem = target.deletingPathExtension().lastPathComponent
        let directory = target.deletingLastPathComponent()
        var candidate = target
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem) (\(counter)).mp4")
            counter += 1
        }
        return candidate
    }

    // MARK: - 渲染

    /// 录像 → 缩放成片 MP4。`segments` 先经 `ZoomSegment.validate` 规整（排序/钳制/
    /// 去重叠）；空段表 = 全程恒等直通转码。`context` 供 headless 测试注入软件渲染
    /// 上下文（缺省 GPU——与实时 PiPCompositor 同口径）。
    static func render(sourceURL: URL, segments: [ZoomSegment], options: ExportVideoOptions,
                       progress: @escaping (Double) -> Void,
                       context: CIContext = CIContext(options: [.useSoftwareRenderer: false])) async throws -> URL {
        let timeline = ZoomSegment.validate(segments)
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

        // writer（不 claim；冲突惯例命名保证目标不存在）
        let destinationURL = zoomedDestinationURL(for: sourceURL)
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
        var sessionStarted = false
        // 首个到轨样本锚定会话时间轴（AssetWriterSession 同款纪律——音画起点一致）
        func startSessionIfNeeded(at pts: CMTime) {
            guard !sessionStarted else { return }
            writer.startWriting()
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
        }

        // 音频输入须在 startWriting 前装配（AVAssetWriter 硬约束）——首个 PCM 样本
        // 在 reader.startReading 后拉取取解码格式建 AAC 输入（copyNextSampleBuffer
        // 须待 reader 进入 reading；该样本暂存，循环内首个追加）。音轨存在但零样本
        // 时 audioInput 保持 nil：循环内音轨侧拉到 nil 即收尾，按纯视频装配。
        var audioInput: AVAssetWriterInput?
        var pendingAudioSample: CMSampleBuffer?

        /// 离线无丢帧：轮询到受理再追加（取消感知、writer 失败即抛——不吞错误空转）。
        func waitForReady(_ input: AVAssetWriterInput) async throws {
            while !input.isReadyForMoreMediaData {
                if Task.isCancelled { throw CancellationError() }
                guard writer.status != .failed else {
                    throw RenderError.writerFailed(status: writer.status, underlying: writer.error)
                }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
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
            // 拉首个 PCM 样本装配 AAC 输入（writer 尚未 startWriting——装配窗口合法）
            if let audioOutput, let first = audioOutput.copyNextSampleBuffer() {
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

            while !videoDone || !audioDone {
                if Task.isCancelled { throw CancellationError() }

                // 暂存的首个音频样本先行入轨（其格式已建好 audioInput）
                if let pending = pendingAudioSample {
                    pendingAudioSample = nil
                    try await appendAudio(pending)
                }

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
            guard let sourceBuffer = CMSampleBufferGetImageBuffer(sample) else { return } // 无像素载荷：跳过
            let t = CMTimeGetSeconds(pts)

            // fps 档（nil/≤0 = 沿用源全帧）：按源时间轴等隔丢帧——同一 tick 只保留
            // 首帧，PTS 原样，时长不动；首帧恒保留。
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

            startSessionIfNeeded(at: pts)
            try await waitForReady(videoInput)
            guard adaptor.append(outputBuffer, withPresentationTime: pts) else {
                throw RenderError.appendFailedVideo(underlying: writer.error)
            }
            pushFrameProgress(t)
        }

        func appendAudio(_ sample: CMSampleBuffer) async throws {
            guard let input = audioInput else { throw RenderError.cannotAddAudioInput }
            startSessionIfNeeded(at: CMSampleBufferGetPresentationTimeStamp(sample))
            try await waitForReady(input)
            guard input.append(sample) else {
                throw RenderError.appendFailedAudio(underlying: writer.error)
            }
        }

        func pushFrameProgress(_ t: Double) {
            push(max(0, min(0.95, 0.95 * t / durationSeconds)))
        }
    }
}
