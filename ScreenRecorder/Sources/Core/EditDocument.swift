import CoreGraphics
import Foundation

/// 剪除段（剪辑 v1，2026-11-21 用户裁定「掐头去尾 + 删中段」）：成片时间轴上标记
/// **丢弃**的区间（半开 [start, end)，与 `ZoomSegment` 同区间口径）。Codable：段列表
/// 进 `EditDocument` 草稿持久化（与缩放段同一落盘面）。
struct CutSegment: Codable, Equatable {
    /// 剪除入点（成片时间轴秒，钳 ≥ 0）。
    var start: TimeInterval
    /// 剪除出点（> start；区间半开 [start, end)）。
    var end: TimeInterval

    /// 校验 + 规整（与 `ZoomSegment.validate` 同纪律：非法丢弃 / 钳制 / 排序 /
    /// 去重叠保留先者；首尾相接不算重叠——两段相邻剪除各自存活，折叠语义一致）。
    static func validate(_ segments: [CutSegment]) -> [CutSegment] {
        var cleaned: [CutSegment] = []
        cleaned.reserveCapacity(segments.count)
        for segment in segments {
            guard segment.start.isFinite, segment.end.isFinite else { continue }
            let start = max(0, segment.start)
            guard start < segment.end else { continue }
            cleaned.append(CutSegment(start: start, end: segment.end))
        }
        let sorted = cleaned.sorted {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }
        var result: [CutSegment] = []
        result.reserveCapacity(sorted.count)
        for segment in sorted {
            if let previous = result.last, segment.start < previous.end { continue } // 保留先者
            result.append(segment)
        }
        return result
    }
}

/// 剪辑文档（剪辑 v1 的 EDL，2026-11-21 审查裁定「后续剪辑能力都长在这个模型上」）：
/// 源成片 + 剪除段 + 缩放段的持久化面。**坐标系钉定：全部段都在源时间轴上**——渲染
/// 侧按源时间判断帧是否落在剔除段内（跳过）并平移 PTS，缩放段在源时间轴上照常查找
/// （「剔除优先」语义由跳帧自然成立：交集帧不存在即被剪，完全落入剔除段的缩放段
/// 自然作废，零重映射逻辑）。草稿落 `<成片>.zoomdraft.json`（沿用既有文件名——删除/
/// 重命名随删随移的既有生命周期零改动）。
struct EditDocument: Codable, Equatable {
    /// 剪除段（已过 validate：有序、无重叠）。
    var cuts: [CutSegment]
    /// 缩放段（已过 validate：有序、无重叠）。
    var zoomSegments: [ZoomSegment]

    static let empty = EditDocument(cuts: [], zoomSegments: [])

    /// 校验 + 规整：两段表各自过 validate（存/读两侧的统一闸）。
    static func validate(_ document: EditDocument) -> EditDocument {
        EditDocument(
            cuts: CutSegment.validate(document.cuts),
            zoomSegments: ZoomSegment.validate(document.zoomSegments))
    }
}

/// 剪辑时间线纯函数（无头钉测面）：保留区间、源→输出时间映射、播放跳剪、拖选提案
/// 修剪。折叠语义的唯一真源——渲染器（PTS 平移）、编辑器（时长估算/预览跳剪）、
/// 钉测三方共用。
enum EditTimeline {
    /// 剪除段交互/提交的最短时长（秒）：防误触（与 `ZoomEditorLogic.minimumSegmentDuration`
    /// 同量级；validate 硬约束仍是 `start < end`，本下限是交互闸）。
    static let minimumCutDuration: TimeInterval = 0.1

    /// 保留区间 = [0, duration) − cuts（cuts 防御性重排序；超界剪除段按求交自然裁剪）。
    /// 返回升序不重叠的闭开区间数组；duration ≤ 0 → 空表。
    static func keptRanges(cuts: [CutSegment],
                           duration: TimeInterval) -> [(start: TimeInterval, end: TimeInterval)] {
        guard duration.isFinite, duration > 0 else { return [] }
        let sorted = CutSegment.validate(cuts)
        var ranges: [(start: TimeInterval, end: TimeInterval)] = []
        var cursor: TimeInterval = 0
        for cut in sorted {
            let start = min(max(cut.start, 0), duration)
            let end = min(max(cut.end, 0), duration)
            guard end > cursor else { continue }
            if start > cursor {
                ranges.append((cursor, min(start, duration)))
            }
            cursor = max(cursor, end)
            if cursor >= duration { break }
        }
        if cursor < duration {
            ranges.append((cursor, duration))
        }
        return ranges.filter { $0.end > $0.start }
    }

