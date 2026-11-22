import XCTest

@testable import Hummingbird

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
        // zoom 平移语义（批次 1）：左界外钳到 −playheadWidth（线宽距离，线全隐）。
        XCTAssertEqual(ZoomTimelineGeometry.playheadX(playhead: -5, scale: 10, width: 100), -1.5)
        XCTAssertEqual(ZoomTimelineGeometry.playheadX(playhead: 100, scale: 10, width: 100), 98.5)
    }

    /// 缩放/平移映射钉测（2026-11-21 剪映对齐·批次 1）：time↔x 往返 + offset 钳制。
    func testZoomMappingAndOffsetClamp() {
        let pxPerSec = ZoomTimelineGeometry.pxPerSec(width: 664, sourceDuration: 48.4, zoom: 4)
        XCTAssertEqual(pxPerSec, 664 / 12.1, accuracy: 1e-9)
        XCTAssertEqual(ZoomTimelineGeometry.timeToX(15, pxPerSec: pxPerSec, offset: 10),
                       5 * pxPerSec, accuracy: 1e-9)
        XCTAssertEqual(
            ZoomTimelineGeometry.xToTime(ZoomTimelineGeometry.timeToX(15, pxPerSec: pxPerSec, offset: 10),
                                         pxPerSec: pxPerSec, offset: 10),
            15, accuracy: 1e-9, "time↔x 往返保值")
        XCTAssertEqual(ZoomTimelineGeometry.clampedOffset(100, sourceDuration: 48.4, zoom: 4),
                       48.4 - 12.1, accuracy: 1e-9, "右界 = 源时长 − 可视时长")
        XCTAssertEqual(ZoomTimelineGeometry.clampedOffset(-1, sourceDuration: 48.4, zoom: 4), 0)
        XCTAssertEqual(ZoomTimelineGeometry.clampedOffset(0, sourceDuration: 48.4, zoom: 1), 0,
                       "zoom 1 平移恒 0")
    }

    /// 吸附钉测（剪映对齐）：容差内吸最近磁点、容差外原值、零容差不吸附。
    func testSnappedToNearestCandidateWithinTolerance() {
        let candidates: [TimeInterval] = [0, 3.0, 3.19, 12.18, 48.4]
        XCTAssertEqual(ZoomTimelineGeometry.snapped(3.21, candidates: candidates, toleranceSeconds: 0.1),
                       3.19, "容差内吸最近磁点")
        XCTAssertEqual(ZoomTimelineGeometry.snapped(3.5, candidates: candidates, toleranceSeconds: 0.1),
                       3.5, "容差外原值")
        XCTAssertEqual(ZoomTimelineGeometry.snapped(3.05, candidates: candidates, toleranceSeconds: 0.1),
                       3.0, "等距取先入者（确定性）")
        XCTAssertEqual(ZoomTimelineGeometry.snapped(3.5, candidates: candidates, toleranceSeconds: 0),
                       3.5, "零容差 = 不吸附")
    }

    /// 磁吸主逻辑钉测（剪映对齐·粘滞/邻近/穿越/无吸附四态；穿越态是「快速拖动事件
    /// 合并跳过容差窗」的根因修复——磁吸「体感不存在」的解药）。
    func testMagnetSnap() {
        let candidates: [TimeInterval] = [0, 3.0, 3.19, 12.18, 48.4]
        // 邻近：容差内吸最近
        XCTAssertEqual(
            ZoomTimelineGeometry.magnetSnap(proposed: 3.15, previous: nil, activeSnap: nil,
                                            candidates: candidates, toleranceSeconds: 0.1)?.time,
            3.19)
        // 粘滞：上一吸附点在 1.5× 容差内 → 咬住不放（即使已出邻近容差）
        XCTAssertEqual(
            ZoomTimelineGeometry.magnetSnap(proposed: 3.32, previous: 3.32, activeSnap: 3.19,
                                            candidates: candidates, toleranceSeconds: 0.1)?.time,
            3.19, "1.5×容差内粘滞咬住")
        // 粘滞解除：拉出 1.5× 容差且邻近无磁点 → 无吸附
        XCTAssertNil(
            ZoomTimelineGeometry.magnetSnap(proposed: 3.4, previous: 3.32, activeSnap: 3.19,
                                            candidates: candidates, toleranceSeconds: 0.1))
        // 穿越：光标从 3.5 一步跳到 12.5（事件合并形态）——路径跨过 12.18 → 吸之
        XCTAssertEqual(
            ZoomTimelineGeometry.magnetSnap(proposed: 12.5, previous: 3.5, activeSnap: nil,
                                            candidates: candidates, toleranceSeconds: 0.1)?.time,
            12.18, "快速拖动跨越磁点也吸附")
        // 穿越：反方向
        XCTAssertEqual(
            ZoomTimelineGeometry.magnetSnap(proposed: 2.9, previous: 3.5, activeSnap: nil,
                                            candidates: candidates, toleranceSeconds: 0.1)?.time,
            3.0, "反向跨越同样吸附")
        // 无吸附：容差外且路径无磁点
        XCTAssertNil(
            ZoomTimelineGeometry.magnetSnap(proposed: 6.0, previous: 5.8, activeSnap: nil,
                                            candidates: candidates, toleranceSeconds: 0.1))
        // 零容差 = 磁吸关闭
        XCTAssertNil(
            ZoomTimelineGeometry.magnetSnap(proposed: 3.19, previous: 3.19, activeSnap: nil,
                                            candidates: candidates, toleranceSeconds: 0))
        // 穿越不吸「被拖段自身端点」的语义由调用方排除候选保证（magnetSnap 不再单测）
    }

    /// 波形桶区间钳制钉测（2026-11-21 draw 崩溃回归）：源时间超桶表时两端都钳。
    func testClampedBucketRange() {
        // 正常区间
        XCTAssertEqual(
            ZoomTimelineGeometry.clampedBucketRange(sourceStart: 0.30, sourceEnd: 0.50,
                                                    bucketSeconds: 0.02, count: 100),
            15...25)
        // 起点超桶表上界（音轨短于视频）→ 两端钳到 count-1，不越界
        XCTAssertEqual(
            ZoomTimelineGeometry.clampedBucketRange(sourceStart: 900, sourceEnd: 901,
                                                    bucketSeconds: 0.02, count: 100),
            99...99, "超上界钳 count-1（曾交换后越界崩溃）")
        // 负时间钳 0
        XCTAssertEqual(
            ZoomTimelineGeometry.clampedBucketRange(sourceStart: -1, sourceEnd: 0.04,
                                                    bucketSeconds: 0.02, count: 100),
            0...2)
        // 倒序区间自动交换
        XCTAssertEqual(
            ZoomTimelineGeometry.clampedBucketRange(sourceStart: 0.50, sourceEnd: 0.30,
                                                    bucketSeconds: 0.02, count: 100),
            15...25)
        XCTAssertNil(ZoomTimelineGeometry.clampedBucketRange(sourceStart: 0, sourceEnd: 1,
                                                             bucketSeconds: 0.02, count: 0))
    }

    /// 车道判定钉测（2026-11-22 双击音频道不加关键帧回归 + 剪映复刻改版）：
    /// 非翻转坐标 y=0 在底部，音频子行 = 底部 16pt。
    func testAudioLaneDetection() {
        let height: CGFloat = 84
        XCTAssertTrue(ZoomTimelineGeometry.isAudioLane(y: 0, height: height), "底边 = 音频子行")
        XCTAssertTrue(ZoomTimelineGeometry.isAudioLane(y: 15, height: height), "16pt 以内 = 音频子行")
        XCTAssertFalse(ZoomTimelineGeometry.isAudioLane(y: 16, height: height), "16pt 起 = 视频缩略图带")
        XCTAssertFalse(ZoomTimelineGeometry.isAudioLane(y: 80, height: height), "顶部（ruler 区）= 视频带")
        XCTAssertFalse(ZoomTimelineGeometry.isAudioLane(y: 10, height: 0), "零高退化")
    }

    /// 时间码钉测（剪映同款 HH:MM:SS:FF @30）。
    func testTimecodeFormat() {
        XCTAssertEqual(ZoomTimelineGeometry.timecode(0), "00:00:00:00")
        XCTAssertEqual(ZoomTimelineGeometry.timecode(13.939), "00:00:13:28",
                       "13.939×30 = 418.17 → 418 帧 = 13s28f")
        XCTAssertEqual(ZoomTimelineGeometry.timecode(3661.5), "01:01:01:15", "小时段")
        XCTAssertEqual(ZoomTimelineGeometry.timecode(-1), "—")
        XCTAssertEqual(ZoomTimelineGeometry.timecode(.nan), "—")
        XCTAssertEqual(ZoomTimelineGeometry.timecode(1, fps: 0), "—")
    }
}

