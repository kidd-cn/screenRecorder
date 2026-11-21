import AVFoundation
import CoreGraphics
import XCTest

@testable import Hummingbird

/// 剪辑 v1 核心纯函数钉测：`CutSegment.validate` / `EditDocument.validate`（规整纪律
/// 与 ZoomSegment 同款）、`EditTimeline` 折叠缝（保留区间 / 源→输出映射 / 跳剪 /
/// 拖选提案修剪）。折叠语义是渲染器（PTS 平移）、编辑器（时长估算/预览跳剪）的
/// 单一真源——本文件即契约。
final class EditDocumentTests: XCTestCase {
    // MARK: CutSegment.validate

    func testCutValidateDropsNonFiniteAndBackwards() {
        let valid = CutSegment(start: 1, end: 2)
        XCTAssertEqual(CutSegment.validate([
            valid,
            CutSegment(start: .nan, end: 2), // 非有限丢弃
            CutSegment(start: 1, end: .infinity), // 非有限丢弃
            CutSegment(start: -3, end: -1), // 钳 start≥0 后 start<end 失败 → 丢
            CutSegment(start: 2, end: 2), // 零长丢弃
            CutSegment(start: 3, end: 1), // 倒序丢弃
        ]), [valid])
    }

    func testCutValidateSortsAndKeepsFirstOnOverlapAllowsTouching() {
        let first = CutSegment(start: 1, end: 3)
        let touching = CutSegment(start: 3, end: 4)
        let sorted = CutSegment.validate([
            CutSegment(start: 5, end: 6), touching, first,
            CutSegment(start: 2, end: 4), // 与 first 重叠（保留先者）→ 丢
        ])
        XCTAssertEqual(sorted, [first, touching, CutSegment(start: 5, end: 6)],
                       "排序 + 去重叠保留先者；首尾相接不算重叠")
    }

    // MARK: EditDocument.validate

    func testEditDocumentValidateRunsBothGates() {
        let document = EditDocument.validate(EditDocument(
            cuts: [CutSegment(start: 2, end: 1), CutSegment(start: 0, end: 1)],
            zoomSegments: [ZoomSegment(start: 1, end: 2, level: 9.9, center: CGPoint(x: 5, y: -1))]))
        XCTAssertEqual(document.cuts, [CutSegment(start: 0, end: 1)], "剪除段闸生效")
        XCTAssertEqual(document.zoomSegments,
                       [ZoomSegment(start: 1, end: 2, level: 1.9, center: CGPoint(x: 1, y: 0))],
                       "缩放段闸生效")
        XCTAssertEqual(EditDocument.empty, EditDocument(cuts: [], zoomSegments: []))
    }

    // MARK: keptRanges

    func testKeptRangesComplement() {
        XCTAssertEqual(EditTimeline.keptRanges(cuts: [], duration: 10).map { $0.start },
                       [0], "无剪除 = 全保留")
        XCTAssertTrue(
            EditTimeline.keptRanges(cuts: [CutSegment(start: 0, end: 10)], duration: 10).isEmpty,
            "全剪 = 空")
        XCTAssertEqual(
            EditTimeline.keptRanges(cuts: [CutSegment(start: 2, end: 4), CutSegment(start: 6, end: 8)], duration: 10)
                .map { [$0.start, $0.end] },
            [[0.0, 2.0], [4.0, 6.0], [8.0, 10.0]], "中段剪除 → 三保留区间")
        XCTAssertEqual(
            EditTimeline.keptRanges(cuts: [CutSegment(start: 0, end: 3), CutSegment(start: 3, end: 5)], duration: 10)
                .map { [$0.start, $0.end] },
            [[5.0, 10.0]], "首尾相接剪除段合并覆盖")
        XCTAssertEqual(
            EditTimeline.keptRanges(cuts: [CutSegment(start: 8, end: 20)], duration: 10)
                .map { [$0.start, $0.end] },
            [[0.0, 8.0]], "超界剪除段按求交裁剪")
        XCTAssertTrue(EditTimeline.keptRanges(cuts: [], duration: 0).isEmpty, "零时长退化")
    }

