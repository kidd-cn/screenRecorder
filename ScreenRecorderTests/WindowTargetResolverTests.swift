import CoreGraphics
import XCTest

@testable import ScreenRecorder

// MARK: - 夹具（无头可构造中性快照，同 WindowPickerTests 纪律）

private func makeWindow(
    id: CGWindowID,
    title: String? = nil,
    appName: String? = nil,
    bundleID: String? = nil,
    width: CGFloat = 800,
    height: CGFloat = 600,
    layer: Int = 0
) -> ShareableWindow {
    ShareableWindow(
        windowID: id,
        title: title,
        appName: appName,
        appBundleID: bundleID,
        frame: CGRect(x: 0, y: 0, width: width, height: height),
        layer: layer)
}

/// 固定 savedAt 的目标（Equatable 断言不含当下时间噪声）。
private func makeTarget(identifier: String, title: String) -> WindowCaptureTarget {
    WindowCaptureTarget(
        ownerAppIdentifier: identifier,
        windowTitle: title,
        savedAt: Date(timeIntervalSince1970: 1_000_000))
}

// MARK: - WindowTargetResolver.resolve（简报 Step 1：解析顺序逐条钉测）

/// 解析顺序（裁定 2）：bundleID+标题全等 → bundleID+标题前缀 → ownerName 兜底；
/// 同段多命中取面积最大，仍平取候选序首个；零命中 / 空目标 → nil。纯函数全无头。
final class WindowTargetResolverTests: XCTestCase {

    // MARK: 空目标

    func testNilTargetResolvesToNil() {
        XCTAssertNil(WindowTargetResolver.resolve(candidates: [makeWindow(id: 1)], target: nil))
    }

    /// 空目标 = 标识或标题有空串：无法构成稳定标识，解析必 nil（含「标识全空」防御）。
    func testEmptyIdentifierOrTitleResolvesToNil() {
        let candidates = [makeWindow(id: 1, title: "文档", appName: "Pages", bundleID: "com.apple.Pages")]
        XCTAssertNil(WindowTargetResolver.resolve(candidates: candidates, target: makeTarget(identifier: "", title: "文档")))
        XCTAssertNil(WindowTargetResolver.resolve(candidates: candidates, target: makeTarget(identifier: "com.apple.Pages", title: "")))
    }

    // MARK: 第一段：bundleID + 标题全等

    func testExactBundleIDAndTitleMatch() {
        let candidates = [
            makeWindow(id: 1, title: "其他", appName: "Pages", bundleID: "com.apple.Pages"),
            makeWindow(id: 2, title: "文档", appName: "Pages", bundleID: "com.apple.Pages"),
        ]
        XCTAssertEqual(
            WindowTargetResolver.resolve(candidates: candidates, target: makeTarget(identifier: "com.apple.Pages", title: "文档"))?.windowID,
            2)
    }

    /// 段序裁定：全等段整体优先于前缀段——即便前缀命中面积更大也不越段。
    func testExactMatchBeatsPrefixStageEvenWhenPrefixWindowIsLarger() {
        let candidates = [
            makeWindow(id: 1, title: "文档 — 编辑", appName: "Pages", bundleID: "com.apple.Pages",
                       width: 1920, height: 1080),
            makeWindow(id: 2, title: "文档", appName: "Pages", bundleID: "com.apple.Pages",
                       width: 100, height: 50),
        ]
        XCTAssertEqual(
            WindowTargetResolver.resolve(candidates: candidates, target: makeTarget(identifier: "com.apple.Pages", title: "文档"))?.windowID,
            2, "全等段先于前缀段，不受面积影响")
    }

    // MARK: 第二段：bundleID + 标题前缀（窗口改名场景：标题被加前后缀）

    func testTitlePrefixMatchWhenExactAbsent() {
        let candidates = [
            makeWindow(id: 1, title: "文档 2", appName: "Pages", bundleID: "com.apple.Pages"),
        ]
        XCTAssertEqual(
            WindowTargetResolver.resolve(candidates: candidates, target: makeTarget(identifier: "com.apple.Pages", title: "文档"))?.windowID,
            1, "「文档」是「文档 2」的前缀：改名不丢目标")
    }

