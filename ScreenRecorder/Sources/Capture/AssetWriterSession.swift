import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// AVAssetWriter 落盘会话：视频走 `AVAssetWriterInputPixelBufferAdaptor`，
/// 音频走直通（`outputSettings = nil` + 由 `AVAudioFormat` 构造的格式提示，写入样本必须与之一致），
/// 输出 MP4。生命周期：init（排他创建输出文件）→ addVideoInput / addAudioInput → startWriting
/// → appendVideo / appendAudio（首个到轨样本自动 startSession 锚定时间轴）→ finish。
///
/// 不覆盖既有录像（硬约束）：init 用 `open(O_CREAT | O_EXCL)` 原子占位目标路径，
/// 与任何并发创建者竞争时必有一方失败——失败方抛 `outputAlreadyExists`。
/// 从机制上排除「AVAssetWriter 静默截断覆盖既有录像」的路径；占位后未写入任何样本即放弃的，
/// 由 `discardIfNoContent()` / `finish()` 删除空壳文件。
///
/// 线程模型：append* 在采集回调队列调用（热路径），finish / 只读属性可在任意线程；
/// 所有 `AVAssetWriter` 触碰经 `stateLock` 串行化（每帧一次锁，开销可忽略）。
/// 单次生命周期：finish 只应调用一次，重复行为未定义。
final class AssetWriterSession {
    enum AssetWriterSessionError: LocalizedError {
        case outputAlreadyExists(URL)
        case cannotCreateOutputFile(path: String, errno: Int32)
        case cannotCreateWriter(underlying: Error)
        case cannotAddVideoInput
        case cannotAddAudioInput
        case cannotMakeAudioFormatHint(OSStatus)
        case noVideoInput
        case noAudioInput
        case writerNotWriting(status: AVAssetWriter.Status)
        case appendFailedVideo(underlying: Error?)
        case appendFailedAudio(underlying: Error?)
        case nothingWritten
        case finishFailed(status: AVAssetWriter.Status, underlying: Error?)

        var errorDescription: String? {
            switch self {
            case .outputAlreadyExists(let url):
                return "输出文件已存在，拒绝覆盖：\(url.path)"
            case .cannotCreateOutputFile(let path, let errnoCode):
                return "无法排他创建输出文件 \(path)（errno=\(errnoCode)，目录未创建？）"
            case .cannotCreateWriter(let underlying):
                return "AVAssetWriter 创建失败：\(underlying)"
            case .cannotAddVideoInput:
                return "AVAssetWriter 拒绝添加视频输入"
            case .cannotAddAudioInput:
                return "AVAssetWriter 拒绝添加音频输入"
            case .cannotMakeAudioFormatHint(let status):
                return "构造音频格式提示失败（status=\(status)）"
            case .noVideoInput:
                return "视频输入未装配（appendVideo 早于 addVideoInput/startWriting）"
            case .noAudioInput:
                return "音频输入未装配（appendAudio 早于 addAudioInput）"
            case .writerNotWriting(let status):
                return "AVAssetWriter 不在写入状态（status=\(status.rawValue)）"
            case .appendFailedVideo(let underlying):
                return "视频帧写入失败：\(underlying.map(String.init(describing:)) ?? "未知原因")"
            case .appendFailedAudio(let underlying):
                return "音频样本写入失败：\(underlying.map(String.init(describing:)) ?? "未知原因")"
            case .nothingWritten:
                return "本次录制未写入任何样本，无成片"
            case .finishFailed(let status, let underlying):
                return "收尾失败（status=\(status.rawValue)）：\(underlying.map(String.init(describing:)) ?? "未知原因")"
            }
        }
    }

    /// 输出文件 URL（init 时已排他占位）。
    let outputURL: URL

    /// 会话时间轴锚点：首个到轨样本的 PTS（即 startSession 的 atSourceTime）。
    /// 合成管线取起始时间戳用；未锚定时为 `.invalid`。
    var isReadyForVideoMediaTime: CMTime {
        stateLock.withStateLock { anchor }
    }