    // MARK: outputSeconds（源→输出折叠映射）

    func testOutputSecondsIdentityWithoutCuts() {
        XCTAssertEqual(EditTimeline.outputSeconds(forSourceSeconds: 3.7, cuts: []), 3.7)
    }

    func testOutputSecondsNilInsideCutHalfOpen() {
        let cuts = [CutSegment(start: 2, end: 4)]
        XCTAssertNil(EditTimeline.outputSeconds(forSourceSeconds: 2, cuts: cuts), "入点 = 剪除")
        XCTAssertNil(EditTimeline.outputSeconds(forSourceSeconds: 3.9, cuts: cuts), "段内 = 剪除")
        XCTAssertEqual(EditTimeline.outputSeconds(forSourceSeconds: 4, cuts: cuts), 2,
                       "出点（半开）= 存活且平移")
        XCTAssertEqual(EditTimeline.outputSeconds(forSourceSeconds: 1.9, cuts: cuts), 1.9,
                       "入点前恒等")
    }

    func testOutputSecondsCumulativeShiftAcrossMultipleCuts() {
        let cuts = [CutSegment(start: 1, end: 2), CutSegment(start: 4, end: 7)]
        XCTAssertEqual(EditTimeline.outputSeconds(forSourceSeconds: 3, cuts: cuts), 2,
                       "第一段剪除后平移 −1")
        XCTAssertEqual(EditTimeline.outputSeconds(forSourceSeconds: 8, cuts: cuts), 4,
                       "两段剪除累计平移 −(1+3)：8 − 4 = 4")
        XCTAssertEqual(EditTimeline.outputSeconds(forSourceSeconds: 5, cuts: cuts), nil,
                       "第二段剪除内")
    }

    // MARK: totalCutSeconds / skipCuts

    func testTotalCutSecondsClampedToDuration() {
        XCTAssertEqual(EditTimeline.totalCutSeconds(cuts: [], duration: 10), 0)
        XCTAssertEqual(EditTimeline.totalCutSeconds(
            cuts: [CutSegment(start: 1, end: 3), CutSegment(start: 8, end: 20)], duration: 10), 4,
            "2s + 超界段钳后 2s = 4s")
        XCTAssertEqual(EditTimeline.totalCutSeconds(cuts: [CutSegment(start: 0, end: 100)], duration: 10), 10)
        XCTAssertEqual(EditTimeline.totalCutSeconds(cuts: [CutSegment(start: 1, end: 2)], duration: 0), 0)
    }

    func testSkipCutsChainsTouchingCuts() {
        let cuts = [CutSegment(start: 1, end: 2), CutSegment(start: 2, end: 3)]
        XCTAssertEqual(EditTimeline.skipCuts(from: 0.5, cuts: cuts), 0.5, "段外原值")
        XCTAssertEqual(EditTimeline.skipCuts(from: 1.5, cuts: cuts), 3, "链式跳过相邻剪除段")
        XCTAssertEqual(EditTimeline.skipCuts(from: 2.5, cuts: cuts), 3)
        XCTAssertEqual(EditTimeline.skipCuts(from: 3, cuts: cuts), 3, "段尾（半开）不跳")
    }

    // MARK: trimCutProposal（拖选提案修剪闸）

    func testTrimProposalClampsAndSorts() {
        let trimmed = EditTimeline.trimCutProposal(
            anchor: 5, proposedStart: 8, proposedEnd: 2,
            existingCuts: [], sourceDuration: 10)
        XCTAssertEqual(trimmed?.start, 2, "倒序提案排序")
        XCTAssertEqual(trimmed?.end, 8)
        let clamped = EditTimeline.trimCutProposal(
            anchor: 5, proposedStart: -5, proposedEnd: 100,
            existingCuts: [], sourceDuration: 10)
        XCTAssertEqual(clamped?.start, 0, "钳进源时长（下界）")
        XCTAssertEqual(clamped?.end, 10, "钳进源时长（上界）")
    }