    func testPrefixMatchesPickLargestArea() {
        let candidates = [
            makeWindow(id: 1, title: "文档 2", appName: "Pages", bundleID: "com.apple.Pages",
                       width: 100, height: 50),
            makeWindow(id: 2, title: "文档 — 编辑", appName: "Pages", bundleID: "com.apple.Pages",
                       width: 2000, height: 1000),
        ]
        XCTAssertEqual(
            WindowTargetResolver.resolve(candidates: candidates, target: makeTarget(identifier: "com.apple.Pages", title: "文档"))?.windowID,
            2, "前缀段多命中取面积最大")
    }

    /// 前缀匹配绑定 bundleID：其他应用的同前缀标题不得命中。
    func testPrefixDoesNotCrossApps() {
        let candidates = [
            makeWindow(id: 1, title: "文档 — 备忘录", appName: "Notes", bundleID: "com.apple.Notes"),
        ]
        XCTAssertNil(WindowTargetResolver.resolve(candidates: candidates, target: makeTarget(identifier: "com.apple.Pages", title: "文档")))
    }

    // MARK: 第三段：ownerName 兜底（保存时 bundle id 不可得、落的是 ownerName）

    func testOwnerNameFallbackMatchesWhenBundleIDStageEmpty() {
        let candidates = [
            makeWindow(id: 1, title: "未命名", appName: "TextEdit", bundleID: "com.apple.TextEdit"),
        ]
        // 存的标识是 ownerName「TextEdit」，与候选 bundleID 不相等 → 前两段空 → ownerName 段命中。
        XCTAssertEqual(
            WindowTargetResolver.resolve(candidates: candidates, target: makeTarget(identifier: "TextEdit", title: "未命名"))?.windowID,
            1)
    }

    /// ownerName 兜底同样要求标题全等：appName 相等但标题已变 → 不命中（宁重选不录错窗）。
    func testOwnerNameFallbackRequiresExactTitle() {
        let candidates = [
            makeWindow(id: 1, title: "未命名 2", appName: "TextEdit", bundleID: "com.apple.TextEdit"),
        ]
        XCTAssertNil(WindowTargetResolver.resolve(candidates: candidates, target: makeTarget(identifier: "TextEdit", title: "未命名")))
    }

    // MARK: 多命中 / 平决 / 零命中

    func testMultipleExactMatchesPickLargestArea() {
        let candidates = [
            makeWindow(id: 1, title: "文档", appName: "Pages", bundleID: "com.apple.Pages",
                       width: 800, height: 600),
            makeWindow(id: 2, title: "文档", appName: "Pages", bundleID: "com.apple.Pages",
                       width: 1024, height: 768),
        ]
        XCTAssertEqual(
            WindowTargetResolver.resolve(candidates: candidates, target: makeTarget(identifier: "com.apple.Pages", title: "文档"))?.windowID,
            2)
    }

    /// 面积也平 → 取候选序首个（枚举侧排序确定，结果可复现）。
    func testAreaTieBreaksToFirstInListOrder() {
        let candidates = [
            makeWindow(id: 7, title: "文档", appName: "Pages", bundleID: "com.apple.Pages"),
            makeWindow(id: 8, title: "文档", appName: "Pages", bundleID: "com.apple.Pages"),
        ]
        XCTAssertEqual(
            WindowTargetResolver.resolve(candidates: candidates, target: makeTarget(identifier: "com.apple.Pages", title: "文档"))?.windowID,
            7)
    }

    func testZeroMatchReturnsNil() {
        let candidates = [
            makeWindow(id: 1, title: "文档", appName: "Notes", bundleID: "com.apple.Notes"),
        ]
        // 标识对不上应用（三段全空）：标题再像也不跨应用命中。
        XCTAssertNil(WindowTargetResolver.resolve(candidates: candidates, target: makeTarget(identifier: "com.apple.Pages", title: "文档")))
        // 应用对得上但标题完全不同：同样零命中。
        XCTAssertNil(WindowTargetResolver.resolve(candidates: candidates, target: makeTarget(identifier: "com.apple.Notes", title: "表格")))
    }
}

// MARK: - WindowStartDecision（裁定 5：⇧⌘W handler 三分支决策，纯函数）

final class WindowStartDecisionTests: XCTestCase {

    func testNoTargetOpensPicker() {
        XCTAssertEqual(
            WindowStartDecision.resolve(target: nil, candidates: [makeWindow(id: 1)]),
            .openPicker)
    }

