import Combine
import CoreGraphics
import Foundation

/// 标记颜色（P2 边录边标记）：RGB 0…1 三通道的值类型。Codable（随笔画可序列化，
/// 为后续快照落盘留口）。预设两色为简报钉定的工具条常量——Task 5 的色/宽选择直接
/// 引用这里的 `static let`，不散落字面量。
struct MarkingColor: Equatable, Codable {
    var red: Double
    var green: Double
    var blue: Double

    /// 钉定预设：黑（简报 0,0,0）。
    static let black = MarkingColor(red: 0, green: 0, blue: 0)
    /// 钉定预设：红（简报 1,0.23,0.19）。
    static let red = MarkingColor(red: 1, green: 0.23, blue: 0.19)
}

/// 一条笔画：点列 + 颜色 + 线宽。points 为**底帧归一化坐标 0…1**（与 Task 2 缩放中心
/// 同一归一化空间：(0,0) 底帧左上、x 右 y 下）——内容锚定，缩放时笔画跟随内容而非
/// viewport。width 为归一化线宽：于底帧**短边**归一（渲染方按底帧短边 × width 换算
/// 像素），简报钉定两档 0.004/0.008，本类型只存 Double 不解释（画布不持档位常量）。
struct MarkingStroke: Equatable, Codable {
    var points: [CGPoint]
    var color: MarkingColor
    var width: Double
}

/// 合成器每帧入参的笔画快照（值类型）：`MarkingCanvas.snapshot` 产出，经 Task 5 的
/// `strokeOverlayProvider` 过河到合成线程。Equatable 供测试与去重。
struct MarkingStrokeSnapshot: Equatable {
    var strokes: [MarkingStroke]
}

/// 标记画布（P2 核心，纯逻辑）：begin/extend/end 生命周期累积笔画，undo/clear 管理，
/// `snapshot` 产出合成器每帧入参。@MainActor（输入事件侧独占写）；无 Date、无屏幕
/// API——headless 纪律，任意事件源（Task 5 覆盖层拖拽 / 测试）可驱动。
///
/// 生命周期语义（本实现钉定，Task 5 消费）：
/// - `beginStroke` 点越出 0…1（NaN/∞ 同判越界）时不开始笔画：该次拖拽不成笔，
///   后续 extend 亦无笔画可续，直至下一次 begin（出界拖拽起点不烧入画面）；
/// - `extendStroke` 在 begin 之前 / end 之后是安全 no-op（不断言不崩溃）；点越出
///   0…1 时仅丢弃该点——笔画断续继续，回到界内即续写，不分裂笔画；
/// - `undoLast` 撤销最后一笔；若撤的正是进行中的那一笔，视同终止（后续 extend 不再
///   续写已撤销的笔画）。空栈撤销安全 no-op。
@MainActor
final class MarkingCanvas: ObservableObject {
    /// 全部笔画（begin 顺序）。`@Published`：工具条撤销/清空按钮态可观测
    /// （Task 5）；写仅在 begin/extend/undo/clear，读随便。
    @Published private(set) var strokes: [MarkingStroke] = []

    /// 进行中笔画的下标（begin 置位；end/undo/clear 失效）；nil = 无进行中笔画。
    /// begin 恒追加到末尾，故该下标（若非 nil）恒指向最后一笔。
    private var activeStrokeIndex: Int?

    /// 开始一笔（点为底帧归一化 0…1；越界/非有限不成笔，见类文档）。
    func beginStroke(color: MarkingColor, width: Double, at point: CGPoint) {
        guard Self.isInUnitSquare(point) else { return }
        strokes.append(MarkingStroke(points: [point], color: color, width: width))
        activeStrokeIndex = strokes.count - 1
    }

    /// 进行中笔画追加一点；越出 0…1 丢弃该点（笔画断续继续，不分裂）。
    func extendStroke(to point: CGPoint) {
        guard let index = activeStrokeIndex, Self.isInUnitSquare(point) else { return }
        strokes[index].points.append(point)
    }

    /// 结束当前笔画（此后 extend 为 no-op，直至下一次 begin）。重复 end 安全 no-op。
    func endStroke() {
        activeStrokeIndex = nil
    }

    /// 撤销最后一笔（空栈 no-op）。
    func undoLast() {
        guard !strokes.isEmpty else { return }
        strokes.removeLast()
        // 撤的可能正是进行中的那一笔：一并终止，extend 不得续写已撤销的笔画
        activeStrokeIndex = nil
    }

    /// 清空全部笔画。
    func clear() {
        strokes.removeAll()
        activeStrokeIndex = nil
    }

    /// 当前笔画快照（值拷贝）：合成器每帧入参的安全前提——取出后画布再怎么改
    /// （续写/撤销/清空）都不影响已取快照。`[MarkingStroke]` 值语义 + 写时复制保证：
    /// 此处 O(1) 浅拷，画布后续原地写自动触发拷贝分离。
    var snapshot: MarkingStrokeSnapshot {
        MarkingStrokeSnapshot(strokes: strokes)
    }

    /// viewport 点 → 底帧点的逆映射（Task 1 变换可逆性消费）：对当前缩放仿射取逆
    /// 施加。`zoomTransform` 为 `ZoomTransforms.contentTransform` 的 base→viewport
    /// 输出，且为非可选——调用方把 contentTransform 的 nil（progress 0 / 非法参数）
    /// 先解成 `.identity` 再调用；identity 原样返回该点（无缩放 = 坐标直通）。
    ///
    /// 坐标空间即变换自身空间（contentTransform 的底帧 bounds 点空间，viewport =
    /// bounds）；`bounds` 为口径对称参数（调用方以它求变换），不参与本函数求值。
    /// 奇异阵（正常缩放不会出现）按 CoreGraphics 语义回退 identity。
    static func baseFramePoint(fromViewport point: CGPoint,
                               zoomTransform: CGAffineTransform,
                               bounds: CGRect) -> CGPoint {
        point.applying(zoomTransform.inverted())
    }

    /// 0…1 归一化防御（NaN/∞ 的比较为 false，天然落入丢弃分支，无需特判）。
    private static func isInUnitSquare(_ point: CGPoint) -> Bool {
        (0...1).contains(point.x) && (0...1).contains(point.y)
    }
}
