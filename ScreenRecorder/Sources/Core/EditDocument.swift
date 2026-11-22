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

/// 配乐轨（剪辑 v2 批次 4b）：导入的本地音频文件（security-scoped bookmark 锚定）+
/// 音量。渲染后与成片混音（循环铺满成片时长）。
struct EditMusicTrack: Codable, Equatable {
    /// 用户选定文件的 security-scoped bookmark（沙盒访问凭证）。
    var bookmark: Data
    /// 展示名（文件名）。
    var name: String
    /// 音量（0…1，默认 0.5——配乐盖过人声是常见事故）。
    var volume: Double
}

/// 画面裁剪（剪映 01.png 剪刀「裁剪」功能复刻）：四边内缩比例（0…0.45，成对和 ≤0.9）。
/// 语义：成片画布尺寸不变，裁掉区域填黑（内容保持原位）——CapCut 同款。
struct EditCrop: Codable, Equatable {
    var left: Double
    var top: Double
    var right: Double
    var bottom: Double

    init(left: Double = 0, top: Double = 0, right: Double = 0, bottom: Double = 0) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    static let maxInset: Double = 0.45

    var isIdentity: Bool {
        abs(left) < 1e-4 && abs(top) < 1e-4 && abs(right) < 1e-4 && abs(bottom) < 1e-4
    }

    /// 钳制：各边 0…0.45；成对和超 0.9 时按比例压回（保证至少 10% 可视）。
    var validated: EditCrop {
        var crop = EditCrop(
            left: min(max(left, 0), Self.maxInset),
            top: min(max(top, 0), Self.maxInset),
            right: min(max(right, 0), Self.maxInset),
            bottom: min(max(bottom, 0), Self.maxInset))
        let horizontal = crop.left + crop.right
        if horizontal > 0.9 {
            let scale = 0.9 / horizontal
            crop.left *= scale
            crop.right *= scale
        }
        let vertical = crop.top + crop.bottom
        if vertical > 0.9 {
            let scale = 0.9 / vertical
            crop.top *= scale
            crop.bottom *= scale
        }
        return crop
    }
}

/// 片段间转场（剪辑 v2 批次 4c-2）：挂在**接缝**上（clips[i-1] 与 clips[i] 之间，
/// 键 = i ∈ 1..<clips.count）。转场窗口 [boundary − d/2, boundary + d/2) 占用两侧
/// 各半——成片总时长不变（占用两侧素材的头尾）。v1 两种：黑场 / 交叉溶解。
struct EditTransition: Codable, Equatable {
    enum Kind: String, Codable {
        case black
        case crossfade
    }

    var kind: Kind
    var duration: TimeInterval

    init(kind: Kind, duration: TimeInterval = 1.0) {
        self.kind = kind
        self.duration = min(max(duration, Self.durationRange.lowerBound),
                            Self.durationRange.upperBound)
    }

    /// 合法时长区间（秒；剪映档位同量级）。
    static let durationRange: ClosedRange<TimeInterval> = 0.2...2.0
}

/// 音量关键帧（剪辑 v2 批次 4c-2）：**成品时间轴**上锚定的原声音量点。相邻帧线性
/// 插值；首帧前取首帧值、末帧后取末帧值；无关键帧 → 自动首尾 0.5s 淡入淡出（4c-1）。
struct EditKeyframe: Codable, Equatable {
    var outputTime: TimeInterval
    var volume: Double

    init(outputTime: TimeInterval, volume: Double) {
        self.outputTime = outputTime
        self.volume = volume
    }