/// 接缝号映射钉测（2026-11-22「多个删除没法设置转场」回归）：seamPositions 下标 j
/// ↔ 接缝号 j+1——裸下标曾致右键第一缝加转场被 validate 丢弃、其余缝错位一档。
final class SeamNumberMappingTests: XCTestCase {
    func testHitReturnsSeamNumberNotPositionIndex() {
        // 三 clip，接缝白线在 x = 100 / 200 / 300（位置下标 0/1/2 ↔ 接缝号 1/2/3）
        // 点第一条白线（位置下标 0）→ 接缝号 1（validate/转场键即此号）
        let first = ZoomTimelineGeometry.hit(
            at: CGPoint(x: 102, y: 30),
            zoomBlocks: [], seamPositions: [100, 200, 300], height: 64)
        guard case .seamHandle(let seam1) = first else {
            XCTFail("白线上应命中接缝，实得 \(first)")
            return
        }
        XCTAssertEqual(seam1, 1, "位置下标 0 → 接缝号 1（裸下标曾致此缝加转场被丢弃）")
        // 点第二条白线（位置下标 1）→ 接缝号 2
        let second = ZoomTimelineGeometry.hit(
            at: CGPoint(x: 202, y: 30),
            zoomBlocks: [], seamPositions: [100, 200, 300], height: 64)
        guard case .seamHandle(let seam2) = second else {
            XCTFail("第二条白线应命中接缝，实得 \(second)")
            return
        }
        XCTAssertEqual(seam2, 2, "位置下标 1 → 接缝号 2")
    }

