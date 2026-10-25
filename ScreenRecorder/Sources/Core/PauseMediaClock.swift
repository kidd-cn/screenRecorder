import CoreMedia

/// 录制会话的暂停媒体时钟（Task 10）：暂停门控 + 时间戳平移 + 每轨单调护栏。
/// 值类型：无 I/O、无时钟——pause/resume 的时点由调用方传入（生产方为
/// `CMClock.hostTimeClock.time`，与 SCStream 帧 PTS 及混音器输出 PTS 同 mach 时基）；
/// 调用方（`SCStreamRecorder`）经 stateLock 串行化所有访问。
///
/// 规则（Task 10 简报钉死）：
/// - 暂停中 `shiftedPTS` 返回 nil——视频帧与音频包一律丢弃（不入 writer、不补静音）；
/// - 恢复后所有 append 的 PTS = `PauseTimeTracker.shifted`，视频与音频共用同一
///   tracker（两路在混音后同一 append 路径，平移量天然一致）；
/// - 每轨独立记录最近一次放行的平移 PTS，平移后不大于前值的样本（暂停边界在途的
///   迟到样本）返回 nil——macOS 27 writer 对回跳 PTS 会静默钳位到成片起点，必须在
///   上游挡住（早于锚点的校验仍由 recorder 的文件基锚点兜底负责，两者互补）。
struct PauseMediaClock {
    /// 媒体轨：视频与音频各持一条单调基线（暂停边界两侧的管道深度不同，护栏互不干扰）。
    enum Track {
        case video
        case audio
    }

    private var tracker = PauseTimeTracker()
    private(set) var isPaused = false
    /// 每轨最近一次放行的平移 PTS（`.invalid` = 尚未放行过）。
    private var lastShiftedVideo = CMTime.invalid
    private var lastShiftedAudio = CMTime.invalid

    init() {}

    /// 诊断只读：累计暂停时长。
    var accumulatedPause: CMTime { tracker.accumulatedPause }

    /// 开始暂停（幂等，首次时点生效）。`at` 用与媒体 PTS 同一 mach 时基的当前时刻；
    /// 暂停起点的记账不依赖后续帧到达（SCStream 静止画面不发帧，等首帧会漏记暂停段）。
    mutating func pause(at time: CMTime) {
        guard !isPaused else { return }
        isPaused = true
        tracker.pause(at: time)
    }

    /// 结束暂停（幂等）：此后平移量含本段暂停。
    mutating func resume(at time: CMTime) {
        guard isPaused else { return }
        isPaused = false
        tracker.resume(at: time)
    }

    /// 指定轨下一次 append 应使用的 PTS；返回 nil = 丢弃该样本（暂停中、PTS 非数值，
    /// 或平移后相对该轨不单调）。放行时推进该轨单调基线——各采样回调队列串行且按
    /// 原始 PTS 序交付，尝试顺序即样本顺序，基线因此恒为该轨已放行的最大平移值。
    mutating func shiftedPTS(_ raw: CMTime, for track: Track) -> CMTime? {
        guard !isPaused, raw.isNumeric else { return nil }
        let shifted = tracker.shifted(raw)
        switch track {
        case .video:
            guard monotonic(shifted, after: lastShiftedVideo) else { return nil }
            lastShiftedVideo = shifted
        case .audio:
            guard monotonic(shifted, after: lastShiftedAudio) else { return nil }
            lastShiftedAudio = shifted
        }
        return shifted
    }

    /// 平移后必须严格大于该轨前值：等于前值的两帧/两包同样会让 writer 钳位或拒绝。
    private func monotonic(_ candidate: CMTime, after last: CMTime) -> Bool {
        guard last.isValid, last.isNumeric else { return true }
        return CMTimeCompare(candidate, last) > 0
    }
}
