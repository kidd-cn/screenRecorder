import CoreMedia

/// 暂停时间记账：把调用方传入的墙钟时间戳平移为去除暂停段的内容时间戳。
/// 纯值类型：无 I/O、无时钟，所有时间戳由调用方提供；
/// CMTime 的 +/- 运算符自行处理跨 timescale 重标定，此处不做手写乘算。
struct PauseTimeTracker {
    /// 累计暂停时长，初始 .zero。
    private(set) var accumulatedPause: CMTime = .zero

    /// 当前暂停段起点；nil 表示未在暂停中。
    private var pauseStart: CMTime?

    /// 显式 init：存在私有存储属性时合成 memberwise init 会退化为私有，无法从外部构造。
    init() {}

    /// 开始一段暂停；已暂停时重复调用为幂等（首次时间戳生效）。
    mutating func pause(at time: CMTime) {
        guard pauseStart == nil else { return }
        pauseStart = time
    }

    /// 结束当前暂停段：`accumulatedPause += resume.at − pause.at`；未暂停时无操作。
    mutating func resume(at time: CMTime) {
        guard let start = pauseStart else { return }
        accumulatedPause = accumulatedPause + (time - start)
        pauseStart = nil
    }

    /// `t − accumulatedPause`；结果不允许为负，负则返回 `.zero`。
    func shifted(_ t: CMTime) -> CMTime {
        let result = t - accumulatedPause
        return CMTimeCompare(result, .zero) < 0 ? .zero : result
    }
}