    func testTrimProposalAvoidsExistingCutsOnBothSides() {
        let existing = [CutSegment(start: 2, end: 3), CutSegment(start: 7, end: 8)]
        let bothSides = EditTimeline.trimCutProposal(
            anchor: 5, proposedStart: 1, proposedEnd: 9,
            existingCuts: existing, sourceDuration: 10)
        XCTAssertEqual(bothSides?.start, 3, "左侧避让既有剪除段")
        XCTAssertEqual(bothSides?.end, 7, "右侧避让既有剪除段")
        let anchorLeft = EditTimeline.trimCutProposal(
            anchor: 1.5, proposedStart: 1, proposedEnd: 9,
            existingCuts: existing, sourceDuration: 10)
        XCTAssertEqual(anchorLeft?.start, 1, "锚点在左侧 → 保留锚点侧子区间（起）")
        XCTAssertEqual(anchorLeft?.end, 2, "锚点在左侧 → 保留锚点侧子区间（止）")
    }

    func testTrimProposalRejectsBelowMinimum() {
        XCTAssertNil(EditTimeline.trimCutProposal(
            anchor: 5, proposedStart: 5.0, proposedEnd: 5.05,
            existingCuts: [], sourceDuration: 10), "不足最短剪除时长 → nil")
        XCTAssertNil(EditTimeline.trimCutProposal(
            anchor: 5, proposedStart: 4, proposedEnd: 6,
            existingCuts: [CutSegment(start: 0, end: 10)], sourceDuration: 10,
            ), "全被既有剪除段吞没 → nil")
    }

    func testTrimProposalAnchorInsideExistingCutFallsRight() {
        let fallsRight = EditTimeline.trimCutProposal(
            anchor: 2.5, proposedStart: 1, proposedEnd: 5,
            existingCuts: [CutSegment(start: 2, end: 3)], sourceDuration: 10)
        XCTAssertEqual(fallsRight?.start, 3, "锚点落在既有红块内（兜底形态）→ 收窄到红块右侧（起）")
        XCTAssertEqual(fallsRight?.end, 5, "锚点落在既有红块内（兜底形态）→ 收窄到红块右侧（止）")
    }

    // MARK: Codable

    func testEditDocumentCodableRoundtrip() throws {
        let document = EditDocument(
            cuts: [CutSegment(start: 1, end: 2)],
            zoomSegments: [ZoomSegment(start: 3, end: 4, level: 1.6, center: CGPoint(x: 0.5, y: 0.5))])
        let decoded = try JSONDecoder().decode(
            EditDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(decoded, document, "Codable 往返保值")
    }
}

/// 真实 mp4 夹具工厂（编辑器模型级钉测共用）：1s@30fps 320×180 纯色视频。
@MainActor
enum EditorMovieFixture {
    static func makeMovie(at url: URL) async throws {
        let writer = try AVAssetWriter(url: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320,
            AVVideoHeightKey: 180,
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 320,
                kCVPixelBufferHeightKey as String: 180,
            ])
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            var pixelBuffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(
                kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA, nil, &pixelBuffer),
                kCVReturnSuccess)
            let buffer = try XCTUnwrap(pixelBuffer)
            XCTAssertTrue(adaptor.append(
                buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)),
                "夹具帧 \(frame) 写入失败：\(String(describing: writer.error))")
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        XCTAssertEqual(writer.status, .completed)
    }
}

/// 模型链路钉测（剪辑 v1）：ZoomEditorModel 的剪除段提交路径——真实 mp4 夹具补齐
/// sourceDuration（loadMediaInfo）→ commitCutCreation 全链（trim 闸 → validate → 落库
/// → 草稿）+ scrub/seek/settle 差分。
@MainActor
final class CutCreationModelTests: XCTestCase {
    func testCommitCutCreationOnRealMovie() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CutCreationModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("剪辑模型夹具.mp4")
        try await EditorMovieFixture.makeMovie(at: url)

