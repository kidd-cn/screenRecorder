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

    private var defaultOutputDirectory: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenRecorder", isDirectory: true)
    }
}