    func testHitBackgroundBeyondHotzone() {
        let hit = ZoomTimelineGeometry.hit(
            at: CGPoint(x: 150, y: 30),
            zoomBlocks: [],
            seamPositions: [100, 200, 300],
            height: 64)
        XCTAssertEqual(hit, .background, "距白线 >4pt = 背景（波纹删除可武装）")
    }
}

/// 刻度尺钉测（剪映 01.png 像素复刻）：主刻度间隔自适应 + mm:ss 标签。
final class RulerTests: XCTestCase {
    func testRulerIntervalAdapts() {
        // 14px/s（zoom 1 @664pt/48.4s）：0.5s = 7pt ✗、1s = 14 ✗……3s = 41 ✗、5s = 70 ✗、10s = 140 ✓
        XCTAssertEqual(ZoomTimelineGeometry.rulerInterval(pxPerSec: 13.7), 10)
        // 高倍放大 200×：0.5s 即 ≥72pt
        XCTAssertEqual(ZoomTimelineGeometry.rulerInterval(pxPerSec: 300), 0.5)
        // 极低像素率全档不满足 → 回退最大 120s
        XCTAssertEqual(ZoomTimelineGeometry.rulerInterval(pxPerSec: 0.1), 120)
    }

    func testRulerLabel() {
        XCTAssertEqual(ZoomTimelineGeometry.rulerLabel(0), "00:00")
        XCTAssertEqual(ZoomTimelineGeometry.rulerLabel(3), "00:03")
        XCTAssertEqual(ZoomTimelineGeometry.rulerLabel(66), "01:06")
    }
}
