import AVFoundation
import CoreMedia
import XCTest

@testable import ScreenRecorder

/// 暂停媒体时钟（Task 10）无头单测：暂停门控、时间平移、每轨单调护栏，
/// 以及音频 CMSampleBuffer 的平移复制（recorder 音频 append 的落盘口径）。
final class PauseMediaClockTests: XCTestCase {
    private func t(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    // MARK: - 门控 + 平移（视频与音频同一 tracker）

    /// 未暂停时恒等：shiftedPTS == 原始 PTS，累计暂停为零。
    func testIdentityBeforeAnyPause() {
        var clock = PauseMediaClock()

        XCTAssertFalse(clock.isPaused)
        XCTAssertEqual(clock.shiftedPTS(t(10), for: .video), t(10))
        XCTAssertEqual(clock.shiftedPTS(t(10.1), for: .audio), t(10.1))
        XCTAssertEqual(clock.accumulatedPause, .zero)
    }

    /// 暂停中两路一律丢弃（不写 writer、不补静音）；恢复后视频与音频用同一平移量
    /// ——「双路同一 tracker」规则的时钟层验证。
    func testPauseDropsBothTracksAndResumeShiftsWithSharedTracker() {
        var clock = PauseMediaClock()

        clock.pause(at: t(10))
        XCTAssertTrue(clock.isPaused)
        XCTAssertNil(clock.shiftedPTS(t(10.033), for: .video), "暂停中的视频帧必须丢弃")
        XCTAssertNil(clock.shiftedPTS(t(10.1), for: .audio), "暂停中的音频包必须丢弃")

        clock.resume(at: t(40))
        XCTAssertFalse(clock.isPaused)
        XCTAssertEqual(clock.shiftedPTS(t(40.033), for: .video), t(10.033), "恢复后首个视频帧平移 30s")
        XCTAssertEqual(clock.shiftedPTS(t(40.1), for: .audio), t(10.1), "恢复后音频必须用同一平移量")
        XCTAssertEqual(clock.accumulatedPause, t(30))
    }

    /// 幂等：重复 pause 取首次时点，多余 resume 无操作（继承 PauseTimeTracker 语义）。
    func testRepeatedPauseAndResumeAreIdempotent() {
        var clock = PauseMediaClock()

        clock.pause(at: t(10))
        clock.pause(at: t(50)) // 已暂停，忽略
        clock.resume(at: t(80))
        clock.resume(at: t(90)) // 未暂停，无操作

        XCTAssertFalse(clock.isPaused)
        XCTAssertEqual(clock.accumulatedPause, t(70))
        XCTAssertEqual(clock.shiftedPTS(t(90), for: .video), t(20))
    }

    /// 非数值 PTS 一律丢弃（防御：异常样本不得进入 writer）。
    func testInvalidRawPTSDropped() {
        var clock = PauseMediaClock()

        XCTAssertNil(clock.shiftedPTS(.invalid, for: .video))
        XCTAssertNil(clock.shiftedPTS(.invalid, for: .audio))
        clock.pause(at: t(10))
        XCTAssertNil(clock.shiftedPTS(.invalid, for: .video))
    }

    // MARK: - 每轨单调护栏（平移后回跳的边界在途样本丢弃）

    /// 平移后相对该轨最近放行值不递增的样本返回 nil；其后正常样本恢复推进
    /// （macOS 27 writer 对回跳 PTS 会静默钳位，必须在时钟层挡住）。
    func testRegressedShiftedPTSDropped() {
        var clock = PauseMediaClock()
        clock.pause(at: t(100))
        clock.resume(at: t(200))

        XCTAssertEqual(clock.shiftedPTS(t(250), for: .video), t(150)) // 累计暂停 100，视频基线 150
        XCTAssertNil(clock.shiftedPTS(t(240), for: .video), "平移后 140 ≤ 150：回跳丢弃")
        XCTAssertEqual(clock.shiftedPTS(t(260), for: .video), t(160), "回跳样本被丢后正常推进")
    }

    /// 护栏按轨独立：一轨回跳不得误杀另一轨（暂停边界视频、音频管道深度不同）。
    func testMonotonicGuardIsPerTrack() {
        var clock = PauseMediaClock()
        clock.pause(at: t(100))
        clock.resume(at: t(200))

        XCTAssertEqual(clock.shiftedPTS(t(310), for: .video), t(210)) // 视频基线 210
        XCTAssertEqual(clock.shiftedPTS(t(320), for: .audio), t(220)) // 音频基线 220
        XCTAssertNil(clock.shiftedPTS(t(305), for: .video), "视频回跳（205 ≤ 210）丢弃")
        XCTAssertEqual(clock.shiftedPTS(t(360), for: .audio), t(260), "视频护栏不得影响音频")
        XCTAssertNil(clock.shiftedPTS(t(315), for: .audio), "音频回跳（215 ≤ 220）丢弃")
        XCTAssertEqual(clock.shiftedPTS(t(370), for: .video), t(270), "音频护栏不得影响视频")
    }

    /// 暂停中的丢弃不得推进单调基线：恢复后首个样本不被误杀。
    func testPauseDoesNotAdvanceMonotonicBaseline() {
        var clock = PauseMediaClock()

        XCTAssertEqual(clock.shiftedPTS(t(10), for: .video), t(10)) // 基线 10
        clock.pause(at: t(20))
        XCTAssertNil(clock.shiftedPTS(t(25), for: .video)) // 暂停中丢弃
        clock.resume(at: t(30)) // 累计暂停 10

        XCTAssertEqual(clock.shiftedPTS(t(30.033), for: .video), t(20.033), "恢复后首个帧必须放行（20.033 > 10）")
    }

    // MARK: - 音频 CMSampleBuffer 平移复制

    private let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!

    /// 构造非交错 PCM 的 CMSampleBuffer（与 SystemAudioMixer 输出口径一致）。
    private func makeAudioSample(pts: CMTime, value: Float) throws -> CMSampleBuffer {
        guard let pcm = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: 1024) else {
            XCTFail("AVAudioPCMBuffer 创建失败")
            throw CancellationError()
        }
        pcm.frameLength = 1024
        for index in 0..<1024 {
            pcm.floatChannelData![0][index] = value
            pcm.floatChannelData![1][index] = -value
        }
        var asbd = audioFormat.streamDescription.pointee
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
        let description = try XCTUnwrap(descriptionOut, "CMFormatDescription 创建失败")
        return try XCTUnwrap(
            AudioSampleBridge.makeSampleBuffer(pcm: pcm, skipFrames: 0, pts: pts, formatDescription: description),
            "CMSampleBuffer 打包失败"
        )
    }

