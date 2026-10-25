import AVFoundation
import CoreMedia
import XCTest

@testable import ScreenRecorder

/// SystemAudioMixer 可无头验证的纯逻辑回归：环形缓冲溢出丢旧 / 欠载、gate 裁剪决策、
/// PCM ↔ CMSampleBuffer 往返。AVAudioEngine 本体（实时渲染）不在此覆盖——走 T11 后的
/// 真控制流手动验收。
final class SystemAudioMixerTests: XCTestCase {
    private typealias RingBuffer = SystemAudioMixer.RingBuffer

    private let masterFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!

    // MARK: - 环形缓冲

    /// 容量 8 帧写满后再写：必须丢最旧、保最新（实时录制语义）。
    func testRingBufferOverflowDropsOldest() {
        let ring = RingBuffer(channels: 2, capacityFrames: 8)
        let first: [[Float]] = [[0, 1, 2, 3, 4, 5, 6, 7], [-0, -1, -2, -3, -4, -5, -6, -7]]
        ring.write(first, frameCount: 8)
        XCTAssertEqual(ring.bufferedCount, 8)

        let second: [[Float]] = [[8, 9, 10, 11], [-8, -9, -10, -11]]
        ring.write(second, frameCount: 4)
        XCTAssertEqual(ring.bufferedCount, 8, "溢出后缓冲仍应为满容量")

        var out: [[Float]] = [Array(repeating: -1, count: 8), Array(repeating: -1, count: 8)]
        let read = ring.read(into: &out, frameCount: 8)
        XCTAssertEqual(read, 8)
        XCTAssertEqual(out[0], [4, 5, 6, 7, 8, 9, 10, 11], "最旧的 0..3 必须被丢弃")
        XCTAssertEqual(out[1], [-4, -5, -6, -7, -8, -9, -10, -11])
        XCTAssertEqual(ring.bufferedCount, 0)
    }

    /// 一次写入超过容量：只保留最新 capacity 帧。
    func testRingBufferSingleWriteBeyondCapacityKeepsNewest() {
        let ring = RingBuffer(channels: 1, capacityFrames: 8)
        ring.write([(0..<20).map { Float($0) }], frameCount: 20)
        XCTAssertEqual(ring.bufferedCount, 8)

        var out: [[Float]] = [Array(repeating: -1, count: 8)]
        XCTAssertEqual(ring.read(into: &out, frameCount: 8), 8)
        XCTAssertEqual(out[0], (12..<20).map { Float($0) })
    }

    /// 欠载读取：返回实际可用帧数，缓冲读空；再次读取返回 0。
    func testRingBufferPartialReadReturnsAvailable() {
        let ring = RingBuffer(channels: 2, capacityFrames: 16)
        ring.write([[1, 2, 3, 4, 5], [10, 20, 30, 40, 50]], frameCount: 5)

        var out: [[Float]] = [Array(repeating: 0, count: 16), Array(repeating: 0, count: 16)]
        XCTAssertEqual(ring.read(into: &out, frameCount: 16), 5)
        XCTAssertEqual(Array(out[0][0..<5]), [1, 2, 3, 4, 5])
        XCTAssertEqual(Array(out[1][0..<5]), [10, 20, 30, 40, 50])
        XCTAssertEqual(ring.bufferedCount, 0)
        var empty: [[Float]] = [Array(repeating: 0, count: 16), Array(repeating: 0, count: 16)]
        XCTAssertEqual(ring.read(into: &empty, frameCount: 16), 0, "空缓冲再读必须返回 0")
    }

    /// 环回绕正确性：写读交错多轮，数据不串位（容量 8，5 轮各写 6 → 剩最后 8 帧）。
    func testRingBufferWraparoundKeepsOrder() {
        let ring = RingBuffer(channels: 1, capacityFrames: 8)
        var seed: Float = 0
        for _ in 0..<5 {
            let block = (0..<6).map { seed + Float($0) }
            seed += 6
            ring.write([block], frameCount: 6)
        }
        XCTAssertEqual(ring.bufferedCount, 8)
        var out: [[Float]] = [Array(repeating: -1, count: 8)]
        XCTAssertEqual(ring.read(into: &out, frameCount: 8), 8)
        XCTAssertEqual(out[0], (22..<30).map { Float($0) })
    }

    /// AVAudioPCMBuffer 写入路径（生产热路径）：超容丢最旧，与数组写入语义一致。
    func testRingBufferWriteFromPCMBufferMatchesArraySemantics() {
        let ring = RingBuffer(channels: 2, capacityFrames: 8)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: masterFormat, frameCapacity: 12) else {
            return XCTFail("AVAudioPCMBuffer 创建失败")
        }
        pcm.frameLength = 12
        for index in 0..<12 {
            pcm.floatChannelData![0][index] = Float(index)
            pcm.floatChannelData![1][index] = -Float(index)
        }
        ring.write(from: pcm)
        XCTAssertEqual(ring.bufferedCount, 8, "12 帧写入容量 8：丢最旧 4 帧")

