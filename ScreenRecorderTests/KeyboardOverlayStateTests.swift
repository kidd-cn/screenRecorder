import XCTest

@testable import Hummingbird

/// KeyboardOverlayState 键帽聚合状态机钉测（Task 8 简报 Step 1）。
/// 全部经注入 `now` 驱动（headless 硬规矩：逻辑内不读墙钟，与 AutoZoomStateTests
/// 同纪律），断言只走 `snapshot` 纯读口径与 `phase` 观测，不偷看实现内部。
@MainActor
final class KeyboardOverlayStateTests: XCTestCase {
    private let style = KeyboardOverlayStyle(fontSize: 14)
    private let linger: TimeInterval = 2

    // 修饰位本地别名（掩码是纯 Int，运算须写全名——无 OptionSet 点语法）
    private let shift = KeyboardModifierMaskBits.shift
    private let control = KeyboardModifierMaskBits.control
    private let option = KeyboardModifierMaskBits.option
    private let command = KeyboardModifierMaskBits.command

    /// descriptor 构造助手（flagsChanged 事件 characters 为空串）。
    private func key(_ keyCode: UInt64,
                     characters: String = "",
                     modifiers: ModifierFlagsMask = 0) -> KeyDescriptor {
        KeyDescriptor(keyCode: keyCode, characters: characters, modifiers: modifiers)
    }

    // MARK: 简报钉测

    /// 无修饰单键：按下瞬间即显、按住期间持续显示（linger 不在按住期计时）、
    /// 弹起结算进 linger、停留边界 elapsed >= linger → nil。样式原样透传。
    func testSingleKeyShowsAndFadesAfterLinger() {
        let state = KeyboardOverlayState()

        state.keyDown(key(0, characters: "A"), now: 0)
        XCTAssertEqual(state.phase, .live, "按下即 live")
        let shown = state.snapshot(style: style, lingerSeconds: linger, now: 0)
        XCTAssertEqual(shown?.text, "A", "即按即显")
        XCTAssertEqual(shown?.style, style, "样式参数原样透传")
        // 按住不放：远超 linger 仍显示（linger 锚定 keyUp，不在按住期跑表）
        XCTAssertEqual(state.snapshot(style: style, lingerSeconds: linger, now: 5)?.text, "A")

        state.keyUp(key(0, characters: "A"), now: 10)
        XCTAssertEqual(state.phase, .lingering, "弹起立即结算进 linger")
        XCTAssertEqual(state.snapshot(style: style, lingerSeconds: linger, now: 11.9)?.text, "A")
        // 停留边界：elapsed == linger 即淡出
        XCTAssertNil(state.snapshot(style: style, lingerSeconds: linger, now: 12))
        XCTAssertNil(state.snapshot(style: style, lingerSeconds: linger, now: 15))
        XCTAssertNil(state.snapshot(style: style, lingerSeconds: linger, now: 100), "空转恒 nil")
    }

    /// 修饰键组合：单独按 ⌘ 即显 glyph；⌘ 按住再按 C → "⌘C"，再按 V → "⌘V" 覆盖
    /// （简报钉死）；按住期间组合持续显示（held 模式不进 linger 计时）。
    func testModifierComboUpdatesWhileHeld() {
        let state = KeyboardOverlayState()

        state.keyDown(key(55, modifiers: command), now: 0)
        XCTAssertEqual(state.snapshot(style: style, lingerSeconds: linger, now: 0)?.text, "⌘",
                       "修饰键单独按下即显")

        state.keyDown(key(8, characters: "C", modifiers: command), now: 0.5)
        XCTAssertEqual(state.snapshot(style: style, lingerSeconds: linger, now: 0.5)?.text, "⌘C")
        state.keyDown(key(9, characters: "V", modifiers: command), now: 1.0)
        XCTAssertEqual(state.snapshot(style: style, lingerSeconds: linger, now: 1.0)?.text, "⌘V",
                       "新键覆盖旧键")

        // held 模式不计时：远超 linger 组合仍在
        XCTAssertEqual(state.snapshot(style: style, lingerSeconds: linger, now: 100)?.text, "⌘V")
        XCTAssertEqual(state.phase, .live)
    }

