import AppKit
import XCTest

@testable import ScreenRecorder

// MARK: - 测试夹具（与 CaptureControllerTests 同款：受控门闩 + FakeSession）

/// 受控倒计时门闩：`open()` 预存放行 credit；`wait()` 消费 credit，无 credit 时让出主线程。
private final class ControlledGate: @unchecked Sendable {
    private let lock = NSLock()
    private var credits = 0

    func open() {
        lock.lock()
        defer { lock.unlock() }
        credits += 1
    }

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

/// CaptureSessionManaging 假实现：记录调用。
private final class FakeSession: CaptureSessionManaging {
    var beginCallCount = 0
    var finishCount = 0

    func begin(_ config: RecordingConfiguration) async throws {
        beginCallCount += 1
    }

    func pause() {}
    func resume() {}

    func finish() async -> URL? {
        finishCount += 1
        return nil
    }
}

/// 不真正上屏的记录窗口：orderFrontRegardless/orderOut 只计数（测试期不打扰用户桌面）。
private final class SpyOverlayWindow: NSWindow {
    var orderFrontCount = 0
    var orderOutCount = 0

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
    }

    override func orderFrontRegardless() { orderFrontCount += 1 }
    override func orderOut(_ sender: Any?) { orderOutCount += 1 }
}

/// 窗口工厂调用计数（钉窗口复用：多次倒计时只建一次窗口）。
private final class CounterBox {
    var value = 0
}

// MARK: - 覆盖层状态驱动 show/hide 逻辑（T12 无头可测部分）

@MainActor
final class CountdownOverlayControllerTests: XCTestCase {
    private var tempDirectory: URL!
    private var session: FakeSession!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CountdownOverlayTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    // MARK: 夹具

    private func makeController(countdownSeconds: Int) -> CaptureController {
        let session = FakeSession()
        self.session = session
        let controller = CaptureController(
            session: session,
            store: RecordingFileStore(baseDirectory: tempDirectory),
            countdownSeconds: countdownSeconds,
            onFinishedFile: { _ in }
        )
        controller.waitForTick = { _ in try await Task.sleep(nanoseconds: 1_000_000) }
        controller.screenPermissionProbe = { true }
        return controller
    }

    private func makeConfig() -> RecordingConfiguration {
        RecordingConfiguration(
            mode: .display(1),
            captureSystemAudio: false,
            captureMicrophone: false,
            micVolume: 1.0,
            includeCamera: false,
            fps: 30,
            codec: .h264,
            outputURL: tempDirectory.appendingPathComponent("overlay-test.mp4"),
            clickHighlightEnabled: false
        )
    }

    private func makeOverlay(
        controller: CaptureController,
        window: SpyOverlayWindow,
        factoryCalls: CounterBox = CounterBox(),
        onCancel: @escaping () -> Void = {}
    ) -> CountdownOverlayController {
        CountdownOverlayController(
            controller: controller,
            onCancelAction: onCancel,
            windowFactory: {
                factoryCalls.value += 1
                return window
            }
        )
    }