    /// 源时间 → 输出时间（剔除段之后的帧平移 −其前剪除总量）；`t` 落在任一剪除段内
    /// → nil（该帧不进输出）。cuts 须已过 validate（内部不再排序——逐帧热路径）。
    static func outputSeconds(forSourceSeconds t: TimeInterval,
                              cuts: [CutSegment]) -> TimeInterval? {
        var shift: TimeInterval = 0
        for cut in cuts {
            if t < cut.start { break } // 已排序：后续剪除段全在 t 之后
            if t < cut.end { return nil } // 半开区间内 → 剪除
            shift += cut.end - cut.start
        }
        return t - shift
    }

    /// 有效剪除总量（秒）：各剪除段与 [0, duration] 求交后的长度和（供时长估算）。
    static func totalCutSeconds(cuts: [CutSegment], duration: TimeInterval) -> TimeInterval {
        guard duration.isFinite, duration > 0 else { return 0 }
        return CutSegment.validate(cuts).reduce(0) { total, cut in
            let start = min(max(cut.start, 0), duration)
            let end = min(max(cut.end, 0), duration)
            return total + max(end - start, 0)
        }
    }

    /// 播放跳剪（预览「播放头跳过剔除段连续播放」语义）：`t` 落在剪除段内则跳到段尾，
    /// 相邻剪除段链式跳过（validate 允许首尾相接）。不在剪除段内 → 原值。
    static func skipCuts(from t: TimeInterval, cuts: [CutSegment]) -> TimeInterval {
        var time = t
        let sorted = CutSegment.validate(cuts)
        while let cut = sorted.first(where: { $0.start <= time && time < $0.end }) {
            time = cut.end
        }
        return time
    }

    /// 拖选剪除提案修剪（时间线空白处拖选的提交闸）：提案先钳进 [0, sourceDuration]，
    /// 再减去与既有剪除段的重叠（提案 sweeping 过既有红块时只保留**含拖拽锚点**的
    /// 子区间——交互语义「从锚点起剪」），剩余长度不足最短剪除时长 → nil（本次拖选
    /// 不产生剪除段）。
    static func trimCutProposal(anchor: TimeInterval,
                                proposedStart: TimeInterval,
                                proposedEnd: TimeInterval,
                                existingCuts: [CutSegment],
                                sourceDuration: TimeInterval,
                                minimum: TimeInterval = EditTimeline.minimumCutDuration) -> (start: TimeInterval, end: TimeInterval)? {
        var start = min(max(min(proposedStart, proposedEnd), 0), max(0, sourceDuration))
        var end = min(max(max(proposedStart, proposedEnd), 0), max(0, sourceDuration))
        let existing = CutSegment.validate(existingCuts)
        // 锚点落在既有剪除段内的退化形态（时间线命中红块不会进入背景拖选，兜底）：
        // 结果收窄到该段右侧，直接出结果。
        if let blocking = existing.first(where: { $0.start <= anchor && anchor < $0.end }) {
            start = max(start, blocking.end)
            end = max(end, start)
            guard end - start >= minimum else { return nil }
            return (start, end)
        }
        // 从锚点侧向两端扩张，遇既有剪除段即止：
        // - 锚点左侧相交的剪除段 → 抬起 start（提案向左扫过红块不吞它）；
        // - 锚点右侧相交的剪除段 → 压低 end（右扩截断）。
        for cut in existing {
            if cut.start >= end { break } // 已排序：后续剪除段全在提案右侧之外
            if cut.end <= start { continue } // 完全在提案左侧之外
            if cut.end <= anchor {
                start = max(start, cut.end)
            } else {
                end = min(end, cut.start)
            }
        }
        guard end - start >= minimum else { return nil }
        return (start, end)
    }
}