    /// 松修饰键：部分松开组合持续（前缀收窄为剩余修饰键）；松开全部修饰键立即
    /// 结算进 linger（锚定弹起时刻）；结算后迟到的普通键弹起不重锚 linger。
    func testModifierReleaseSettlesCombo() {
        let state = KeyboardOverlayState()

        state.keyDown(key(56, modifiers: shift), now: 0)
        state.keyDown(key(55, modifiers: shift | command), now: 0.5)
        state.keyDown(key(8, characters: "C", modifiers: shift | command), now: 1.0)
        XCTAssertEqual(state.snapshot(style: style, lingerSeconds: linger, now: 1.0)?.text, "⇧⌘C")

        // 部分松开（⇧ 弹起，⌘ 仍按住）：组合持续，前缀收窄
        state.keyUp(key(56, modifiers: command), now: 2.0)
        XCTAssertEqual(state.phase, .live)
        XCTAssertEqual(state.snapshot(style: style, lingerSeconds: linger, now: 3.0)?.text, "⌘C",
                       "部分松开不结算，前缀随剩余修饰键收窄")

        // 最后一个修饰键弹起：立即结算进 linger
        state.keyUp(key(55, modifiers: 0), now: 5.0)
        XCTAssertEqual(state.phase, .lingering)
        XCTAssertEqual(state.snapshot(style: style, lingerSeconds: linger, now: 6.9)?.text, "⌘C")
        XCTAssertNil(state.snapshot(style: style, lingerSeconds: linger, now: 7))

        // 结算后迟到的普通键弹起（松键次序颠倒）：忽略，不重锚已结算的 linger
        state.keyUp(key(8, characters: "C"), now: 9.0)
        XCTAssertNil(state.snapshot(style: style, lingerSeconds: linger, now: 9.0),
                     "迟到弹起不得复活或延期 linger")
    }

    /// 安全输入（Review Focus #2）：置位 snapshot 恒 nil（静默跳过，不崩溃）；
    /// 置位期间事件不记录；解除后旧组合不复现，新输入恢复正常显示。
    func testSecureInputSuppressesSnapshot() {
        let state = KeyboardOverlayState()

        state.keyDown(key(0, characters: "A"), now: 0)
        XCTAssertNotNil(state.snapshot(style: style, lingerSeconds: linger, now: 0))

        state.setSecureInputActive(true)
        XCTAssertNil(state.snapshot(style: style, lingerSeconds: linger, now: 0),
                     "置位即恒 nil——live 态一并静默")
        // 置位期间事件不记录（规格：不显示、不记录、不崩溃）
        state.keyDown(key(8, characters: "C", modifiers: command), now: 1)
        state.keyUp(key(55, modifiers: 0), now: 2)
        state.tick(now: 2)
        XCTAssertNil(state.snapshot(style: style, lingerSeconds: linger, now: 2))

        // 解除：旧输入不复现；此后新输入恢复正常
        state.setSecureInputActive(false)
        XCTAssertNil(state.snapshot(style: style, lingerSeconds: linger, now: 3))
        state.keyDown(key(0, characters: "A"), now: 4)
        XCTAssertEqual(state.snapshot(style: style, lingerSeconds: linger, now: 4)?.text, "A",
                       "解除后新输入正常显示")
    }