    /// 因编码器未就绪而丢弃的视频帧数（实时录制语义：宁丢帧不阻塞采集队列）。
    private(set) var droppedVideoFrameCount = 0

    private let pixelSize: CGSize
    private let codec: SettingsStore.VideoCodec
    private let writer: AVAssetWriter
    private var videoInput: AVAssetWriterInput?
    private var videoAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?
    private var didStartWriting = false
    private var sessionStarted = false
    private var wroteAnySamples = false
    private var anchor: CMTime = .invalid
    private let stateLock = NSLock()

    /// 排他创建输出文件并装配 writer；目标路径已存在时抛
    /// `outputAlreadyExists`（绝不覆盖既有录像）。目录须由调用方先行创建
    ///（全代码库唯一创建点是 `RecordingFileStore.ensureDirectory`）。
    init(config: RecordingConfiguration, pixelSize: CGSize) throws {
        self.pixelSize = pixelSize
        self.codec = config.codec
        self.outputURL = config.outputURL

        let fd = open(config.outputURL.path, O_CREAT | O_EXCL, 0o644)
        guard fd != -1 else {
            if errno == EEXIST {
                throw AssetWriterSessionError.outputAlreadyExists(config.outputURL)
            }
            throw AssetWriterSessionError.cannotCreateOutputFile(path: config.outputURL.path, errno: errno)
        }
        close(fd)

        do {
            writer = try AVAssetWriter(url: config.outputURL, fileType: .mp4)
        } catch {
            try? FileManager.default.removeItem(at: config.outputURL) // 清掉自家占位空壳
            throw AssetWriterSessionError.cannotCreateWriter(underlying: error)
        }
    }

    // MARK: - 输入装配