    func testHitStartsWindowDirectly() {
        let candidates = [makeWindow(id: 42, title: "文档", appName: "Pages", bundleID: "com.apple.Pages")]
        XCTAssertEqual(
            WindowStartDecision.resolve(target: makeTarget(identifier: "com.apple.Pages", title: "文档"), candidates: candidates),
            .start(windowID: 42))
    }

    func testStaleTargetNotifiesThenOpensPicker() {
        // 目标仍在但现场解析不命中（窗口已关/改名）→ 提示后开选择器；既有目标不清除（由装配层保证）。
        let candidates = [makeWindow(id: 1, title: "别的窗口", appName: "Pages", bundleID: "com.apple.Pages")]
        XCTAssertEqual(
            WindowStartDecision.resolve(target: makeTarget(identifier: "com.apple.Pages", title: "文档"), candidates: candidates),
            .staleNotifyThenPicker)
    }

    /// 有目标但为空串标识/标题：解析必 nil → 走 stale 分支而非 openPicker（分支语义不混淆）。
    func testEmptyTargetFallsIntoStaleBranch() {
        XCTAssertEqual(
            WindowStartDecision.resolve(target: makeTarget(identifier: "", title: "文档"), candidates: [makeWindow(id: 1)]),
            .staleNotifyThenPicker)
    }
}

// MARK: - makeTarget（裁定 1：选定时刻的稳定标识组装）

final class WindowTargetAssemblyTests: XCTestCase {
    private let savedAt = Date(timeIntervalSince1970: 2_000_000)

    func testNilSnapshotReturnsNil() {
        XCTAssertNil(WindowTargetResolver.makeTarget(
            windowID: 9, snapshot: nil, savedAt: savedAt,
            bundleIdentifierForPID: { _ in "com.x" }))
    }

    func testBundleIDPreferredOverOwnerName() {
        let snapshot = WindowOwnerSnapshot(ownerPID: 4711, title: "文档", ownerName: "TextEdit")
        XCTAssertEqual(
            WindowTargetResolver.makeTarget(
                windowID: 9, snapshot: snapshot, savedAt: savedAt,
                bundleIdentifierForPID: { $0 == 4711 ? "com.apple.TextEdit" : nil }),
            WindowCaptureTarget(ownerAppIdentifier: "com.apple.TextEdit", windowTitle: "文档", savedAt: savedAt))
    }

    func testOwnerNameFallbackWhenBundleIDUnavailable() {
        let snapshot = WindowOwnerSnapshot(ownerPID: 4711, title: "未命名", ownerName: "TextEdit")
        XCTAssertEqual(
            WindowTargetResolver.makeTarget(
                windowID: 9, snapshot: snapshot, savedAt: savedAt,
                bundleIdentifierForPID: { _ in nil }),
            WindowCaptureTarget(ownerAppIdentifier: "TextEdit", windowTitle: "未命名", savedAt: savedAt))
    }

    func testNilWhenBothIdentifiersUnavailable() {
        let snapshot = WindowOwnerSnapshot(ownerPID: 4711, title: "文档", ownerName: nil)
        XCTAssertNil(WindowTargetResolver.makeTarget(
            windowID: 9, snapshot: snapshot, savedAt: savedAt,
            bundleIdentifierForPID: { _ in nil }))
    }

    /// 无标题窗口：立即开录仍可用（windowID 在手），持久化标题以空串占位（下次解析走 stale 分支）。
    func testMissingTitlePersistsAsEmptyString() {
        let snapshot = WindowOwnerSnapshot(ownerPID: 4711, title: nil, ownerName: "TextEdit")
        XCTAssertEqual(
            WindowTargetResolver.makeTarget(
                windowID: 9, snapshot: snapshot, savedAt: savedAt,
                bundleIdentifierForPID: { _ in "com.apple.TextEdit" })?.windowTitle,
            "")
    }
}

// MARK: - WindowPicker.enumeratedWindows（T20 新枚举缝：解析用中性快照，不产缩略图）

@MainActor
final class WindowPickerEnumeratedWindowsTests: XCTestCase {

    func testPermissionDeniedShortCircuitsWithoutEnumerating() async {
        var didEnumerate = false
        do {
            _ = try await WindowPicker.enumeratedWindows(
                preflight: { false },
                loadWindows: {
                    didEnumerate = true
                    return []
                })
            XCTFail("权限未授予必须抛错")
        } catch {
            XCTAssertEqual(error as? WindowPickerError, .screenRecordingPermissionDenied)
            XCTAssertFalse(didEnumerate, "权限短路：内容枚举不得发生（T14 语义一致）")
        }
    }

