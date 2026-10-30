import XCTest
import AVFoundation
import CoreGraphics

@testable import ScreenRecorder

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

    private var defaultOutputDirectory: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenRecorder", isDirectory: true)
    }
}
