import Combine
import CoreGraphics
import Foundation

/// 点击自动缩放时间线（P1a）：attack(0.25s) → hold(1.0s) → release(0.4s) → idle。
/// 纯逻辑、无 I/O、不读墙钟——所有时间点由调用方注入 `now`（与 PauseMediaClock /
/// ClickHighlightTracker.evaluate 同一 headless 纪律），任意时钟口径可用。
///
/// 时间线语义（Task 1 简报钉定）：
/// - `click` 任意相位可入：hold/release 中再点击以新中心重启 attack；点击点先经
///   `ZoomTransforms` 同款钳制（0…1 归一化钳制在此处，档位/bounds 相关的窗口钳制
///   在 `currentTransform` → `ZoomTransforms.contentTransform` 内按有效档位进行）；
/// - `tick(now:)` 仅推进已发布相位（`phase`），不计算变换；
/// - `currentTransform(in:now:)` 纯读：由点击锚点与 now 推导进度求值变换——调用方
///   漏 tick 也不影响正确性（合成热路径每帧只需这一个调用点）；
/// - idle / 时间线走完 / progress 0 → nil，调用方按无缩放直通。
///
/// 时长常量为单一真源（Task 17 裁定）：P9 离线渲染直接引用本类 static let，
/// init 缺省值亦出自它们。
@MainActor
final class AutoZoomState: ObservableObject {
    /// 攻击时长（秒，简报钉死 0.25）。`nonisolated`：init 缺省值与 P9 离线渲染
    /// （非主 actor 上下文）直接引用，不可变常量跨隔离安全。
    nonisolated static let attackDuration: TimeInterval = 0.25
    /// 保持时长（秒，简报钉死 1.0）。
    nonisolated static let holdDuration: TimeInterval = 1.0
    /// 回弹时长（秒，简报钉死 0.4）。
    nonisolated static let releaseDuration: TimeInterval = 0.4

    /// 时间线相位（`tick` 推进，接线/UI 层可观测）。
    enum Phase: Equatable {
        case idle
        case attack
        case hold
        case release
    }

    /// 当前相位（仅 `click` / `tick` / `reset` 写；`currentTransform` 纯读不写）。
    @Published private(set) var phase: Phase = .idle

    private let level: CGFloat
    private let attackDuration: TimeInterval
    private let holdDuration: TimeInterval
    private let releaseDuration: TimeInterval
    /// 锚点快照锁（Task 2 接线）：MainActor 侧写（click/reset）、SCStream video 队列经
    /// `frameTransform` 读——NSLock 保护单个不可变快照（锁内一次结构体拷贝），与
    /// ClickHighlightTracker 的合成热路径纪律同款：不加额外分配。
    private let timelineLock = NSLock()
    /// 最近一次点击锚点（时刻 + 已钳 0…1 的归一化中心）；nil = idle。一律锁内读写；
    /// `nonisolated(unsafe)` 为跨线程读缝（frameTransform）豁免 actor 隔离——线程安全
    /// 由 timelineLock 保证（锁内单快照拷贝），与 ClickHighlightTracker.lastClick 同纪律。
    nonisolated(unsafe) private var clickAnchor: (time: TimeInterval, center: CGPoint)?

    init(level: CGFloat,
         attackDuration: TimeInterval = AutoZoomState.attackDuration,
         holdDuration: TimeInterval = AutoZoomState.holdDuration,
         releaseDuration: TimeInterval = AutoZoomState.releaseDuration) {
        self.level = level
        self.attackDuration = attackDuration
        self.holdDuration = holdDuration
        self.releaseDuration = releaseDuration
    }

    /// 记录一次点击（任意相位可入）：以点击点为新中心重启 attack。
    /// 非有限坐标防御性忽略（与 `ClickHighlightTracker.evaluate` 的野值防御同纪律）。
    func click(atNormalizedPoint point: CGPoint, now: TimeInterval) {
        guard point.x.isFinite, point.y.isFinite else { return }
        timelineLock.lock()
        clickAnchor = (now, ZoomTransforms.clampedNormalizedCenter(point))
        timelineLock.unlock()
        phase = .attack
    }

    /// 推进相位到 now（不计算变换——变换只经 `currentTransform` 求值）。
    func tick(now: TimeInterval) {
        phase = phaseAt(now: now)
    }

    /// now 时刻的缩放仿射（viewport = bounds）：idle/走完/progress 0 → nil。纯读。
    func currentTransform(in bounds: CGRect, now: TimeInterval) -> CGAffineTransform? {
        guard let anchor = timelineSnapshot(),
              let progress = Self.progress(of: anchor,
                                           now: now,
                                           attack: attackDuration,
                                           hold: holdDuration,
                                           release: releaseDuration)
        else { return nil }
        return ZoomTransforms.contentTransform(center: anchor.center,
                                               level: level,
                                               progress: progress,
                                               in: bounds)
    }

    /// now 时刻的缩放仿射——**非隔离读缝**（Task 2：SCStream video 队列逐帧调用）。
    /// 合成回调不能同步进 MainActor（逐帧 main sync 是热路径反模式），故锚点走锁内
    /// 快照、锁外求值；时间线推导与 `currentTransform(in:now:)` 共用同一个私有 static
    /// `progress`（单一真源，不存在并行实现）。零分配：锚点为值类型快照，求值纯
    /// CoreGraphics。
    nonisolated func frameTransform(in bounds: CGRect, now: TimeInterval) -> CGAffineTransform? {
        guard let anchor = timelineSnapshot(),
              let progress = Self.progress(of: anchor,
                                           now: now,
                                           attack: attackDuration,
                                           hold: holdDuration,
                                           release: releaseDuration)
        else { return nil }
        return ZoomTransforms.contentTransform(center: anchor.center,
                                               level: level,
                                               progress: progress,
                                               in: bounds)
    }

    /// 清空时间线回 idle（录制收尾清态，同 `ClickHighlightTracker.stop` 的残影防御语义）。
    func reset() {
        timelineLock.lock()
        clickAnchor = nil
        timelineLock.unlock()
        phase = .idle
    }

    // MARK: 相位/进度推导（now 注入，无副作用）

    /// 锁内锚点快照（一次结构体拷贝；MainActor 与非隔离读共用）。
    private nonisolated func timelineSnapshot() -> (time: TimeInterval, center: CGPoint)? {
        timelineLock.lock()
        defer { timelineLock.unlock() }
        return clickAnchor
    }

    private func phaseAt(now: TimeInterval) -> Phase {
        guard let anchor = timelineSnapshot() else { return .idle }
        let elapsed = max(0, now - anchor.time) // 时钟回拨钳回攻击起点
        if elapsed < attackDuration { return .attack }
        if elapsed < attackDuration + holdDuration { return .hold }
        if elapsed < attackDuration + holdDuration + releaseDuration { return .release }
        return .idle
    }

    /// 缩放进度 0…1（线性相位位置；nil = 无缩放）——缓动由 `contentTransform` 施加。
    /// MainActor 版与非隔离 video 队列版共用的单一推导。
    private nonisolated static func progress(of anchor: (time: TimeInterval, center: CGPoint),
                                             now: TimeInterval,
                                             attack: TimeInterval,
                                             hold: TimeInterval,
                                             release: TimeInterval) -> Double? {
        let elapsed = max(0, now - anchor.time) // 时钟回拨钳回攻击起点
        if elapsed < attack { return elapsed / attack }
        if elapsed < attack + hold { return 1 }
        if elapsed < attack + hold + release {
            return 1 - (elapsed - attack - hold) / release
        }
        return nil
    }
}
