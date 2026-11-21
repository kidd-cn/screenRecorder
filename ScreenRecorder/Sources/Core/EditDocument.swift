import CoreGraphics
import Foundation

/// 剪辑片段（剪辑 v2 片段流·剪映同构）：时间线 = 有序 clip 拼接成的**成品轨**。
/// 波纹删除/接缝修剪/变速全部作用在 clips 上；原文件只读不动。
struct EditClip: Codable, Equatable {
    /// 源入点（源时间轴秒，钳 ≥ 0）。
    var sourceStart: TimeInterval
    /// 源出点（> sourceStart；半开 [sourceStart, sourceEnd)）。
    var sourceEnd: TimeInterval
    /// 播放速度（> 0；1 = 原速；显示时长 = (sourceEnd − sourceStart) / speed）。
    var speed: Double

    init(sourceStart: TimeInterval, sourceEnd: TimeInterval, speed: Double = 1) {
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.speed = speed
    }

    /// 显示时长（成品轨上的秒数）。
    var displayDuration: TimeInterval { (sourceEnd - sourceStart) / speed }
}

/// 剪辑文档（剪辑 v2 片段流 EDL，2026-11-21 剪映对齐批次 4a）：源成片 + 有序片段 +
/// 缩放段（zoom 段恒定义在**源时间轴**——渲染逐源帧查找不变）。**坐标系钉定**：
/// 时间线 UI 与播放头都在**成品时间轴**；源↔成品双向映射（含速度折算）是唯一真源
///（`sourceTime(forOutputTime:)` / `outputTime(forSourceTime:)`）。草稿落
/// `<成片>.zoomdraft.json`（v1 剪除段草稿加载时自动迁移为 clips）。
struct EditDocument: Codable, Equatable {
    /// 有序片段（validate 后：按源时间升序、无重叠、源长 ≥ 最短约束、速度合法）。
    var clips: [EditClip]
    /// 缩放段（源时间轴；validate 同 ZoomSegment）。
    var zoomSegments: [ZoomSegment]

    static let empty = EditDocument(clips: [], zoomSegments: [])

    /// 最短片段源长（秒；validate 硬约束——交互闸另设更宽裕的手感下限）。
    static let minimumClipSourceDuration: TimeInterval = 0.05
    /// 速度合法区间（钳制用；UI 档位子集）。
    static let speedRange: ClosedRange<Double> = 0.25...4

    /// 初始文档：单 clip 全程原速（新建编辑的起点）。
    static func initial(duration: TimeInterval) -> EditDocument {
        guard duration.isFinite, duration > 0 else { return empty }
        return EditDocument(clips: [EditClip(sourceStart: 0, sourceEnd: duration)], zoomSegments: [])
    }

    /// 校验 + 规整：clips 非法丢弃/钳制/排序/去重叠保留先者；zoom 段过既有闸。
    static func validate(_ document: EditDocument) -> EditDocument {
        var cleaned: [EditClip] = []
        for var clip in document.clips {
            guard clip.sourceStart.isFinite, clip.sourceEnd.isFinite, clip.speed.isFinite else { continue }
            clip.sourceStart = max(0, clip.sourceStart)
            clip.speed = min(max(clip.speed, Self.speedRange.lowerBound), Self.speedRange.upperBound)
            guard clip.sourceEnd - clip.sourceStart >= Self.minimumClipSourceDuration else { continue }
            cleaned.append(clip)
        }
        let sorted = cleaned.sorted { $0.sourceStart < $1.sourceStart }
        var clips: [EditClip] = []
        for clip in sorted {
            if let previous = clips.last, clip.sourceStart < previous.sourceEnd { continue } // 重叠保留先者
            clips.append(clip)
        }
        return EditDocument(clips: clips, zoomSegments: ZoomSegment.validate(document.zoomSegments))
    }

    // MARK: 源↔成品双向映射（折叠真源——渲染 PTS、预览 seek、UI 铺排共用）

    /// 成片总时长（Σ 显示时长）。
    var outputDuration: TimeInterval {
        clips.reduce(0) { $0 + $1.displayDuration }
    }

