import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// GIF 导出参数（P8）。档位外钳制到默认档：frameRate ∉ {5, 10, 15} → 10；
/// maxWidth ∉ {480, 720, nil(不缩放)} → 720（与 frameRate 同规则——集合外一律归默认档）。
/// 钳制仅发生在构造时（`var` 无 didSet——构造后直赋属性不设防；brief 钉 `var`，API 不变）。
struct GIFExportOptions: Equatable {
    var frameRate: Int
    var maxWidth: Int?
    var loops: Bool

    init(frameRate: Int = 10, maxWidth: Int? = 720, loops: Bool = true) {
        self.frameRate = Self.clampedFrameRate(frameRate)
        self.maxWidth = Self.clampedMaxWidth(maxWidth)
        self.loops = loops
    }

    private static func clampedFrameRate(_ value: Int) -> Int {
        [5, 10, 15].contains(value) ? value : 10
    }

    private static func clampedMaxWidth(_ value: Int?) -> Int? {
        guard let value else { return nil }
        return value == 480 || value == 720 ? value : 720
    }
}

/// 压缩预设（P8）：编码器 + 最大高度档。缺省「源分辨率 HEVC 高效重编码」（brief 钉定）。
/// maxHeight ∉ {nil(源), 1080, 720} 就近归档（< 900 → 720，否则 → 1080；nil 保留）——
/// 钳制仅发生在构造时（`var` 无 didSet，构造后直赋属性不设防）；UI Picker 只出合法档。
struct CompressionPreset: Equatable {
    var codec: VideoCodec
    var maxHeight: Int?

    init(codec: VideoCodec = .hevc, maxHeight: Int? = nil) {
        self.codec = codec
        self.maxHeight = Self.clampedMaxHeight(maxHeight)
    }

    private static func clampedMaxHeight(_ value: Int?) -> Int? {
        guard let value else { return nil }
        switch value {
        case 720, 1080:
            return value
        default:
            return value < 900 ? 720 : 1080
        }
    }

    /// 源分辨率 HEVC 高效重编码（缺省预设）。
    static let hevcSource = CompressionPreset(codec: .hevc, maxHeight: nil)
    static let hevc1080p = CompressionPreset(codec: .hevc, maxHeight: 1080)
    static let hevc720p = CompressionPreset(codec: .hevc, maxHeight: 720)
}

/// `compress` 的装配参数（代码级钉测点——真实转码归批次真机验收）：
/// - `presetName`：HEVC/H.264 最高质量档（画质优先，「源码率高效重编码」）；
/// - `renderSize`：缩放目标（nil = 源分辨率直通、不设 videoComposition）。
/// macOS SDK 的 HEVC 维度预设只有 1080p 起（无 720 档），故缩放统一走
/// `videoComposition.renderSize` 路径而非维度预设——单一代码路径，720/1080 两档行为一致。
struct CompressionPlan: Equatable {
    let presetName: String
    let renderSize: CGSize?
}

/// 导出失败的可呈现错误（T16 以通知呈现——文案简体中文，全局约束）。
enum ExportError: LocalizedError {
    /// 源不含可抽帧内容（时长 ≤ 0）。
    case emptySource
    /// 压缩预设与源不兼容（AVAssetExportSession 拒绝装配）。
    case incompatiblePreset(String)
    /// GIF 编码失败（ImageIO destination 装配/收尾失败——`gifData` 以空 Data 表现）。
    case gifEncodingFailed

    var errorDescription: String? {
        switch self {
        case .emptySource:
            return "导出失败：源文件没有可用的视频内容"
        case .incompatiblePreset(let presetName):
            return "导出失败：压缩预设与源不兼容（\(presetName)）"
        case .gifEncodingFailed:
            return "导出失败：GIF 编码失败，请重试"
        }
    }
}

