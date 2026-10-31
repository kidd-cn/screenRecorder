import CoreGraphics
import XCTest

@testable import ScreenRecorder

/// MarkingStroke / MarkingCanvas 纯逻辑钉测（Task 4 简报 Step 1）。
/// 全部纯值逻辑驱动（无 Date、无屏幕 API——headless 硬纪律）；逆映射用
/// `ZoomTransforms.contentTransform` 造变换做往返钉（Task 1 变换可逆性的消费口径）。
@MainActor
final class MarkingCanvasTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)

    /// 浮点噪声容差（仿射正逆往返为纯 Double 乘加，相对误差远小于视觉精度）。
    private static let accuracy: CGFloat = 1e-9

    // MARK: 简报钉测

    func testStrokeAccumulatesPoints() {
        let canvas = MarkingCanvas()

        // begin 之前的 extend 是文档钉定的安全 no-op（不断言、不崩溃、不产笔画）
        canvas.extendStroke(to: CGPoint(x: 0.5, y: 0.5))
        XCTAssertTrue(canvas.strokes.isEmpty, "begin 前 extend 应为安全 no-op")

        canvas.beginStroke(color: .black, width: 0.004, at: CGPoint(x: 0.1, y: 0.2))
        canvas.extendStroke(to: CGPoint(x: 0.3, y: 0.4))
        canvas.extendStroke(to: CGPoint(x: 0.5, y: 0.6))
        canvas.endStroke()

        XCTAssertEqual(canvas.strokes.count, 1)
        let stroke = canvas.strokes[0]
        XCTAssertEqual(stroke.points, [
            CGPoint(x: 0.1, y: 0.2),
            CGPoint(x: 0.3, y: 0.4),
            CGPoint(x: 0.5, y: 0.6),
        ], "笔画应按顺序累积 begin + extend 的点")
        XCTAssertEqual(stroke.color, .black, "颜色应随笔画记录")
        XCTAssertEqual(stroke.width, 0.004, "线宽应随笔画记录（窄档 0.004）")
    }

    func testExtendOutsideUnitSquareDropsPoint() {
        let canvas = MarkingCanvas()
        canvas.beginStroke(color: .red, width: 0.008, at: CGPoint(x: 0.5, y: 0.5))

        canvas.extendStroke(to: CGPoint(x: 1.2, y: 0.5)) // 越出 0…1（右侧）
        canvas.extendStroke(to: CGPoint(x: -0.1, y: 0.5)) // 越出 0…1（左侧）
        XCTAssertEqual(canvas.strokes[0].points.count, 1, "越界点应丢弃，不追加")

        canvas.extendStroke(to: CGPoint(x: 0.7, y: 0.5)) // 回到 0…1 → 续上
        XCTAssertEqual(canvas.strokes.count, 1, "越界丢弃不分裂笔画")
        XCTAssertEqual(canvas.strokes[0].points, [
            CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 0.7, y: 0.5),
        ], "回到界内后笔画应续写（丢弃点只是不追加）")

        // 边界恰在 1.0：0…1 为闭区间，边界点保留（复审轮 1 钉定）
        canvas.extendStroke(to: CGPoint(x: 1.0, y: 1.0))
        XCTAssertEqual(canvas.strokes[0].points.last, CGPoint(x: 1.0, y: 1.0),
                       "边界点 1.0 属闭区间 0…1，应保留")
        XCTAssertEqual(canvas.strokes.count, 1, "边界点不分裂笔画")

        // 非有限点（NaN/∞）：contains 比较为 false，同落丢弃分支（复审轮 1 钉定）
        canvas.extendStroke(to: CGPoint(x: CGFloat.nan, y: .infinity))
        XCTAssertEqual(canvas.strokes[0].points.count, 3, "非有限点应丢弃，不追加")

        // begin 路径同款防御：非有限起点不成笔
        let nonFiniteCanvas = MarkingCanvas()
        nonFiniteCanvas.beginStroke(color: .black, width: 0.004,
                                    at: CGPoint(x: CGFloat.nan, y: .infinity))
        XCTAssertTrue(nonFiniteCanvas.strokes.isEmpty, "非有限起点的 begin 不成笔")
    }

    func testUndoRemovesLastStrokeOnly() {
        let canvas = MarkingCanvas()
        canvas.beginStroke(color: .black, width: 0.004, at: CGPoint(x: 0.1, y: 0.1))
        canvas.endStroke()
        canvas.beginStroke(color: .red, width: 0.008, at: CGPoint(x: 0.9, y: 0.9))
        canvas.endStroke()

        canvas.undoLast()
        XCTAssertEqual(canvas.strokes.count, 1, "撤销只移除最后一笔")
        XCTAssertEqual(canvas.strokes[0].color, .black, "更早的笔画保留")
        XCTAssertEqual(canvas.strokes[0].width, 0.004, "保留笔画的线宽不变")

        canvas.undoLast()
        XCTAssertTrue(canvas.strokes.isEmpty)
        canvas.undoLast() // 空栈撤销：安全 no-op
        XCTAssertTrue(canvas.strokes.isEmpty)

        // 撤销进行中的笔画 = 终止：续写下标失效，后续 extend 不得复活已撤销的
        // 笔画（复审轮 1 钉定，Task 5 消费语义）
        canvas.beginStroke(color: .red, width: 0.008, at: CGPoint(x: 0.3, y: 0.3))
        canvas.extendStroke(to: CGPoint(x: 0.4, y: 0.4))
        XCTAssertEqual(canvas.strokes.count, 1)
        canvas.undoLast()
        canvas.extendStroke(to: CGPoint(x: 0.5, y: 0.5))
        XCTAssertTrue(canvas.strokes.isEmpty, "撤销进行中的笔画后，extend 不得复活它")
    }

    func testClearEmptiesAll() {
        let canvas = MarkingCanvas()
        canvas.beginStroke(color: .black, width: 0.004, at: CGPoint(x: 0.1, y: 0.1))
        canvas.endStroke()
        canvas.beginStroke(color: .red, width: 0.008, at: CGPoint(x: 0.9, y: 0.9))
        canvas.endStroke()

        canvas.clear()
        XCTAssertTrue(canvas.strokes.isEmpty, "清空应移除全部笔画")
        XCTAssertTrue(canvas.snapshot.strokes.isEmpty, "快照口径同样为空")
    }

    /// Task 1 消费口径：contentTransform 造当前缩放仿射，viewport 点经本函数逆映射
    /// 回底帧点应等于原点（round-trip）。另钉调用方口径：contentTransform 返回 nil
    /// （非法参数）→ 先解成 identity 再调用，identity 原样返回该点。
    func testBaseFramePointInvertsZoomTransform() throws {
        let zoomCases: [(center: CGPoint, level: CGFloat, progress: Double)] = [
            (CGPoint(x: 0.5, y: 0.5), 1.6, 1.0),
            (CGPoint(x: 0.2, y: 0.8), 1.9, 0.5),
            (CGPoint(x: 0.0, y: 0.0), 1.35, 1.0), // 角点：钳制贴边路径
        ]
        for zoomCase in zoomCases {
            let transform = try XCTUnwrap(
                ZoomTransforms.contentTransform(center: zoomCase.center,
                                                level: zoomCase.level,
                                                progress: zoomCase.progress,
                                                in: bounds),
                "center=\(zoomCase.center) level=\(zoomCase.level) 应产出变换")
            // 取点于放大窗口内（窗口 = viewport 逆映射回底帧，恒在 bounds 内）
            let window = bounds.applying(transform.inverted())
            let basePoints = [
                CGPoint(x: window.midX, y: window.midY),
                CGPoint(x: window.midX + window.width * 0.25, y: window.midY - window.height * 0.25),
                CGPoint(x: window.minX + 1, y: window.maxY - 1),
            ]
            for basePoint in basePoints {
                let viewport = basePoint.applying(transform)
                let roundTripped = MarkingCanvas.baseFramePoint(fromViewport: viewport,
                                                                zoomTransform: transform,
                                                                bounds: bounds)
                XCTAssertEqual(roundTripped.x, basePoint.x, accuracy: Self.accuracy,
                               "\(zoomCase.center) x 应逆映射回原底帧点")
                XCTAssertEqual(roundTripped.y, basePoint.y, accuracy: Self.accuracy,
                               "\(zoomCase.center) y 应逆映射回原底帧点")
            }
        }

        // 调用方口径：contentTransform 的 nil（此处 level ≤ 1）先解成 identity——
        // identity 逆映射必须原样返回该点（文档钉定，无缩放时笔画即屏幕坐标）。
        let nilResolved = ZoomTransforms.contentTransform(center: .zero, level: 1, progress: 1,
                                                          in: bounds) ?? .identity
        let point = CGPoint(x: 37.5, y: 62.5)
        XCTAssertEqual(MarkingCanvas.baseFramePoint(fromViewport: point,
                                                    zoomTransform: nilResolved,
                                                    bounds: bounds),
                       point,
                       "identity（含 nil→identity 解析）应原样返回该点")
    }

    func testSnapshotIsValueCopy() {
        let canvas = MarkingCanvas()
        canvas.beginStroke(color: .black, width: 0.004, at: CGPoint(x: 0.1, y: 0.1))
        canvas.extendStroke(to: CGPoint(x: 0.2, y: 0.2))
        let snapshot = canvas.snapshot

        // 快照之后画布继续变：旧快照必须原封不动（合成器每帧入参的值拷贝前提）
        canvas.extendStroke(to: CGPoint(x: 0.3, y: 0.3))
        canvas.beginStroke(color: .red, width: 0.008, at: CGPoint(x: 0.9, y: 0.9))
        XCTAssertEqual(snapshot.strokes.count, 1, "旧快照不随后续新增笔画增长")
        XCTAssertEqual(snapshot.strokes[0].points.count, 2, "旧快照不随后续点位增长")
        XCTAssertEqual(canvas.strokes.count, 2, "画布本身照常累积")
        XCTAssertEqual(canvas.strokes[0].points.count, 3)

        canvas.clear()
        XCTAssertEqual(snapshot.strokes.count, 1, "清空画布不影响已取快照")
        XCTAssertEqual(canvas.snapshot.strokes.count, 0, "新快照反映清空后的状态")
    }
}
