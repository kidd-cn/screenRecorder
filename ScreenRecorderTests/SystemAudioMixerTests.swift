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

    // MARK: - Task 9 麦克风路径

    /// reset()：清空缓冲并把写指针归零——setMicMuted 转换时排空陈旧音频用。
    /// 覆盖回绕态重置（写指针若未归零，重置后再写满容量会读到错位内容）。
    func testRingBufferResetClearsContentAndRebasesWrite() {
        let ring = RingBuffer(channels: 2, capacityFrames: 8)
        ring.write([[1, 2, 3, 4], [10, 20, 30, 40]], frameCount: 4)
        ring.reset()
        XCTAssertEqual(ring.bufferedCount, 0, "reset 后缓冲必须为空")
        var out: [[Float]] = [Array(repeating: -1, count: 4), Array(repeating: -1, count: 4)]
        XCTAssertEqual(ring.read(into: &out, frameCount: 4), 0, "reset 后读必须返回 0")

        // 先写到回绕位置（写指针 6/8），reset 后再写满容量：读回必须恰为新内容（证明写指针已归零）
        ring.write([[1, 2, 3, 4, 5, 6], [-1, -2, -3, -4, -5, -6]], frameCount: 6)
        XCTAssertEqual(ring.bufferedCount, 6)
        ring.reset()
        let refreshed: [[Float]] = [(0..<8).map { Float($0) + 100 }, (0..<8).map { -Float($0) - 100 }]
        ring.write(refreshed, frameCount: 8)
        XCTAssertEqual(ring.bufferedCount, 8)
        var out2: [[Float]] = [Array(repeating: -1, count: 8), Array(repeating: -1, count: 8)]
        XCTAssertEqual(ring.read(into: &out2, frameCount: 8), 8)
        XCTAssertEqual(out2[0], (0..<8).map { Float($0) + 100 }, "reset 后写满必须从位置 0 起写")
        XCTAssertEqual(out2[1], (0..<8).map { -Float($0) - 100 })
    }

    /// setMicrophoneInput 登记麦克风输入格式与增益：format 必达，volume 缺省 1.0、可覆盖、
    /// 越界收敛到 0…1（后续装配据此建 converter 与施加 mixer 输入增益）。
    func testSetMicrophoneInputRegistersFormatAndGain() {
        let mixer = SystemAudioMixer()
        XCTAssertNil(mixer.microphoneFormat, "初始未登记")

        let mono = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        mixer.setMicrophoneInput(mono)
        XCTAssertEqual(mixer.microphoneFormat, mono)
        XCTAssertEqual(mixer.micVolume, 1.0, "缺省增益 1.0")

        mixer.setMicrophoneInput(mono, volume: 0.5)
        XCTAssertEqual(mixer.micVolume, 0.5)

        mixer.setMicrophoneInput(mono, volume: 1.7)
        XCTAssertEqual(mixer.micVolume, 1.0, "增益越上界收敛到 1")
        mixer.setMicrophoneInput(mono, volume: -0.2)
        XCTAssertEqual(mixer.micVolume, 0.0, "增益越下界收敛到 0")
    }

    /// 空闲态（engine 未运行）setMicMuted：仅记录状态供 start() 装配时裁决，不做节点手术；
    /// 同值重复设置幂等。
    func testSetMicMutedWhileIdleRecordsFlagOnly() {
        let mixer = SystemAudioMixer()
        XCTAssertFalse(mixer.isMicMuted)
        mixer.setMicMuted(true)
        XCTAssertTrue(mixer.isMicMuted)
        mixer.setMicMuted(true)
        XCTAssertTrue(mixer.isMicMuted, "同值重复设置幂等")
        mixer.setMicMuted(false)
        XCTAssertFalse(mixer.isMicMuted)
    }

    /// mic tap 处理器（渲染线程回调的生产逻辑，无头直测）：单声道 48k 输入经 converter 转
    /// masterFormat 立体声后经串行队列写入 ring——L=R=输入值（实测 AVAudioConverter 单声道
    /// 上混为通道复制），帧数守恒。
    func testMicTapHandlerDuplicatesMonoIntoStereoRing() throws {
        let mixer = SystemAudioMixer()
        let ring = RingBuffer(channels: 2, capacityFrames: 48000)
        let mono48 = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let converter = try XCTUnwrap(AVAudioConverter(from: mono48, to: masterFormat))
        let handler = mixer.makeMicTapHandler(ring: ring, converter: converter)

        let frames = 96
        guard let pcm = AVAudioPCMBuffer(pcmFormat: mono48, frameCapacity: AVAudioFrameCount(frames)) else {
            return XCTFail("AVAudioPCMBuffer 创建失败")
        }
        pcm.frameLength = AVAudioFrameCount(frames)
        for index in 0..<frames {
            pcm.floatChannelData![0][index] = Float(index) * 0.25
        }
        handler(pcm)
        mixer.flushMicDeliveryForTesting()

        XCTAssertEqual(ring.bufferedCount, frames, "同采样率转换帧数守恒")
        var out: [[Float]] = [Array(repeating: -1, count: frames), Array(repeating: -1, count: frames)]
        XCTAssertEqual(ring.read(into: &out, frameCount: frames), frames)
        for index in 0..<frames {
            XCTAssertEqual(out[0][index], Float(index) * 0.25, accuracy: 1e-6, "L[\(index)]")
            XCTAssertEqual(out[1][index], Float(index) * 0.25, accuracy: 1e-6, "R[\(index)] = 上混复制")
        }
    }

    /// mic tap 处理器：44.1k 单声道 → 48k 立体声跨缓冲重采样——converter 状态跨 tap 延续。
    /// 实测（/tmp probe，30 轮流）：SRC 以 4096 帧为发射量子，内部滞留为有界锯齿
    ///（≤ 1 个量子 ≈ 85ms），长期速率守恒不丢样本。断言累计输出落在
    /// [expected − 4096, expected + 64] 窗口（下界 = 一个量子的有界滞留，上界 = 不超产）。
    func testMicTapHandlerResamples44100MonoAcrossBuffers() throws {
        let mixer = SystemAudioMixer()
        let ring = RingBuffer(channels: 2, capacityFrames: 48000)
        let mono441 = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let converter = try XCTUnwrap(AVAudioConverter(from: mono441, to: masterFormat))
        let handler = mixer.makeMicTapHandler(ring: ring, converter: converter)

        let framesPerBuffer = 4410
        let bufferCount = 6
        for batch in 0..<bufferCount {
            guard let pcm = AVAudioPCMBuffer(pcmFormat: mono441, frameCapacity: AVAudioFrameCount(framesPerBuffer)) else {
                return XCTFail("AVAudioPCMBuffer 创建失败")
            }
            pcm.frameLength = AVAudioFrameCount(framesPerBuffer)
            for index in 0..<framesPerBuffer {
                pcm.floatChannelData![0][index] = Float(index + batch * framesPerBuffer) * 0.5
            }
            handler(pcm)
        }
        mixer.flushMicDeliveryForTesting()

        let expected = Int(Double(framesPerBuffer * bufferCount) * 48000.0 / 44100.0) // 28800
        let lag = ring.bufferedCount - expected
        XCTAssertTrue(lag >= -4096 && lag <= 64,
                      "累计输出应约 \(expected) 帧（有界滞留 ≤4096），实际 \(ring.bufferedCount)")
    }
}