/// 导出核心（P8）：GIF 编码纯函数 + 真实转码编排。
/// - `gifData` 无头纯函数：均匀抽帧（窗口语义见 `samplePlan` 注释，与
///   ExportCoreTests 类注释共同钉定）→ 缩放至 maxWidth → CGImageDestination GIF
///   （逐帧延时 + loop 属性）；
/// - `exportGIF`：AVAssetImageGenerator 精确抽帧（零容差）复用 `gifData` 落盘；
/// - `compress`：AVAssetExportSession 按预设导出 MP4；
/// - 输出落源文件同目录，命名 `<原名>_gif.gif` / `<原名>_压缩.mp4`，同名冲突沿用
///   `RecordingFileStore.nextFileURL` 同款惯例（扩展名前追加 " (n)" 自 2 递增）。
/// 进度回调契约：0…1，单调到顶恰一次 1.0，主线程外调用（UI 侧自行 hop——T16 消费契约）。
/// 真实转码链路（精确抽帧质量/导出成功率/输出可播性）归批次真机验收。
enum ExportCore {
    // MARK: - GIF 编码（纯函数）

    /// 帧序列 → GIF Data。抽帧窗口语义（`samplePlan`）；`maxWidth` 只降不升；GIF 每帧
    /// 延时 = 1/目标帧率；`loops = true` 写 NETSCAPE2.0 循环块（LoopCount 0 = 无限
    /// 循环），false 不写循环块（播一遍即停）。空输入返回空 Data。
    static func gifData(fromFrames frames: [(image: CGImage, pts: CMTime)], options: GIFExportOptions) -> Data {
        let plan = samplePlan(for: frames, frameRate: options.frameRate)
        guard !plan.isEmpty else { return Data() }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.gif.identifier as CFString, plan.count, nil)
        else { return Data() }
        if options.loops {
            // 本工具链实测（2026-10-31，Xcode 26/macOS 27 SDK）：帧属性里的
            // LoopCount 不落盘；NETSCAPE2.0 循环块只在目标级 SetProperties 的
            // GIF dict 生效。0 = 无限循环；不调用 → 无循环块（播一遍即停）。
            CGImageDestinationSetProperties(
                destination,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        }

        let delay = 1.0 / Double(options.frameRate)
        for (index, sourceIndex) in plan.enumerated() {
            var gifProperties: [CFString: Any] = [kCGImagePropertyGIFDelayTime: delay]
            if index == 0, options.loops {
                gifProperties[kCGImagePropertyGIFLoopCount] = 0
            }
            let image = scaledImage(frames[sourceIndex].image, maxPixelWidth: options.maxWidth)
            CGImageDestinationAddImage(
                destination, image,
                [kCGImagePropertyGIFDictionary: gifProperties] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { return Data() }
        return data as Data
    }

    /// 采样计划（返回源帧索引序列）。前置条件：frames 按 pts 升序（真实抽帧序列天然
    /// 满足——下方指针单调推进依赖此序）。窗口语义：
    /// - 窗 = `[首帧 pts, 尾帧 pts + 源帧步长)`，源帧步长 = 相邻 pts 最小正差（单帧回退
    ///   `1/目标帧率`）——窗端含首不含尾，30fps 整 1s 源在窗内容纳整数个目标帧周期；
    /// - 样本时刻 = 首 pts + `n/目标帧率`（CMTime 整数有理数，零浮点噪声），n = 0..<N，
    ///   N = `max(1, ceil(窗长 × 目标帧率 − 1e-4))`（1e-4 吸浮点抖动，真整数不虚胖）；
    /// - 每样本取「pts ≤ 样本时刻的最大 pts」源帧（hold-last 无插值），首帧必含；
    /// - 样本单调 ⇒ 源帧指针单调推进不回溯（O(n)）；
    /// - 升档场景连续样本映射同一源帧时不去重——GIF 每帧自带延时，重复帧保节拍。
    static func samplePlan(for frames: [(image: CGImage, pts: CMTime)], frameRate: Int) -> [Int] {
        guard !frames.isEmpty, frameRate > 0 else { return [] }
        guard frames.count > 1 else { return [0] }

        var frameStep: CMTime?
        for index in 1..<frames.count {
            let delta = CMTimeSubtract(frames[index].pts, frames[index - 1].pts)
            if CMTimeCompare(delta, .zero) > 0,
               frameStep == nil || CMTimeCompare(delta, frameStep!) < 0 {
                frameStep = delta
            }
        }
        let step = frameStep ?? CMTime(value: 1, timescale: CMTimeScale(frameRate))
        let window = CMTimeAdd(CMTimeSubtract(frames[frames.count - 1].pts, frames[0].pts), step)
        let raw = CMTimeGetSeconds(window) * Double(frameRate)
        guard raw.isFinite else { return [] }
        let count = max(1, Int(ceil(raw - 1e-4)))

        var plan: [Int] = []
        plan.reserveCapacity(count)
        var cursor = 0
        for n in 0..<count {
            let target = CMTimeAdd(
                frames[0].pts, CMTime(value: CMTimeValue(n), timescale: CMTimeScale(frameRate)))
            while cursor + 1 < frames.count, CMTimeCompare(frames[cursor + 1].pts, target) <= 0 {
                cursor += 1
            }
            plan.append(cursor)
        }
        return plan
    }

    /// 缩放至 maxWidth（只降不升，高按比例取整）。上下文创建失败原样返回（GIF 编码
    /// 仍以原尺寸进行——缩放是优化不是正确性前提）。
    static func scaledImage(_ image: CGImage, maxPixelWidth: Int?) -> CGImage {
        guard let maxPixelWidth, maxPixelWidth > 0, image.width > maxPixelWidth else { return image }
        let scaledHeight = max(
            1, Int((CGFloat(image.height) * CGFloat(maxPixelWidth) / CGFloat(image.width)).rounded()))
        guard let context = CGContext(
            data: nil, width: maxPixelWidth, height: scaledHeight, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: maxPixelWidth, height: scaledHeight))
        return context.makeImage() ?? image
    }

    // MARK: - 真实转码编排

    /// 录像文件 → GIF。AVAssetImageGenerator 零容差精确抽帧（目标时刻即采样时刻，
    /// 确定性；长片性能归真机验收清单），复用 `gifData` 编码落盘。
    /// 进度：抽帧阶段 0…0.95（首回调 0），落盘完成恰一次 1.0。
    static func exportGIF(
        from url: URL, options: GIFExportOptions, progress: @escaping (Double) -> Void
    ) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let times = sampleTimes(duration: duration, frameRate: options.frameRate)
        guard !times.isEmpty else { throw ExportError.emptySource }
        progress(0)

        var frames: [(image: CGImage, pts: CMTime)] = []
        frames.reserveCapacity(times.count)
        for (index, time) in times.enumerated() {
            let extracted = try await generator.image(at: time)
            frames.append((extracted.image, time))
            progress(Double(index + 1) / Double(times.count) * 0.95)
        }

        let data = gifData(fromFrames: frames, options: options)
        // gifData 的 ImageIO 装配/收尾失败以空 Data 表现（纯函数签名不抛）——空 GIF
        // 拒绝落盘（R1）：不得以成功 URL + 进度 1.0 静默交付 0 字节文件。触发路径
        // （ImageIO 失败）无头不可确定性构造——守卫在位，归真机验收观察。
        guard !data.isEmpty else { throw ExportError.gifEncodingFailed }
        let outputURL = gifDestinationURL(for: url)
        try data.write(to: outputURL, options: [.atomic])
        progress(1.0)
        return outputURL
    }