    /// 关键帧集校验 + 规整：时间有限非负、音量钳 0…1、**先排序后去重**（1e-6 内保留
    /// 先者——去重若在排序前执行，无序输入会把更早时间误判为重复而丢弃）。
    static func validate(_ keyframes: [EditKeyframe]) -> [EditKeyframe] {
        var cleaned: [EditKeyframe] = []
        for var keyframe in keyframes {
            guard keyframe.outputTime.isFinite, keyframe.outputTime >= 0,
                  keyframe.volume.isFinite else { continue }
            keyframe.volume = min(max(keyframe.volume, 0), 1)
            cleaned.append(keyframe)
        }
        let sorted = cleaned.sorted { $0.outputTime < $1.outputTime }
        var result: [EditKeyframe] = []
        for keyframe in sorted {
            if let previous = result.last, keyframe.outputTime - previous.outputTime < 1e-6 {
                continue // 去重保留先者
            }
            result.append(keyframe)
        }
        return result
    }

    /// 插值（纯函数）：帧间线性；首帧前=首帧值；末帧后=末帧值；空集 → nil（回退自动淡入淡出）。
    static func volume(atOutputTime t: TimeInterval, keyframes: [EditKeyframe]) -> Double? {
        let sorted = keyframes // validate 后有序；调用方闸保证
        guard let first = sorted.first else { return nil }
        if t <= first.outputTime { return first.volume }
        guard let last = sorted.last else { return nil }
        if t >= last.outputTime { return last.volume }
        for (previous, next) in zip(sorted, sorted.dropFirst()) where t >= previous.outputTime && t <= next.outputTime {
            let span = next.outputTime - previous.outputTime
            guard span > 1e-9 else { return next.volume }
            let progress = (t - previous.outputTime) / span
            return previous.volume + (next.volume - previous.volume) * progress
        }
        return last.volume
    }
}

/// 剪辑文档（剪辑 v2 片段流 EDL，2026-11-21 剪映对齐批次 4a；4b 增原声/配乐音轨字段；4c-2 增音量关键帧）：
/// 源成片 + 有序片段 + 缩放段（zoom 段恒定义在**源时间轴**——渲染逐源帧查找不变）。
/// **坐标系钉定**：
/// 时间线 UI 与播放头都在**成品时间轴**；源↔成品双向映射（含速度折算）是唯一真源
///（`sourceTime(forOutputTime:)` / `outputTime(forSourceTime:)`）。草稿落
/// `<成片>.zoomdraft.json`（v1 剪除段草稿加载时自动迁移为 clips）。
struct EditDocument: Codable, Equatable {
    /// 有序片段（validate 后：按源时间升序、无重叠、源长 ≥ 最短约束、速度合法）。
    var clips: [EditClip]
    /// 缩放段（源时间轴；validate 同 ZoomSegment）。
    var zoomSegments: [ZoomSegment]
    /// 原声（源成片自带音轨）音量 0…1（1 = 原样；批次 4b）。
    var sourceVolume: Double
    /// 配乐轨（nil = 未导入；批次 4b）。
    var backgroundMusic: EditMusicTrack?
    /// 音量关键帧（成品时间轴；空 = 自动首尾淡入淡出；批次 4c-2）。
    var keyframes: [EditKeyframe]
    /// 接缝转场（键 = 接缝下标 = 该接缝右侧 clip 的下标；批次 4c-2）。
    var transitions: [Int: EditTransition]
    /// 画面裁剪（nil = 不裁；批次 4c-2 裁剪复刻）。
    var crop: EditCrop?

    static let empty = EditDocument(clips: [], zoomSegments: [])

    /// 手写 Codable（旧版草稿缺字段 → 默认值 decodeIfPresent）。
    enum CodingKeys: String, CodingKey {
        case clips, zoomSegments, sourceVolume, backgroundMusic, keyframes, transitions, crop
    }

