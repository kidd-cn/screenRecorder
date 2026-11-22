import AVFoundation
import CoreGraphics
import XCTest

@testable import Hummingbird

/// 剪辑 v2 片段流钉测（剪映对齐·批次 4a）：`EditClip`/`EditDocument.validate`、
/// 源↔成品双向映射（含速度折算）、波纹删除、接缝移动、缩放段映射、v1 迁移、
/// 命名分流；编辑器模型链路（波纹删除/撤销栈/scrub-settle）。
final class EditDocumentTests: XCTestCase {
    // MARK: validate

    func testValidateDropsBadClampsSortsKeepsFirstOnOverlap() {
        let document = EditDocument.validate(EditDocument(
            clips: [
                EditClip(sourceStart: 2, sourceEnd: 4),
                EditClip(sourceStart: -1, sourceEnd: 1), // 钳 start ≥ 0
                EditClip(sourceStart: 5, sourceEnd: 5), // 零长丢弃
                EditClip(sourceStart: 6, sourceEnd: 2), // 倒序丢弃
                EditClip(sourceStart: 3, sourceEnd: 6, speed: 50), // 重叠丢弃（保留先者）+ 速度钳
                EditClip(sourceStart: 8, sourceEnd: 9, speed: 0.01), // 速度钳 0.25
            ],
            zoomSegments: []))
        XCTAssertEqual(document.clips, [
            EditClip(sourceStart: 0, sourceEnd: 1),
            EditClip(sourceStart: 2, sourceEnd: 4),
            EditClip(sourceStart: 8, sourceEnd: 9, speed: 0.25),
        ])
        // 首尾相接不算重叠
        let touching = EditDocument.validate(EditDocument(
            clips: [EditClip(sourceStart: 0, sourceEnd: 1), EditClip(sourceStart: 1, sourceEnd: 2)],
            zoomSegments: []))
        XCTAssertEqual(touching.clips.count, 2)
    }

    func testInitialDocument() {
        XCTAssertEqual(EditDocument.initial(duration: 10).clips,
                       [EditClip(sourceStart: 0, sourceEnd: 10)])
        XCTAssertEqual(EditDocument.initial(duration: 0), EditDocument.empty)
    }

    // MARK: 源↔成品映射

    func testMappingIdentityOnSingleFullClip() throws {
        let document = EditDocument.initial(duration: 10)
        XCTAssertEqual(document.outputDuration, 10)
        XCTAssertEqual(try XCTUnwrap(document.sourceTime(forOutputTime: 3.7)), 3.7, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(document.outputTime(forSourceTime: 3.7)), 3.7, accuracy: 1e-9)
        XCTAssertNil(document.sourceTime(forOutputTime: 11), "越界 nil")
        XCTAssertNil(document.outputTime(forSourceTime: 11), "越界 nil")
    }

    func testMappingWithDeletedMiddleAndSpeed() throws {
        // clips：[0,1) 原速 + [2,3) 2× 速 → 成片 = 1 + 0.5 = 1.5s
        let document = EditDocument(clips: [
            EditClip(sourceStart: 0, sourceEnd: 1),
            EditClip(sourceStart: 2, sourceEnd: 3, speed: 2),
        ], zoomSegments: [])
        XCTAssertEqual(document.outputDuration, 1.5, accuracy: 1e-9)
        // 源 1.5 在裁掉区间 → nil；源 2.5 在第二 clip → 输出 1 + 0.5/2 = 1.25
        XCTAssertNil(document.outputTime(forSourceTime: 1.5))
        XCTAssertEqual(try XCTUnwrap(document.outputTime(forSourceTime: 2.5)), 1.25, accuracy: 1e-9)
        // 成品 1.25 → 源 2.5
        XCTAssertEqual(try XCTUnwrap(document.sourceTime(forOutputTime: 1.25)), 2.5, accuracy: 1e-9)
        // 边界：成品 1.0（接缝）→ 前 clip 源终点 1.0（实现语义：边界归属前段）
        XCTAssertEqual(try XCTUnwrap(document.sourceTime(forOutputTime: 1.0)), 1.0, accuracy: 1e-9)
        XCTAssertEqual(document.speed(atSourceTime: 2.5), 2)
        XCTAssertNil(document.speed(atSourceTime: 1.5))
    }

    // MARK: 波纹删除

