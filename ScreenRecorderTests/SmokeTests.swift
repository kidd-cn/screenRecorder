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

    /// P1b 音轨存在性矩阵（spec §5「双源全关+音效开必有音轨」钉测）：双开/仅系统/仅麦/
    /// 双关+音效开 → 音轨恒存在（双关+音效开 = 「效果专用音轨」）；双关+音效关 → 无音轨
    ///（既有行为回归）。同时回归 clickSoundEnabled 经 makeConfiguration 的快照透传。
    func testConfigAudioTrackMatrix() {
        let matrix: [(systemAudio: Bool, microphone: Bool, clickSound: Bool, hasTrack: Bool)] = [
            (true, true, true, true),     // 双开+音效
            (true, false, false, true),   // 仅系统声
            (false, true, false, true),   // 仅麦克风
            (false, false, true, true),   // 双关+音效开：效果专用音轨（本任务核心语义）
            (false, false, false, false), // 双关+音效关：无音轨（既有）
        ]
        for row in matrix {
            let settings = SettingsStore(userDefaults: defaults)
            settings.captureSystemAudio = row.systemAudio
            settings.captureMicrophone = row.microphone
            settings.clickSoundEnabled = row.clickSound

            let config = AppAssembly.makeConfiguration(
                settings: settings,
                mode: .display(1),
                outputURL: URL(fileURLWithPath: "/tmp/matrix.mp4"))

            XCTAssertEqual(config.clickSoundEnabled, row.clickSound,
                           "clickSoundEnabled 快照透传（system=\(row.systemAudio), mic=\(row.microphone)）")
            XCTAssertEqual(
                SCStreamRecorder.includesAudioTrack(
                    captureSystemAudio: config.captureSystemAudio,
                    captureMicrophone: config.captureMicrophone,
                    clickSoundEnabled: config.clickSoundEnabled),
                row.hasTrack,
                "音轨存在性（system=\(row.systemAudio), mic=\(row.microphone), sound=\(row.clickSound)）")
        }
    }
}

// MARK: - 窗口区域开录钳制（P3b 修复轮 1：安全关键路径纯函数化钉测）

/// `SCStreamRecorder.clampedWindowRect` 三采样（审阅修复轮 1 Minor 2）：开录钳制 + 空交集
/// 保护原内联在触 SCShareableContent 的 async 方法里钉不了，抽取纯函数后在此无头钉死。
/// 夹具窗口 800×500（窗口相对系原点 = 窗口左上）。
final class WindowRegionClampTests: XCTestCase {
    private let windowSize = CGSize(width: 800, height: 500)

    /// 采样 1：窗口内 rect（选区路径的常态产物）恒等还原——钳制不得侵蚀合法选区。
    func testClampedWindowRectKeepsInsideRectUntouched() {
        let rect = CGRect(x: 100, y: 50, width: 200, height: 150)
        XCTAssertEqual(
            SCStreamRecorder.clampedWindowRect(windowSize: windowSize, rect: rect),
            rect, "窗口内 rect 恒等还原")
        // 恰贴窗口右/下边的临界 rect 同样不动（交集=自身）。
        let flush = CGRect(x: 600, y: 400, width: 200, height: 100)
        XCTAssertEqual(
            SCStreamRecorder.clampedWindowRect(windowSize: windowSize, rect: flush),
            flush, "贴边 rect 恰与窗口 frame 求交为自身，不动")
    }

    /// 采样 2：⇧⌘R 复播遇窗口缩小（陈旧 rect 越过当前右边/下边）→ 裁回窗口范围。
    func testClampedWindowRectClipsRectExceedingShrunkenWindow() {
        XCTAssertEqual(
            SCStreamRecorder.clampedWindowRect(windowSize: windowSize,
                                               rect: CGRect(x: 600, y: 400, width: 400, height: 300)),
            CGRect(x: 600, y: 400, width: 200, height: 100),
            "越界部分裁到窗口右边/下边（开录钳制固定语义）")
        XCTAssertEqual(
            SCStreamRecorder.clampedWindowRect(windowSize: windowSize,
                                               rect: CGRect(x: -50, y: -50, width: 300, height: 300)),
            CGRect(x: 0, y: 0, width: 250, height: 250),
            "负坐标越界同样裁到窗口左上边")
    }

    /// 采样 3：完全裁空 → nil（无内容可录，resolveTarget 据此走 windowRegionClippedEmpty
    /// begin 失败路径）；零尺寸窗口同判（交集恒空）。
    func testClampedWindowRectReturnsNilWhenFullyOutsideOrWindowEmpty() {
        XCTAssertNil(
            SCStreamRecorder.clampedWindowRect(windowSize: windowSize,
                                               rect: CGRect(x: 900, y: 600, width: 100, height: 100)),
            "rect 完全落在窗口之外 → nil")
        XCTAssertNil(
            SCStreamRecorder.clampedWindowRect(windowSize: windowSize,
                                               rect: CGRect(x: 600, y: 500, width: 200, height: 100)),
            "rect 紧贴窗口下边起（y=500，窗口相对系底边之外）→ 高度交集为零 → nil")
        XCTAssertNil(
            SCStreamRecorder.clampedWindowRect(windowSize: .zero,
                                               rect: CGRect(x: 0, y: 0, width: 100, height: 100)),
            "零尺寸窗口 → nil（防御采样）")
    }
}