        let item = RecordingFileMetadata(
            id: url, url: url, name: url.lastPathComponent, sizeBytes: 1, createdAt: nil, duration: nil)
        let vm = RecordingListViewModel(
            store: RecordingFileStore(baseDirectory: directory),
            durationProvider: { _ in 0 })
        let model = ZoomEditorModel(item: item, listViewModel: vm)
        await model.loadMediaInfo()
        XCTAssertEqual(model.sourceDuration, 1.0, accuracy: 0.05, "真实时长探针就绪")

        // 提交路径全链：锚 0.2s、提案 [0.1, 0.6] → 剪除段落库 + 草稿
        model.commitCutCreation(anchor: 0.2, start: 0.1, end: 0.6)
        XCTAssertEqual(model.cuts, [CutSegment(start: 0.1, end: 0.6)], "剪除段经修剪闸落库")
        XCTAssertEqual(vm.loadDraft(for: item).cuts, model.cuts, "草稿即时落盘")
        XCTAssertEqual(model.totalCutSeconds, 0.5, accuracy: 1e-9)

        // 亚最短提案被静默丢弃
        model.commitCutCreation(anchor: 0.8, start: 0.81, end: 0.82)
        XCTAssertEqual(model.cuts.count, 1, "不足 0.1s 的拖选不产生剪除段")

        // scrub vs seek 差分（2026-11-21 用户要求「拖动时间线视频跟随」）：scrub 原始
        // 落点（扫查光标在剪除段内也照实显示），seek 避让剪除段（播放落位语义）。
        model.scrub(to: 0.3) // 0.1–0.6 剪除段内
        XCTAssertEqual(model.playhead, 0.3, accuracy: 1e-9, "scrub 原始落点不避让")
        model.seek(to: 0.3)
        XCTAssertEqual(model.playhead, 0.6, accuracy: 1e-9, "seek 避让跳到段尾")
        model.settlePlayhead() // 播放头已在段尾 → 原位
        XCTAssertEqual(model.playhead, 0.6, accuracy: 1e-9)
        model.scrub(to: 0.35)
        model.settlePlayhead() // 播放头落在剪除段内 → 跳段尾
        XCTAssertEqual(model.playhead, 0.6, accuracy: 1e-9, "settle 落位避让剪除段")
    }
}

/// 精剪工作台钉测（2026-11-21 剪映专业版对齐·批次 1）：缩放映射、吸附、时间码、
/// 撤销/重做快照栈。
@MainActor
final class PrecisionWorkbenchTests: XCTestCase {
    // MARK: 缩放/平移映射

    func testPxPerSecAndClampedOffset() {
        // zoom 1 = 全程适配（与旧 scale 恒等）
        XCTAssertEqual(ZoomTimelineGeometry.pxPerSec(width: 664, sourceDuration: 48.4, zoom: 1),
                       ZoomTimelineGeometry.scale(width: 664, sourceDuration: 48.4), accuracy: 1e-9)
        XCTAssertEqual(ZoomTimelineGeometry.pxPerSec(width: 664, sourceDuration: 48.4, zoom: 2),
                       664 / 24.2, accuracy: 1e-9, "zoom 2 = 可视时长减半")
        XCTAssertEqual(ZoomTimelineGeometry.clampedOffset(5, sourceDuration: 48.4, zoom: 1), 0,
                       "zoom 1 平移恒 0")
        XCTAssertEqual(ZoomTimelineGeometry.clampedOffset(100, sourceDuration: 48.4, zoom: 2), 24.2,
                       "钳到 源时长 − 可视时长")
        XCTAssertEqual(ZoomTimelineGeometry.clampedOffset(-3, sourceDuration: 48.4, zoom: 2), 0)
    }

