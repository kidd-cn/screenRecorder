import Combine
import Foundation

/// 修饰键位掩码（P4）：纯 `Int` 位掩码——Core 不引入 AppKit 类型（简报钉死）。
/// 位定义与 `NSEvent.ModifierFlags.rawValue` 一致（shift 1<<17 / control 1<<18 /
/// option 1<<19 / command 1<<20 / capsLock 1<<16 / function 1<<23），监听层
/// （Task 9 KeyboardMonitor）`ModifierFlagsMask(event.modifierFlags.rawValue)`
/// 一步完成换算，无查表成本。
typealias ModifierFlagsMask = Int

/// 位掩码位常量（与 `ModifierFlagsMask` 同文件同源）：raw 值对齐 NSEvent。
/// 组合前缀只渲染 shift/control/option/command 四显示位；capsLock/function 仅
/// 参与按下记账、不出 glyph。
enum KeyboardModifierMaskBits {
    static let capsLock: ModifierFlagsMask = 1 << 16
    static let shift: ModifierFlagsMask = 1 << 17
    static let control: ModifierFlagsMask = 1 << 18
    static let option: ModifierFlagsMask = 1 << 19
    static let command: ModifierFlagsMask = 1 << 20
    static let function: ModifierFlagsMask = 1 << 23
}

/// 单个按键描述（NSEvent → 纯值的换算产物，换算在 Task 9 KeyboardMonitor）：
/// `keyCode` 为 ANSI 硬件码（修饰键分类与特殊键 glyph 查表主键）、`characters`
/// 为事件自带字符（普通键直显原文）、`modifiers` 为事件时刻掩码（随事件携带；
/// 组合态真源是状态机自身的按下/松开记账，见 KeyboardOverlayState）。
struct KeyDescriptor: Equatable {
    var keyCode: UInt64
    var characters: String
    var modifiers: ModifierFlagsMask
}

/// 键帽样式（Task 9 合成器渲染入参）：`colorAlternate` 两色单选（false = 主色，
/// true = 备选色，取色在合成器）；`fontSize` 字号档位（SettingsStore 已钳制到
/// 12/14/18，此处不做二次钳制）。
struct KeyboardOverlayStyle: Equatable {
    var colorAlternate: Bool
    var fontSize: Int
}

/// 键帽合成快照（Task 9 合成器逐帧入参）：`text` 如 "⌘C"/"A"——修饰符用固定
/// 符号序 ⇧⌃⌥⌘；`style` 原样透传调用方样式。
struct KeyboardOverlaySnapshot: Equatable {
    var text: String
    var style: KeyboardOverlayStyle
}

/// 键帽聚合状态机（P4 核心）：把键盘事件的按下/松开流聚合成「当前该显示什么」
/// 的纯逻辑，合成热路径逐帧经 `snapshot(style:lingerSeconds:now:)` 纯读取用。
/// 纯逻辑、无 I/O、不读墙钟——所有时间点由调用方注入 `now`（与 AutoZoomState /
/// PauseMediaClock 同一 headless 纪律），任意时钟口径可用。
///
/// 显示语义（Task 8 简报钉定）：
/// - **live（held）模式**：无修饰单键按下即显；修饰键按下即显 glyph；组合持续
///   显示并随新键覆盖更新（⌘ 按住再按 C → "⌘C"，再按 V → "⌘V"）。live 期间
///   **不计时**——按住不放多久都显示；
/// - **结算（settle）**：松开全部显示位修饰键（⇧⌃⌥⌘ 任一按下过且此刻全松）或
///   无修饰普通键弹起时，立即把当前文本结算进 linger，锚定该弹起时刻；
/// - **linger**：结算文本显示 `lingerSeconds`（`snapshot` 调用方参数），到期
///   （elapsed ≥ linger）返回 nil 即淡出；纯读判定，漏 tick 不出错（时长参数在
///   调用方，tick 无法也不必代为计时，与 AutoZoomState 的「tick 仅推进相位」同理）；
/// - **安全输入**（Review Focus #2）：`setSecureInputActive(true)` 一次性清空全部
///   可见状态，置位期间 keyDown/keyUp 整键忽略（规格：不显示、不记录、不崩溃），
///   `snapshot` 恒 nil；解除后旧组合不复现，新输入从头正常。标志是外部事实
///   （Task 9 以 0.5s 轮询 `NSEvent.isSecureInputEnabled` 驱动），`reset` 不代置
///   ——保守保持抑制，直到监听层解除；
/// - 组合态真源是本类对修饰键 keyCode（左右 ⇧/⌃/⌥/⌘ + caps/fn 记账位）的按下/
///   松开记账（flagsChanged → keyDown/keyUp，Task 9 换算），`KeyDescriptor.modifiers`
///   仅随事件携带、不参与组合态判定（记账口径自洽、单测免构造掩码真值）。
///
/// 迟到事件防御：已结算（lingering/idle）后的普通键弹起忽略，不复活、不重锚
/// linger（松键次序颠倒如 ⌘ 先于 C 弹起，linger 保持 ⌘ 弹起时刻口径）。
@MainActor
final class KeyboardOverlayState: ObservableObject {
    /// 显示相位（`keyDown/keyUp/tick/reset` 推进，接线/UI 层可观测）：
    /// `.live` 按住显示中；`.lingering` 结算停留中（是否已到期由 snapshot 按
    /// lingerSeconds 判定）；`.idle` 无显示。
    enum Phase: Equatable {
        case idle
        case live
        case lingering
    }

