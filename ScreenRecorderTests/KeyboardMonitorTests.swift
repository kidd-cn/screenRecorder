import AppKit
import XCTest

@testable import ScreenRecorder

// MARK: - 假事件源（EventSource 缝：测试经假源发事件，不触真实 NSEvent monitor）

/// 记录型假源：只记录装机/摘除调用并持有 handler 闭包，供测试在无头环境直接投喂
/// 合成 NSEvent（真源 NSEventKeyboardSource 装卸真实 monitor，无头不可测）。
private final class FakeKeyboardEventSource: KeyboardEventSource {
    private(set) var globalHandlers: KeyboardEventHandlers?
    private(set) var localHandlers: KeyboardEventHandlers?
    private(set) var removeAllCount = 0

    func installGlobal(handlers: KeyboardEventHandlers) { globalHandlers = handlers }
    func installLocal(handlers: KeyboardEventHandlers) { localHandlers = handlers }
    func removeAll() {
        removeAllCount += 1
        globalHandlers = nil
        localHandlers = nil
    }
}

// MARK: - 合成事件助手（CGEvent → NSEvent，无头可构造）

/// 构造带 keyCode/characters/flags 的 NSEvent：`characters` 经 CGEvent 的 unicode 串注入
/// （NSEvent.characters 的无头来源）；flagsChanged 事件 characters 为空串（真机同口径）。
private func makeKeyEvent(keyCode: UInt64,
                          characters: String = "",
                          flags: NSEvent.ModifierFlags = [],
                          type: NSEvent.EventType = .keyDown) -> NSEvent {
    let cg = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: type != .keyUp)!
    cg.type = type.nativeCGEventType
    cg.flags = CGEventFlags(rawValue: UInt64(flags.rawValue))
    if !characters.isEmpty {
        var utf16 = Array(characters.utf16)
        cg.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
    }
    return NSEvent(cgEvent: cg)!
}

private extension NSEvent.EventType {
    /// 键盘三类事件的 CGEvent 类型（NSEvent.EventType 无直连 rawValue 换算，查表三行）。
    var nativeCGEventType: CGEventType {
        switch self {
        case .keyDown: return .keyDown
        case .keyUp: return .keyUp
        case .flagsChanged: return .flagsChanged
        default: return .keyDown
        }
    }
}

// MARK: - KeyboardMonitor 钉测（简报 Step 1：Descriptor 换算 / 安全输入轮询 / 起停对称）

@MainActor
final class KeyboardMonitorTests: XCTestCase {
    private var clock: TimeInterval = 1_000
    private var secureInputActive = false

    private func makeMonitor(source: FakeKeyboardEventSource,
                             enabled: Bool = true,
                             globalPermitted: Bool = true) -> KeyboardMonitor {
        KeyboardMonitor(
            state: KeyboardOverlayState(),
            store: KeyboardOverlaySnapshotStore(),
            source: source,
            enabled: enabled,
            globalPermissionProbe: { globalPermitted },
            secureInputProbe: { [weak self] in self?.secureInputActive ?? false },
            styleProvider: { KeyboardOverlayStyle(colorAlternate: false, fontSize: 14) },
            lingerProvider: { 2 },
            now: { [weak self] in self?.clock ?? 0 })
    }

    // MARK: 简报钉测

    /// 简报钉测：全局 keyDown → KeyDescriptor（keyCode/characters/modifiers）→ 状态机
    /// live 直显 → keyUp 结算 linger → 到期 nil。样式原样透传。
    func testGlobalHandlerFeedsDescriptorToState() {
        let source = FakeKeyboardEventSource()
        let monitor = makeMonitor(source: source)
        monitor.start()
        let handlers = source.globalHandlers

        handlers?.onKeyDown(makeKeyEvent(keyCode: 0, characters: "A"))
        let shown = monitor.currentSnapshot()
        XCTAssertEqual(shown?.text, "A", "全局 keyDown → descriptor → 状态机 live 直显")
        XCTAssertEqual(shown?.style, KeyboardOverlayStyle(colorAlternate: false, fontSize: 14), "样式原样透传")

        handlers?.onKeyUp(makeKeyEvent(keyCode: 0, characters: "A", type: .keyUp))
        clock += 1
        XCTAssertEqual(monitor.currentSnapshot()?.text, "A", "弹起结算进 linger，窗口内仍在")
        clock += 3
        XCTAssertNil(monitor.currentSnapshot(), "linger 到期 nil（淡出）")
    }

    /// 简报钉测：安全输入轮询命中即抑制——置位后 snapshot 恒 nil、置位期事件不记录；
    /// 解除后旧组合不复现，新输入从头正常（0.5s timer 的节拍由生命周期钉测覆盖，
    /// 本用例经 `pollSecureInputOnce` 确定性驱动同一轮询逻辑）。
    func testSecureInputPollSuppresses() {
        let source = FakeKeyboardEventSource()
        let monitor = makeMonitor(source: source)
        monitor.start()
        let handlers = source.globalHandlers

        handlers?.onKeyDown(makeKeyEvent(keyCode: 0, characters: "A"))
        XCTAssertEqual(monitor.currentSnapshot()?.text, "A")

        secureInputActive = true
        monitor.pollSecureInputOnce()
        XCTAssertNil(monitor.currentSnapshot(), "轮询置位安全输入：snapshot 恒 nil")

        // 置位期间事件不记录（不显示、不记录、不崩溃）
        handlers?.onKeyDown(makeKeyEvent(keyCode: 8, characters: "C", flags: .command))
        XCTAssertNil(monitor.currentSnapshot(), "安全输入期间按键被整键忽略")

        secureInputActive = false
        monitor.pollSecureInputOnce()
        XCTAssertNil(monitor.currentSnapshot(), "解除后旧组合不复现")
        handlers?.onKeyDown(makeKeyEvent(keyCode: 2, characters: "D"))
        XCTAssertEqual(monitor.currentSnapshot()?.text, "D", "解除后新输入正常显示")
    }

