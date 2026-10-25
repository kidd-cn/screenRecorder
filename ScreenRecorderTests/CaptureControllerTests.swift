import XCTest
import ScreenCaptureKit

@testable import ScreenRecorder

// MARK: - 测试夹具

/// 受控倒计时门闩：`open()` 预存一次放行 credit；`wait()` 消费 credit，无 credit 时让出主线程，
/// 所在 Task 取消时立即返回（生产 `Task.sleep` 取消语义在测试注入下的等价物）。
private final class ControlledGate: @unchecked Sendable {
    private let lock = NSLock()
    private var credits = 0

    func open() {
        lock.lock()
        defer { lock.unlock() }
        credits += 1
    }

    /// 同步消费一次 credit（锁的 acquire/release 收敛在同步方法内，避免 async 上下文解锁告警）。
    private func consumeCredit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard credits > 0 else { return false }
        credits -= 1
        return true
    }

    func wait() async {
        while true {
            if consumeCredit() { return }
            if Task.isCancelled { return }
            await Task.yield()
        }
    }
}

/// 可推进的单调时钟假实现（@unchecked Sendable：闭包跨 actor 捕获，值只在主线程读写）。
private final class UptimeBox: @unchecked Sendable {
    var value: TimeInterval = 0
}

/// waitForTick 区间记录器（钉倒计时 1s / elapsed 0.5s 节拍）。
private final class IntervalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval] = []

    func append(_ value: TimeInterval) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var snapshot: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

/// CaptureSessionManaging 假实现：记录调用、可注入 begin 失败与 finish 返回值。
private final class FakeSession: CaptureSessionManaging {
    var beginCallCount = 0
    var beginError: Error?
    var pauseCount = 0
    var resumeCount = 0
    var finishCount = 0
    var finishedURL: URL?

    func begin(_ config: RecordingConfiguration) async throws {
        beginCallCount += 1
        if let beginError { throw beginError }
    }

    func pause() { pauseCount += 1 }

    func resume() { resumeCount += 1 }

    func finish() async -> URL? {
        finishCount += 1
        return finishedURL
    }
}

/// RecordingNotifying spy：收集通知内容供断言。
@MainActor
private final class SpyNotifier: RecordingNotifying {
    var savedURLs: [URL] = []
    var failureMessages: [String] = []
    var warningCount = 0

    func notifySaved(fileURL: URL) { savedURLs.append(fileURL) }
    func notifyFailure(message: String) { failureMessages.append(message) }
    func notifyDiskSpaceWarning() { warningCount += 1 }
}

// MARK: - 状态机测试（brief Step 1 场景逐条 + 生命周期边界）

@MainActor
final class CaptureControllerTests: XCTestCase {
    private var tempDirectory: URL!
    private var session: FakeSession!
    private var notifier: SpyNotifier!
    private var uptime: UptimeBox!
    private var finishedFiles: [URL] = []

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureControllerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        finishedFiles = []
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    // MARK: 夹具

    private func makeController(countdownSeconds: Int) -> CaptureController {
        let session = FakeSession()
        let notifier = SpyNotifier()
        let uptimeBox = UptimeBox()
        self.session = session
        self.notifier = notifier
        self.uptime = uptimeBox
        let controller = CaptureController(
            session: session,
            store: RecordingFileStore(baseDirectory: tempDirectory),
            countdownSeconds: countdownSeconds,
            onFinishedFile: { [weak self] url in self?.finishedFiles.append(url) }
        )
        // 测试缝默认值：与运行环境 TCC 解耦；等待 1ms（可被取消打断，不 busy-spin）
        controller.notifier = notifier
        controller.monotonicNow = { uptimeBox.value }
        controller.waitForTick = { _ in try await Task.sleep(nanoseconds: 1_000_000) }
        controller.screenPermissionProbe = { true }
        return controller
    }

    private func makeConfig(outputURL: URL? = nil) -> RecordingConfiguration {
        RecordingConfiguration(
            mode: .display(1),
            captureSystemAudio: false,
            captureMicrophone: false,
            micVolume: 1.0,
            includeCamera: false,
            fps: 30,
            codec: .h264,
            outputURL: outputURL ?? tempDirectory.appendingPathComponent("config-target.mp4"),
            clickHighlightEnabled: false
        )
    }

    private func waitForState(
        _ target: CaptureState,
        of controller: CaptureController,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while controller.state != target && Date() < deadline {
            await Task.yield()
        }
        XCTAssertEqual(controller.state, target, "等待状态 \(target) 超时", file: file, line: line)
    }

    // MARK: - brief Step 1：countdownSeconds: 0 直接录制路径