    /// 成品时间 → 源时间（二分定位 clip；t ∈ [0, outputDuration] 之外 → nil）。
    /// 映射：s = clip.sourceStart + (t − clip 输出起点) × clip.speed。
    func sourceTime(forOutputTime t: TimeInterval) -> TimeInterval? {
        guard t.isFinite, t >= 0 else { return nil }
        var outputCursor: TimeInterval = 0
        for clip in clips {
            let span = clip.displayDuration
            if t <= outputCursor + span {
                return clip.sourceStart + (t - outputCursor) * clip.speed
            }
            outputCursor += span
        }
        return nil
    }

    /// 源时间 → 成品时间（s 落在裁掉区间 / 任何 clip 之外 → nil——该帧不进成品）。
    /// 映射：t = clip 输出起点 + (s − clip.sourceStart) / clip.speed。
    func outputTime(forSourceTime s: TimeInterval) -> TimeInterval? {
        guard s.isFinite, s >= 0 else { return nil }
        var outputCursor: TimeInterval = 0
        for clip in clips {
            if s >= clip.sourceStart, s < clip.sourceEnd {
                return outputCursor + (s - clip.sourceStart) / clip.speed
            }
            outputCursor += clip.displayDuration
        }
        return nil
    }

    /// s 所在 clip 的速度（不在任何 clip → nil）。
    func speed(atSourceTime s: TimeInterval) -> Double? {
        for clip in clips where s >= clip.sourceStart && s < clip.sourceEnd {
            return clip.speed
        }
        return nil
    }

    // MARK: 剪映式编辑操作（纯函数——模型统一闸 + 钉测共用）

    /// 波纹删除（输出坐标 [lower, upper)）：跨接处的 clip 拆分/收缩/消亡，其余平移
    /// 接合——时间线无空洞。lower/upper 钳进 [0, outputDuration]；空集/退化 → 原文档。
    func removingOutputRange(lower: TimeInterval, upper: TimeInterval) -> EditDocument {
        let lo = min(max(min(lower, upper), 0), outputDuration)
        let hi = min(max(max(lower, upper), 0), outputDuration)
        guard hi - lo >= 1e-9 else { return self }
        var result: [EditClip] = []
        var outputCursor: TimeInterval = 0
        for clip in clips {
            let clipStart = outputCursor
            let clipEnd = outputCursor + clip.displayDuration
            outputCursor = clipEnd
            // clip 与删除区间的输出交集
            let a = max(lo, clipStart)
            let b = min(hi, clipEnd)
            guard b > a else {
                result.append(clip) // 不相交 → 原样保留
                continue
            }
            // 保留前段 [clipStart, a) 与后段 [b, clipEnd)（输出→源换算）
            if a - clipStart > Self.minimumClipSourceDuration {
                let sourceCut = clip.sourceStart + (a - clipStart) * clip.speed
                result.append(EditClip(
                    sourceStart: clip.sourceStart, sourceEnd: sourceCut, speed: clip.speed))
            }
            if clipEnd - b > Self.minimumClipSourceDuration {
                let sourceCut = clip.sourceStart + (b - clipStart) * clip.speed
                result.append(EditClip(
                    sourceStart: sourceCut, sourceEnd: clip.sourceEnd, speed: clip.speed))
            }
        }
        return EditDocument.validate(EditDocument(clips: result, zoomSegments: zoomSegments))
    }

    /// 接缝移动（剪映 trim 语义）：seamIndex ∈ 0...clips.count——0 = 片头裁切
    ///（clips[0].sourceStart）、count = 片尾裁切（last.sourceEnd）、i = 内接缝
    ///（clips[i-1].sourceEnd 与 clips[i].sourceStart 共享移动到 s：右移 = 找回删除
    /// 区间、左移 = 扩大删除）。越界/越邻界/源长不足 → nil。
    func movingSeam(at seamIndex: Int, toSourceTime s: TimeInterval) -> EditDocument? {
        guard s.isFinite, s >= 0 else { return nil }
        var clips = self.clips
        switch seamIndex {
        case 0:
            guard let first = clips.first else { return nil }
            guard s < first.sourceEnd - Self.minimumClipSourceDuration else { return nil }
            clips[0].sourceStart = s
        case clips.count:
            guard let last = clips.last else { return nil }
            guard s > last.sourceStart + Self.minimumClipSourceDuration else { return nil }
            clips[clips.count - 1].sourceEnd = s
        default:
            guard clips.indices.contains(seamIndex), seamIndex < clips.count else { return nil }
            let left = clips[seamIndex - 1]
            let right = clips[seamIndex]
            let lowerBound = max(left.sourceStart, 0) + Self.minimumClipSourceDuration
            let upperBound = min(right.sourceEnd - Self.minimumClipSourceDuration,
                                 left.sourceEnd + (Self.speedRange.upperBound) * 1) // 右移找回上限 = 右 clip 允许的源延伸由 validate 收口
            guard s >= lowerBound, s <= max(upperBound, lowerBound) else { return nil }
            clips[seamIndex - 1].sourceEnd = s
            clips[seamIndex].sourceStart = s
        }
        return EditDocument.validate(EditDocument(clips: clips, zoomSegments: zoomSegments))
    }