        var out: [[Float]] = [Array(repeating: -1, count: 8), Array(repeating: -1, count: 8)]
        XCTAssertEqual(ring.read(into: &out, frameCount: 8), 8)
        XCTAssertEqual(out[0], Array(4..<12).map(Float.init))
        XCTAssertEqual(out[1], (4..<12).map { -Float($0) })
    }

    // MARK: - gate 裁剪决策

    private let sampleRate: Double = 48000
    private let gate = CMTime(value: 480_000, timescale: 48_000) // 10.0s

    /// 完全早于锚点的整段：丢弃。
    func testTrimDecisionDropsBufferFullyBeforeGate() {
        let pts = CMTime(value: 432_000, timescale: 48_000) // 9.0s，1s 长度恰止于 10.0s
        XCTAssertNil(AudioSampleBridge.trimDecision(
            bufferPTS: pts, frameCount: 48_000, sampleRate: sampleRate, gate: gate
        ))
    }

    /// 跨锚点段：裁掉头部，输出 PTS 恰为锚点（整数运算，无浮点漂移）。
    func testTrimDecisionStraddleTrimsHeadToGate() {
        let pts = CMTime(value: 479_976, timescale: 48_000) // 9.9995s，48 帧 = 1ms 跨 10.0s
        let decision = AudioSampleBridge.trimDecision(
            bufferPTS: pts, frameCount: 48, sampleRate: sampleRate, gate: gate
        )
        XCTAssertNotNil(decision)
        XCTAssertEqual(decision?.skipFrames, 24, "前 0.5ms（24 帧）在锚点前，必须裁掉")
        XCTAssertEqual(CMTimeCompare(decision?.outputPTS ?? .invalid, gate), 0, "输出 PTS 应恰为锚点")
    }

    /// 锚点之后的段：原样通过。
    func testTrimDecisionPassesBufferAfterGate() {
        let pts = CMTime(value: 504_000, timescale: 48_000) // 10.5s
        let decision = AudioSampleBridge.trimDecision(
            bufferPTS: pts, frameCount: 1024, sampleRate: sampleRate, gate: gate
        )
        XCTAssertEqual(decision?.skipFrames, 0)
        XCTAssertEqual(CMTimeCompare(decision?.outputPTS ?? .invalid, pts), 0)
    }

    /// gate 未设置（.invalid）：不裁剪，原样通过。
    func testTrimDecisionWithInvalidGatePassesThrough() {
        let pts = CMTime(value: 1, timescale: 48_000)
        let decision = AudioSampleBridge.trimDecision(
            bufferPTS: pts, frameCount: 100, sampleRate: sampleRate, gate: .invalid
        )
        XCTAssertEqual(decision?.skipFrames, 0)
        XCTAssertEqual(CMTimeCompare(decision?.outputPTS ?? .invalid, pts), 0)
    }

    // MARK: - PCM ↔ CMSampleBuffer 往返

    /// 打包（非交错 PCM → CMSampleBuffer）与 SCStream 侧桥接（CMSampleBuffer → PCM）
    /// 往返数据一致；skipFrames 跳头语义正确。
    func testPCMSampleBufferRoundTrip() throws {
        var asbd = masterFormat.streamDescription.pointee
        var descriptionOut: CMFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &descriptionOut
        )
        XCTAssertEqual(status, noErr)
        let formatDescription = try XCTUnwrap(descriptionOut)

        guard let pcm = AVAudioPCMBuffer(pcmFormat: masterFormat, frameCapacity: 64) else {
            return XCTFail("AVAudioPCMBuffer 创建失败")
        }
        pcm.frameLength = 64
        for index in 0..<64 {
            pcm.floatChannelData![0][index] = Float(index + 1) * 0.5
            pcm.floatChannelData![1][index] = -Float(index + 1) * 0.25
        }
        let pts = CMTime(value: 96_000, timescale: 48_000)
        guard let sample = AudioSampleBridge.makeSampleBuffer(
            pcm: pcm, skipFrames: 4, pts: pts, formatDescription: formatDescription
        ) else {
            return XCTFail("CMSampleBuffer 打包失败")
        }
        XCTAssertEqual(CMSampleBufferGetNumSamples(sample), 60, "跳过 4 个头部帧")
        XCTAssertEqual(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), pts), 0)

        let roundTripped = try XCTUnwrap(AudioSampleBridge.pcmBuffer(from: sample))
        XCTAssertEqual(roundTripped.frameLength, 60)
        XCTAssertEqual(roundTripped.format.sampleRate, masterFormat.sampleRate)
        XCTAssertEqual(Int(roundTripped.format.channelCount), 2)
        for index in 0..<60 {
            XCTAssertEqual(roundTripped.floatChannelData![0][index], Float(index + 5) * 0.5, "channel0[\(index)]")
            XCTAssertEqual(roundTripped.floatChannelData![1][index], -Float(index + 5) * 0.25, "channel1[\(index)]")
        }
    }
}