    /// 当前相位（仅状态机方法写；`tick` 仅重发布不计时）。
    @Published private(set) var phase: Phase = .idle

    /// 按住中的修饰键记账位（左右同位合并；caps/fn 记账但不显示）。
    private var heldModifierBits: ModifierFlagsMask = 0
    /// 组合尾键文本（live 期间持续保留，新键按下覆盖；结算时清空——否则下次按
    /// ⌘ 会凭空复现旧尾键）。
    private var trailingKeyText: String?
    /// live 文本（non-nil ⇔ live 模式；预拼接避免逐帧重算分配）。
    private var liveText: String?
    /// 结算文本与锚定时刻（lingering 态）。
    private var settledText: String?
    private var settledAt: TimeInterval?
    /// 安全输入标志（外部事实，监听层轮询驱动；置位期间整键忽略、snapshot 恒 nil）。
    private var secureInputActive = false

    // MARK: 事件入口

    /// 按键按下：修饰键并入记账；普通键换算直显文本并成为组合尾键。即按即显
    /// （取消 linger 转 live）。不可直显键（空/控制字符且无 glyph）静默忽略。
    func keyDown(_ key: KeyDescriptor, now: TimeInterval) {
        // 安全输入期间整键忽略（不显示、不记录、不崩溃）——清态由
        // setSecureInputActive(true) 一次性完成，此处连记账也不动。
        guard !secureInputActive else { return }

        if let bit = Self.modifierBit(forKeyCode: key.keyCode) {
            heldModifierBits |= bit
        } else if let keyText = Self.displayText(forKeyCode: key.keyCode, characters: key.characters) {
            trailingKeyText = keyText
        } else {
            return
        }

        // 仅记账位（caps/fn）单独按下无 glyph 可显：不动显示、不动 linger。
        guard displayedBits != 0 || trailingKeyText != nil else { return }
        settledText = nil
        settledAt = nil
        liveText = Self.modifierGlyphs(for: displayedBits) + (trailingKeyText ?? "")
        phase = .live
    }

    /// 按键松开：修饰键移出记账——部分松开则组合持续（前缀收窄为剩余修饰键），
    /// 显示位全松即立即结算进 linger（锚定此刻）；普通键弹起在无显示位修饰键
    /// 按住时结算、组合仍按住则组合持续显示。已结算后的迟到弹起忽略。
    func keyUp(_ key: KeyDescriptor, now: TimeInterval) {
        guard !secureInputActive else { return }

        if let bit = Self.modifierBit(forKeyCode: key.keyCode) {
            heldModifierBits &= ~bit
            if displayedBits != 0 {
                if liveText != nil {
                    liveText = Self.modifierGlyphs(for: displayedBits) + (trailingKeyText ?? "")
                    phase = .live
                }
            } else if let text = liveText {
                settle(text: text, at: now)
            }
            // 其余（caps/fn 等记账位弹起、已 lingering/idle 的迟到弹起）不动 linger。
        } else if let text = liveText, displayedBits == 0 {
            settle(text: text, at: now)
        }
    }

    /// 安全输入置位/解除（Task 9 轮询驱动）：置位一次性清空全部可见与记账状态
    /// （退出安全输入后旧组合不复现、held 记账不跨安全窗口泄漏），snapshot 恒 nil
    /// 由 `snapshot` 入口兜底（双保险）。
    func setSecureInputActive(_ active: Bool) {
        guard active != secureInputActive else { return }
        secureInputActive = active
        if active {
            heldModifierBits = 0
            trailingKeyText = nil
            liveText = nil
            settledText = nil
            settledAt = nil
            phase = .idle
        }
    }

    /// 重发布相位（供观测；与 AutoZoomState.tick 同纪律——不计算显示、不计时，
    /// 漏 tick 不影响正确性：linger 过期判定在 `snapshot` 纯读完成）。
    func tick(now: TimeInterval) {
        if liveText != nil {
            phase = .live
        } else if settledText != nil {
            phase = .lingering
        } else {
            phase = .idle
        }
    }

    /// now 时刻的键帽快照（合成热路径逐帧调用，纯读零副作用）：安全输入恒 nil
    /// （静默跳过）；live 态返回当前组合文本；lingering 态在停留窗口内
    /// （max(0, now − 锚点) < lingerSeconds，时钟回拨钳 0 同 AutoZoomState）返回
    /// 结算文本，到期/停留参数非法（≤0 或非有限）返回 nil。`style` 原样透传。
    func snapshot(style: KeyboardOverlayStyle,
                  lingerSeconds: Double,
                  now: TimeInterval) -> KeyboardOverlaySnapshot? {
        if secureInputActive { return nil }
        if let liveText {
            return KeyboardOverlaySnapshot(text: liveText, style: style)
        }
        guard let settledText, let settledAt,
              lingerSeconds.isFinite, lingerSeconds > 0 else { return nil }
        let elapsed = max(0, now - settledAt)
        guard elapsed < lingerSeconds else { return nil }
        return KeyboardOverlaySnapshot(text: settledText, style: style)
    }

