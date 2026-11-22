import AVFoundation
import CoreMedia
import XCTest

@testable import Hummingbird

/// 波形采样钉测（剪映对齐·批次 2）：`waveformExtremes` 纯函数（16-bit PCM 已知正弦 →
/// min/max 逼近幅值；静音 → 归一化钳 (0,0)）+ `sampleWaveform` 端到端（响/静两段夹具
/// → 对应时段桶幅度差异；空桶死循环回归——首样本晚于 0 时游标必须无条件推进）。
final class WaveformTests: XCTestCase {
    // MARK: PCM 样本构造（waveformExtremes 输入面）

    /// 构造 16-bit 44.1kHz 单声道 PCM CMSampleBuffer（values 归一化 -1…1）。
    private func makePCMSample(values: [Float], sampleRate: Double = 44100) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var descriptionOut: CMFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &descriptionOut), noErr)
        let description = try XCTUnwrap(descriptionOut)
        let byteCount = values.count * 2
        var blockBuffer: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
            flags: 0, blockBufferOut: &blockBuffer), noErr)
        let block = try XCTUnwrap(blockBuffer)
        let int16s = values.map { Int16(clamping: Int($0 * 32767)) }
        XCTAssertEqual(int16s.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: byteCount)
        }, kCMBlockBufferNoErr)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(values.count), timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: description,
            sampleCount: values.count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer), noErr)
        return try XCTUnwrap(sampleBuffer)
    }

    func testWaveformExtremesOnSine() throws {
        // 单周期正弦 ±0.5：min≈-0.5、max≈0.5（离散采样略欠冲）
        let values = (0..<441).map { Float(sin(Double($0) / 441 * 2 * .pi) * 0.5) }
        let extremes = try XCTUnwrap(
            OfflineZoomRenderer.waveformExtremes(of: makePCMSample(values: values)))
        XCTAssertGreaterThan(extremes.maximum, 0.45, "正弦峰值逼近 +0.5")
        XCTAssertLessThan(extremes.minimum, -0.45, "正弦谷值逼近 -0.5")
    }

    func testWaveformExtremesOnSilenceClampsToZero() throws {
        let zeros = [Float](repeating: 0, count: 100)
        let extremes = try XCTUnwrap(
            OfflineZoomRenderer.waveformExtremes(of: makePCMSample(values: zeros)))
        XCTAssertEqual(extremes.minimum, 0, "静音钳 (0, …)")
        XCTAssertEqual(extremes.maximum, 0, "静音钳 (…, 0)")
    }

    // MARK: sampleWaveform 端到端（响/静两段音频夹具）

    /// 程序生成 2s 音频-only mp4：前 1s ±0.8 正弦（440Hz），后 1s ±0.005 近静音。
    func makeLoudSilentFixture(at url: URL) async throws {
        let sampleRate = 44100.0
        let framesPerChunk = 4410 // 0.1s × 20 chunks = 2s
        let writer = try AVAssetWriter(url: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ])
        input.expectsMediaDataInRealTime = true
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var descriptionOut: CMFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &descriptionOut), noErr)
        let description = try XCTUnwrap(descriptionOut)

        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for chunk in 0..<20 {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            let amplitude: Float = chunk < 10 ? 0.8 : 0.005
            let chunkStartFrame = chunk * framesPerChunk
            let rate = sampleRate
            var values: [Float] = []
            values.reserveCapacity(framesPerChunk)
            for frame in 0..<framesPerChunk {
                let t = Double(chunkStartFrame + frame) / rate
                let phase: Double = sin(2.0 * Double.pi * 440.0 * t)
                let wave: Double = phase * Double(amplitude)
                values.append(Float(wave))
            }
            let byteCount = values.count * 4
            var blockBuffer: CMBlockBuffer?
            XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
                blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
                flags: 0, blockBufferOut: &blockBuffer), noErr)
            let block = try XCTUnwrap(blockBuffer)
            XCTAssertEqual(values.withUnsafeBytes { raw in
                CMBlockBufferReplaceDataBytes(
                    with: raw.baseAddress!, blockBuffer: block,
                    offsetIntoDestination: 0, dataLength: byteCount)
            }, kCMBlockBufferNoErr)
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: CMTimeValue(framesPerChunk), timescale: CMTimeScale(sampleRate)),
                presentationTimeStamp: CMTime(value: CMTimeValue(chunk * framesPerChunk), timescale: CMTimeScale(sampleRate)),
                decodeTimeStamp: .invalid)
            var sampleBuffer: CMSampleBuffer?
            XCTAssertEqual(CMSampleBufferCreate(
                allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
                makeDataReadyCallback: nil, refcon: nil, formatDescription: description,
                sampleCount: framesPerChunk, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer), noErr)
            XCTAssertTrue(input.append(try XCTUnwrap(sampleBuffer)),
                          "夹具音频块 \(chunk) 写入失败：\(String(describing: writer.error))")
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        XCTAssertEqual(writer.status, .completed)
    }

    func testSampleWaveformDistinguishesLoudAndSilentRanges() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WaveformTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("响静夹具.mp4")
        try await makeLoudSilentFixture(at: url)

        // 内联诊断：与 sampleWaveform 同循环手动聚合，dump 前 5 个样本的 pts/extremes
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(audioTracks.first)
        let reader = try AVAssetReader(asset: url.path.isEmpty ? asset : asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var debugCount = 0
        while let sample = output.copyNextSampleBuffer() {
            debugCount += 1
            if debugCount <= 5 {
                let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                let extremes = OfflineZoomRenderer.waveformExtremes(of: sample)
                print("DEBUG-INLINE-\(debugCount) pts=\(pts) extremes=\(String(describing: extremes)) status=\(reader.status.rawValue)")
            }
        }
        print("DEBUG-INLINE total=\(debugCount) finalStatus=\(reader.status.rawValue)")
        let buckets = await OfflineZoomRenderer.sampleWaveform(sourceURL: url)
        XCTAssertFalse(buckets.isEmpty, "有音轨夹具应出非空波形")
        XCTAssertEqual(buckets.count, 100, accuracy: 6, "2s @0.02s/桶 ≈ 100 桶")

        let loud = buckets.filter { $0.start >= 0.1 && $0.start < 0.9 }
        XCTAssertFalse(loud.isEmpty)
        for bucket in loud {
            XCTAssertGreaterThan(bucket.maximum, 0.4, "响段桶峰值 >0.4（t=\(bucket.start)）")
        }
        // 静段断言从 1.2s 起：跨响/静边界的解码大包（AAC 解码合并 ≈0.186s/包，平台
        // 约束）把整包极值带进边界桶——包级粒度的固有近似（显示上 0.19s ≈ 2-3px）。
        let silent = buckets.filter { $0.start >= 1.2 && $0.start < 1.9 }
        XCTAssertFalse(silent.isEmpty)
        for bucket in silent {
            XCTAssertLessThan(bucket.maximum, 0.15, "静段桶峰值 <0.15（AAC 编码底噪容忍）")
        }
        // 桶时间轴单调且贴合网格（PTS 驱动推进的正确性）
        for (previous, current) in zip(buckets, buckets.dropFirst()) {
            XCTAssertLessThan(previous.start, current.start, "桶起点单调递增")
        }
        XCTAssertEqual(buckets[0].start, 0, accuracy: 1e-9, "首桶从 0 起")
    }

    /// 空桶推进回归：桶粒度远大于音轨首个样本时刻（构造首样本在 0.5s 的形态不可行，
    /// AAC 解码首样本恒 ~0——改以「桶数 ≥ 时长/粒度」钉游标推进收敛：若 flush 不推进
    /// 会在此处死循环超时挂死测试）。
    func testSampleWaveformAdvancesCursorOnEmptyBuckets() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WaveformTests-gap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("游标夹具.mp4")
        try await makeLoudSilentFixture(at: url)
        // 大桶粒度（0.5s/桶）：4 桶覆盖 2s——任何「不推进」实现都会死循环挂死
        let buckets = await OfflineZoomRenderer.sampleWaveform(sourceURL: url, bucketSeconds: 0.5)
        XCTAssertEqual(buckets.count, 4, accuracy: 1, "0.5s/桶 × 2s ≈ 4 桶（游标推进收敛）")
    }
}