    func testRippleDeleteSplitsSingleClip() {
        let document = EditDocument.initial(duration: 10)
        let edited = document.removingOutputRange(lower: 2, upper: 4)
        XCTAssertEqual(edited.clips, [
            EditClip(sourceStart: 0, sourceEnd: 2),
            EditClip(sourceStart: 4, sourceEnd: 10),
        ])
        XCTAssertEqual(edited.outputDuration, 8, accuracy: 1e-9)
    }

    func testRippleDeleteAcrossClipsAndBounds() {
        let document = EditDocument(clips: [
            EditClip(sourceStart: 0, sourceEnd: 1),
            EditClip(sourceStart: 2, sourceEnd: 3, speed: 2),
        ], zoomSegments: [])
        // 删除成品 [0.5, 1.25)：跨接缝——前 clip 剩 [0,0.5)；后 clip 成品 [1.0,1.25) 被删
        //（源 2.0→2.5），余下源 [2.5,3)（成品 0.25s @2x）
        let edited = document.removingOutputRange(lower: 0.5, upper: 1.25)
        XCTAssertEqual(edited.clips, [
            EditClip(sourceStart: 0, sourceEnd: 0.5),
            EditClip(sourceStart: 2.5, sourceEnd: 3, speed: 2),
        ])
        // 全删 → 空
        XCTAssertEqual(document.removingOutputRange(lower: 0, upper: 99).clips, [])
        // 退化区间 → 原文档
        XCTAssertEqual(document.removingOutputRange(lower: 5, upper: 5), document)
    }

    // MARK: 接缝移动

    func testMovingSeamHeadTailAndMiddle() {
        let document = EditDocument.initial(duration: 10)
        // 片头裁到 2
        XCTAssertEqual(document.movingSeam(at: 0, toSourceTime: 2)?.clips,
                       [EditClip(sourceStart: 2, sourceEnd: 10)])
        // 片尾裁到 8
        XCTAssertEqual(document.movingSeam(at: 1, toSourceTime: 8)?.clips,
                       [EditClip(sourceStart: 0, sourceEnd: 8)])
        // 非法：片头裁到出点之外
        XCTAssertNil(document.movingSeam(at: 0, toSourceTime: 11))
        // 中间接缝（两 clip 拼合后拖接缝找回/扩大删除）
        let split = document.removingOutputRange(lower: 4, upper: 6)
        XCTAssertEqual(split.movingSeam(at: 1, toSourceTime: 7)?.clips,
                       [EditClip(sourceStart: 0, sourceEnd: 7), EditClip(sourceStart: 7, sourceEnd: 10)],
                       "接缝右移 = 左 clip 找回删除区")
        XCTAssertEqual(split.movingSeam(at: 1, toSourceTime: 5)?.clips,
                       [EditClip(sourceStart: 0, sourceEnd: 5), EditClip(sourceStart: 5, sourceEnd: 10)])
        XCTAssertNil(split.movingSeam(at: 1, toSourceTime: -1))
    }

    // MARK: 缩放段映射（截断/平移/÷速度）

    func testMappedZoomSegments() {
        let document = EditDocument(clips: [
            EditClip(sourceStart: 0, sourceEnd: 1),
            EditClip(sourceStart: 2, sourceEnd: 4, speed: 2),
        ], zoomSegments: [
            ZoomSegment(start: 0.5, end: 3.0, level: 1.6, center: CGPoint(x: 0.5, y: 0.5)),
        ])
        let mapped = document.mappedZoomSegments()
        // zoom 段 [0.5,3.0)：clip1 交集 [0.5,1) → 成品 [0.5,1)；clip2 交集 [2,3) → 成品 [1,1.5)（÷2）
        XCTAssertEqual(mapped.map(\.start), [0.5, 1.0])
        XCTAssertEqual(mapped.map(\.end), [1.0, 1.5])
    }

    // MARK: v1 迁移 + 命名分流