    /// keyCode/掩码 → glyph 映射：⇧⌃⌥⌘ 符号与固定符号序（简报钉死）、特殊键
    /// glyph 兜底表、普通键 characters 直显、不可直显键返回 nil。
    func testKeyCodeToGlyphMapping() {
        XCTAssertEqual(KeyboardOverlayState.modifierGlyphs(for: shift), "⇧")
        XCTAssertEqual(KeyboardOverlayState.modifierGlyphs(for: control), "⌃")
        XCTAssertEqual(KeyboardOverlayState.modifierGlyphs(for: option), "⌥")
        XCTAssertEqual(KeyboardOverlayState.modifierGlyphs(for: command), "⌘")
        let all = shift | control | option | command
        XCTAssertEqual(KeyboardOverlayState.modifierGlyphs(for: all), "⇧⌃⌥⌘",
                       "全组合固定符号序 ⇧⌃⌥⌘")
        XCTAssertEqual(KeyboardOverlayState.modifierGlyphs(for: command | control), "⌃⌘",
                       "子集亦按固定序（不得按位序或按下序）")
        XCTAssertEqual(KeyboardOverlayState.modifierGlyphs(for: 0), "")

        // 特殊键（characters 为控制字符/空格不宜直显）按 ANSI 码出 glyph
        XCTAssertEqual(KeyboardOverlayState.displayText(forKeyCode: 36, characters: "\r"), "⏎")
        XCTAssertEqual(KeyboardOverlayState.displayText(forKeyCode: 49, characters: " "), "␣")
        XCTAssertEqual(KeyboardOverlayState.displayText(forKeyCode: 53, characters: "\u{1B}"), "⎋")
        XCTAssertEqual(KeyboardOverlayState.displayText(forKeyCode: 123, characters: ""), "←")

        // 普通键 characters 原样直显（状态机不改写大小写）；空串/控制字符且无
        // glyph 可用 → nil（调用方静默忽略，不上屏问号占位）
        XCTAssertEqual(KeyboardOverlayState.displayText(forKeyCode: 8, characters: "A"), "A")
        XCTAssertNil(KeyboardOverlayState.displayText(forKeyCode: 999, characters: ""))
        XCTAssertNil(KeyboardOverlayState.displayText(forKeyCode: 999, characters: "\t"))
    }

    // MARK: 行为补钉（自审清单：连按续期 / reset 清态）

    /// 快速连按：第二次按下取消第一次 linger 转 live，弹起重新锚定——连按期间
    /// 显示不因首按 linger 到期而闪断（续期语义）。
    func testRapidRePressRefreshesLinger() {
        let state = KeyboardOverlayState()

        state.keyDown(key(0, characters: "A"), now: 0)
        state.keyUp(key(0, characters: "A"), now: 1)
        state.keyDown(key(0, characters: "A"), now: 2.5) // 首按 linger（1…3）内重按
        XCTAssertEqual(state.phase, .live)
        XCTAssertEqual(state.snapshot(style: style, lingerSeconds: linger, now: 2.9)?.text, "A",
                       "重按转 live，不受首按 linger 到期（t=3）影响")

        state.keyUp(key(0, characters: "A"), now: 3.0)
        XCTAssertEqual(state.snapshot(style: style, lingerSeconds: linger, now: 3 + linger - 0.1)?.text,
                       "A", "linger 以第二次弹起重锚")
        XCTAssertNil(state.snapshot(style: style, lingerSeconds: linger, now: 3 + linger))
    }

    /// reset 清态（录制收尾，同 AutoZoomState.reset 残影防御语义）：live/linger/
    /// 修饰键记账全清回 idle；安全输入标志是外部事实（由监听层轮询驱动），reset
    /// 不代置——保守保持抑制，直到监听层解除。
    func testResetClearsDisplayStateButKeepsSecureFlag() {
        let state = KeyboardOverlayState()

        state.keyDown(key(55, modifiers: command), now: 0)
        state.keyDown(key(8, characters: "C", modifiers: command), now: 0.5)
        XCTAssertEqual(state.phase, .live)
        state.setSecureInputActive(true)
        state.reset()

        XCTAssertEqual(state.phase, .idle, "reset 回 idle")
        XCTAssertNil(state.snapshot(style: style, lingerSeconds: linger, now: 1))
        // 安全输入仍置位：reset 后的新按键继续被抑制（fail-safe），直到轮询解除
        state.keyDown(key(0, characters: "A"), now: 2)
        XCTAssertNil(state.snapshot(style: style, lingerSeconds: linger, now: 2),
                     "reset 不代置安全输入标志——抑制保持到监听层解除")
        state.setSecureInputActive(false)
        state.keyDown(key(0, characters: "A"), now: 3)
        XCTAssertEqual(state.snapshot(style: style, lingerSeconds: linger, now: 3)?.text, "A",
                       "解除后从头正常")
    }

