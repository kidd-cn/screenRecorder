import CoreGraphics
import Foundation

/// 离线缩放时间线段（P9）：一次「点击自动缩放」在成片时间轴上的区间。
/// `center` 为底帧归一化坐标（与实时 `ZoomTransforms` 消费口径一致——0…1 归一化钳制
/// 在 `validate` 时做，档位/窗口钳制在 `ZoomTransforms.contentTransform` 内按有效档位做）。
/// Codable：段列表是 P9 分析产物的持久化面（JSON 落库，与 `CaptureMode` 同纪律）。
struct ZoomSegment: Codable, Equatable {
    /// 缩放入点（成片时间轴秒，钳 ≥ 0）。
    var start: TimeInterval
    /// 缩放出点（> start；区间半开 [start, end)——出点时刻已回到原始画面）。
    var end: TimeInterval
    /// 缩放档位（合法 1.35/1.6/1.9，校验时钳到最近档）。
    var level: Double
    /// 缩放中心（底帧归一化 0…1）。
    var center: CGPoint

    /// 合法档位集合（与 `SettingsStore.autoZoomLevel` 的 1.35/1.6/1.9 同一档位族）。
    static let levels: [Double] = [1.35, 1.6, 1.9]

    /// 校验 + 规整（P9 渲染管线的前置闸——离线渲染与后续分析产物落库共用）：
    /// 1. 丢弃非法段——任一字段非有限（不可钳）、或钳制后 `start >= end`（`start < end`
    ///    约束不可钳，只能丢）；
    /// 2. 钳制——start 钳 ≥ 0（时间轴非负）；level 钳到最近合法档位；center 经
    ///    `ZoomTransforms.clampedNormalizedCenter` 钳 0…1（与实时 `AutoZoomState.click`
    ///    同款钳制前半——窗口钳制留给 `contentTransform`）；
    /// 3. 排序——按 (start, end) 升序（同键段值相等与否不影响结果集确定性：完全相同
    ///    的段谁留谁丢等价）；
    /// 4. 去重叠——顺序扫描，当前段 start 严格早于**已保留**前段的 end 即重叠
    ///    （比较对象是最后保留者，被丢段不参与），**保留先者**、丢当前。区间半开
    ///    [start, end)：首尾相接（前 end == 后 start）不算重叠。
    static func validate(_ segments: [ZoomSegment]) -> [ZoomSegment] {
        var cleaned: [ZoomSegment] = []
        cleaned.reserveCapacity(segments.count)
        for var segment in segments {
            guard segment.start.isFinite, segment.end.isFinite, segment.level.isFinite,
                  segment.center.x.isFinite, segment.center.y.isFinite
            else { continue }
            segment.start = max(0, segment.start)
            segment.level = nearestLevel(segment.level)
            segment.center = ZoomTransforms.clampedNormalizedCenter(segment.center)
            guard segment.start < segment.end else { continue }
            cleaned.append(segment)
        }
        let sorted = cleaned.sorted {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }
        var result: [ZoomSegment] = []
        result.reserveCapacity(sorted.count)
        for segment in sorted {
            if let previous = result.last, segment.start < previous.end { continue } // 保留先者
            result.append(segment)
        }
        return result
    }

    /// 最近合法档位（1.35/1.6/1.9）：低于最低档归 1.35、高于最高档归 1.9、中间取距最近。
    private static func nearestLevel(_ level: Double) -> Double {
        var nearest = levels[0]
        for candidate in levels.dropFirst()
        where abs(level - candidate) < abs(level - nearest) {
            nearest = candidate
        }
        return nearest
    }
}
