import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// SCStream 采集 → `AssetWriterSession` 落盘的录制会话（Task 7 仅视频路径；
/// audio 样本在 Task 8 接 SystemAudioMixer 前直接丢弃）。
/// 生命周期：`start()`（解析目标 + 建流 + 开采集）→ video 队列首帧装配 writer 输入并
/// startWriting → 逐帧 append（Task 15 合成管线接管前直通）→ `stop()`（停流 + 收尾成片）。
///
/// 失败通道：append 失败与 `stream(_:didStopWithError:)` 经 `onStreamFailure`（主队列保证）
/// 上报，首次失败生效；上层收到后负责调用 `stop()` 完成安全收尾（本类不自动停流）。
/// `stop()` 后读 `finishedFileURL`（nil = 无成片）与 `lastError`（首个失败原因）。
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
    /// 仅 videoQueue 触碰：writer 输入是否已在首帧装配完毕。
    private var writerArmed = false

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
            }
            try await stream.startCapture()
        } catch {
            // 采集没跑起来：不会有任何帧到达，清理排他占位文件再上抛。
            session.discardIfNoContent()
            throw error
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
            // 先摘输出再停流：终止回调派发后再收尾 writer。
            try? stream.removeStreamOutput(self, type: .screen)
            if config.captureSystemAudio {
                try? stream.removeStreamOutput(self, type: .audio)
            }
            try? await stream.stopCapture()
        }
        let session: AssetWriterSession? = stateLock.withStateLock {
            let owned = self.writerSession
            self.writerSession = nil
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
            break // Task 8 前丢弃样本，之后送 SystemAudioMixer
        default:
            break // .microphone（macOS 15+）及未来新增类型：Task 9 接麦克风前一律丢弃
        }
    }

    /// video 队列串行执行：首帧装配 writer（addVideoInput + startWriting，需首帧格式描述），
    /// 之后逐帧直 append（Task 15 合成管线接管前的直通路径）。
    private func handleVideoSample(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let session: AssetWriterSession? = stateLock.withStateLock { writerSession }
        guard let session else { return } // stop() 已收走会话：丢弃尾部帧
        do {
            if !writerArmed {
                let formatHint = CMSampleBufferGetFormatDescription(sampleBuffer)
                try session.addVideoInput(with: formatHint)
                session.startWriting()
                writerArmed = true
            }
            try session.appendVideo(pixelBuffer, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
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