    /// 均匀采样时刻：`n/帧率`（整数有理数，零浮点噪声），n = 0..<N，
    /// N = `max(1, ceil(时长 × 帧率 − 1e-4))`；时长 ≤ 0 返回空（上层抛 emptySource）。
    private static func sampleTimes(duration: CMTime, frameRate: Int) -> [CMTime] {
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { return [] }
        let count = max(1, Int(ceil(seconds * Double(frameRate) - 1e-4)))
        return (0..<count).map { CMTime(value: CMTimeValue($0), timescale: CMTimeScale(frameRate)) }
    }

    /// 进度去重包装：仅转发严格递增的值（0…1 单调不减、无重复推）。
    /// `compress` 的轮询器与显式推并发——轮询器可能在 export 返回前读到 1.0（与显式
    /// 终值双推）、或在首拍读到 0.0（与显式首拍重合）；去重后终值 1.0 恰推一次
    /// （轮询器抢先则显式推等值被吞）。NSLock：轮询器（协作池）与 async 主体并发调用。
    static func deduplicatedProgress(_ progress: @escaping (Double) -> Void) -> (Double) -> Void {
        let lock = NSLock()
        var lastPushed = -1.0
        return { newValue in
            lock.lock()
            guard newValue > lastPushed else {
                lock.unlock()
                return
            }
            lastPushed = newValue
            lock.unlock()
            progress(newValue)
        }
    }

