import Combine
import CoreGraphics
import XCTest

@testable import ScreenRecorder

/// ZoomEditor（P9/T18 缩放分段编辑器）逻辑层无头钉测：brief Step 1 四测试
/// （testDraftRoundTrip / testDraftDeletedWithMovie / testEstimateFormula /
/// testSegmentEditGoesThroughValidate）+ 缩放渲染编排钉测（单飞门 + 进度 hop +
/// 编排边界 validate + 自动入列）。UI 面（时间线拖拽/AVPlayer 预览）不做无头断言
/// ——归批次真机验收清单。
@MainActor
final class ZoomEditorLogicTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZoomEditorLogicTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    private func makeViewModel(duration: TimeInterval = 42.0) -> RecordingListViewModel {
        RecordingListViewModel(
            store: RecordingFileStore(baseDirectory: directory),
            durationProvider: { _ in duration })
    }

    /// 磁盘真实存在的成片条目（草稿挂文件名随删，须真文件验证）。
    private func writeMovie(named name: String) throws -> RecordingFileMetadata {
        let url = directory.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return RecordingFileMetadata(
            id: url, url: url, name: name, sizeBytes: 1, createdAt: nil, duration: nil)
    }

    private func makeItem(named name: String) -> RecordingFileMetadata {
        RecordingFileMetadata(
            id: directory.appendingPathComponent(name),
            url: directory.appendingPathComponent(name),
            name: name, sizeBytes: 0, createdAt: nil, duration: nil)
    }

    private static func draftURL(for item: RecordingFileMetadata) -> URL {
        RecordingListViewModel.draftURL(for: item.url)
    }

    // MARK: - 草稿持久化（<成片>.zoomdraft.json，Codable JSON 数组）

    /// 草稿往返：文件名格式（成片全名追加 `.zoomdraft.json`，与成片同目录）、Codable
    /// 往返保真、存/读两侧均过 `ZoomSegment.validate`（存前闸 + 再用前闸）、坏草稿与
    /// 缺草稿归空表不抛。
    func testDraftRoundTrip() throws {
        let vm = makeViewModel()
        let item = try writeMovie(named: "录屏_2026-10-30_09-00-00.mp4")

        XCTAssertEqual(
            Self.draftURL(for: item).lastPathComponent,
            "录屏_2026-10-30_09-00-00.mp4.zoomdraft.json",
            "草稿文件名 = <成片全名>.zoomdraft.json（与成片同目录）")

        let segments = [
            ZoomSegment(start: 0.5, end: 2.0, level: 1.6, center: CGPoint(x: 0.25, y: 0.75)),
            ZoomSegment(start: 3.0, end: 4.5, level: 1.9, center: CGPoint(x: 1.0, y: 0.0)),
        ]
        try vm.saveDraft(segments, for: item)
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.draftURL(for: item).path), "草稿落盘")
        XCTAssertEqual(vm.loadDraft(for: item), segments, "Codable JSON 数组往返保真")

        // 存储闸：野值存入 → 落盘前 validate（level 就近钳档、center 钳 0…1）
        try vm.saveDraft([ZoomSegment(start: 5, end: 6, level: 9.9, center: CGPoint(x: 3, y: -1))], for: item)
        XCTAssertEqual(
            vm.loadDraft(for: item),
            [ZoomSegment(start: 5, end: 6, level: 1.9, center: CGPoint(x: 1.0, y: 0.0))],
            "存前过 validate：野值不落盘（x=3 钳 1.0、y=-1 钳 0.0）")

        // 读取闸：手改草稿野值（外部编辑形态）→ 读出规整（再用前的闸）
        let wild = try JSONEncoder().encode(
            [ZoomSegment(start: 1, end: 2, level: 0.1, center: CGPoint(x: -5, y: 5))])
        try wild.write(to: Self.draftURL(for: item))
        XCTAssertEqual(
            vm.loadDraft(for: item),
            [ZoomSegment(start: 1, end: 2, level: 1.35, center: CGPoint(x: 0, y: 1))],
            "读出过 validate：手改野值归一")

        // 坏草稿（非 JSON）→ 空表不抛（按无草稿开新编辑）
        try Data("not json".utf8).write(to: Self.draftURL(for: item))
        XCTAssertEqual(vm.loadDraft(for: item), [], "坏草稿归空表")

        // 无草稿 → 空表
        try FileManager.default.removeItem(at: Self.draftURL(for: item))
        XCTAssertEqual(vm.loadDraft(for: item), [], "缺草稿归空表")
    }

    /// 成片删除时草稿随删（brief 钉定）：挂进 RecordingListViewModel 现有 delete 路径。
    func testDraftDeletedWithMovie() async throws {
        let vm = makeViewModel()
        let item = try writeMovie(named: "录屏_2026-10-30_10-00-00.mp4")
        try vm.saveDraft(
            [ZoomSegment(start: 0, end: 1, level: 1.6, center: CGPoint(x: 0.5, y: 0.5))],
            for: item)
        await vm.refresh()
        XCTAssertEqual(vm.items.count, 1, "成片在列（草稿 .json 不入成片列表）")

        vm.delete(vm.items[0])

        XCTAssertFalse(FileManager.default.fileExists(atPath: item.url.path), "成片已删")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: Self.draftURL(for: item).path),
            "草稿随成片删除")
        XCTAssertEqual(vm.loadDraft(for: item), [], "删除后再读为空表")
    }

    // MARK: - 预估大小公式（源码率 × 有效时长 × 编码系数）

    /// 预估大小 = 源码率（size ÷ 源时长）× 有效时长 × 编码系数（h264 1.0 / hevc 0.65）。
    /// 有效时长 = 源时长（缩放分段不改时间线——OfflineZoomRenderer「音画时间线不动」钉定，
    /// 分段只改画面）。退化输入（size ≤ 0 / 时长非正非有限）归 0（UI 显示 —）。
    func testEstimateFormula() {
        // 源 10MB / 100s → 码率 100,000 B/s × 100s：h264 1.0 → 10MB、hevc 0.65 → 6.5MB
        XCTAssertEqual(
            ZoomEditorLogic.estimatedExportBytes(
                sourceSizeBytes: 10_000_000, sourceDuration: 100, codec: .h264),
            10_000_000, "h264 系数 1.0：同族重编码近似持平")
        XCTAssertEqual(
            ZoomEditorLogic.estimatedExportBytes(
                sourceSizeBytes: 10_000_000, sourceDuration: 100, codec: .hevc),
            6_500_000, "hevc 系数 0.65：等观感省 30–40% 码率的经验中值")

        // 非整除取整（1_000_001 B / 2s → 码率 500000.5 × 2s × 0.65 = 650000.65 → 就近 650001）
        XCTAssertEqual(
            ZoomEditorLogic.estimatedExportBytes(
                sourceSizeBytes: 1_000_001, sourceDuration: 2, codec: .hevc),
            650_001, "非整数结果四舍五入")

        // 退化输入归 0
        XCTAssertEqual(
            ZoomEditorLogic.estimatedExportBytes(sourceSizeBytes: 0, sourceDuration: 100, codec: .h264), 0)
        XCTAssertEqual(
            ZoomEditorLogic.estimatedExportBytes(sourceSizeBytes: 1_000, sourceDuration: 0, codec: .h264), 0)
        XCTAssertEqual(
            ZoomEditorLogic.estimatedExportBytes(sourceSizeBytes: 1_000, sourceDuration: -5, codec: .h264), 0)
        XCTAssertEqual(
            ZoomEditorLogic.estimatedExportBytes(
                sourceSizeBytes: 1_000, sourceDuration: .nan, codec: .h264), 0)
    }

    // MARK: - 分段修改统一闸（所有 UI 编辑路径 → ZoomSegment.validate 后再存/再用）

    /// 编辑器的增/调档/九宫格中心/拖端点/删全部经 `ZoomEditorLogic.applyEdit` 统一闸
    /// → `ZoomSegment.validate`（排序/钳制/去重叠保留先者）；落库即存草稿；
    /// 拖端点先钳邻居边界（保先者语义下跨界拖拽不得被当重叠丢弃）。
    func testSegmentEditGoesThroughValidate() throws {
        let vm = makeViewModel()
        let item = makeItem(named: "录屏_2026-10-30_11-00-00.mp4")
        let model = ZoomEditorModel(item: item, listViewModel: vm)
        XCTAssertEqual(model.segments, [], "无草稿开新编辑 = 空表")

        // 增：播放头 2.0s → ±hold 窗 [1, 3]，新段即选中
        model.addSegment(at: 2.0)
        XCTAssertEqual(
            model.segments,
            [ZoomSegment(start: 1.0, end: 3.0, level: 1.6, center: CGPoint(x: 0.5, y: 0.5))])
        XCTAssertEqual(model.selectedIndex, 0, "新增段即选中")
        XCTAssertEqual(vm.loadDraft(for: item), model.segments, "落库即存草稿")

        // 调档：野档位 2.5 → 就近钳 1.9
        model.setLevel(at: 0, level: 2.5)
        XCTAssertEqual(model.segments[0].level, 1.9, "档位经 validate 钳最近合法档")

        // 九宫格中心：视觉顶行右列 → x/y 高位（center 为 CI 画布 y 向上口径，y=1 画面顶）
        model.setCenter(atIndex: 0, ninePatchRow: 0, column: 2)
        XCTAssertEqual(model.segments[0].center, CGPoint(x: 5.0 / 6.0, y: 5.0 / 6.0))

        // 九宫格双向映射对称（9 格：center(row:column:) 经 cell(for:) 原路返回）
        for row in 0..<3 {
            for column in 0..<3 {
                let cell = ZoomEditorLogic.ninePatchCell(
                    for: ZoomEditorLogic.ninePatchCenter(row: row, column: column))
                XCTAssertEqual(cell.row, row, "行映射对称（row \(row)）")
                XCTAssertEqual(cell.column, column, "列映射对称（column \(column)）")
            }
        }

        // 重叠编辑被 validate 丢弃（保留先者）：同播放头重复添加 → 段表不变
        model.addSegment(at: 2.0)
        XCTAssertEqual(model.segments.count, 1, "与既有段重叠 → validate 丢新段")

        // 拖端点：提案越前段边界 → 钳到前段 end（半开相邻合法），编辑段存活不被丢
        model.addSegment(at: 5.0)
        XCTAssertEqual(model.segments.count, 2)
        model.commitDrag(index: 1, start: 2.5, end: 5.5)
        XCTAssertEqual(model.segments[1].start, 3.0, "入点钳前段 end")
        XCTAssertEqual(model.segments[1].end, 5.5)
        XCTAssertEqual(model.selectedIndex, 1, "编辑存活段保持选中")

        // 删
        model.removeSegment(at: 0)
        XCTAssertEqual(model.segments.map(\.start), [3.0])
        XCTAssertNil(model.selectedIndex, "删除后清选中")

        // 终态草稿与内存一致
        XCTAssertEqual(vm.loadDraft(for: item), model.segments)
    }

    // MARK: - 缩放渲染编排（单飞门 + 进度 hop + 编排边界 validate + 自动入列）

    /// 编辑器渲染有自己的运行态（controller 裁定：单调递增 ID + 独立忙布尔，不复用
    /// T16 exportRunID 回收形态）：进行中第二次调用被单飞门忽略；渲染回调主线程外
    /// （OfflineZoomRenderer 契约）→ 进度经 VM hop 主线程且完成后复位；segments 在
    /// 编排边界过 validate 再进渲染缝；成功后自动入列（refresh——按 `_压缩.mp4` 先例，
    /// T18 默认裁定）。
    func testZoomRenderProgressHopsToMainAndSingleFlight() async throws {
        let outputURL = directory.appendingPathComponent("录屏_2026-10-30_12-00-00_缩放.mp4")
        let seam = GatedZoomRenderer(outputURL: outputURL)
        let vm = RecordingListViewModel(
            store: RecordingFileStore(baseDirectory: directory),
            durationProvider: { _ in 42.0 },
            zoomRenderer: seam)
        let item = makeItem(named: "录屏_2026-10-30_12-00-00.mp4")

        var deliveries: [(value: Double, onMain: Bool)] = []
        let progressDelivered = expectation(description: "假缝主线程外推送的 0.42 送达主线程")
        let cancellable = vm.$zoomRenderProgress.sink { value in
            guard let value else { return } // 完成复位(nil)不计
            deliveries.append((value, Thread.isMainThread))
            if value == 0.42 { progressDelivered.fulfill() }
        }
        defer { cancellable.cancel() }

        let wildSegments = [
            ZoomSegment(start: 3.0, end: 4.0, level: 2.5, center: CGPoint(x: 0.5, y: 0.5)),
            ZoomSegment(start: 1.0, end: 2.0, level: 1.6, center: CGPoint(x: 1.4, y: -0.2)),
        ]
        let run = Task {
            await vm.renderZoom(
                item, segments: wildSegments,
                options: ExportVideoOptions(fps: nil, maxHeight: nil, codec: .h264))
        }
        await fulfillment(of: [seam.entered], timeout: 5)

        // 单飞：进行中第二次调用直接忽略
        await vm.renderZoom(
            item, segments: [],
            options: ExportVideoOptions(fps: nil, maxHeight: nil, codec: .h264))
        XCTAssertEqual(seam.callCount, 1, "进行中第二次调用被单飞门忽略")

        seam.resumeGate()
        await run.value
        await fulfillment(of: [progressDelivered], timeout: 5)

        XCTAssertEqual(seam.callCount, 1, "放行后仍只有一次真实渲染")
        XCTAssertEqual(
            seam.capturedSegments, ZoomSegment.validate(wildSegments),
            "编排边界先过 validate 再进渲染缝（排序/钳档/钳中心）")
        XCTAssertEqual(deliveries.map(\.value), [0.0, 0.42], "进度序列：模型置 0 + 假缝主线程外推送 0.42")
        XCTAssertTrue(
            deliveries.allSatisfy(\.onMain),
            "全部进度投递必须发生在主线程（渲染回调主线程外 → VM hop 契约）：\(deliveries)")
        XCTAssertNil(vm.zoomRenderProgress, "完成后进度复位空闲")
        XCTAssertEqual(
            vm.items.map(\.name), ["录屏_2026-10-30_12-00-00_缩放.mp4"],
            "成功后自动入列（refresh——按 _压缩.mp4 先例）")
    }
}

