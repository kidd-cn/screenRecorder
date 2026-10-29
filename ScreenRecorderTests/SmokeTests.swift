import XCTest

@testable import ScreenRecorder

final class SmokeTests: XCTestCase {
    func testSmoke() {
        XCTAssertTrue(true)
    }
}

// MARK: - 开录 config 快照（终审 F2 复审残余：micMuted 必须随快照入照）

/// 唯一装配点 `AppAssembly.makeConfiguration` 的无头钉测（AppAssembly 本体装配窗口/通知
/// 中心不可无头构造，故抽纯函数缝——同 assemblyPlan/QuitGuard 模式）。
@MainActor
final class RecordingConfigurationSnapshotTests: XCTestCase {
    private static let suiteName = "test.assembly.snapshot"

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

    /// 持久化静音（true）场景：快照必须携带 micMuted——漏带则 registerMicrophone 拿到
    /// 缺省 false，开录照装 tap，持久化静音被每场开录静默忽略（复审残余指向的缺陷）。
    func testConfigurationSnapshotCarriesMicMutedTrue() {
        let settings = SettingsStore(userDefaults: defaults)
        settings.captureMicrophone = true
        settings.micMuted = true

        let config = AppAssembly.makeConfiguration(
            settings: settings,
            mode: .display(1),
            outputURL: URL(fileURLWithPath: "/tmp/snapshot.mp4"))

        XCTAssertTrue(config.micMuted, "开录快照必须携带持久化静音")
        XCTAssertTrue(config.captureMicrophone)
        XCTAssertEqual(config.micVolume, settings.micVolume, "既有快照字段回归守卫（同缝）")
    }

    /// 静音关（缺省）场景照常携带 false，不改变既有开录行为。
    func testConfigurationSnapshotDefaultsToUnmuted() {
        let settings = SettingsStore(userDefaults: defaults)

        let config = AppAssembly.makeConfiguration(
            settings: settings,
            mode: .display(1),
            outputURL: URL(fileURLWithPath: "/tmp/snapshot.mp4"))

        XCTAssertFalse(config.micMuted)
        XCTAssertEqual(config.mode, .display(1))
    }
}
