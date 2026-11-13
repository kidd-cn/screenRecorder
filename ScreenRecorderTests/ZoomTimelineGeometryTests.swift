import XCTest

@testable import ScreenRecorder

/// 时间线条几何钉测（交互层修复）：时间 → 像素映射、把手/段体/背景命中分区、
/// 播放头钳制。旧版这些常量埋在 SwiftUI 视图里（DragGesture 坐标换算），
/// 迁移到 AppKit 后在此钉死。
final class ZoomTimelineGeometryTests: XCTestCase {
    func testScaleIsWidthOverDuration() {
        XCTAssertEqual(ZoomTimelineGeometry.scale(width: 600, sourceDuration: 60), 10)
        XCTAssertEqual(ZoomTimelineGeometry.scale(width: 300, sourceDuration: 2), 150)
    }

    func testScaleDegradesToPositiveFloorWhenDurationNotReady() {
        // 源时长 0（媒体信息未就绪）→ 600 / 0.001（旧版 max(0.001) 同款退化口径）。
        XCTAssertEqual(
            ZoomTimelineGeometry.scale(width: 600, sourceDuration: 0),
            600 / 0.001,
            accuracy: 1e-6)
    }

    func testBlocksMapTimeRangeToPixels() {
        let blocks = ZoomTimelineGeometry.blocks(
            ranges: [(index: 0, start: 1, end: 3), (index: 1, start: 5, end: 6)],
            scale: 10,
            height: 64)
        XCTAssertEqual(blocks, [
            ZoomTimelineGeometry.Block(index: 0, rect: CGRect(x: 10, y: 4, width: 20, height: 56)),
            ZoomTimelineGeometry.Block(index: 1, rect: CGRect(x: 50, y: 4, width: 10, height: 56))
        ])
    }

    func testBlocksClampNegativeStartToZero() {
        let blocks = ZoomTimelineGeometry.blocks(
            ranges: [(index: 0, start: -2, end: 1)], scale: 10, height: 64)
        XCTAssertEqual(blocks[0].rect.minX, 0)
        XCTAssertEqual(blocks[0].rect.width, 30) // 端差 3s × 10（宽按端差不按起点钳制）
    }

    func testZeroLengthSegmentKeepsMinimumVisibleWidth() {
        let blocks = ZoomTimelineGeometry.blocks(
            ranges: [(index: 0, start: 1, end: 1)], scale: 10, height: 64)
        XCTAssertEqual(blocks[0].rect.width, ZoomTimelineGeometry.minimumBlockWidth)
    }

    func testHitBackgroundOutsideAllBlocks() {
        let blocks = ZoomTimelineGeometry.blocks(
            ranges: [(index: 0, start: 1, end: 3)], scale: 10, height: 64)
        XCTAssertEqual(ZoomTimelineGeometry.hit(at: CGPoint(x: 5, y: 30), in: blocks), .background)
        XCTAssertEqual(ZoomTimelineGeometry.hit(at: CGPoint(x: 100, y: 30), in: blocks), .background)
        // 纵向越界（块带外）也算背景——段块只占 [4, 60]。
        XCTAssertEqual(ZoomTimelineGeometry.hit(at: CGPoint(x: 20, y: 1), in: blocks), .background)
    }

    func testHitSplitsBlockIntoLeadingBodyTrailing() {
        // 块 x ∈ [10, 30)：把手各 8pt → 前把手 x ≤ 18、后把手 x ≥ 22、段体 18 < x < 22。
        let blocks = ZoomTimelineGeometry.blocks(
            ranges: [(index: 0, start: 1, end: 3)], scale: 10, height: 64)
        XCTAssertEqual(ZoomTimelineGeometry.hit(at: CGPoint(x: 12, y: 30), in: blocks), .leadingHandle(index: 0))
        XCTAssertEqual(ZoomTimelineGeometry.hit(at: CGPoint(x: 20, y: 30), in: blocks), .segment(index: 0))
        XCTAssertEqual(ZoomTimelineGeometry.hit(at: CGPoint(x: 28, y: 30), in: blocks), .trailingHandle(index: 0))
    }

    func testNarrowBlockPrefersLeadingHandle() {
        // 最小宽 2pt 的窄段：两端把手重叠，入点把手优先（与视觉自左向右一致）。
        let blocks = ZoomTimelineGeometry.blocks(
            ranges: [(index: 0, start: 1, end: 1)], scale: 10, height: 64)
        XCTAssertEqual(
            ZoomTimelineGeometry.hit(at: CGPoint(x: 10.5, y: 30), in: blocks),
            .leadingHandle(index: 0))
    }

    func testHitReturnsOwnIndexForEachBlock() {
        // 块 0 x∈[0,20)、块 1 x∈[40,60)；各取把手区内一点（minX+3 < 把手宽 8）。
        let blocks = ZoomTimelineGeometry.blocks(
            ranges: [(index: 0, start: 0, end: 2), (index: 1, start: 4, end: 6)],
            scale: 10, height: 64)
        XCTAssertEqual(ZoomTimelineGeometry.hit(at: CGPoint(x: 3, y: 30), in: blocks), .leadingHandle(index: 0))
        XCTAssertEqual(ZoomTimelineGeometry.hit(at: CGPoint(x: 43, y: 30), in: blocks), .leadingHandle(index: 1))
        // 段体区（两端把手之间）同样按块归属。
        XCTAssertEqual(ZoomTimelineGeometry.hit(at: CGPoint(x: 10, y: 30), in: blocks), .segment(index: 0))
        XCTAssertEqual(ZoomTimelineGeometry.hit(at: CGPoint(x: 50, y: 30), in: blocks), .segment(index: 1))
    }

    func testPlayheadXClampsToStripBounds() {
        XCTAssertEqual(ZoomTimelineGeometry.playheadX(playhead: 2, scale: 10, width: 100), 20)
        XCTAssertEqual(ZoomTimelineGeometry.playheadX(playhead: -5, scale: 10, width: 100), 0)
        XCTAssertEqual(ZoomTimelineGeometry.playheadX(playhead: 100, scale: 10, width: 100), 98.5)
    }
}