    func testStartWithZeroCountdownEntersRecordingDirectly() async {
        let controller = makeController(countdownSeconds: 0)

        await controller.start(mode: .display(1), config: makeConfig())

        XCTAssertEqual(controller.state, .recording)
        XCTAssertEqual(session.beginCallCount, 1)
        XCTAssertEqual(controller.elapsed, 0, accuracy: 0.001)
    }

    func testConcurrentDoubleStartStartsOnlyOneSession() async {
        let controller = makeController(countdownSeconds: 0)

        async let first: Void = controller.start(mode: .display(1), config: makeConfig())
        async let second: Void = controller.start(mode: .display(1), config: makeConfig())
        await first
        await second

        XCTAssertEqual(session.beginCallCount, 1, "并发双 start（guard 与 await 之间的窗口）只允许一场录制")
    }

    func testPauseTransitionsToPausedAndResumeBackToRecording() async {
        let controller = makeController(countdownSeconds: 0)
        await controller.start(mode: .display(1), config: makeConfig())

        controller.pause()
        XCTAssertEqual(controller.state, .paused)
        XCTAssertEqual(session.pauseCount, 1)

        controller.resume()
        XCTAssertEqual(controller.state, .recording)
        XCTAssertEqual(session.resumeCount, 1)
    }

    func testStopFinalizesDeliversFileAndReturnsToIdle() async throws {
        let controller = makeController(countdownSeconds: 0)
        let url = tempDirectory.appendingPathComponent("out.mp4")
        try Data("x".utf8).write(to: url)
        session.finishedURL = url
        await controller.start(mode: .display(1), config: makeConfig())

        controller.stop()
        XCTAssertEqual(controller.state, .finishing) // 去抖位同步置位（按钮连点屏障）

        await waitForState(.idle, of: controller)
        XCTAssertEqual(session.finishCount, 1)
        XCTAssertEqual(finishedFiles, [url])
    }

    func testPauseInIdleIsNoOp() {
        let controller = makeController(countdownSeconds: 0)

        controller.pause()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(session.pauseCount, 0)
    }

    func testResumeInIdleIsNoOp() {
        let controller = makeController(countdownSeconds: 0)

        controller.resume()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(session.resumeCount, 0)
    }

    // MARK: - 修复轮 1（Minor #6）：stop/cancelAndDiscard 于 .idle 的显式 no-op 钉测

    func testStopInIdleIsNoOp() {
        let controller = makeController(countdownSeconds: 0)

        controller.stop()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(session.finishCount, 0)
        XCTAssertTrue(finishedFiles.isEmpty)
    }

    func testCancelAndDiscardInIdleIsNoOp() {
        let controller = makeController(countdownSeconds: 0)

        controller.cancelAndDiscard()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(session.finishCount, 0)
        XCTAssertTrue(finishedFiles.isEmpty)
    }

    // MARK: - brief Step 1：倒计时路径

    func testCountdownDecrementAndCancelPreventsBegin() async {
        let gate = ControlledGate()
        let intervals = IntervalRecorder()
        let controller = makeController(countdownSeconds: 2)
        controller.waitForTick = { [gate, intervals] interval in
            intervals.append(interval)
            await gate.wait()
        }
        let task = Task { await controller.start(mode: .display(1), config: makeConfig()) }

        await waitForState(.countdown(secondsLeft: 2), of: controller)
        gate.open()
        await waitForState(.countdown(secondsLeft: 1), of: controller)

        controller.cancelAndDiscard()
        await waitForState(.idle, of: controller)
        await task.value

        XCTAssertEqual(session.beginCallCount, 0, "倒计时被打断：session.begin 不得被调")
        XCTAssertEqual(session.finishCount, 0)
        XCTAssertEqual(intervals.snapshot, [1.0, 1.0], "每步展示各等待 1 秒（第二步被取消打断）")
        XCTAssertTrue(finishedFiles.isEmpty)
    }

    func testCountdownCompletionBeginsRecording() async {
        let gate = ControlledGate()
        let controller = makeController(countdownSeconds: 2)
        controller.waitForTick = { [gate] _ in await gate.wait() }
        let task = Task { await controller.start(mode: .display(1), config: makeConfig()) }

        await waitForState(.countdown(secondsLeft: 2), of: controller)
        gate.open()
        await waitForState(.countdown(secondsLeft: 1), of: controller)
        gate.open()
        await waitForState(.recording, of: controller)
        await task.value

        XCTAssertEqual(session.beginCallCount, 1)
    }

    func testCountdownSingleSecondStartsAtOne() async {
        let gate = ControlledGate()
        let controller = makeController(countdownSeconds: 1)
        controller.waitForTick = { [gate] _ in await gate.wait() }
        let task = Task { await controller.start(mode: .display(1), config: makeConfig()) }

        await waitForState(.countdown(secondsLeft: 1), of: controller)
        gate.open()
        await waitForState(.recording, of: controller)
        await task.value

        XCTAssertEqual(session.beginCallCount, 1)
    }

