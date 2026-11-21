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