    init(clips: [EditClip], zoomSegments: [ZoomSegment],
         sourceVolume: Double = 1, backgroundMusic: EditMusicTrack? = nil,
         keyframes: [EditKeyframe] = [], transitions: [Int: EditTransition] = [:],
         crop: EditCrop? = nil) {
        self.clips = clips
        self.zoomSegments = zoomSegments
        self.sourceVolume = sourceVolume
        self.backgroundMusic = backgroundMusic
        self.keyframes = EditKeyframe.validate(keyframes)
        self.transitions = transitions
        self.crop = crop?.validated
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clips = try container.decodeIfPresent([EditClip].self, forKey: .clips) ?? []
        zoomSegments = try container.decodeIfPresent([ZoomSegment].self, forKey: .zoomSegments) ?? []
        sourceVolume = try container.decodeIfPresent(Double.self, forKey: .sourceVolume) ?? 1
        backgroundMusic = try container.decodeIfPresent(EditMusicTrack.self, forKey: .backgroundMusic)
        keyframes = EditKeyframe.validate(
            try container.decodeIfPresent([EditKeyframe].self, forKey: .keyframes) ?? [])
        // Int 键字典走 [String: EditTransition] 落地（JSON 对象形态更稳）
        let decodedTransitions = try container.decodeIfPresent(
            [String: EditTransition].self, forKey: .transitions) ?? [:]
        var parsed: [Int: EditTransition] = [:]
        for (key, value) in decodedTransitions {
            if let index = Int(key) { parsed[index] = value }
        }
        transitions = parsed
        crop = try container.decodeIfPresent(EditCrop.self, forKey: .crop)?.validated
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(clips, forKey: .clips)
        try container.encode(zoomSegments, forKey: .zoomSegments)
        try container.encode(sourceVolume, forKey: .sourceVolume)
        try container.encodeIfPresent(backgroundMusic, forKey: .backgroundMusic)
        try container.encode(keyframes, forKey: .keyframes)
        let stringKeys = Dictionary(uniqueKeysWithValues: transitions.map { (String($0.key), $0.value) })
        try container.encode(stringKeys, forKey: .transitions)
        try container.encodeIfPresent(crop, forKey: .crop)
    }

    /// 最短片段源长（秒；validate 硬约束——交互闸另设更宽裕的手感下限）。
    static let minimumClipSourceDuration: TimeInterval = 0.05
    /// 速度合法区间（钳制用；UI 档位子集）。
    static let speedRange: ClosedRange<Double> = 0.25...4