    /// 简报钉测（start/stop 对称，语义与 ClickHighlightTracker 对称）：监听 + 轮询随
    /// start 装机、随 stop 摘除；重复 start/stop 幂等；stop 后事件不再馈送（无残影）。
    func testLifecycleStopsWithRecording() {
        let source = FakeKeyboardEventSource()
        let monitor = makeMonitor(source: source)
        monitor.stop() // 未 start 先 stop：no-op
        XCTAssertFalse(monitor.isMonitoring)

        monitor.start()
        XCTAssertTrue(monitor.isMonitoring, "随录制启动：监听装机")
        XCTAssertTrue(monitor.isSecureInputPolling, "安全输入轮询随监听生命周期同起")
        XCTAssertNotNil(source.globalHandlers)
        XCTAssertNotNil(source.localHandlers)
        let hadHandlersBefore = source.globalHandlers != nil
        monitor.start() // 重复 start 幂等：闭包无身份可比，以「未摘除 + 仍装机」钉幂等
        XCTAssertTrue(hadHandlersBefore && source.globalHandlers != nil, "幂等：装机态保持")
        XCTAssertEqual(source.removeAllCount, 0, "幂等：不重复摘除重装")

        let handlers = source.globalHandlers
        monitor.stop()
        XCTAssertFalse(monitor.isMonitoring, "随录制收尾摘除监听")
        XCTAssertFalse(monitor.isSecureInputPolling, "轮询随监听生命周期同停")
        XCTAssertNil(source.globalHandlers)
        XCTAssertNil(source.localHandlers)
        XCTAssertEqual(source.removeAllCount, 1)
        monitor.stop() // 重复 stop 幂等
        XCTAssertEqual(source.removeAllCount, 1)

        handlers?.onKeyDown(makeKeyEvent(keyCode: 0, characters: "A"))
        XCTAssertNil(monitor.currentSnapshot(), "stop 后事件不再馈送（残影防御：状态一并清空）")

        monitor.start() // 重启录制语义：可再次装机
        XCTAssertTrue(monitor.isMonitoring)
        monitor.stop()
    }

    // MARK: 降级与换算补钉

    /// 规格钉定「授权前仅本地监听降级」：Input Monitoring 预检不过 → 全局监听不装
    /// （无弹窗、无错误刷屏），本地监听照装（本 App 前台按键仍可可视化）。
    func testUnauthorizedDegradesToLocalOnlyListening() {
        let source = FakeKeyboardEventSource()
        let monitor = makeMonitor(source: source, globalPermitted: false)
        monitor.start()

        XCTAssertFalse(monitor.usesGlobalListening)
        XCTAssertNil(source.globalHandlers, "未授权不得装全局监听（降级）")
        XCTAssertNotNil(source.localHandlers, "本地监听照装（本 App 前台按键可用）")

        source.localHandlers?.onKeyDown(makeKeyEvent(keyCode: 9, characters: "L"))
        XCTAssertEqual(monitor.currentSnapshot()?.text, "L", "降级路径本地事件照常馈送")
        monitor.stop()
    }

    /// flagsChanged → 修饰键 keyDown/keyUp 换算（Task 8 类注释钉定的换算路径）：
    /// ⌘ flagsChanged 按下即显 glyph、按住再按 C → "⌘C"、全松立即结算进 linger。
    /// NSEvent.ModifierFlags.rawValue ↔ ModifierFlagsMask 位定义一致性在此过桥钉死。
    func testFlagsChangedDrivesModifierAccounting() {
        let source = FakeKeyboardEventSource()
        let monitor = makeMonitor(source: source)
        monitor.start()
        let handlers = source.globalHandlers

        handlers?.onFlagsChanged(makeKeyEvent(keyCode: 55, flags: .command, type: .flagsChanged))
        XCTAssertEqual(monitor.currentSnapshot()?.text, "⌘", "修饰键 flagsChanged 按下即显 glyph")

        handlers?.onKeyDown(makeKeyEvent(keyCode: 8, characters: "c", flags: .command))
        XCTAssertEqual(monitor.currentSnapshot()?.text, "⌘c", "事件自带 characters 原样直显")

        handlers?.onFlagsChanged(makeKeyEvent(keyCode: 55, flags: [], type: .flagsChanged))
        XCTAssertEqual(monitor.currentSnapshot()?.text, "⌘c", "显示位全松立即结算进 linger")
        monitor.stop()
    }

    /// enabled 开关（快照语义，与 ClickHighlightTracker.setEnabled 同纪律）：disabled 时
    /// start 不装机；监听中翻转 false 立即摘除；只对齐开关、不自动重装。
    func testDisabledMonitorDoesNotInstallOnStart() {
        let source = FakeKeyboardEventSource()
        let monitor = makeMonitor(source: source, enabled: false)
        monitor.start()
        monitor.start() // 幂等
        XCTAssertFalse(monitor.isMonitoring, "disabled 时 start 后不装机")
        XCTAssertNil(source.globalHandlers)
        monitor.stop()
        XCTAssertFalse(monitor.isMonitoring)

        monitor.setEnabled(true)
        XCTAssertFalse(monitor.isMonitoring, "setEnabled 只对齐开关，不自动装机（装机是 start 职责）")
        monitor.setEnabled(false) // 复原，防泄漏
    }
}