    func testMigratingFromCutsAndHasEdits() {
        let migrated = EditDocument.migrating(cuts: [(2, 4)], duration: 10)
        XCTAssertEqual(migrated.clips, [
            EditClip(sourceStart: 0, sourceEnd: 2),
            EditClip(sourceStart: 4, sourceEnd: 10),
        ])
        XCTAssertFalse(EditDocument.initial(duration: 10).hasEdits(sourceDuration: 10), "原速全覆盖 = 未剪")
        XCTAssertTrue(migrated.hasEdits(sourceDuration: 10), "中段删除 = 已剪")
        XCTAssertTrue(EditDocument(clips: [EditClip(sourceStart: 0, sourceEnd: 10, speed: 2)],
                                   zoomSegments: []).hasEdits(sourceDuration: 10), "变速 = 已剪")
        XCTAssertTrue(EditDocument(clips: [EditClip(sourceStart: 1, sourceEnd: 10)],
                                   zoomSegments: []).hasEdits(sourceDuration: 10), "掐头 = 已剪")
    }

    // MARK: Codable

    func testEditDocumentCodableRoundtrip() throws {
        let document = EditDocument(
            clips: [EditClip(sourceStart: 1, sourceEnd: 2, speed: 1.5)],
            zoomSegments: [ZoomSegment(start: 3, end: 4, level: 1.6, center: CGPoint(x: 0.5, y: 0.5))])
        let decoded = try JSONDecoder().decode(
            EditDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(decoded, document, "Codable 往返保值")
    }
}

/// 模型链路钉测（剪辑 v2）：ZoomEditorModel 波纹删除/撤销栈/scrub-settle——真实 mp4
/// 夹具补齐 sourceDuration 后全链断言。
@MainActor
final class ClipEditModelTests: XCTestCase {
    func testRippleDeleteUndoRedoOnRealMovie() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipEditModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("波纹夹具.mp4")
        try await EditorMovieFixture.makeMovie(at: url)

        let item = RecordingFileMetadata(
            id: url, url: url, name: url.lastPathComponent, sizeBytes: 1, createdAt: nil, duration: nil)
        let vm = RecordingListViewModel(
            store: RecordingFileStore(baseDirectory: directory), durationProvider: { _ in 0 })
        let model = ZoomEditorModel(item: item, listViewModel: vm)
        await model.loadMediaInfo()
        XCTAssertEqual(model.sourceDuration, 1.0, accuracy: 0.05)
        XCTAssertEqual(model.clips.count, 1, "时长就绪后空文档置单 clip 全程")

        // 波纹删除成品 [0.1, 0.6) → 两 clip
        model.cutOutputRange(lower: 0.1, upper: 0.6)
        XCTAssertEqual(model.clips.count, 2)
        XCTAssertEqual(model.clips[0].sourceEnd, 0.1, accuracy: 1e-9)
        XCTAssertEqual(model.clips[1].sourceStart, 0.6, accuracy: 1e-9)
        XCTAssertEqual(model.outputDuration, 0.5, accuracy: 1e-9)
        XCTAssertTrue(model.canUndo)

        // 撤销/重做
        model.undo()
        XCTAssertEqual(model.clips.count, 1, "撤销回单 clip")
        model.redo()
        XCTAssertEqual(model.clips.count, 2)

        // 接缝移动：中间接缝（seamIndex 1）源 0.3 → 找回删除区
        model.moveSeam(at: 1, toSourceTime: 0.3)
        XCTAssertEqual(model.clips, [
            EditClip(sourceStart: 0, sourceEnd: 0.3),
            EditClip(sourceStart: 0.3, sourceEnd: 1.0),
        ])
        XCTAssertEqual(model.outputDuration, 1.0, accuracy: 1e-9, "找回删除区 → 成片复原")

        // scrub/seek 在成品轴（接缝找回后成片 = 1.0s）
        model.seek(to: 0.5)
        XCTAssertEqual(model.playhead, 0.5, accuracy: 1e-9)
        model.scrub(to: 0.9)
        XCTAssertEqual(model.playhead, 0.9, accuracy: 1e-9)

        // 调速：clip 0 → 2x → 成片 = 0.15 + 0.7 = 0.85
        model.setClipSpeed(at: 0, speed: 2)
        XCTAssertEqual(model.clips[0].speed, 2)
        XCTAssertEqual(model.outputDuration, 0.85, accuracy: 1e-9)
        model.seek(to: 0.99)
        XCTAssertEqual(model.playhead, 0.85, accuracy: 1e-9, "越界钳成片时长")

        // 草稿同步
        XCTAssertEqual(vm.loadDraft(for: item, sourceDuration: 1.0).clips, model.clips)
    }