    /// 缩放段映射到成品时间轴（UI 铺排用；渲染按源时间查找不走此函数）：
    /// 每个 zoom 段与每 clip 源区间求交 → 截断 → 平移到输出起点 ÷ 速度（拆成多段），
    /// 再过 ZoomSegment.validate。
    func mappedZoomSegments() -> [ZoomSegment] {
        var mapped: [ZoomSegment] = []
        var outputCursor: TimeInterval = 0
        for clip in clips {
            for segment in zoomSegments {
                let a = max(segment.start, clip.sourceStart)
                let b = min(segment.end, clip.sourceEnd)
                guard b > a else { continue }
                let outStart = outputCursor + (a - clip.sourceStart) / clip.speed
                let outEnd = outputCursor + (b - clip.sourceStart) / clip.speed
                mapped.append(ZoomSegment(
                    start: outStart, end: outEnd, level: segment.level, center: segment.center))
            }
            outputCursor += clip.displayDuration
        }
        return ZoomSegment.validate(mapped)
    }

    /// 是否含剪辑痕迹（命名分流：有 → `_剪辑.mp4`；纯单 clip 原速全覆盖 → `_缩放.mp4`）。
    /// `sourceDuration` 供首尾裁切判断。
    func hasEdits(sourceDuration: TimeInterval) -> Bool {
        if clips.count > 1 { return true }
        if let first = clips.first {
            if first.speed != 1 { return true }
            if first.sourceStart > 0.01 { return true }
            if sourceDuration.isFinite, sourceDuration > 0, first.sourceEnd < sourceDuration - 0.01 { return true }
        }
        return false
    }

    // MARK: v1 迁移（剪除段标记 → 片段流）

    /// 从 v1 剪除段列表迁移：保留区间（[0, duration) − cuts）→ 逐段 clip（原速）。
    /// `duration` 为源时长（迁移必需——保留区间的右边界）。
    static func migrating(cuts: [(start: TimeInterval, end: TimeInterval)],
                          duration: TimeInterval) -> EditDocument {
        let kept = EditDocument.keptRanges(cuts: cuts, duration: duration)
        let clips = kept.map { EditClip(sourceStart: $0.start, sourceEnd: $0.end) }
        return EditDocument.validate(EditDocument(clips: clips, zoomSegments: []))
    }

    /// 保留区间 = [0, duration) − cuts（v1 迁移内部用；升序不重叠闭开区间）。
    private static func keptRanges(cuts: [(start: TimeInterval, end: TimeInterval)],
                                   duration: TimeInterval) -> [(start: TimeInterval, end: TimeInterval)] {
        guard duration.isFinite, duration > 0 else { return [] }
        let sorted = cuts.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        var ranges: [(start: TimeInterval, end: TimeInterval)] = []
        var cursor: TimeInterval = 0
        for cut in sorted {
            let start = min(max(cut.start, 0), duration)
            let end = min(max(cut.end, 0), duration)
            guard end > cursor else { continue }
            if start > cursor { ranges.append((cursor, min(start, duration))) }
            cursor = max(cursor, end)
            if cursor >= duration { break }
        }
        if cursor < duration { ranges.append((cursor, duration)) }
        return ranges.filter { $0.end > $0.start }
    }
}

/// v1 剪除段（仅作旧草稿迁移解码面；运行时模型已裁撤）。
struct CutSegment: Codable, Equatable {
    var start: TimeInterval
    var end: TimeInterval
}