    // MARK: 2026-11-15 Omi 键盘事件页复刻钉测（仅组合键 / 换行延迟合行 / 消失时长淡出）

    /// combosOnly：无修饰单键（live 与 linger 两态）恒 nil；带修饰前缀的组合照常；
    /// 修饰键单独按住（"⌘"）算组合前缀照常显示。
    func testCombosOnlyFiltersPlainKeysOnly() {
        let state = KeyboardOverlayState()
        let combos = KeyboardOverlayStyle(combosOnly: true, fontSize: 14)

        state.keyDown(key(0, characters: "A"), now: 0)
        XCTAssertNil(state.snapshot(style: combos, lingerSeconds: linger, now: 0),
                     "combosOnly：单键 live 不显示")
        XCTAssertNotNil(state.snapshot(style: style, lingerSeconds: linger, now: 0),
                        "默认样式不受过滤影响")
        state.keyUp(key(0, characters: "A"), now: 1)
        XCTAssertNil(state.snapshot(style: combos, lingerSeconds: linger, now: 1.5),
                     "combosOnly：单键 linger 不显示")

        state.keyDown(key(55, modifiers: command), now: 2)
        state.keyDown(key(8, characters: "C", modifiers: command), now: 2.2)
        state.keyUp(key(8, characters: "C", modifiers: command), now: 2.5)
        state.keyUp(key(55, modifiers: command), now: 2.8)
        XCTAssertEqual(state.snapshot(style: combos, lingerSeconds: linger, now: 3)?.text, "⌘C",
                       "combosOnly：组合键两态照常")
    }

    /// 换行延迟：窗口内连续结算合行为一行（空格连接、带式钉测文本序）；间隔 ≥ 窗口
    /// 断行只显最新段；wrapDelay 0 = 旧语义不合行。
    func testWrapDelayMergesConsecutiveSettlements() {
        let state = KeyboardOverlayState()

        // "A" 弹起结算 0s，"B" 弹起结算 0.3s（0.5s 窗口内）→ 合行 "A B"
        state.keyDown(key(0, characters: "A"), now: 0)
        state.keyUp(key(0, characters: "A"), now: 0.1)
        state.keyDown(key(11, characters: "B"), now: 0.3)
        state.keyUp(key(11, characters: "B"), now: 0.4)
        XCTAssertEqual(
            state.snapshot(style: style, lingerSeconds: 2, wrapDelaySeconds: 0.5, now: 0.5)?.text,
            "A B", "窗口内连续结算合行")
        // linger 锚定最新段弹起：0.5 + 2 到期
        XCTAssertNil(
            state.snapshot(style: style, lingerSeconds: 2, wrapDelaySeconds: 0.5, now: 2.5))
        // 断行：0.8s 后再按 C → 只显 "C"
        state.keyDown(key(8, characters: "C"), now: 1.2)
        state.keyUp(key(8, characters: "C"), now: 1.4)
        XCTAssertEqual(
            state.snapshot(style: style, lingerSeconds: 2, wrapDelaySeconds: 0.5, now: 1.5)?.text,
            "C", "间隔 ≥ 窗口断行只显最新段")

        // wrapDelay 0：旧语义，第二次结算只显 "B"
        let plain = KeyboardOverlayState()
        plain.keyDown(key(0, characters: "A"), now: 0)
        plain.keyUp(key(0, characters: "A"), now: 0.1)
        plain.keyDown(key(11, characters: "B"), now: 0.2)
        plain.keyUp(key(11, characters: "B"), now: 0.3)
        XCTAssertEqual(
            plain.snapshot(style: style, lingerSeconds: 2, now: 0.4)?.text, "B",
            "wrapDelay 0 = 旧语义不合行")
    }