    /// 初始文档：单 clip 全程原速（新建编辑的起点）。
    static func initial(duration: TimeInterval, keyframes: [EditKeyframe] = []) -> EditDocument {
        guard duration.isFinite, duration > 0 else { return empty }
        return EditDocument(clips: [EditClip(sourceStart: 0, sourceEnd: duration)], zoomSegments: [],
                            keyframes: keyframes)
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
        // 转场过滤：接缝下标须 ∈ 1..<clips.count（首缝之前/末缝之后无转场）；时长钳制
        var transitions: [Int: EditTransition] = [:]
        for (seam, transition) in document.transitions
        where seam >= 1 && seam < clips.count {
            transitions[seam] = EditTransition(kind: transition.kind, duration: transition.duration)
        }
        return EditDocument(clips: clips, zoomSegments: ZoomSegment.validate(document.zoomSegments),
                            sourceVolume: document.sourceVolume, backgroundMusic: document.backgroundMusic,
                            keyframes: document.keyframes, transitions: transitions,
                            crop: document.crop?.validated)
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

    /// 原声增益（批次 4c-2）：有关键帧 → 插值；无 → 自动首尾 0.5s 淡入淡出曲线。
    /// `sourceVolume`（全局音量）由调用方另行乘积。
    func sourceGain(atOutputTime t: TimeInterval, fadeSeconds: TimeInterval) -> Double {
        if let keyframed = EditKeyframe.volume(atOutputTime: t, keyframes: keyframes) {
            return keyframed
        }
        var gain = 1.0
        if fadeSeconds > 0, t < fadeSeconds { gain *= t / fadeSeconds }
        let fromEnd = outputDuration - t
        if fadeSeconds > 0, fromEnd < fadeSeconds { gain *= max(fromEnd, 0) / fadeSeconds }
        return gain
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
        // 关键帧随接合平移：删除区间内的丢弃，右侧 −(hi−lo) 平移（validate 去重）
        let shift = hi - lo
        let shiftedKeyframes = keyframes.compactMap { keyframe -> EditKeyframe? in
            guard keyframe.outputTime < lo else { return nil }
            return keyframe
        } + keyframes.compactMap { keyframe -> EditKeyframe? in
            guard keyframe.outputTime > hi else { return nil }
            return EditKeyframe(outputTime: keyframe.outputTime - shift, volume: keyframe.volume)
        }
        var document = EditDocument.validate(EditDocument(
            clips: result, zoomSegments: zoomSegments,
            sourceVolume: sourceVolume, backgroundMusic: backgroundMusic,
            keyframes: shiftedKeyframes))
        // 转场随波纹删除重定位：与删除区间相交的窗口丢弃；其余接缝按新边界重算下标
        var repositioned: [Int: EditTransition] = [:]
        let oldBoundaries = seamBoundaries(of: clips)
        let newBoundaries = seamBoundaries(of: document.clips)
        for (seam, transition) in transitions {
            guard seam >= 1, seam <= oldBoundaries.count else { continue }
            let boundary = oldBoundaries[seam - 1]
            let half = transition.duration / 2
            if boundary + half > lo && boundary - half < hi { continue } // 相交 → 丢弃
            let newBoundary = boundary - min(max(boundary - lo, 0), hi - lo)
            if let newIndex = newBoundaries.firstIndex(where: { abs($0 - newBoundary) < 1e-6 }) {
                let newSeam = newIndex + 1
                if newSeam < document.clips.count { repositioned[newSeam] = transition }
            }
        }
        document.transitions = repositioned
        return document
    }

    /// 接缝边界（成品时间，第 i 项 = 剪掉后第 i+1 个 clip 的起点，含末边界）。
    func seamBoundaries(of clips: [EditClip]) -> [TimeInterval] {
        var cursor: TimeInterval = 0
        return clips.map { clip in
            cursor += clip.displayDuration
            return cursor
        }
    }

    /// 成品时间的转场状态（纯函数）：命中窗口 → (kind, progress 0…1)；否则 nil。
    func transitionState(atOutputTime t: TimeInterval) -> (kind: EditTransition.Kind, progress: Double)? {
        guard !transitions.isEmpty else { return nil }
        let boundaries = seamBoundaries(of: clips)
        for (seam, transition) in transitions {
            guard seam >= 1, seam <= boundaries.count else { continue }
            let boundary = boundaries[seam - 1]
            let half = transition.duration / 2
            let start = boundary - half
            let end = boundary + half
            guard t >= start, t < end else { continue }
            return (transition.kind, (t - start) / max(transition.duration, 1e-9))
        }
        return nil
    }

    /// 黑场转场增益（纯函数）：窗口内 |progress − 0.5| × 2 后过 **0.2 平台 + smoothstep**
    /// ——中点附近 20% 窗口持续全黑（线性三角的「全黑」仅一帧，观感一闪而过——
    /// 2026-11-22 用户反馈），两端平滑回到 1。溶解转场音频不处理（返回 1）。
    func blackTransitionGain(atOutputTime t: TimeInterval) -> Double {
        guard let state = transitionState(atOutputTime: t), state.kind == .black else { return 1 }
        let linear = min(max(abs(state.progress - 0.5) * 2, 0), 1)
        let plateau = 0.2
        guard linear > plateau else { return 0 }
        let x = min((linear - plateau) / (1 - plateau), 1)
        return x * x * (3 - 2 * x) // smoothstep
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
        return EditDocument.validate(EditDocument(clips: clips, zoomSegments: zoomSegments,
                                                  sourceVolume: sourceVolume, backgroundMusic: backgroundMusic,
                                                  keyframes: keyframes, transitions: transitions,
                                                  crop: crop))
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