    /// 时间线平移钳制按**成品轴**（2026-11-22 用户反馈：放大可滚出内容尽头）：
    /// 成片 0.5s、zoom 2 → 可视 0.25s，offset 上限 0.25（不得按源时长 1.0 放到 0.5）。
    func testTimelineOffsetClampsToOutputDuration() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimelineClamp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("钳制夹具.mp4")
        try await EditorMovieFixture.makeMovie(at: url)
        let item = RecordingFileMetadata(
            id: url, url: url, name: url.lastPathComponent, sizeBytes: 1, createdAt: nil, duration: nil)
        let vm = RecordingListViewModel(
            store: RecordingFileStore(baseDirectory: directory), durationProvider: { _ in 0 })
        let model = ZoomEditorModel(item: item, listViewModel: vm)
        await model.loadMediaInfo()
        model.cutOutputRange(lower: 0.1, upper: 0.6) // 成片 0.5s
        XCTAssertEqual(model.outputDuration, 0.5, accuracy: 1e-9)
        XCTAssertEqual(model.timelineDuration, 0.5, accuracy: 1e-9, "比例尺基准 = 成品时长")
        model.timelineOffset = 100
        model.timelineZoom = 2 // didSet 钳制
        XCTAssertEqual(model.timelineOffset, 0.25, accuracy: 1e-6,
                       "offset 上限 = 成片 − 可视（0.5 − 0.25）")
        model.timelineZoom = 1
        XCTAssertEqual(model.timelineOffset, 0, accuracy: 1e-9, "zoom=1 平移归零")
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

/// 音量关键帧钉测（剪映对齐·批次 4c-2 Task A）：validate 规整、插值三态、波纹删除
/// 平移、v3 草稿兼容解码、模型级添加-拖动-删除-撤销全链。
final class KeyframeTests: XCTestCase {
    func testValidateSortsClampsDedupes() {
        let validated = EditKeyframe.validate([
            EditKeyframe(outputTime: 2, volume: 2), // 钳 1
            EditKeyframe(outputTime: -1, volume: 0.5), // 负时间丢弃
            EditKeyframe(outputTime: 1, volume: 0.3),
            EditKeyframe(outputTime: 1 + 5e-7, volume: 0.9), // 去重保留先者
            EditKeyframe(outputTime: .nan, volume: 0.5), // 丢弃
        ])
        XCTAssertEqual(validated, [
            EditKeyframe(outputTime: 1, volume: 0.3),
            EditKeyframe(outputTime: 2, volume: 1),
        ])
    }

    func testVolumeInterpolationThreeStates() throws {
        let keyframes = [
            EditKeyframe(outputTime: 1, volume: 0.2),
            EditKeyframe(outputTime: 3, volume: 0.8),
        ]
        XCTAssertEqual(try XCTUnwrap(EditKeyframe.volume(atOutputTime: 0, keyframes: keyframes)),
                       0.2, accuracy: 1e-9, "首帧前 = 首帧值")
        XCTAssertEqual(try XCTUnwrap(EditKeyframe.volume(atOutputTime: 2, keyframes: keyframes)),
                       0.5, accuracy: 1e-9, "帧间线性")
        XCTAssertEqual(try XCTUnwrap(EditKeyframe.volume(atOutputTime: 9, keyframes: keyframes)),
                       0.8, accuracy: 1e-9, "末帧后 = 末帧值")
        XCTAssertNil(EditKeyframe.volume(atOutputTime: 2, keyframes: []), "空集 nil → 回退自动淡")
    }

    func testRippleDeleteShiftsKeyframes() {
        let document = EditDocument(
            clips: [EditClip(sourceStart: 0, sourceEnd: 10)],
            zoomSegments: [],
            keyframes: [
                EditKeyframe(outputTime: 1, volume: 0.1),
                EditKeyframe(outputTime: 3, volume: 0.5), // 删除区间 [2,4) 内 → 丢
                EditKeyframe(outputTime: 6, volume: 0.9), // 右侧 → −2 平移
            ])
        let edited = document.removingOutputRange(lower: 2, upper: 4)
        XCTAssertEqual(edited.keyframes, [
            EditKeyframe(outputTime: 1, volume: 0.1),
            EditKeyframe(outputTime: 4, volume: 0.9),
        ])
    }