/// 轨道缩略图钉测（剪映对齐·批次 3）：间隔纯函数（0.5s 下限 / ≤240 张自适应）、
/// 真实 mp4 抽帧（键位落在请求网格、尺寸钳 maxSize）。
final class FilmstripTests: XCTestCase {
    func testFilmstripInterval() {
        XCTAssertEqual(OfflineZoomRenderer.filmstripInterval(forDuration: 0), 1, "退化回退")
        XCTAssertEqual(OfflineZoomRenderer.filmstripInterval(forDuration: 48.4), 0.5,
                       "48.4/240 = 0.2 → 0.5s 下限兜住")
        XCTAssertEqual(OfflineZoomRenderer.filmstripInterval(forDuration: 7200), 30,
                       accuracy: 0.01, "2h → ≤240 张自适应")
    }

    func testSampleFilmstripOnRealMovie() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FilmstripTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("抽帧夹具.mp4")
        try await EditorMovieFixture.makeMovie(at: url)

        let filmstrip = await OfflineZoomRenderer.sampleFilmstrip(
            sourceURL: url, interval: 0.5, maxSize: CGSize(width: 128, height: 72))
        let strip = try XCTUnwrap(filmstrip, "有视频轨夹具应出缩略图")
        XCTAssertGreaterThanOrEqual(strip.images.count, 2, "1s @0.5s → ≥2 张（0 / 0.5）")
        for (time, image) in strip.images {
            XCTAssertGreaterThanOrEqual(time, 0)
            XCTAssertLessThan(time, 1.0, "键位在时长内")
            XCTAssertLessThanOrEqual(image.width, 128, "宽度钳 maxSize")
            XCTAssertLessThanOrEqual(image.height, 72)
        }
        // 无视频轨（纯音频夹具）→ nil
        let audioURL = directory.appendingPathComponent("响静夹具.mp4")
        try await WaveformTests().makeLoudSilentFixture(at: audioURL)
        let audioStrip = await OfflineZoomRenderer.sampleFilmstrip(
            sourceURL: audioURL, interval: 0.5, maxSize: CGSize(width: 128, height: 72))
        XCTAssertNil(audioStrip, "无视频轨 → nil")
    }
}