    func testEnumerationFailureIsWrappedAsContentUnavailable() async {
        do {
            _ = try await WindowPicker.enumeratedWindows(
                preflight: { true },
                loadWindows: { throw StubEnumerationFailure() })
            XCTFail("枚举失败必须抛错")
        } catch {
            XCTAssertEqual(
                error as? WindowPickerError,
                .contentUnavailable(underlying: "stub 枚举失败"),
                "与 availableWindows 同款包裹语义")
        }
    }

    /// 过滤 + 排序与 T14 selectableWindows 一致：自身/非零层/零面积剔除，App 名→标题→id 序。
    func testReturnsFilteredSelectableWindowsInCanonicalOrder() async throws {
        let windows = [
            makeWindow(id: 1, title: "浮条", bundleID: "com.screenrecorder.app"),
            makeWindow(id: 2, title: "状态项", bundleID: "com.apple.SUI", layer: 25),
            makeWindow(id: 3, title: "零宽", bundleID: "com.apple.Z", width: 0, height: 100),
            makeWindow(id: 5, title: "终端", appName: "Terminal", bundleID: "com.apple.Terminal",
                       width: 100, height: 50),
            makeWindow(id: 4, title: "文档", appName: "Pages", bundleID: "com.apple.Pages",
                       width: 1920, height: 1080),
        ]
        let result = try await WindowPicker.enumeratedWindows(
            preflight: { true },
            loadWindows: { windows })
        XCTAssertEqual(result.map(\.windowID), [4, 5], "过滤排序与 selectableWindows 同规")
        XCTAssertEqual(result[0].appBundleID, "com.apple.Pages", "解析所需的 bundleID/frame 原样携带")
        XCTAssertEqual(result[0].frame.width, 1920)
    }
}

/// 枚举失败替身（同 WindowPickerTests 的固定文案形态）。
private struct StubEnumerationFailure: Error, CustomStringConvertible {
    var description: String { "stub 枚举失败" }
}

// MARK: - SettingsStore.windowCaptureTarget（简报 Step 2：持久化 + Codable 往返钉测）

/// 隔离纪律同 SettingsStoreTests：独立 suite + setUp/tearDown removePersistentDomain。
final class WindowCaptureTargetSettingsTests: XCTestCase {
    private static let suiteName = "test.settings.windowCaptureTarget"

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

    /// 默认未配置（nil = 未设置；偏好区显示「未设置」，⇧⌘W 走 openPicker 分支）。
    func testDefaultIsNil() {
        let store = SettingsStore(userDefaults: defaults)
        XCTAssertNil(store.windowCaptureTarget)
    }

    /// Codable JSON 整只落库，跨实例往返（含 savedAt 的 Date 编码）。
    func testPersistsAcrossInstancesWithCodableRoundTrip() {
        let store = SettingsStore(userDefaults: defaults)
        let target = WindowCaptureTarget(
            ownerAppIdentifier: "com.apple.TextEdit",
            windowTitle: "未命名",
            savedAt: Date(timeIntervalSince1970: 1_765_000_000))
        store.windowCaptureTarget = target

        let reloaded = SettingsStore(userDefaults: defaults)

        XCTAssertEqual(reloaded.windowCaptureTarget, target)
    }

    /// 落库损坏（无法解码）时回退未配置，不崩溃、不阻塞启动（同 lastCaptureMode 纪律）。
    func testCorruptDataFallsBackToNil() {
        defaults.set(Data([0x00, 0x01, 0x02]), forKey: "windowCaptureTarget")

        let store = SettingsStore(userDefaults: defaults)

        XCTAssertNil(store.windowCaptureTarget)
    }

    /// 置 nil = 清除配置：落库键一并移除（重载后仍为未配置）。
    func testSettingNilRemovesPersistedValue() {
        let store = SettingsStore(userDefaults: defaults)
        store.windowCaptureTarget = makeTarget(identifier: "com.apple.TextEdit", title: "未命名")
        XCTAssertNotNil(defaults.data(forKey: "windowCaptureTarget"))

        store.windowCaptureTarget = nil

        let reloaded = SettingsStore(userDefaults: defaults)
        XCTAssertNil(reloaded.windowCaptureTarget)
        XCTAssertNil(defaults.data(forKey: "windowCaptureTarget"), "落库键移除，不留死数据")
    }
}