    func testV3DraftDecodesWithEmptyKeyframes() throws {
        let v3JSON = #"{"clips":[{"sourceStart":0,"sourceEnd":5,"speed":1}],"zoomSegments":[],"sourceVolume":0.5}"#
        let decoded = try JSONDecoder().decode(EditDocument.self, from: Data(v3JSON.utf8))
        XCTAssertEqual(decoded.keyframes, [], "v3 缺字段 → 空关键帧")
        XCTAssertEqual(decoded.sourceVolume, 0.5)
    }
}

/// 关键帧模型链钉测（真实 mp4 夹具）：添加-拖动-删除-撤销全链。
@MainActor
final class KeyframeModelTests: XCTestCase {
    func testAddMoveRemoveUndoOnRealMovie() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyframeModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("关键帧夹具.mp4")
        try await EditorMovieFixture.makeMovie(at: url)

        let item = RecordingFileMetadata(
            id: url, url: url, name: url.lastPathComponent, sizeBytes: 1, createdAt: nil, duration: nil)
        let vm = RecordingListViewModel(
            store: RecordingFileStore(baseDirectory: directory), durationProvider: { _ in 0 })
        let model = ZoomEditorModel(item: item, listViewModel: vm)
        await model.loadMediaInfo()

        model.addKeyframe(at: 0.4, volume: 0.3)
        XCTAssertEqual(model.keyframes, [EditKeyframe(outputTime: 0.4, volume: 0.3)])

        // 拖动（按原时间寻址；重排后下标漂移不影响）
        model.moveKeyframe(fromOriginalTime: 0.4, to: 0.7, volume: 0.9)
        XCTAssertEqual(model.keyframes, [EditKeyframe(outputTime: 0.7, volume: 0.9)])

        // 删除 + 撤销
        model.removeKeyframe(at: 0)
        XCTAssertEqual(model.keyframes, [])
        XCTAssertTrue(model.canUndo)
        model.undo()
        XCTAssertEqual(model.keyframes, [EditKeyframe(outputTime: 0.7, volume: 0.9)], "撤销恢复删除前")

        // 草稿同步
        XCTAssertEqual(vm.loadDraft(for: item, sourceDuration: 1.0).keyframes,
                       model.keyframes, "关键帧随草稿落盘")
    }
}

/// 转场钉测（剪映对齐·批次 4c-2 Task B/C）：validate、窗口映射、黑场增益、波纹删除
/// 重定位、接缝移动保持。
final class TransitionTests: XCTestCase {
    func testValidateDropsInvalidSeamsAndClampsDuration() {
        let document = EditDocument.validate(EditDocument(
            clips: [EditClip(sourceStart: 0, sourceEnd: 1), EditClip(sourceStart: 1, sourceEnd: 2)],
            zoomSegments: [],
            transitions: [
                0: EditTransition(kind: .black), // 片头缝无效 → 丢
                1: EditTransition(kind: .black, duration: 9), // 钳 2s
                2: EditTransition(kind: .crossfade), // 片尾缝（=clips.count）无效 → 丢
            ]))
        XCTAssertEqual(document.transitions.count, 1)
        XCTAssertEqual(document.transitions[1], EditTransition(kind: .black, duration: 2))
    }

    func testTransitionStateWindowAndProgress() {
        let document = EditDocument(
            clips: [EditClip(sourceStart: 0, sourceEnd: 1), EditClip(sourceStart: 1, sourceEnd: 2)],
            zoomSegments: [],
            transitions: [1: EditTransition(kind: .crossfade, duration: 0.4)])
        // 边界 = 1.0；窗口 [0.8, 1.2)
        XCTAssertNil(document.transitionState(atOutputTime: 0.7), "窗口外")
        XCTAssertEqual(try XCTUnwrap(document.transitionState(atOutputTime: 0.8)).progress, 0,
                       accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(document.transitionState(atOutputTime: 1.0)).progress, 0.5,
                       accuracy: 1e-9, "边界中点 progress=0.5")
        XCTAssertNil(document.transitionState(atOutputTime: 1.2), "窗口右界开区间")
        XCTAssertEqual(try XCTUnwrap(document.transitionState(atOutputTime: 1.0)).kind, .crossfade)
    }