// MARK: - 缩放渲染编排测试替身（OfflineZoomRenderer 为 enum 静态面不可替换——经缝注入）

/// 可门控假渲染缝：进入即置位 entered、主线程外推 0.42、挂在续体上等测试放行；
/// 放行后写真实 `.mp4` 空文件（自动入列断言消费）返回。
/// `@unchecked Sendable`：可变状态全在 NSLock 内（RecordingListViewModelTests StoreBox
/// 同纪律）；加锁收拢进同步方法——NSLock.lock 在 async 函数体内直接调用为不可用诊断。
private final class GatedZoomRenderer: ZoomRendering, @unchecked Sendable {
    let entered = XCTestExpectation(description: "渲染缝进入")
    private let outputURL: URL
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var callCountStorage = 0
    private var capturedSegmentsStorage: [ZoomSegment] = []

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCountStorage
    }

    var capturedSegments: [ZoomSegment] {
        lock.lock()
        defer { lock.unlock() }
        return capturedSegmentsStorage
    }

    func render(
        sourceURL: URL, segments: [ZoomSegment], options: ExportVideoOptions,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        record(segments)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            storeContinuation(continuation)
            DispatchQueue.global().async {
                progress(0.42) // T15/T17 契约：进度回调主线程外
                self.entered.fulfill()
            }
        }
        await MainActor.run {} // VM 续体晚于进度 hop 入队（主队列 FIFO），断言不受竞态干扰
        try? Data().write(to: outputURL)
        return outputURL
    }

    /// 放行门（续体在异步函数体外的同步方法内存取/恢复）。
    func resumeGate() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }

    private func record(_ segments: [ZoomSegment]) {
        lock.lock()
        defer { lock.unlock() }
        callCountStorage += 1
        capturedSegmentsStorage = segments
    }

    private func storeContinuation(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        self.continuation = continuation
    }
}