    // MARK: - 生命周期边界：收尾去抖与丢弃

    func testStopIsDebouncedDuringFinishing() async {
        let controller = makeController(countdownSeconds: 0)
        await controller.start(mode: .display(1), config: makeConfig())

        controller.stop()
        controller.stop() // .finishing 期间重复触发 → no-op
        controller.cancelAndDiscard() // 同理不得触发第二次收尾

        await waitForState(.idle, of: controller)
        XCTAssertEqual(session.finishCount, 1)
    }

    func testCancelAndDiscardDuringRecordingDeletesFileWithoutCallback() async throws {
        let controller = makeController(countdownSeconds: 0)
        let url = tempDirectory.appendingPathComponent("discard.mp4")
        try Data("x".utf8).write(to: url)
        session.finishedURL = url
        await controller.start(mode: .display(1), config: makeConfig())

        controller.cancelAndDiscard()

        await waitForState(.idle, of: controller)
        XCTAssertEqual(session.finishCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "丢弃：成片文件应被删除")
        XCTAssertTrue(finishedFiles.isEmpty, "丢弃：onFinishedFile 不得回调")
    }

    // MARK: - 修复轮 1（Minor #1）：正常停止但未产出成片不再静默

    func testStopWithoutProducedFileNotifiesMiss() async {
        let controller = makeController(countdownSeconds: 0)
        session.finishedURL = nil // finish() 无成片（零样本 nothingWritten 等）
        await controller.start(mode: .display(1), config: makeConfig())

        controller.stop()

        await waitForState(.idle, of: controller)
        XCTAssertEqual(session.finishCount, 1)
        XCTAssertTrue(finishedFiles.isEmpty)
        XCTAssertEqual(notifier.failureMessages.count, 1, "正常停止但无成片：必须通知，不得静默")
        XCTAssertTrue(notifier.failureMessages[0].contains("未能保存成片"))
    }

    func testDiscardWithoutProducedFileStaysSilent() async {
        let controller = makeController(countdownSeconds: 0)
        session.finishedURL = nil
        await controller.start(mode: .display(1), config: makeConfig())

        controller.cancelAndDiscard() // 丢弃本意即无产出：不通知

        await waitForState(.idle, of: controller)
        XCTAssertTrue(notifier.failureMessages.isEmpty)
    }

    // MARK: - 修复轮 1（Minor #3）：begin 失败文案为「未能开始」语义

    func testBeginFailureMessageUsesNotStartedWording() async {
        let controller = makeController(countdownSeconds: 0)
        session.beginError = CaptureSessionError.insufficientDiskSpace(freeBytes: 100, requiredBytes: 500_000_000)

        await controller.start(mode: .display(1), config: makeConfig())

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(notifier.failureMessages.count, 1)
        XCTAssertTrue(notifier.failureMessages[0].contains("未能开始"), "begin 失败文案：实际 \(notifier.failureMessages[0])")
        XCTAssertFalse(notifier.failureMessages[0].contains("录制中断"), "从未开始不得写成中断")
    }

    // MARK: - 失败通道（T18 依赖）：handleSessionFailure 自动保存

    func testSessionFailureAutoSavesFileAndNotifies() async throws {
        let controller = makeController(countdownSeconds: 0)
        let url = tempDirectory.appendingPathComponent("failure.mp4")
        try Data("x".utf8).write(to: url)
        session.finishedURL = url
        await controller.start(mode: .display(1), config: makeConfig())

        controller.handleSessionFailure(NSError(domain: "test", code: -1))

        await waitForState(.idle, of: controller)
        XCTAssertEqual(session.finishCount, 1, "失败必须触发 stop 保存路径")
        XCTAssertEqual(finishedFiles, [url], "失败自动保存：成片保留")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(notifier.failureMessages.count, 1)
        XCTAssertTrue(notifier.failureMessages[0].contains("已自动保存"))
        XCTAssertFalse(notifier.failureMessages[0].contains("重新授权"), "普通失败不混入权限引导文案")
    }

    func testSessionFailureReentryIsGuarded() async {
        let controller = makeController(countdownSeconds: 0)
        await controller.start(mode: .display(1), config: makeConfig())

        controller.handleSessionFailure(NSError(domain: "test", code: -1))
        XCTAssertEqual(controller.state, .finishing)
        controller.handleSessionFailure(NSError(domain: "test", code: -2)) // 重入 → no-op

        await waitForState(.idle, of: controller)
        XCTAssertEqual(session.finishCount, 1)
        XCTAssertEqual(notifier.failureMessages.count, 1)
    }