    func testBlackGainCurve() {
        // 窗口 [0.8, 1.2)，d=0.4
        let document = EditDocument(
            clips: [EditClip(sourceStart: 0, sourceEnd: 1), EditClip(sourceStart: 1, sourceEnd: 2)],
            zoomSegments: [],
            transitions: [1: EditTransition(kind: .black, duration: 0.4)])
        XCTAssertEqual(document.blackTransitionGain(atOutputTime: 0.8), 1, accuracy: 1e-9)
        // 平台段：中点 ±20% 窗口持续全黑（线性 0.5 → 平台后 smoothstep ≈0.316）
        XCTAssertEqual(document.blackTransitionGain(atOutputTime: 1.0), 0, accuracy: 1e-9)
        let gainAtP25 = document.blackTransitionGain(atOutputTime: 0.9)
        XCTAssertGreaterThan(gainAtP25, 0.2, "平台外开始回升")
        XCTAssertLessThan(gainAtP25, 0.5, "smoothstep 比线性低（黑保持更久）")
        XCTAssertEqual(document.blackTransitionGain(atOutputTime: 0.5), 1, "窗口外恒 1")
        // 平台内（p=0.45 → linear 0.1 ≤ 0.2 → 全黑）
        XCTAssertEqual(document.blackTransitionGain(atOutputTime: 0.98), 0, accuracy: 1e-9)
    }

    func testRippleDeleteDropsCrossedTransitionAndKeepsShiftedSeam() {
        // 三 clip：缝在 1.0 与 2.0；转场挂缝 2（边界 2.0，d=0.4 → 窗口 [1.8, 2.2)）
        let document = EditDocument(
            clips: [EditClip(sourceStart: 0, sourceEnd: 1),
                    EditClip(sourceStart: 1, sourceEnd: 2),
                    EditClip(sourceStart: 2, sourceEnd: 3)],
            zoomSegments: [],
            transitions: [2: EditTransition(kind: .black, duration: 0.4)])
        // 删除 [1.4, 1.6)：不触及转场窗口 [1.8, 2.2)（1.6 < 1.8）；新边界 1.8 → 缝保持
        let kept = document.removingOutputRange(lower: 1.4, upper: 1.6)
        XCTAssertEqual(kept.transitions.count, 1, "未相交 → 保留")
        XCTAssertEqual(kept.transitions.values.first?.kind, .black)
        // 删除 [2.1, 2.3)：与窗口 [1.75, 2.25) 相交 → 丢弃
        let dropped = document.removingOutputRange(lower: 2.1, upper: 2.3)
        XCTAssertTrue(dropped.transitions.isEmpty, "跨越转场窗口 → 删除")
    }

    func testMovingSeamKeepsTransitionAtSameIndex() {
        let document = EditDocument(
            clips: [EditClip(sourceStart: 0, sourceEnd: 1), EditClip(sourceStart: 1, sourceEnd: 2)],
            zoomSegments: [],
            transitions: [1: EditTransition(kind: .crossfade)])
        let moved = document.movingSeam(at: 1, toSourceTime: 1.5)
        XCTAssertEqual(moved?.transitions[1], EditTransition(kind: .crossfade))
    }

    /// 转场时长档位钳制（init 内 0.2…2s）。
    func testTransitionDurationClamp() throws {
        let document = EditDocument(
            clips: [EditClip(sourceStart: 0, sourceEnd: 1), EditClip(sourceStart: 1, sourceEnd: 2)],
            zoomSegments: [],
            transitions: [1: EditTransition(kind: .black, duration: 9)])
        let clamped = try XCTUnwrap(document.transitions[1]).duration
        XCTAssertEqual(clamped, 2, accuracy: 1e-9, "超上限钳 2s")
        let small = EditTransition(kind: .crossfade, duration: 0.05)
        XCTAssertEqual(small.duration, 0.2, accuracy: 1e-9, "低于下限钳 0.2s")
    }

    func testV3DraftDecodesWithoutTransitions() throws {
        let v3JSON = #"{"clips":[{"sourceStart":0,"sourceEnd":5,"speed":1}],"zoomSegments":[]}"#
        let decoded = try JSONDecoder().decode(EditDocument.self, from: Data(v3JSON.utf8))
        XCTAssertTrue(decoded.transitions.isEmpty)
    }