    /// 平移复制：PTS 替换为新值，样本数与数据保真——暂停平移只动时间轴不动内容。
    func testSampleBufferRetimeReplacesPTSAndKeepsData() throws {
        let original = try makeAudioSample(pts: t(1000), value: 0.25)

        let retimed = try XCTUnwrap(
            AudioSampleBridge.sampleBuffer(copying: original, presentationTimeStamp: t(20)),
            "平移复制失败"
        )

        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(retimed), t(20), "PTS 必须替换为平移值")
        XCTAssertEqual(CMSampleBufferGetNumSamples(retimed), CMSampleBufferGetNumSamples(original), "样本数不变")
        XCTAssertEqual(CMSampleBufferGetTotalSampleSize(retimed), CMSampleBufferGetTotalSampleSize(original), "数据量不变")

        // 数据保真：非交错打包口径下首通道首个样本值一致（0.25）
        guard let block = CMSampleBufferGetDataBuffer(retimed) else { return XCTFail("平移副本缺数据块") }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
        guard let pointer else { return XCTFail("平移副本数据指针不可用") }
        let firstSample = pointer.withMemoryRebound(to: Float.self, capacity: 1) { $0.pointee }
        XCTAssertEqual(firstSample, 0.25, accuracy: 0.0001, "样本数据必须原样保留")
    }
}