    func testPermissionClassFailureGuidesReauthorization() async {
        let controller = makeController(countdownSeconds: 0)
        await controller.start(mode: .display(1), config: makeConfig())

        // SCStream 权限族错误码（TCC 授权失效/进程陈旧场景，预检可能仍为 true——以错误码为准）
        controller.handleSessionFailure(
            NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue))

        await waitForState(.idle, of: controller)
        let message = notifier.failureMessages.first ?? ""
        XCTAssertTrue(message.contains("重新授权") || message.contains("重启"), "权限类失败须引导重启/重授权，实际：\(message)")
    }

    func testStalePermissionPreflightGuidesReauthorization() async {
        let controller = makeController(countdownSeconds: 0)
        await controller.start(mode: .display(1), config: makeConfig())
        controller.screenPermissionProbe = { false } // 运行时预检已无授权

        controller.handleSessionFailure(NSError(domain: "test", code: -1))

        await waitForState(.idle, of: controller)
        let message = notifier.failureMessages.first ?? ""
        XCTAssertTrue(message.contains("重新授权") || message.contains("重启"))
    }

    func testDiskCriticalInterruptionMentionsDiskAndSaves() async throws {
        let controller = makeController(countdownSeconds: 0)
        let url = tempDirectory.appendingPathComponent("disk.mp4")
        try Data("x".utf8).write(to: url)
        session.finishedURL = url
        await controller.start(mode: .display(1), config: makeConfig())

        controller.handleSessionFailure(CaptureSessionError.diskSpaceCritical)

        await waitForState(.idle, of: controller)
        XCTAssertEqual(finishedFiles, [url])
        XCTAssertTrue(notifier.failureMessages[0].contains("磁盘"))
    }

    // MARK: - begin 失败

    func testBeginFailureReturnsToIdleAndNotifiesWithoutFile() async {
        let controller = makeController(countdownSeconds: 0)
        session.beginError = CaptureSessionError.insufficientDiskSpace(freeBytes: 100, requiredBytes: 500_000_000)

        await controller.start(mode: .display(1), config: makeConfig())

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(session.beginCallCount, 1)
        XCTAssertEqual(session.finishCount, 0, "begin 失败无会话可收尾")
        XCTAssertTrue(finishedFiles.isEmpty)
        XCTAssertEqual(notifier.failureMessages.count, 1)
        XCTAssertTrue(notifier.failureMessages[0].contains("磁盘"))
    }

    // MARK: - elapsed：不含暂停时长 + 0.5s 刷新节拍

    func testElapsedExcludesPausedDuration() async {
        let controller = makeController(countdownSeconds: 0)
        uptime.value = 100 // 段起点
        await controller.start(mode: .display(1), config: makeConfig())

        uptime.value = 110 // 录制 10s
        controller.pause()
        XCTAssertEqual(controller.elapsed, 10, accuracy: 0.001)

        uptime.value = 115 // 暂停 5s 不累计
        controller.resume()
        XCTAssertEqual(controller.elapsed, 10, accuracy: 0.001)

        uptime.value = 118 // 再录 3s
        controller.pause()
        XCTAssertEqual(controller.elapsed, 13, accuracy: 0.001)
    }

    func testElapsedTimerRefreshesAtHalfSecondWhileRecording() async {
        let intervals = IntervalRecorder()
        let controller = makeController(countdownSeconds: 0)
        controller.waitForTick = { [intervals] interval in
            intervals.append(interval)
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        await controller.start(mode: .display(1), config: makeConfig())
        controller.stop()
        await waitForState(.idle, of: controller)

        XCTAssertTrue(intervals.snapshot.contains(0.5), "录制期 elapsed 计时器节拍应为 0.5s，实际：\(intervals.snapshot)")
        XCTAssertFalse(intervals.snapshot.contains(1.0), "elapsed 计时器不得复用倒计时节拍")
    }

    // MARK: - 磁盘警告（stop-supersedes-warn）

    func testDiskSpaceWarningOnlyWhileSessionActive() async {
        let controller = makeController(countdownSeconds: 0)

        controller.showDiskSpaceWarning() // idle：抑制
        XCTAssertEqual(notifier.warningCount, 0)

        await controller.start(mode: .display(1), config: makeConfig())
        controller.showDiskSpaceWarning()
        XCTAssertEqual(notifier.warningCount, 1)

        controller.stop()
        await waitForState(.idle, of: controller)
        controller.showDiskSpaceWarning() // 收尾后（含收尾中）：stop 优先，不再警告
        XCTAssertEqual(notifier.warningCount, 1)
    }
}