    func testCodableRoundtripWithTransitions() throws {
        let document = EditDocument(
            clips: [EditClip(sourceStart: 0, sourceEnd: 1), EditClip(sourceStart: 1, sourceEnd: 2)],
            zoomSegments: [],
            transitions: [1: EditTransition(kind: .crossfade, duration: 0.7)])
        let decoded = try JSONDecoder().decode(EditDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(decoded.transitions, document.transitions, "Int 键字典往返保值")
    }

    /// 溶解对侧源时间映射（纯函数）：前半取右 clip 头部、后半取左 clip 尾部。
    func testCrossfadeOtherSourceTime() throws {
        let clips = [EditClip(sourceStart: 0, sourceEnd: 1), EditClip(sourceStart: 1, sourceEnd: 2)]
        let windows = OfflineZoomRenderer.transitionWindows(
            clips: clips, transitions: [1: EditTransition(kind: .crossfade, duration: 0.4)])
        let window = windows[0]
        // 窗口 [0.8, 1.2) 边界 1.0：t=0.8 → 右 clip 源 1.0；t=0.9 → 1.05
        XCTAssertEqual(
            try XCTUnwrap(OfflineZoomRenderer.crossfadeOtherSourceTime(t: 0.8, window: window, clips: clips)),
            1.0, accuracy: 1e-9)
        XCTAssertEqual(
            try XCTUnwrap(OfflineZoomRenderer.crossfadeOtherSourceTime(t: 0.9, window: window, clips: clips)),
            1.1, accuracy: 1e-9)
        // 后半：t=1.1 → 左 clip 源 0.9（取尾部）
        XCTAssertEqual(
            try XCTUnwrap(OfflineZoomRenderer.crossfadeOtherSourceTime(t: 1.1, window: window, clips: clips)),
            0.9, accuracy: 1e-9)
    }
}

/// 选中下标钳制钉测（2026-11-22 右键崩溃回归）：波纹删除缩短 clips 后，过期
/// selectedClipIndex 必须被置 nil——否则 SwiftUI Binding 差分评估越界崩溃。
@MainActor
final class SelectionClampTests: XCTestCase {
    func testRippleDeleteClampsSelectedClipIndex() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SelectionClamp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("选中钳制夹具.mp4")
        try await EditorMovieFixture.makeMovie(at: url)
        let item = RecordingFileMetadata(
            id: url, url: url, name: url.lastPathComponent, sizeBytes: 1, createdAt: nil, duration: nil)
        let vm = RecordingListViewModel(
            store: RecordingFileStore(baseDirectory: directory), durationProvider: { _ in 0 })
        let model = ZoomEditorModel(item: item, listViewModel: vm)
        await model.loadMediaInfo()

        // 两 clip，选中第二个（下标 1）
        model.cutOutputRange(lower: 0.1, upper: 0.6)
        XCTAssertEqual(model.clips.count, 2)
        model.selectedClipIndex = 1
        XCTAssertEqual(model.clips.indices.contains(1), true)

        // 再删除第二个 clip 的整个成品区间 → clips 变 1 → 选中失效置 nil
        model.cutOutputRange(lower: 0.1, upper: 0.5)
        XCTAssertEqual(model.clips.count, 1, "第二个 clip 整段被删")
        XCTAssertNil(model.selectedClipIndex, "过期下标必须置 nil（防 Binding 越界）")
        XCTAssertFalse(model.clips.indices.contains(1))
    }
}

/// 转场循环钉测（批次 4c-2 无鼠标通道）：播放头最近接缝寻址 + 无→黑场→溶解→无 循环。
@MainActor
final class TransitionCycleTests: XCTestCase {
    func testCycleAndNearestSeamOnRealMovie() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransitionCycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("转场循环夹具.mp4")
        try await EditorMovieFixture.makeMovie(at: url)
        let item = RecordingFileMetadata(
            id: url, url: url, name: url.lastPathComponent, sizeBytes: 1, createdAt: nil, duration: nil)
        let vm = RecordingListViewModel(
            store: RecordingFileStore(baseDirectory: directory), durationProvider: { _ in 0 })
        let model = ZoomEditorModel(item: item, listViewModel: vm)
        await model.loadMediaInfo()