    /// 轮询等待（主 actor Task.yield 让订阅 apply 的 Task 跳转落地）。
    private func waitFor(
        _ condition: @escaping () -> Bool,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition(), "等待条件超时", file: file, line: line)
    }

    // MARK: - 状态驱动 show/hide

    func testIdleInitiallyDoesNotShowOverlay() async {
        let controller = makeController(countdownSeconds: 2)
        let window = SpyOverlayWindow()
        _ = makeOverlay(controller: controller, window: window)

        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(window.orderFrontCount, 0, "初始 idle（订阅首值）不得显示覆盖层")
        XCTAssertEqual(controller.state, .idle, "前置：夹具确实处于 idle")
    }

    func testCountdownShowsOverlayUpdatesNumberPerTickAndHidesOnCompletion() async {
        let gate = ControlledGate()
        let controller = makeController(countdownSeconds: 2)
        controller.waitForTick = { [gate] _ in await gate.wait() }
        let window = SpyOverlayWindow()
        let overlay = makeOverlay(controller: controller, window: window)
        let task = Task { await controller.start(mode: .display(1), config: makeConfig()) }

        await waitFor { window.orderFrontCount == 1 }
        await waitFor { overlay.model.secondsLeft == 2 }

        gate.open()
        await waitFor { overlay.model.secondsLeft == 1 }
        XCTAssertEqual(window.orderFrontCount, 1, "逐秒 tick 只换数字，不得重复 orderFront 重建显示")

        gate.open()
        await waitFor { controller.state == .recording }
        await waitFor { window.orderOutCount == 1 }
        XCTAssertNil(overlay.model.secondsLeft, "离开倒计时（完成进录制）：覆盖层收起且数字清空")
        await task.value

        XCTAssertEqual(session.beginCallCount, 1)
    }

    // MARK: - 取消接线（生产同款：取消出口 = cancelAndDiscard）

    func testCancelDuringCountdownRoutesActionHidesAndPreventsBegin() async {
        let gate = ControlledGate()
        let controller = makeController(countdownSeconds: 5)
        controller.waitForTick = { [gate] _ in await gate.wait() }
        let window = SpyOverlayWindow()
        let overlay = makeOverlay(controller: controller, window: window, onCancel: { [weak controller] in
            Task { @MainActor in controller?.cancelAndDiscard() }
        })
        let task = Task { await controller.start(mode: .display(1), config: makeConfig()) }

        await waitFor { window.orderFrontCount == 1 }
        await waitFor { overlay.model.secondsLeft == 5 }

        overlay.performCancel() // 点击手势与 ESC monitor 的共用入口

        await waitFor { controller.state == .idle }
        await waitFor { window.orderOutCount == 1 }
        XCTAssertNil(overlay.model.secondsLeft)
        await task.value

        XCTAssertEqual(session.beginCallCount, 0, "倒计时取消：session.begin 不得被调")
        XCTAssertEqual(session.finishCount, 0)
    }

    func testPerformCancelWhileHiddenIsNoOp() async {
        let controller = makeController(countdownSeconds: 2)
        let window = SpyOverlayWindow()
        var cancelCount = 0
        let overlay = makeOverlay(controller: controller, window: window, onCancel: { cancelCount += 1 })

        overlay.performCancel()

        XCTAssertEqual(cancelCount, 0, "未显示时取消入口不得触发出口")
        XCTAssertEqual(window.orderFrontCount, 0)
    }

    func testOverlayReshowsOnNextCountdownReusingSameWindow() async {
        let gate = ControlledGate()
        let controller = makeController(countdownSeconds: 5)
        controller.waitForTick = { [gate] _ in await gate.wait() }
        let window = SpyOverlayWindow()
        let factoryCalls = CounterBox()
        let overlay = makeOverlay(controller: controller, window: window, factoryCalls: factoryCalls, onCancel: { [weak controller] in
            Task { @MainActor in controller?.cancelAndDiscard() }
        })

        // 第一场：倒计时取消
        let first = Task { await controller.start(mode: .display(1), config: makeConfig()) }
        await waitFor { window.orderFrontCount == 1 }
        await waitFor { overlay.model.secondsLeft == 5 }
        overlay.performCancel()
        await waitFor { controller.state == .idle }
        await first.value

        // 第二场：同一窗口再次显示（复用，不重建）
        let second = Task { await controller.start(mode: .display(1), config: makeConfig()) }
        await waitFor { window.orderFrontCount == 2 }
        await waitFor { overlay.model.secondsLeft == 5 }
        overlay.performCancel()
        await waitFor { controller.state == .idle }
        await second.value

        XCTAssertEqual(factoryCalls.value, 1, "两场倒计时复用同一覆盖层窗口，工厂只调一次")
        XCTAssertEqual(window.orderOutCount, 2, "两次取消各收起一次")
        XCTAssertEqual(session.beginCallCount, 0)
    }

    // MARK: - ESC 识别（monitor 与测试共用的纯函数）

    /// 合成 keyDown：CGEvent 路线（新 SDK 已无 NSEvent.keyDownEvent 工厂）；
    /// 可注入 unicode 字符（keyboardSetUnicodeString）以独立钉 keyCode / Unicode 两个条款。
    private func makeKeyDown(keyCode: UInt16, unicodeCharacter: UniChar?) -> NSEvent {
        let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true)!
        if let unicodeCharacter {
            cgEvent.keyboardSetUnicodeString(stringLength: 1, unicodeString: [unicodeCharacter])
        }
        return NSEvent(cgEvent: cgEvent)!
    }

    func testIsEscapeKeyRecognizesEscapeKeycodeAndUnicodeOnly() {
        XCTAssertTrue(CountdownOverlayController.isEscapeKey(makeKeyDown(keyCode: 53, unicodeCharacter: UniChar(0x61))), "keyCode 53（美式布局 ESC）即识别，即便字符载荷非 ESC")
        XCTAssertTrue(CountdownOverlayController.isEscapeKey(makeKeyDown(keyCode: 0, unicodeCharacter: UniChar(0x1b))), "非美式布局 ESC（Unicode 转义符）")
        XCTAssertFalse(CountdownOverlayController.isEscapeKey(makeKeyDown(keyCode: 36, unicodeCharacter: UniChar(0x0d))), "回车不是 ESC")
        XCTAssertFalse(CountdownOverlayController.isEscapeKey(makeKeyDown(keyCode: 0, unicodeCharacter: UniChar(0x61))), "普通键不是 ESC")
    }
}