    func testTimeXRoundtripWithOffset() {
        let pxPerSec = ZoomTimelineGeometry.pxPerSec(width: 664, sourceDuration: 48.4, zoom: 4)
        let offset: TimeInterval = 10
        let x = ZoomTimelineGeometry.timeToX(15, pxPerSec: pxPerSec, offset: offset)
        XCTAssertEqual(ZoomTimelineGeometry.xToTime(x, pxPerSec: pxPerSec, offset: offset), 15,
                       accuracy: 1e-9, "time↔x 往返保值")
    }

    func testTimecodeFormat() {
        XCTAssertEqual(ZoomTimelineGeometry.timecode(0), "00:00:00:00")
        XCTAssertEqual(ZoomTimelineGeometry.timecode(13.939), "00:00:13:28", "13.939×30=418.17→418 帧 = 13s28f")
        XCTAssertEqual(ZoomTimelineGeometry.timecode(3661.5), "01:01:01:15", "小时段")
        XCTAssertEqual(ZoomTimelineGeometry.timecode(-1), "—", "负值退化")
        XCTAssertEqual(ZoomTimelineGeometry.timecode(.nan), "—")
        XCTAssertEqual(ZoomTimelineGeometry.timecode(1, fps: 0), "—")
    }

    // MARK: 吸附

    func testSnappedToNearestCandidateWithinTolerance() {
        let candidates: [TimeInterval] = [0, 3.0, 3.19, 12.18, 48.4]
        XCTAssertEqual(ZoomTimelineGeometry.snapped(3.21, candidates: candidates, toleranceSeconds: 0.1),
                       3.19, "容差内吸最近磁点")
        XCTAssertEqual(ZoomTimelineGeometry.snapped(3.5, candidates: candidates, toleranceSeconds: 0.1),
                       3.5, "容差外原值")
        XCTAssertEqual(ZoomTimelineGeometry.snapped(3.05, candidates: candidates, toleranceSeconds: 0.1),
                       3.0, "两点等距取先入者（确定性）")
        XCTAssertEqual(ZoomTimelineGeometry.snapped(3.5, candidates: candidates, toleranceSeconds: 0),
                       3.5, "零容差 = 不吸附")
    }

    // MARK: 撤销/重做（快照栈，模型级）

    func testUndoRedoStackOnRealMovie() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrecisionWorkbench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("撤销夹具.mp4")
        try await EditorMovieFixture.makeMovie(at: url)

        let item = RecordingFileMetadata(
            id: url, url: url, name: url.lastPathComponent, sizeBytes: 1, createdAt: nil, duration: nil)
        let vm = RecordingListViewModel(
            store: RecordingFileStore(baseDirectory: directory), durationProvider: { _ in 42.0 })
        let model = ZoomEditorModel(item: item, listViewModel: vm)
        await model.loadMediaInfo()
        XCTAssertFalse(model.canUndo)

        model.commitCutCreation(anchor: 0.1, start: 0.1, end: 0.6) // 建段
        XCTAssertEqual(model.cuts.count, 1)
        XCTAssertTrue(model.canUndo)
        XCTAssertFalse(model.canRedo)

        model.undo()
        XCTAssertEqual(model.cuts.count, 0, "撤销回空")
        XCTAssertFalse(model.canUndo)
        XCTAssertTrue(model.canRedo)

        model.redo()
        XCTAssertEqual(model.cuts, [CutSegment(start: 0.1, end: 0.6)], "重做恢复")
        XCTAssertTrue(model.canUndo)
        XCTAssertFalse(model.canRedo)

        // 撤销后再新编辑 → redo 分支清空
        model.undo()
        model.commitCutCreation(anchor: 0.1, start: 0.2, end: 0.8)
        XCTAssertEqual(model.cuts, [CutSegment(start: 0.2, end: 0.8)])
        XCTAssertFalse(model.canRedo, "分叉后 redo 栈清空")

        // 草稿随 undo/redo 同步落盘
        XCTAssertEqual(vm.loadDraft(for: item).cuts, model.cuts, "草稿与栈顶一致")
    }
}