    /// 消失时长：停留窗口内 opacity 1；淡出期线性 1→0 且文本仍可见；到期（含淡出）
    /// 后 nil；fade 0 = 停留到期立即 nil（旧语义钉测在既有用例已覆盖）。
    func testFadeDurationRampsOpacityAfterLinger() {
        let state = KeyboardOverlayState()

        state.keyDown(key(0, characters: "A"), now: 0)
        state.keyUp(key(0, characters: "A"), now: 1)

        let duringLinger = state.snapshot(style: style, lingerSeconds: 2, fadeSeconds: 1, now: 1.5)
        XCTAssertEqual(duringLinger?.opacity, 1, "停留期内全不透明")
        let fadeStart = state.snapshot(style: style, lingerSeconds: 2, fadeSeconds: 1, now: 3.0)
        XCTAssertEqual(fadeStart?.text, "A", "淡出起点文本仍在")
        XCTAssertEqual(fadeStart?.opacity ?? -1, 1, accuracy: 1e-9, "淡出起点 opacity 1")
        let midFade = state.snapshot(style: style, lingerSeconds: 2, fadeSeconds: 1, now: 3.5)
        XCTAssertEqual(midFade?.opacity ?? -1, 0.5, accuracy: 1e-9, "淡出中点 opacity 0.5")
        XCTAssertNil(state.snapshot(style: style, lingerSeconds: 2, fadeSeconds: 1, now: 4.0),
                     "linger+fade 到期消失")
        XCTAssertNil(state.snapshot(style: style, lingerSeconds: 2, now: 3.5),
                     "fade 0 = 停留到期立即消失（旧语义）")
    }

    /// live 按下打断合行行显示但**保留历史**（换行延迟语义）：新键 live 只接管显示；
    /// 新结算在窗口内续接旧行（"A B ⌘C"），间隔 ≥ 窗口才断行。
    func testNewKeyDownContinuesMergedLineWithinWindow() {
        let state = KeyboardOverlayState()
        state.keyDown(key(0, characters: "A"), now: 0)
        state.keyUp(key(0, characters: "A"), now: 0.1)
        state.keyDown(key(11, characters: "B"), now: 0.2)
        state.keyUp(key(11, characters: "B"), now: 0.3)
        XCTAssertEqual(
            state.snapshot(style: style, lingerSeconds: 2, wrapDelaySeconds: 0.5, now: 0.4)?.text,
            "A B")
        // live 期间只显当前组合（旧行不混入 live 直显）
        state.keyDown(key(55, modifiers: command), now: 0.5)
        state.keyDown(key(8, characters: "C", modifiers: command), now: 0.55)
        XCTAssertEqual(
            state.snapshot(style: style, lingerSeconds: 2, wrapDelaySeconds: 0.5, now: 0.6)?.text,
            "⌘C", "live 直显只有当前组合")
        // 全松结算（距上一段 0.25s < 窗口）续接旧行
        state.keyUp(key(8, characters: "C", modifiers: command), now: 0.7)
        state.keyUp(key(55, modifiers: command), now: 0.75)
        XCTAssertEqual(
            state.snapshot(style: style, lingerSeconds: 2, wrapDelaySeconds: 0.5, now: 0.8)?.text,
            "A B ⌘C", "窗口内新结算续接旧行")
        // 间隔 ≥ 窗口后只显最新段
        state.keyDown(key(6, characters: "Z"), now: 2.0)
        state.keyUp(key(6, characters: "Z"), now: 2.2)
        XCTAssertEqual(
            state.snapshot(style: style, lingerSeconds: 2, wrapDelaySeconds: 0.5, now: 2.3)?.text,
            "Z", "间隔 ≥ 窗口断行只显最新段")
    }
}
