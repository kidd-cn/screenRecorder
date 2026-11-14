import AppKit
import CoreImage
import ScreenCaptureKit

/// 单帧抓取（ScreenCaptureKit，2026-11-14 废弃 API 迁移）：替代 `CGDisplayCreateImage`
/// 与 `CGWindowListCreateImage`（均自 macOS 14 起弃用）。路径：
/// - macOS 14+：`SCScreenshotManager.captureImage`（一次调用出帧）。
/// - macOS 13：`SCStream` 起流取首帧后停流（首帧到达即返回；5 秒超时兜底）。
/// 返回像素尺寸由 `SCStreamConfiguration.width/height` 决定（调用方按需对齐比例尺）。
enum ScreenFrameCapture {
    enum CaptureError: LocalizedError {
        case timeout
        case streamFailed(String)

        var errorDescription: String? {
            switch self {
            case .timeout:
                return NSLocalizedString("取帧超时：5 秒内未收到画面", comment: "Frame capture timeout")
            case .streamFailed(let message):
                return String(
                    format: NSLocalizedString("取帧失败：%@", comment: "Frame capture failure"),
                    message)
            }
        }
    }

    /// 按过滤器 + 配置抓一帧。调用方负责构造 filter（显示器/窗口）。
    static func capture(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        if #available(macOS 14.0, *) {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration)
        }
        return try await firstFrameViaStream(filter: filter, configuration: configuration)
    }

    // MARK: - macOS 13 回退（SCStream 首帧）

    private static func firstFrameViaStream(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let output = FirstFrameOutput()
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        do {
            try await stream.startCapture()
        } catch {
            throw CaptureError.streamFailed(String(describing: error))
        }
        defer {
            Task { try? await stream.stopCapture() }
        }
        return try await withCheckedThrowingContinuation { continuation in
            output.attach(continuation)
            // 超时兜底：首帧始终不到（显示器睡眠/串流异常）时给出可诊断错误。
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                output.failIfPending(CaptureError.timeout)
            }
        }
    }

    /// 首帧收集器（SCStreamOutput 回调在专用串行队列）。
    private final class FirstFrameOutput: NSObject, SCStreamOutput, @unchecked Sendable {
        let queue = DispatchQueue(label: "hummingbird.frameCapture")
        private let lock = NSLock()
        private var continuation: CheckedContinuation<CGImage, Error>?
        private let ciContext = CIContext()

        func attach(_ continuation: CheckedContinuation<CGImage, Error>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }

        func failIfPending(_ error: Error) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(throwing: error)
        }

        func stream(
            _ stream: SCStream,
            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
            of outputType: SCStreamOutputType
        ) {
            guard outputType == .screen,
                  sampleBuffer.isValid,
                  let attachments = CMSampleBufferGetSampleAttachmentsArray(
                      sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let statusRaw = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: statusRaw) == .complete,
                  let pixelBuffer = sampleBuffer.imageBuffer
            else { return }
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: cgImage)
        }
    }
}