    /// 添加视频输入。`sourceFormatHint` 建议传首帧的格式描述，让 encoder 按源精确装配；
    /// 传 nil 时仅按 pixelSize 声明的 settings 装配。重复调用幂等（首次生效）。
    /// 必须在 `startWriting()` 之前调用。
    func addVideoInput(with sourceFormatHint: CMVideoFormatDescription?) throws {
        try stateLock.withStateLock {
            guard videoInput == nil else { return }
            let settings: [String: Any] = [
                AVVideoCodecKey: codec.avCodecKey,
                AVVideoWidthKey: Int(pixelSize.width),
                AVVideoHeightKey: Int(pixelSize.height),
            ]
            let input: AVAssetWriterInput
            if let hint = sourceFormatHint {
                input = AVAssetWriterInput(mediaType: .video, outputSettings: settings, sourceFormatHint: hint)
            } else {
                input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            }
            input.expectsMediaDataInRealTime = true // 屏幕帧按显示节奏到达，允许时间戳抖动
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: Int(pixelSize.width),
                    kCVPixelBufferHeightKey as String: Int(pixelSize.height),
                ]
            )
            guard writer.canAdd(input) else { throw AssetWriterSessionError.cannotAddVideoInput }
            writer.add(input)
            videoInput = input
            videoAdaptor = adaptor
        }
    }

    /// 添加音频输入（直通：outputSettings 为 nil 时必须提供格式提示）。
    /// `format` 应与后续 appendAudio 的样本格式一致（系统声音管线的 masterFormat 由此登记）。
    /// 重复调用幂等（首次生效）。必须在 `startWriting()` 之前调用。
    func addAudioInput(with format: AVAudioFormat) throws {
        try stateLock.withStateLock {
            guard audioInput == nil else { return }
            var hintOut: CMFormatDescription?
            let status = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: format.streamDescription,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &hintOut
            )
            guard status == noErr, let hint = hintOut else {
                throw AssetWriterSessionError.cannotMakeAudioFormatHint(status)
            }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw AssetWriterSessionError.cannotAddAudioInput }
            writer.add(input)
            audioInput = input
        }
    }

    /// 开始写会话（输入装配完成后、首个 append 前调用）；重复调用幂等。
    func startWriting() {
        stateLock.withStateLock {
            guard !didStartWriting else { return }
            didStartWriting = true
            writer.startWriting()
        }
    }

    // MARK: - 追加样本

    /// 追加一帧视频像素缓冲。首个 append 自动以该帧 PTS 锚定会话时间轴。
    /// 编码器未就绪时丢弃该帧（计入 `droppedVideoFrameCount`），不阻塞实时采集队列。
    func appendVideo(_ pixelBuffer: CVPixelBuffer, at pts: CMTime) throws {
        try stateLock.withStateLock {
            guard let input = videoInput, let adaptor = videoAdaptor else {
                throw AssetWriterSessionError.noVideoInput
            }
            guard writer.status == .writing else {
                throw AssetWriterSessionError.writerNotWriting(status: writer.status)
            }
            if !sessionStarted {
                writer.startSession(atSourceTime: pts)
                sessionStarted = true
                anchor = pts
            }
            guard input.isReadyForMoreMediaData else {
                droppedVideoFrameCount += 1
                return
            }
            if adaptor.append(pixelBuffer, withPresentationTime: pts) {
                wroteAnySamples = true
            } else {
                throw AssetWriterSessionError.appendFailedVideo(underlying: writer.error)
            }
        }
    }

    /// 追加一段音频样本（CMSampleBuffer 直通）。同样参与自动锚定（首个到轨样本定锚）；
    /// 后到轨样本若 PTS 早于锚点会被 writer 拒绝并抛错——音画起点对齐由上层管线保证。
    /// 编码器未就绪时丢弃该样本（表现为瞬时静音缺口）。
    func appendAudio(_ sampleBuffer: CMSampleBuffer) throws {
        try stateLock.withStateLock {
            guard let input = audioInput else {
                throw AssetWriterSessionError.noAudioInput
            }
            guard writer.status == .writing else {
                throw AssetWriterSessionError.writerNotWriting(status: writer.status)
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if !sessionStarted {
                writer.startSession(atSourceTime: pts)
                sessionStarted = true
                anchor = pts
            }
            guard input.isReadyForMoreMediaData else { return } // 丢样本
            if input.append(sampleBuffer) {
                wroteAnySamples = true
            } else {
                throw AssetWriterSessionError.appendFailedAudio(underlying: writer.error)
            }
        }
    }

    // MARK: - 收尾

    /// 收尾成片：等待各输入就绪（有界 2s）→ markAsFinished → finishWriting → 校验产物状态。
    /// 从未写入任何样本时删除排他占位文件并抛 `nothingWritten`（目录不留空壳）。
    func finish() async throws -> URL {
        let inputs: [AVAssetWriterInput] = try stateLock.withStateLock {
            guard didStartWriting, wroteAnySamples else {
                try? FileManager.default.removeItem(at: outputURL)
                throw AssetWriterSessionError.nothingWritten
            }
            return [videoInput, audioInput].compactMap { $0 }
        }
        for input in inputs {
            // 实时追加此刻已停止（上层先停采集再收尾），输入通常即刻就绪；
            // 有界等待防 writer 内部拥塞挂死，超时仍 markAsFinished（宁可略截断不可挂起）。
            var waited = 0
            while !input.isReadyForMoreMediaData && waited < 200 {
                Thread.sleep(forTimeInterval: 0.01)
                waited += 1
            }
            input.markAsFinished()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw AssetWriterSessionError.finishFailed(status: writer.status, underlying: writer.error)
        }
        return outputURL
    }

    /// 放弃从未开始写入的会话：删除排他占位文件。已 startWriting 时静默 no-op
    ///（有内容的会话不可弃，收尾走 `finish()`）。
    func discardIfNoContent() {
        stateLock.withStateLock {
            guard !didStartWriting else { return }
            try? FileManager.default.removeItem(at: outputURL)
        }
    }
}

/// 模块内共用的锁封装（AssetWriterSession 与 SCStreamRecorder 都用）。
extension NSLock {
    /// 锁内执行同步闭包（与 Foundation 的 `withLock` 同语义的自有封装，
    /// 不依赖具体 SDK 版本的可用性）。闭包内禁止 await。
    func withStateLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
