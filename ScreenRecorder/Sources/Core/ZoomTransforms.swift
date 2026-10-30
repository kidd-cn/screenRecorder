import CoreGraphics
import Foundation

/// 缩放变换唯一真源（P1a 实时合成与 P9 离线渲染共用，Task 1 简报钉定）：底帧归一化
/// 中心 + 档位 + 进度 → 底帧内容空间的仿射。纯 CoreGraphics（无 AppKit/SwiftUI），
/// P9 离线渲染器直接复用。
///
/// 数学：以有效档位 `s = 1 + (level-1)·easeInOut(progress)` 放大底帧，再平移使钳制后
/// 的中心点落到 bounds 中点（`scale.concatenating(translation)`，作用于内容点即
/// `p ↦ s·p + t`）。center 钳两道——先钳 0…1 归一化，再按有效档位钳进「缩放窗口允许
/// 范围」（每轴窗口半宽 = bounds 尺寸 / 2s）：窗口（viewport 逆映射回底帧的 bounds/s
/// 矩形）因此恒在 bounds 内，角点点击窗口恰好贴边、越界为零。
/// progress 0（=原始画面）与非法参数（level ≤ 1、bounds 空、非有限值）返回 nil，
/// 调用方按「无缩放」处理。
enum ZoomTransforms {
    /// 底帧归一化中心 0…1 钳制（`AutoZoomState.click` 与本函数共用的「同款钳制」前半；
    /// 档位/bounds 相关的窗口钳制在 `contentTransform` 内按有效档位进行）。
    static func clampedNormalizedCenter(_ point: CGPoint) -> CGPoint {
        CGPoint(x: clamped(point.x, to: 0...1), y: clamped(point.y, to: 0...1))
    }

    /// 当前缩放的仿射（viewport = bounds）。`center` 为底帧归一化坐标 0…1；
    /// `progress` 0=原始、1=满档位，缓动（easeInOut）在本函数内施加。
    static func contentTransform(center: CGPoint, level: CGFloat, progress: Double,
                                 in bounds: CGRect) -> CGAffineTransform? {
        guard level > 1, level.isFinite, progress.isFinite,
              center.x.isFinite, center.y.isFinite,
              bounds.width > 0, bounds.height > 0,
              bounds.width.isFinite, bounds.height.isFinite
        else { return nil }
        let easedInput = clamped(progress, to: 0...1)
        guard easedInput > 0 else { return nil } // progress 0 = 原始画面（无缩放）
        let scale = 1 + (level - 1) * CGFloat(easeInOut(easedInput))

        let normalized = clampedNormalizedCenter(center)
        let requested = CGPoint(x: bounds.minX + normalized.x * bounds.width,
                                y: bounds.minY + normalized.y * bounds.height)
        // 中心钳进缩放窗口允许范围：超出即窗口越出 bounds，钳到贴边
        let halfWidth = bounds.width / (2 * scale)
        let halfHeight = bounds.height / (2 * scale)
        let clampedCenter = CGPoint(
            x: clamped(requested.x, to: (bounds.minX + halfWidth)...(bounds.maxX - halfWidth)),
            y: clamped(requested.y, to: (bounds.minY + halfHeight)...(bounds.maxY - halfHeight)))

        let translation = CGPoint(x: bounds.midX - scale * clampedCenter.x,
                                  y: bounds.midY - scale * clampedCenter.y)
        return CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: translation.x, y: translation.y))
    }

    // MARK: 助手

    /// easeInOut（二次缓入缓出）：0/1 端点精确，中途单调。
    private static func easeInOut(_ progress: Double) -> Double {
        progress < 0.5 ? 2 * progress * progress : 1 - pow(-2 * progress + 2, 2) / 2
    }

    private static func clamped<Value: Comparable>(_ value: Value,
                                                   to range: ClosedRange<Value>) -> Value {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