    /// 录像文件 → 压缩 MP4。装配按 `compressionPlan`：最高质量预设 + 需要时
    /// `AVMutableVideoComposition.renderSize` 等比缩放（propertiesOf 旋转向自动处理）。
    /// 进度以 100ms 轮询 `session.progress` 推送，经 `deduplicatedProgress` 去重
    ///（0…1 单调不减、终值恰一次 1.0）。
    static func compress(
        from url: URL, preset: CompressionPreset, progress: @escaping (Double) -> Void
    ) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else { throw ExportError.emptySource }
        let naturalSize = try await videoTrack.load(.naturalSize)

        let plan = compressionPlan(for: preset, sourceSize: naturalSize)
        guard let session = AVAssetExportSession(asset: asset, presetName: plan.presetName)
        else { throw ExportError.incompatiblePreset(plan.presetName) }
        if let renderSize = plan.renderSize {
            let composition = AVMutableVideoComposition(propertiesOf: asset)
            composition.renderSize = renderSize
            session.videoComposition = composition
        }

        let outputURL = compressedDestinationURL(for: url)
        let push = deduplicatedProgress(progress)
        push(0)
        let poller = Task(priority: .userInitiated) {
            while !Task.isCancelled {
                push(Double(session.progress))
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        defer { poller.cancel() }
        try await session.export(to: outputURL, as: .mp4)
        push(1.0)
        return outputURL
    }

    /// 压缩装配：最高质量预设名 + 按源尺寸算出的 renderSize（`scaledRenderSize`）。
    static func compressionPlan(for preset: CompressionPreset, sourceSize: CGSize) -> CompressionPlan {
        let presetName: String
        switch preset.codec {
        case .hevc:
            presetName = AVAssetExportPresetHEVCHighestQuality
        case .h264:
            presetName = AVAssetExportPresetHighestQuality
        }
        return CompressionPlan(
            presetName: presetName,
            renderSize: scaledRenderSize(sourceSize: sourceSize, maxHeight: preset.maxHeight))
    }

    /// maxHeight 等比缩放目标（只降不升；宽高取偶——视频编码器普遍偶数尺寸约束，
    /// maxHeight 钳制后 ∈ {720, 1080} 本身即偶）。源高 ≤ maxHeight → nil（直通不放大）。
    static func scaledRenderSize(sourceSize: CGSize, maxHeight: Int?) -> CGSize? {
        guard let maxHeight, maxHeight > 0, sourceSize.height > CGFloat(maxHeight) else { return nil }
        let scale = CGFloat(maxHeight) / sourceSize.height
        func even(_ value: CGFloat) -> CGFloat {
            CGFloat((value.rounded() / 2).rounded(.down) * 2)
        }
        return CGSize(
            width: max(2, even(sourceSize.width * scale)),
            height: CGFloat(maxHeight))
    }

    // MARK: - 输出命名（nextFileURL 冲突惯例）

    /// GIF 输出 URL：源同目录 `<原名>_gif.gif`，冲突追加 " (n)"。
    static func gifDestinationURL(for sourceURL: URL) -> URL {
        conflictFreeURL(for: destinationURL(sourceURL, suffix: "_gif", ext: "gif"))
    }

    /// 压缩输出 URL：源同目录 `<原名>_压缩.mp4`，冲突追加 " (n)"。
    static func compressedDestinationURL(for sourceURL: URL) -> URL {
        conflictFreeURL(for: destinationURL(sourceURL, suffix: "_压缩", ext: "mp4"))
    }

    private static func destinationURL(_ sourceURL: URL, suffix: String, ext: String) -> URL {
        sourceURL.deletingLastPathComponent().appendingPathComponent(
            "\(sourceURL.deletingPathExtension().lastPathComponent)\(suffix).\(ext)")
    }

    /// `RecordingFileStore.nextFileURL` 同款冲突惯例：目标存在 → 扩展名前追加
    /// " (n)"（n 自 2 递增）取首个不存在的候选；不创建文件。
    private static func conflictFreeURL(for target: URL) -> URL {
        let stem = target.deletingPathExtension().lastPathComponent
        let ext = target.pathExtension
        let directory = target.deletingLastPathComponent()
        var candidate = target
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem) (\(counter)).\(ext)")
            counter += 1
        }
        return candidate
    }
}
