import XCTest
import AVFoundation
import CoreGraphics

@testable import Hummingbird

final class SettingsStoreTests: XCTestCase {
    private static let suiteName = "test.settings"

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)
        defaults.removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.suiteName)
        defaults = nil
        super.tearDown()
    }

    func testNewInstanceUsesDefaultValues() {
        let store = SettingsStore(userDefaults: defaults)

        XCTAssertEqual(store.fps, 30)
        XCTAssertEqual(store.videoCodec, .h264)
        XCTAssertTrue(store.captureSystemAudio)
        XCTAssertTrue(store.captureMicrophone)
        XCTAssertEqual(store.micVolume, 1.0)
        XCTAssertEqual(store.outputDirectory, defaultOutputDirectory)
        XCTAssertEqual(store.countdownSeconds, 5)
        XCTAssertFalse(store.pipEnabled)
        XCTAssertFalse(store.clickHighlightEnabled, "T16 裁定：点击高亮默认关（opt-in）")
        XCTAssertEqual(store.lastCaptureMode, .display(CGMainDisplayID()), "T17：上次使用模式默认全屏（主显示器）")
    }

    func testFpsPersistsAcrossInstances() {
        let store = SettingsStore(userDefaults: defaults)
        store.fps = 60

        let reloaded = SettingsStore(userDefaults: defaults)

        XCTAssertEqual(reloaded.fps, 60)
    }

    func testHevcCodecMapsToAvCodecKey() {
        XCTAssertEqual(SettingsStore.VideoCodec.hevc.avCodecKey, .hevc)
    }

    /// T17 裁定 2：⇧⌘R 以上次使用的模式开录，默认全屏（主显示器）。
    func testLastCaptureModeDefaultsToFullScreenMainDisplay() {
        let store = SettingsStore(userDefaults: defaults)

        XCTAssertEqual(store.lastCaptureMode, .display(CGMainDisplayID()))
    }

    /// T17：lastCaptureMode 以 Codable JSON 落库，跨实例往返（含关联值的模式）。
    func testLastCaptureModePersistsAcrossInstances() {
        let store = SettingsStore(userDefaults: defaults)
        let mode = CaptureMode.region(rect: CGRect(x: 10, y: 20, width: 300, height: 200), displayID: 7)
        store.lastCaptureMode = mode

        let reloaded = SettingsStore(userDefaults: defaults)

        XCTAssertEqual(reloaded.lastCaptureMode, mode)
    }

    /// T17：落库损坏（无法解码）时回退默认全屏，不崩溃、不阻塞启动。
    func testLastCaptureModeFallsBackToDefaultOnUndecodableData() {
        defaults.set(Data([0x00, 0x01, 0x02]), forKey: "lastCaptureMode")

        let store = SettingsStore(userDefaults: defaults)

        XCTAssertEqual(store.lastCaptureMode, .display(CGMainDisplayID()))
    }

    /// 审查修复轮 1：defaults 外写野值（fps=24 / countdown=7）加载时钳回合法档位（30/5）——
    /// 偏好设置 Picker 恒有匹配 tag，钳后值驱动录制配置。
    func testOutOfRangePersistedFpsAndCountdownAreClampedToValidOptions() {
        defaults.set(24, forKey: "fps")
        defaults.set(7, forKey: "countdownSeconds")

        let store = SettingsStore(userDefaults: defaults)

        XCTAssertEqual(store.fps, 30)
        XCTAssertEqual(store.countdownSeconds, 5)
    }

    /// 审查修复轮 1：合法档位（含边界 60 / 0）不被钳制，原样通过。
    func testValidFpsAndCountdownValuesAreNotClamped() {
        defaults.set(60, forKey: "fps")
        defaults.set(0, forKey: "countdownSeconds")

        let store = SettingsStore(userDefaults: defaults)

        XCTAssertEqual(store.fps, 60)
        XCTAssertEqual(store.countdownSeconds, 0)
    }

    /// Q2：录制鼠标光标开关默认开（true = 既有行为不变），翻转跨实例持久化、
    /// 落库写回 true 再构造往返（UserDefaults，key = captureMouseCursor）。
    func testCaptureMouseCursorDefaultsTrueAndPersists() {
        let store = SettingsStore(userDefaults: defaults)
        XCTAssertTrue(store.captureMouseCursor, "默认显示鼠标光标（既有行为不变）")

        // 翻转为 false → 重新用同一 suite 构造 → 仍为 false（持久化）
        store.captureMouseCursor = false
        let reloaded = SettingsStore(userDefaults: defaults)
        XCTAssertFalse(reloaded.captureMouseCursor)

        // defaults 写回 true → 再构造 → true（往返）
        defaults.set(true, forKey: "captureMouseCursor")
        let roundTripped = SettingsStore(userDefaults: defaults)
        XCTAssertTrue(roundTripped.captureMouseCursor)
    }

    /// Q5：长录时长提醒间隔默认 1（小时），翻转落库跨实例持久化、「从不」档落库写回
    /// 再构造往返（UserDefaults，key = recordingReminderIntervalHours；合法档位 0/1/2/3）。
    func testRecordingReminderIntervalDefaultsOneAndPersists() {
        let store = SettingsStore(userDefaults: defaults)
        XCTAssertEqual(store.recordingReminderIntervalHours, 1, "默认 1 小时提醒一次")

        // 翻转为 3 → 重新用同一 suite 构造 → 仍为 3（持久化）
        store.recordingReminderIntervalHours = 3
        let reloaded = SettingsStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.recordingReminderIntervalHours, 3)

        // defaults 写回 0（从不）→ 再构造 → 0（往返）
        defaults.set(0, forKey: "recordingReminderIntervalHours")
        let never = SettingsStore(userDefaults: defaults)
        XCTAssertEqual(never.recordingReminderIntervalHours, 0)
    }

    /// Q6：编辑导出后动作两开关默认关（opt-in——绝不主动删用户文件），翻转跨实例
    /// 持久化、落库写回 false 再构造往返（UserDefaults，key =
    /// editorPostExportRevealInFinder / editorPostExportDeleteOriginal；布尔无野值档位）。
    func testEditorPostExportSwitchesDefaultOffAndPersist() {
        let store = SettingsStore(userDefaults: defaults)
        XCTAssertFalse(store.editorPostExportRevealInFinder, "默认不打开 Finder")
        XCTAssertFalse(store.editorPostExportDeleteOriginal, "默认不删原始文件")

        // 翻转为 true → 重新用同一 suite 构造 → 仍为 true（持久化）
        store.editorPostExportRevealInFinder = true
        store.editorPostExportDeleteOriginal = true
        let reloaded = SettingsStore(userDefaults: defaults)
        XCTAssertTrue(reloaded.editorPostExportRevealInFinder)
        XCTAssertTrue(reloaded.editorPostExportDeleteOriginal)

        // defaults 写回 false → 再构造 → false（往返）
        defaults.set(false, forKey: "editorPostExportRevealInFinder")
        defaults.set(false, forKey: "editorPostExportDeleteOriginal")
        let roundTripped = SettingsStore(userDefaults: defaults)
        XCTAssertFalse(roundTripped.editorPostExportRevealInFinder)
        XCTAssertFalse(roundTripped.editorPostExportDeleteOriginal)
    }

    /// 终审 F2：「录制中静音麦克风」持久化默认关，翻转跨实例往返。
    func testMicMutedDefaultsToFalseAndPersistsAcrossInstances() {
        let store = SettingsStore(userDefaults: defaults)
        XCTAssertFalse(store.micMuted, "静音默认关（不改变既有开录行为）")

        store.micMuted = true

        let reloaded = SettingsStore(userDefaults: defaults)
        XCTAssertTrue(reloaded.micMuted)
    }

    /// P1a：点击自动缩放默认关 + 档位默认 1.6（opt-in，同点击高亮）。
    func testAutoZoomDefaultsToDisabledAndLevelOnePointSix() {
        let store = SettingsStore(userDefaults: defaults)

        XCTAssertFalse(store.autoZoomEnabled)
        XCTAssertEqual(store.autoZoomLevel, 1.6)
    }

    /// P1a 简报钉测：非法档位 didSet 钳回 1.6（{1.35,1.6,1.9} 之外一律 1.6），
    /// 合法档位原样通过。
    func testAutoZoomLevelClampsInvalidToDefault() {
        let store = SettingsStore(userDefaults: defaults)

        store.autoZoomLevel = 99
        XCTAssertEqual(store.autoZoomLevel, 1.6)

        store.autoZoomLevel = 1.0
        XCTAssertEqual(store.autoZoomLevel, 1.6)

        store.autoZoomLevel = 1.35
        XCTAssertEqual(store.autoZoomLevel, 1.35)

        store.autoZoomLevel = 1.9
        XCTAssertEqual(store.autoZoomLevel, 1.9)
    }

    /// P1a：开关与档位跨实例往返（UserDefaults 持久化，key = 属性名）。
    func testAutoZoomSettingsPersistAcrossInstances() {
        let store = SettingsStore(userDefaults: defaults)
        store.autoZoomEnabled = true
        store.autoZoomLevel = 1.9

        let reloaded = SettingsStore(userDefaults: defaults)

        XCTAssertTrue(reloaded.autoZoomEnabled)
        XCTAssertEqual(reloaded.autoZoomLevel, 1.9)
    }

    /// defaults 外写野值（如 2.5）加载时钳回 1.6——沿用 fps/countdownSeconds 载入钳制模式。
    func testOutOfRangePersistedAutoZoomLevelClampsToDefault() {
        defaults.set(2.5, forKey: "autoZoomLevel")

        let store = SettingsStore(userDefaults: defaults)

        XCTAssertEqual(store.autoZoomLevel, 1.6)
    }

    // MARK: P4 键盘按键可视化样式（Task 8 简报钉测）

    /// testStyleParamsRoundTrip（2026-11-15 Omi 键盘事件页复刻改版）：默认开（页面无
    /// 启用开关，键帽随录制常显）、组合过滤默认关、字号默认 14（连续 12…48 越界钳界）、
    /// 停留默认 2s（连续 1…5 越界钳界）、换行延迟默认 0.5 / 消失时长默认 0.2（0…1 越界
    /// 钳界）、面板黑 65% / 文字白，全项跨实例往返。
    func testStyleParamsRoundTrip() {
        let store = SettingsStore(userDefaults: defaults)

        XCTAssertTrue(store.keyboardOverlayEnabled, "Omi 复刻：默认开（页面无启用开关）")
        XCTAssertFalse(store.keyboardOverlayCombosOnly, "仅显示组合按键默认关")
        XCTAssertEqual(store.keyboardOverlayFontSize, 14)
        XCTAssertEqual(store.keyboardOverlayLingerSeconds, 2)
        XCTAssertEqual(store.keyboardOverlayWrapDelaySeconds, 0.5)
        XCTAssertEqual(store.keyboardOverlayFadeSeconds, 0.2)
        XCTAssertEqual(store.keyboardOverlayPanelColor, .panelDefault, "面板色默认黑 65%")
        XCTAssertEqual(store.keyboardOverlayTextColor, .textDefault, "文字色默认白")

        store.keyboardOverlayFontSize = 99
        XCTAssertEqual(store.keyboardOverlayFontSize, 48, "越界字号钳上界 48")
        store.keyboardOverlayFontSize = 11
        XCTAssertEqual(store.keyboardOverlayFontSize, 12, "越界字号钳下界 12")
        store.keyboardOverlayFontSize = 12
        XCTAssertEqual(store.keyboardOverlayFontSize, 12, "界内原样通过")
        store.keyboardOverlayFontSize = 24
        XCTAssertEqual(store.keyboardOverlayFontSize, 24)

        store.keyboardOverlayLingerSeconds = 6
        XCTAssertEqual(store.keyboardOverlayLingerSeconds, 5, "越界停留钳上界 5")
        store.keyboardOverlayLingerSeconds = 0.5
        XCTAssertEqual(store.keyboardOverlayLingerSeconds, 1, "越界停留钳下界 1")
        store.keyboardOverlayLingerSeconds = 1
        XCTAssertEqual(store.keyboardOverlayLingerSeconds, 1, "界内原样通过")
        store.keyboardOverlayLingerSeconds = 3
        XCTAssertEqual(store.keyboardOverlayLingerSeconds, 3)

        store.keyboardOverlayWrapDelaySeconds = 2
        XCTAssertEqual(store.keyboardOverlayWrapDelaySeconds, 1, "越界换行延迟钳上界 1")
        store.keyboardOverlayWrapDelaySeconds = -1
        XCTAssertEqual(store.keyboardOverlayWrapDelaySeconds, 0, "越界换行延迟钳下界 0")
        store.keyboardOverlayWrapDelaySeconds = 0.5
        XCTAssertEqual(store.keyboardOverlayWrapDelaySeconds, 0.5)

        store.keyboardOverlayFadeSeconds = 3
        XCTAssertEqual(store.keyboardOverlayFadeSeconds, 1, "越界消失时长钳上界 1")
        store.keyboardOverlayFadeSeconds = 0.2
        XCTAssertEqual(store.keyboardOverlayFadeSeconds, 0.2)

        // 合法组合跨实例往返（含色井 RGBA 保值）
        store.keyboardOverlayEnabled = false
        store.keyboardOverlayCombosOnly = true
        store.keyboardOverlayFontSize = 24
        store.keyboardOverlayLingerSeconds = 3
        store.keyboardOverlayWrapDelaySeconds = 0.8
        store.keyboardOverlayFadeSeconds = 0.4
        store.keyboardOverlayPanelColor = KeyboardOverlayColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.8)
        store.keyboardOverlayTextColor = KeyboardOverlayColor(red: 1, green: 0.5, blue: 0, alpha: 1)

        let reloaded = SettingsStore(userDefaults: defaults)

        XCTAssertFalse(reloaded.keyboardOverlayEnabled)
        XCTAssertTrue(reloaded.keyboardOverlayCombosOnly)
        XCTAssertEqual(reloaded.keyboardOverlayFontSize, 24)
        XCTAssertEqual(reloaded.keyboardOverlayLingerSeconds, 3)
        XCTAssertEqual(reloaded.keyboardOverlayWrapDelaySeconds, 0.8)
        XCTAssertEqual(reloaded.keyboardOverlayFadeSeconds, 0.4)
        XCTAssertEqual(reloaded.keyboardOverlayPanelColor,
                       KeyboardOverlayColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.8))
        XCTAssertEqual(reloaded.keyboardOverlayTextColor,
                       KeyboardOverlayColor(red: 1, green: 0.5, blue: 0, alpha: 1))
    }

    /// defaults 外写野值（字号 99 / 停留 9 / 换行 7 / 消失 -1）加载时钳回区间界——
    /// 沿用 fps/countdownSeconds 载入钳制模式（init 内赋值不触发 didSet，落库野值不回写）。
    func testOutOfRangePersistedKeyboardStyleClampsToDefaults() {
        defaults.set(99, forKey: "keyboardOverlayFontSize")
        defaults.set(9.0, forKey: "keyboardOverlayLingerSeconds")
        defaults.set(7.0, forKey: "keyboardOverlayWrapDelaySeconds")
        defaults.set(-1.0, forKey: "keyboardOverlayFadeSeconds")

        let store = SettingsStore(userDefaults: defaults)

        XCTAssertEqual(store.keyboardOverlayFontSize, 48)
        XCTAssertEqual(store.keyboardOverlayLingerSeconds, 5)
        XCTAssertEqual(store.keyboardOverlayWrapDelaySeconds, 1)
        XCTAssertEqual(store.keyboardOverlayFadeSeconds, 0)
    }

    // MARK: P5 摄像头背景（Task 10 简报钉测）

    /// 默认 off（原画面）；blur 与三个内置背景跨实例往返——枚举整只 JSON 落库
    /// （lastCaptureMode 同款 Codable 模式，key = cameraBackground；枚举无野值档位）。
    func testCameraBackgroundRoundTripAcrossInstances() {
        let store = SettingsStore(userDefaults: defaults)
        XCTAssertEqual(store.cameraBackground, .off, "P5 默认原画面（帧路径零开销旁路）")

        store.cameraBackground = .blur
        XCTAssertEqual(SettingsStore(userDefaults: defaults).cameraBackground, .blur)

        store.cameraBackground = .builtin(.gradientWarm)
        XCTAssertEqual(SettingsStore(userDefaults: defaults).cameraBackground,
                       .builtin(.gradientWarm), "关联值枚举往返保值")

        store.cameraBackground = .builtin(.gradientCool)
        XCTAssertEqual(SettingsStore(userDefaults: defaults).cameraBackground,
                       .builtin(.gradientCool))

        store.cameraBackground = .builtin(.solidSlate)
        XCTAssertEqual(SettingsStore(userDefaults: defaults).cameraBackground,
                       .builtin(.solidSlate))
    }

    /// 落库野值（解码失败）加载回退默认 off——沿 lastCaptureMode/windowCaptureTarget
    /// 的「解码失败回退默认」模式。
    func testCorruptedPersistedCameraBackgroundFallsBackToOff() {
        defaults.set(Data("not-a-codable-payload".utf8), forKey: "cameraBackground")

        let store = SettingsStore(userDefaults: defaults)

        XCTAssertEqual(store.cameraBackground, .off, "解码失败必须回退默认原画面")
    }

    private var defaultOutputDirectory: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hummingbird", isDirectory: true)
    }
}