        // 建 3 clip（缝 1 = 0.1、缝 2 = 0.3、缝 3 = 0.4）
        model.cutOutputRange(lower: 0.1, upper: 0.6)
        model.cutOutputRange(lower: 0.3, upper: 0.4) // 尾段 0.1s > 最短源长 → 保留
        XCTAssertEqual(model.clips.count, 3)

        // 播放头在缝 2 附近（0.32）→ 最近缝 2（缝边界 0.1 / 0.3 / 0.4）
        model.seek(to: 0.32)
        XCTAssertEqual(model.nearestSeam(toOutputTime: 0.32), 2)
        XCTAssertEqual(model.transitionLabelAtPlayhead, "无")

        // 循环：无 → 黑场 → 溶解 → 无
        XCTAssertEqual(model.cycleTransitionNearPlayhead(), .black)
        XCTAssertEqual(model.transitions[2]?.kind, .black)
        XCTAssertEqual(model.cycleTransitionNearPlayhead(), .crossfade)
        XCTAssertEqual(model.transitions[2]?.kind, .crossfade)
        XCTAssertNil(model.cycleTransitionNearPlayhead(), "第三次循环 = 移除")
        XCTAssertNil(model.transitions[2])
        // 缝 1 未被误伤
        XCTAssertNil(model.transitions[1])
    }
}

/// 多转场共存钉测（2026-11-22「无法同时在多个删除点上做转场」回归）：
/// clipsDocument 曾漏带 transitions——applyClipEdit 从空转场文档读改写回，加 B 抹 A。
@MainActor
final class MultiTransitionTests: XCTestCase {
    func testMultipleTransitionsCoexistThroughModel() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultiTransition-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("多转场夹具.mp4")
        try await EditorMovieFixture.makeMovie(at: url)
        let item = RecordingFileMetadata(
            id: url, url: url, name: url.lastPathComponent, sizeBytes: 1, createdAt: nil, duration: nil)
        let vm = RecordingListViewModel(
            store: RecordingFileStore(baseDirectory: directory), durationProvider: { _ in 0 })
        let model = ZoomEditorModel(item: item, listViewModel: vm)
        await model.loadMediaInfo()

        // 三个 clip（缝 1、缝 2）
        model.cutOutputRange(lower: 0.1, upper: 0.5)
        model.cutOutputRange(lower: 0.3, upper: 0.4)
        XCTAssertEqual(model.clips.count, 3)

        // 两个删除点分别加转场 → 必须共存
        model.addTransition(at: 1, kind: .black)
        XCTAssertEqual(model.transitions[1]?.kind, .black)
        model.addTransition(at: 2, kind: .crossfade)
        XCTAssertEqual(model.transitions[2]?.kind, .crossfade)
        XCTAssertEqual(model.transitions[1]?.kind, .black, "加 B 后 A 必须仍在")

        // 草稿同步（两转场都在）
        let draft = vm.loadDraft(for: item, sourceDuration: 1.0)
        XCTAssertEqual(draft.transitions[1]?.kind, .black)
        XCTAssertEqual(draft.transitions[2]?.kind, .crossfade)

        // 改 A 时长不影响 B
        model.setTransitionDuration(at: 1, duration: 1.5)
        let transitionA = try XCTUnwrap(model.transitions[1])
        XCTAssertEqual(transitionA.duration, 1.5, accuracy: 1e-9)
        XCTAssertEqual(model.transitions[2]?.kind, .crossfade)
    }

    func testNearestSeamExcludesTailBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NearestSeam-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("近缝夹具.mp4")
        try await EditorMovieFixture.makeMovie(at: url)
        let item = RecordingFileMetadata(
            id: url, url: url, name: url.lastPathComponent, sizeBytes: 1, createdAt: nil, duration: nil)
        let vm = RecordingListViewModel(
            store: RecordingFileStore(baseDirectory: directory), durationProvider: { _ in 0 })
        let model = ZoomEditorModel(item: item, listViewModel: vm)
        await model.loadMediaInfo()
        model.cutOutputRange(lower: 0.1, upper: 0.5) // 两 clip，内部缝边界 0.1

        model.seek(to: 0.9) // 播放头在片尾附近
        XCTAssertEqual(model.nearestSeam(toOutputTime: 0.9), 1,
                       "片尾缝不参与——最近内部缝兜底")
        model.seek(to: 0.3)
        XCTAssertEqual(model.nearestSeam(toOutputTime: 0.3), 1)
    }
}
