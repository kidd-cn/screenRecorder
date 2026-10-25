import XCTest
import AVFoundation

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
        XCTAssertTrue(store.clickHighlightEnabled)
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

    private var defaultOutputDirectory: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenRecorder", isDirectory: true)
    }
}