    /// 清空显示/记账状态回 idle（录制收尾，同 `AutoZoomState.reset` 残影防御语义）。
    /// 安全输入标志不代置（外部事实，见类注释）。
    func reset() {
        heldModifierBits = 0
        trailingKeyText = nil
        liveText = nil
        settledText = nil
        settledAt = nil
        phase = .idle
    }

    // MARK: 文本换算（keyCode/掩码 → 显示文本，纯函数——Task 9 监听层换算同源复用）

    /// 修饰键 glyph 前缀：**固定符号序 ⇧⌃⌥⌘**（简报钉死，testKeyCodeToGlyphMapping
    /// 钉测），不按位序、不按按下序；仅渲染四显示位，caps/function 等记账位不出
    /// glyph；无显示位返回空串。
    static func modifierGlyphs(for modifiers: ModifierFlagsMask) -> String {
        var glyphs = ""
        if modifiers & KeyboardModifierMaskBits.shift != 0 { glyphs.append("⇧") }
        if modifiers & KeyboardModifierMaskBits.control != 0 { glyphs.append("⌃") }
        if modifiers & KeyboardModifierMaskBits.option != 0 { glyphs.append("⌥") }
        if modifiers & KeyboardModifierMaskBits.command != 0 { glyphs.append("⌘") }
        return glyphs
    }

    /// 普通键直显文本：特殊键 glyph 表优先（return/space/escape/方向键等
    /// `characters` 为控制字符或空白不宜直显的键，ANSI 码布局无关）；否则
    /// `characters` 原样直显（大小写交监听层决定，状态机不改写）；空串/控制字符
    /// 且无 glyph 可用返回 nil（调用方静默忽略，不上屏问号占位）。
    static func displayText(forKeyCode keyCode: UInt64, characters: String) -> String? {
        if let glyph = specialKeyGlyphs[keyCode] { return glyph }
        guard !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F })
        else { return nil }
        return characters
    }

    /// 特殊键 glyph 表（ANSI 码）：仅收常用键（F 键受「F1 作功能键」系统设置影响
    /// characters 不稳定，不收录——未收录键走 characters 直显/静默忽略兜底）。
    private static let specialKeyGlyphs: [UInt64: String] = [
        36: "⏎",    // return
        76: "⏎",    // keypad return
        48: "⇥",    // tab
        49: "␣",    // space
        51: "⌫",    // delete（退格）
        117: "⌦",   // forward delete
        53: "⎋",    // escape
        57: "⇪",    // caps lock
        115: "↖",   // home
        116: "⇞",   // page up
        119: "↘",   // end
        121: "⇟",   // page down
        123: "←",   // left arrow
        124: "→",   // right arrow
        125: "↓",   // down arrow
        126: "↑",   // up arrow
    ]

    /// 修饰键 keyCode → 记账位（ANSI 码；nil = 非修饰键）。左右同位合并（组合
    /// 前缀只按修饰键类别出 glyph）；caps/fn 返回记账位——并入 `heldModifierBits`
    /// 但被 `displayedBits` 掩码滤除，单独按下无 glyph 可显。
    private static func modifierBit(forKeyCode keyCode: UInt64) -> ModifierFlagsMask? {
        switch keyCode {
        case 56, 60: return KeyboardModifierMaskBits.shift    // 左/右 ⇧
        case 59, 62: return KeyboardModifierMaskBits.control  // 左/右 ⌃
        case 58, 61: return KeyboardModifierMaskBits.option   // 左/右 ⌥
        case 55, 54: return KeyboardModifierMaskBits.command  // 左/右 ⌘
        case 57: return KeyboardModifierMaskBits.capsLock
        case 63: return KeyboardModifierMaskBits.function
        default: return nil
        }
    }

    /// 四显示位掩码（⇧⌃⌥⌘）；`heldModifierBits` 与它的交集即当前前缀渲染口径。
    private static let displayedModifiersMask: ModifierFlagsMask =
        KeyboardModifierMaskBits.shift
            | KeyboardModifierMaskBits.control
            | KeyboardModifierMaskBits.option
            | KeyboardModifierMaskBits.command

    /// 按住修饰键中的显示位（caps/function 记账位滤除后）。
    private var displayedBits: ModifierFlagsMask {
        heldModifierBits & Self.displayedModifiersMask
    }

    /// 结算进 linger（显示位全松/普通键弹起的唯一入口）：定格文本、锚定时刻、
    /// 清空 live 态与尾键（防下次按修饰键凭空复现旧尾键）。
    private func settle(text: String, at now: TimeInterval) {
        settledText = text
        settledAt = now
        liveText = nil
        trailingKeyText = nil
        phase = .lingering
    }
}
