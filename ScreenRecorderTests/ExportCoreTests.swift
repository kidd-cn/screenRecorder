import AVFoundation
import CoreGraphics
import CoreMedia
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import ScreenRecorder

/// ExportCore（P8 导出核心）无头钉测：`gifData` 纯函数（均匀抽帧/钳制/缩放/GIF 编码/
/// loop 属性）、输出命名冲突惯例（nextFileURL 同款 `名 (n)` 递增）、压缩预设枚举到
/// `CompressionPlan`（最高质量预设名 + videoComposition renderSize）的参数构造。
/// `exportGIF`/`compress` 的真实转码链路（AVAssetImageGenerator 精确抽帧/
/// AVAssetExportSession 导出/进度推送）无头不可确定性驱动，归批次真机验收（brief 钉定
/// 边界——代码级只钉参数构造与编排）。
///
/// **抽帧窗口语义**（`gifData` 采样计划，实现与测试共同钉定）：
/// - 窗 = `[首帧 pts, 尾帧 pts + 源帧步长)`，源帧步长 = 相邻 pts 最小正差（单帧回退
///   `1/目标帧率`）——窗端含首不含尾，30fps 整 1s 源在窗内恰好容纳整数个目标帧周期；
/// - 样本时刻 = 首 pts + `n/目标帧率`（CMTime 整数有理数，零浮点噪声），n = 0..<N，
///   N = `max(1, ceil(窗长 × 目标帧率 − 1e-4))`（1e-4 吸浮点抖动：真 10.0 不因
///   10.000000002 虚胖成 11）；
/// - 每样本取「pts ≤ 样本时刻的最大 pts」源帧（hold-last，无插值）——首帧必含；30fps
///   1s 源取 10fps 时末样本为 27/30（第 28/29 帧不入 GIF，窗端 1.0 处无样本）；
/// - 样本单调 ⇒ 源帧指针单调推进不回溯（O(n) 一遍扫）；
/// - 升档场景连续样本映射同一源帧时**不去重**——GIF 每帧自带延时，重复帧保节拍
///   （文件更大但时序忠实；UI 档位 {5,10,15} 对 30fps 源恒为降采样，非典型路径）；
/// - 空输入返回空 Data。
///
/// 夹具故障注释：CGContext/CGImageSource 创建失败是测试基础设施故障，必须 XCTUnwrap
/// 表现为失败，不得表现为 skipped（CameraOnlyRecorderTests 同纪律）。
final class ExportCoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        directory = nil
    }

    // MARK: - Helpers

    /// 纯色测试帧（颜色随 seed 变化，帧间可区分）。
    private func makeSolidColorImage(width: Int, height: Int, seed: Double) throws -> CGImage {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            "夹具 CGContext 创建失败")
        context.setFillColor(CGColor(red: seed, green: 1 - seed, blue: 0.25, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage(), "夹具 CGImage 创建失败")
    }

    /// 10 帧等距夹具：pts = n/10（n = 0..<10），窗 = 9/10 + 1/10 = 1.0s。
    private func makeTenFrames(timescale: Int32 = 10) throws -> [(image: CGImage, pts: CMTime)] {
        try (0..<10).map { n in
            (try makeSolidColorImage(width: 64, height: 32, seed: Double(n) / 10.0),
             CMTime(value: CMTimeValue(n), timescale: timescale))
        }
    }

    private func gifSource(of data: Data) throws -> CGImageSource {
        try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil), "夹具 GIF 数据不可解析")
    }

    private func gifFrameCount(of data: Data) throws -> Int {
        CGImageSourceGetCount(try gifSource(of: data))
    }

    private func gifFrame(at index: Int, of data: Data) throws -> CGImage {
        try XCTUnwrap(
            CGImageSourceCreateImageAtIndex(try gifSource(of: data), index, nil),
            "GIF 第 \(index) 帧不可解码")
    }

    /// 解析 NETSCAPE2.0 应用扩展的循环计数（无循环块 → nil）。
    /// 块结构：0x21 0xFF 0x0B "NETSCAPE2.0" 0x03 0x01 <计数低> <计数高> 0x00——
    /// 直接读原始字节（本工具链上 `CGImageSourceCopyProperties` 的文件级 LoopCount
    /// 恒回读 1，无块也然，不可作为断言依据）。
    private func gifLoopCount(of data: Data) -> Int? {
        let bytes = [UInt8](data)
        let marker = Array("NETSCAPE2.0".utf8)
        guard bytes.count > marker.count + 4 else { return nil }
        var blockStart: Int?
        for index in 0...(bytes.count - marker.count) where blockStart == nil {
            if Array(bytes[index..<(index + marker.count)]) == marker {
                blockStart = index + marker.count
            }
        }
        guard let blockStart, bytes[blockStart] == 0x03, bytes[blockStart + 1] == 0x01 else {
            return nil
        }
        return Int(bytes[blockStart + 2]) | (Int(bytes[blockStart + 3]) << 8)
    }

    // MARK: - gifData 纯函数

    func testGifDataFromFixtureFrames() throws {
        let data = ExportCore.gifData(fromFrames: try makeTenFrames(), options: GIFExportOptions())

        XCTAssertFalse(data.isEmpty)
        XCTAssertEqual(Array(data.prefix(4)), Array("GIF8".utf8), "GIF header 魔数")
        XCTAssertEqual(try gifFrameCount(of: data), 10,
                       "10 帧等距 1.0s 窗 @10fps → 恰 10 帧（窗口语义见类注释）")
    }

    /// 帧率钳制（∉{5,10,15} → 10）+ 30fps 源整 1s 抽 10fps 恰 10 帧（窗口语义见类注释：
    /// 末样本 27/30，第 28/29 帧不入，窗端 1.0 处无样本）。
    func testFrameRateClampAndSampling() throws {
        XCTAssertEqual(GIFExportOptions(frameRate: 24).frameRate, 10, "档位外钳到默认 10")
        XCTAssertEqual(GIFExportOptions(frameRate: 0).frameRate, 10)
        XCTAssertEqual(GIFExportOptions(frameRate: -3).frameRate, 10)
        XCTAssertEqual(GIFExportOptions(frameRate: 5).frameRate, 5, "档位内原样保留")
        XCTAssertEqual(GIFExportOptions(frameRate: 15).frameRate, 15)

        let frames = try (0..<30).map { n in
            (try makeSolidColorImage(width: 32, height: 32, seed: Double(n) / 30.0),
             CMTime(value: CMTimeValue(n), timescale: 30))
        }
        let data = ExportCore.gifData(
            fromFrames: frames, options: GIFExportOptions(frameRate: 24))

        XCTAssertEqual(try gifFrameCount(of: data), 10, "30fps 源整 1s @10fps → 恰 10 帧")
    }

    func testMaxWidthClampAndDownscale() throws {
        XCTAssertEqual(GIFExportOptions(maxWidth: 1080).maxWidth, 720, "档位外钳到默认 720")
        XCTAssertEqual(GIFExportOptions(maxWidth: 300).maxWidth, 720)
        XCTAssertEqual(GIFExportOptions(maxWidth: 480).maxWidth, 480, "档位内原样保留")
        XCTAssertEqual(GIFExportOptions(maxWidth: nil).maxWidth, nil, "nil（不缩放）保留")

        let big = try makeSolidColorImage(width: 960, height: 480, seed: 0.5)
        let downscaled = ExportCore.gifData(
            fromFrames: [(big, .zero)], options: GIFExportOptions(maxWidth: 480))
        let frame = try gifFrame(at: 0, of: downscaled)
        XCTAssertEqual(frame.width, 480, "超宽降采样到 maxWidth")
        XCTAssertEqual(frame.height, 240, "高按比例缩（960×480 → 480×240）")

        let small = try makeSolidColorImage(width: 320, height: 160, seed: 0.5)
        let untouched = ExportCore.gifData(
            fromFrames: [(small, .zero)], options: GIFExportOptions(maxWidth: 720))
        XCTAssertEqual(try gifFrame(at: 0, of: untouched).width, 320, "小图不放大")
    }

    /// 循环属性直读 NETSCAPE2.0 原始块（文件级属性回读不可靠——见 gifLoopCount 注释）。
    func testGifLoopPropertyFollowsOption() throws {
        let looping = ExportCore.gifData(
            fromFrames: try makeTenFrames(), options: GIFExportOptions())
        XCTAssertEqual(
            gifLoopCount(of: looping), 0,
            "loops = true（默认）→ NETSCAPE2.0 循环计数 0（无限循环）")

        let once = ExportCore.gifData(
            fromFrames: try makeTenFrames(), options: GIFExportOptions(loops: false))
        XCTAssertNil(
            gifLoopCount(of: once),
            "loops = false → 不写循环块（播一遍即停）")
    }

    // MARK: - 输出命名（nextFileURL 冲突惯例：同名存在 → 扩展名前追加 " (n)" 递增）

    func testGifNamingCollisionAppendsIndex() throws {
        let source = directory.appendingPathComponent("录屏_2026-10-30_10-00-00.mp4")
        try Data("x".utf8).write(to: source)

        XCTAssertEqual(
            ExportCore.gifDestinationURL(for: source).lastPathComponent,
            "录屏_2026-10-30_10-00-00_gif.gif", "无冲突 → `<原名>_gif.gif`")
        XCTAssertEqual(
            ExportCore.compressedDestinationURL(for: source).lastPathComponent,
            "录屏_2026-10-30_10-00-00_压缩.mp4", "无冲突 → `<原名>_压缩.mp4`")

        try Data().write(
            to: directory.appendingPathComponent("录屏_2026-10-30_10-00-00_gif.gif"))
        XCTAssertEqual(
            ExportCore.gifDestinationURL(for: source).lastPathComponent,
            "录屏_2026-10-30_10-00-00_gif (2).gif", "同名冲突 → 追加 (2)")
        try Data().write(
            to: directory.appendingPathComponent("录屏_2026-10-30_10-00-00_gif (2).gif"))
        XCTAssertEqual(
            ExportCore.gifDestinationURL(for: source).lastPathComponent,
            "录屏_2026-10-30_10-00-00_gif (3).gif", "连环冲突 → 继续递增")

        XCTAssertEqual(
            ExportCore.compressedDestinationURL(for: source).lastPathComponent,
            "录屏_2026-10-30_10-00-00_压缩.mp4", "GIF 侧冲突不影响压缩命名")
    }

    // MARK: - 压缩预设（代码级参数构造钉测；真实转码归真机验收）

    func testCompressionPresetEnumPins() {
        XCTAssertEqual(
            CompressionPreset.hevcSource, CompressionPreset(codec: .hevc, maxHeight: nil),
            "缺省预设 = 源分辨率 HEVC 高效重编码")
        XCTAssertEqual(CompressionPreset.hevc1080p.maxHeight, 1080)
        XCTAssertEqual(CompressionPreset.hevc720p.maxHeight, 720)

        XCTAssertEqual(CompressionPreset(codec: .hevc, maxHeight: 480).maxHeight, 720,
                       "maxHeight 档位外就近归档（<900 → 720）")
        XCTAssertEqual(CompressionPreset(codec: .h264, maxHeight: 2160).maxHeight, 1080,
                       "maxHeight 档位外就近归档（≥900 → 1080）")
        XCTAssertEqual(CompressionPreset(codec: .h264, maxHeight: nil).maxHeight, nil,
                       "nil（源分辨率）保留")

        // 参数构造钉测（CompressionPlan）：最高质量预设 + videoComposition renderSize
        // 等比缩放——macOS SDK 的 HEVC 维度预设只有 1080p 起（无 720 档），缩放统一走
        // renderSize 路径，720/1080 两档单一代码路径。
        XCTAssertEqual(
            ExportCore.compressionPlan(for: .hevcSource, sourceSize: CGSize(width: 1920, height: 1080)),
            CompressionPlan(presetName: AVAssetExportPresetHEVCHighestQuality, renderSize: nil),
            "源分辨率档：直通不设 videoComposition")
        XCTAssertEqual(
            ExportCore.compressionPlan(for: .hevc720p, sourceSize: CGSize(width: 1920, height: 1080)).renderSize,
            CGSize(width: 1280, height: 720), "720 档等比缩放")
        XCTAssertNil(
            ExportCore.compressionPlan(for: .hevc1080p, sourceSize: CGSize(width: 1920, height: 1080)).renderSize,
            "源高 ≤ maxHeight：直通不放大")
        XCTAssertEqual(
            ExportCore.compressionPlan(for: .hevc1080p, sourceSize: CGSize(width: 2160, height: 3840)).renderSize,
            CGSize(width: 608, height: 1080), "竖屏 4K → 1080 档（608×1080，宽取偶）")
        XCTAssertEqual(
            ExportCore.compressionPlan(
                for: CompressionPreset(codec: .h264, maxHeight: 720),
                sourceSize: CGSize(width: 1920, height: 1080)),
            CompressionPlan(presetName: AVAssetExportPresetHighestQuality, renderSize: CGSize(width: 1280, height: 720)),
            "H.264 同一缩放路径")
    }

    // MARK: - 进度去重（R1：compress 轮询器与显式推并发——终值双推/首拍重合收敛）

    func testProgressDedupDeliversStrictlyIncreasing() {
        var delivered: [Double] = []
        let push = ExportCore.deduplicatedProgress { delivered.append($0) }
        push(0)
        push(0)
        push(0.4)
        push(1.0)
        push(1.0)

        XCTAssertEqual(delivered, [0, 0.4, 1.0],
                       "仅严格递增转发——首拍零重复、终值恰一次（轮询器抢先推 1.0 时显式终值等值被吞）")
    }
}