/// 音轨批次 4b 钉测：scaledAudioSample 音量缩放 + EditDocument v3 兼容解码。
final class AudioTrackBatchTests: XCTestCase {
    /// 复用 WaveformTests 的 PCM 构造（internal 化前置：此处独立重建简版）。
    private func makePCMSample(values: [Float], sampleRate: Double = 44100) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var descriptionOut: CMFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &descriptionOut), noErr)
        let description = try XCTUnwrap(descriptionOut)
        let byteCount = values.count * 2
        var blockBuffer: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
            flags: 0, blockBufferOut: &blockBuffer), noErr)
        let block = try XCTUnwrap(blockBuffer)
        let int16s = values.map { Int16(clamping: Int($0 * 32767)) }
        XCTAssertEqual(int16s.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: byteCount)
        }, kCMBlockBufferNoErr)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(values.count), timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: description,
            sampleCount: values.count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer), noErr)
        return try XCTUnwrap(sampleBuffer)
    }

    func testScaledAudioSampleHalvesAmplitude() throws {
        let values: [Float] = [0, 0.5, -0.5, 1.0, -1.0]
        let scaled = try XCTUnwrap(
            OfflineZoomRenderer.scaledAudioSample(makePCMSample(values: values), volume: 0.5))
        let raw = try XCTUnwrap(CMSampleBufferGetDataBuffer(scaled))
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        XCTAssertEqual(CMBlockBufferGetDataPointer(
            raw, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
            dataPointerOut: &pointer), kCMBlockBufferNoErr)
        let typed = UnsafeMutableRawPointer(try XCTUnwrap(pointer)).bindMemory(to: Int16.self, capacity: values.count)
        XCTAssertEqual(Float(typed[1]) / 32768.0, 0.25, accuracy: 0.02, "0.5 × 0.5 = 0.25")
        XCTAssertEqual(Float(typed[3]) / 32768.0, 0.5, accuracy: 0.02, "1.0 × 0.5 = 0.5")
    }

    func testScaledAudioSamplePassthroughAtUnity() throws {
        let values: [Float] = [0.5, -0.5]
        let unitySample = try makePCMSample(values: values)
        XCTAssertNil(OfflineZoomRenderer.scaledAudioSample(unitySample, volume: 1),
            "volume 1 → nil（调用方透传零拷贝）")
    }

    /// v2 草稿（无音轨字段）解码 → 音轨默认值（向后兼容）。
    func testV2DraftDecodesWithAudioDefaults() throws {
        let v2JSON = #"{"clips":[{"sourceStart":0,"sourceEnd":5,"speed":1}],"zoomSegments":[]}"#
        let decoded = try JSONDecoder().decode(EditDocument.self, from: Data(v2JSON.utf8))
        XCTAssertEqual(decoded.sourceVolume, 1, "v2 缺字段 → 原声默认 1")
        XCTAssertNil(decoded.backgroundMusic, "v2 缺字段 → 无配乐")
        XCTAssertEqual(decoded.clips, [EditClip(sourceStart: 0, sourceEnd: 5)])
    }
}
