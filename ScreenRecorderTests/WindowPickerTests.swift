import AppKit
import XCTest

@testable import ScreenRecorder

// MARK: - 夹具

/// 无头可构造的中性窗口快照（SCShareableContent 需 TCC 授权，测试全部走注入缝）。
private func makeWindow(
    id: CGWindowID,
    title: String? = nil,
    appName: String? = "示例应用",
    bundleID: String? = "com.example.app",
    frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600),
    layer: Int = 0
) -> ShareableWindow {
    ShareableWindow(
        windowID: id,
        title: title,
        appName: appName,
        appBundleID: bundleID,
        frame: frame,
        layer: layer)
}

/// 枚举失败的底层错误替身：description 固定文案，供包裹断言核对透传
///（生产包裹用 `String(describing:)`——对 NSError 输出完整 domain/code/UserInfo 诊断转储）。
private struct StubEnumerationError: Error, CustomStringConvertible {
    var description: String { "stub 枚举失败" }
}

// MARK: - 过滤与排序（纯函数）

final class WindowPickerFilterTests: XCTestCase {
    /// 自身 App（浮条/倒计时/设置窗同 bundle id）不出现在候选里——简报钉死。
    func testSelfAppWindowsAreExcluded() {
        let windows = [
            makeWindow(id: 1, title: "浮条", bundleID: "com.screenrecorder.app"),
            makeWindow(id: 2, title: "倒计时", bundleID: "com.screenrecorder.app"),
            makeWindow(id: 3, title: "设置", bundleID: "com.screenrecorder.app"),
            makeWindow(id: 4, title: "起步页", appName: "Safari", bundleID: "com.apple.Safari"),
        ]
        let selectable = WindowPicker.selectableWindows(from: windows, excludingBundleID: "com.screenrecorder.app")
        XCTAssertEqual(selectable.map(\.windowID), [4], "自身 bundle id 的窗口全部剔除，他人窗口保留")
    }

    /// layer != 0 的系统内部面板（状态项/Dock/桌面壁纸层）不出现在候选里（本任务过滤裁定）。
    func testNonZeroLayerWindowsAreExcluded() {
        let windows = [
            makeWindow(id: 10, title: "状态项", layer: 25),
            makeWindow(id: 11, title: "Dock", layer: 20),
            makeWindow(id: 12, title: "桌面壁纸", layer: -2147483603),
            makeWindow(id: 13, title: "普通窗口", layer: 0),
        ]
        let selectable = WindowPicker.selectableWindows(from: windows, excludingBundleID: "com.screenrecorder.app")
        XCTAssertEqual(selectable.map(\.windowID), [13], "仅普通层（layer==0）窗口保留")
    }

    /// 零面积窗口不可录制，剔除；1×1 起算可录。
    func testZeroAreaWindowsAreExcluded() {
        let windows = [
            makeWindow(id: 20, frame: CGRect(x: 0, y: 0, width: 0, height: 600)),
            makeWindow(id: 21, frame: CGRect(x: 0, y: 0, width: 800, height: 0)),
            makeWindow(id: 22, frame: .zero),
            makeWindow(id: 23, frame: CGRect(x: 0, y: 0, width: 1, height: 1)),
        ]
        let selectable = WindowPicker.selectableWindows(from: windows, excludingBundleID: "com.screenrecorder.app")
        XCTAssertEqual(selectable.map(\.windowID), [23])
    }

    /// 覆盖度裁定：无标题的普通层窗口保留（简报「列表覆盖所有可见窗口」）。
    func testUntitledLayerZeroWindowsAreKept() {
        let windows = [
            makeWindow(id: 30, title: nil, appName: "无名应用"),
            makeWindow(id: 31, title: "", appName: "无名应用"),
        ]
        let selectable = WindowPicker.selectableWindows(from: windows, excludingBundleID: "com.screenrecorder.app")
        XCTAssertEqual(selectable.map(\.windowID), [30, 31], "无标题不剔除——系统噪声由 layer 过滤承担")
    }

    /// 排序确定性：App 名（大小写不敏感）→ 窗口名（大小写不敏感）→ windowID。
    func testSortingIsAppNameThenTitleThenWindowID() {
        let windows = [
            makeWindow(id: 40, title: "B", appName: "zeta"),
            makeWindow(id: 41, title: "a", appName: "Zeta"),
            makeWindow(id: 42, title: "x", appName: "Alpha"),
            makeWindow(id: 43, title: nil, appName: "zeta"),
            makeWindow(id: 44, title: "b", appName: "zeta"),
        ]
        let selectable = WindowPicker.selectableWindows(from: windows, excludingBundleID: "com.screenrecorder.app")
        // Alpha 组 42；zeta 组内 title ""(43) < "a"(41) < "B"=="b" 大小写等价 → windowID 40 < 44
        XCTAssertEqual(selectable.map(\.windowID), [42, 43, 41, 40, 44])
    }
}

// MARK: - 缩略图点尺寸（纯函数）

final class WindowPickerThumbnailPointSizeTests: XCTestCase {
    func testScaleDownTo128ptCapPreservingAspect() {
        XCTAssertEqual(
            WindowPicker.thumbnailPointSize(fitting: CGSize(width: 1920, height: 1080)),
            CGSize(width: 128, height: 72), "横版最长边封顶 128，等比缩")
        XCTAssertEqual(
            WindowPicker.thumbnailPointSize(fitting: CGSize(width: 800, height: 1200)),
            CGSize(width: 85, height: 128), "竖版最长边封顶 128，等比缩（800×128/1200=85.33→85）")
    }

    func testSmallWindowsAreNotUpscaledAndZeroSizeCollapses() {
        XCTAssertEqual(
            WindowPicker.thumbnailPointSize(fitting: CGSize(width: 100, height: 50)),
            CGSize(width: 100, height: 50), "小于上限不放大")
        XCTAssertEqual(WindowPicker.thumbnailPointSize(fitting: .zero), .zero)
        XCTAssertEqual(WindowPicker.thumbnailPointSize(fitting: CGSize(width: 0, height: 200)), .zero)
    }
}

// MARK: - availableWindows（错误语义 + 组装，全走注入缝；主 actor 入口同生产）

@MainActor
final class WindowPickerAvailableWindowsTests: XCTestCase {
    /// 权限未授予：单独 case，且短路与——绝不触发内容枚举。
    func testPermissionDeniedThrowsDedicatedCaseWithoutEnumeratingContent() async {
        var didEnumerate = false
        do {
            _ = try await WindowPicker.availableWindows(
                preflight: { false },
                loadWindows: {
                    didEnumerate = true
                    return []
                },
                loadThumbnails: { _ in [:] })
            XCTFail("权限未授予必须抛错")
        } catch {
            XCTAssertEqual(error as? WindowPickerError, .screenRecordingPermissionDenied, "权限类单独 case（可诊断）")
            XCTAssertFalse(didEnumerate, "权限短路：SCShareableContent 枚举不得发生")
        }
    }

    /// 枚举失败：包裹为 contentUnavailable，携带底层错误描述（重编译后 TCC 掉授权等场景可诊断）。
    func testEnumerationFailureIsWrappedWithUnderlyingDescription() async {
        do {
            _ = try await WindowPicker.availableWindows(
                preflight: { true },
                loadWindows: { throw StubEnumerationError() },
                loadThumbnails: { _ in [:] })
            XCTFail("枚举失败必须抛错")
        } catch {
            XCTAssertEqual(
                error as? WindowPickerError,
                .contentUnavailable(underlying: "stub 枚举失败"),
                "包裹底层描述，错误链不断")
        }
    }

    /// 错误文案本身可诊断（权限 case 提到授权；包裹 case 携带底层文本）。
    func testErrorMessagesAreDiagnosable() {
        let permissionMessage = WindowPickerError.screenRecordingPermissionDenied.errorDescription ?? ""
        XCTAssertTrue(permissionMessage.contains("屏幕录制权限"), "权限文案点明根因：\(permissionMessage)")
        let wrappedMessage = WindowPickerError.contentUnavailable(underlying: "XYZ").errorDescription ?? ""
        XCTAssertTrue(wrappedMessage.contains("XYZ"), "包裹文案携带底层描述：\(wrappedMessage)")
    }

    /// 组装：过滤后的窗口才进缩略图请求（排序序、封顶点尺寸），候选回填字段与缩略图；
    /// 无标题回退空串（占位文案归视图层）。
    func testCandidatesAreAssembledFromFilteredWindowsWithThumbnailRequests() async throws {
        let windows = [
            makeWindow(id: 50, title: "浮条", bundleID: "com.screenrecorder.app"),
            makeWindow(id: 51, title: "系统面板", layer: 25),
            makeWindow(id: 52, frame: .zero),
            makeWindow(id: 53, title: "文档", appName: "Pages",
                       frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
            makeWindow(id: 54, title: nil, appName: "Terminal",
                       frame: CGRect(x: 0, y: 0, width: 100, height: 50)),
        ]
        var requests: [ThumbnailRequest] = []
        let thumbnailStub = NSImage(size: NSSize(width: 8, height: 8))
        let candidates = try await WindowPicker.availableWindows(
            preflight: { true },
            loadWindows: { windows },
            loadThumbnails: { incoming in
                requests = incoming
                return [53: thumbnailStub]
            })
        XCTAssertEqual(requests.map(\.windowID), [53, 54], "缩略图只为保留窗口请求（排序后）")
        XCTAssertEqual(requests, [
            ThumbnailRequest(windowID: 53, pointSize: CGSize(width: 128, height: 72)),
            ThumbnailRequest(windowID: 54, pointSize: CGSize(width: 100, height: 50)),
        ], "请求携带 128pt 封顶后的展示点尺寸")
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].id, 53)
        XCTAssertEqual(candidates[0].title, "文档")
        XCTAssertEqual(candidates[0].appName, "Pages")
        XCTAssertTrue(candidates[0].thumbnail === thumbnailStub, "缩略图按 windowID 回填")
        XCTAssertEqual(candidates[1].id, 54)
        XCTAssertEqual(candidates[1].title, "", "无标题回退空串，不编造文案")
        XCTAssertEqual(candidates[1].appName, "Terminal")
        XCTAssertNil(candidates[1].thumbnail, "映射缺失的缩略图保持 nil（视图出占位图）")
    }
}

// MARK: - App 范围（P3a：enumeratedApps 注入缝 + App 模式 filter 构造入参收集）

/// App 范围枚举（P3a）：注入缝沿用 `enumeratedWindows` 的缝形状（preflight/loadWindows
/// 可注入），分组/排序全在纯函数上，无头可测。
@MainActor
final class WindowPickerEnumeratedAppsTests: XCTestCase {
    /// 注入缝 fixture（简报钉死：3 App 5 窗口）→ 按 bundle 分组计数正确、排除自身
    ///（本 App bundle 的窗口不进候选）。
    func testEnumeratedAppsGroupsWindowsByBundleID() async throws {
        let windows = [
            makeWindow(id: 1, title: "文档", appName: "Alpha", bundleID: "com.alpha.app"),
            makeWindow(id: 2, title: "表格", appName: "Alpha", bundleID: "com.alpha.app"),
            makeWindow(id: 3, title: "终端", appName: "Beta", bundleID: "com.beta.app"),
            makeWindow(id: 4, title: "编辑器", appName: "Beta", bundleID: "com.beta.app"),
            makeWindow(id: 5, title: "浮条", appName: "ScreenRecorder", bundleID: "com.screenrecorder.app"),
        ]
        let apps = try await WindowPicker.enumeratedApps(
            preflight: { true },
            loadWindows: { windows })
        XCTAssertEqual(apps, [
            AppCandidate(bundleID: "com.alpha.app", appName: "Alpha", windowCount: 2),
            AppCandidate(bundleID: "com.beta.app", appName: "Beta", windowCount: 2),
        ], "3 App 5 窗口：按 bundle 分组计数正确，自身 App 不进候选")
    }

    /// App 模式 filter 构造（裁定：SCContentFilter 需 SCK 授权对象，无头不可构造——钉
    /// 构造入参收集函数）：收集该 bundle 的全部普通层非零面积窗口（即
    /// `SCContentFilter(desktopIndependentWindows:)` 的入参），别家/非零层/零面积不入画。
    func testAppModeFilterConstruction() {
        let windows = [
            makeWindow(id: 10, title: "主窗", appName: "Alpha", bundleID: "com.alpha.app"),
            makeWindow(id: 11, title: "副窗", appName: "Alpha", bundleID: "com.alpha.app"),
            makeWindow(id: 12, title: "别家窗口", appName: "Beta", bundleID: "com.beta.app"),
            makeWindow(id: 13, title: "系统面板", appName: "Alpha", bundleID: "com.alpha.app", layer: 25),
            makeWindow(id: 14, title: "零面积", appName: "Alpha", bundleID: "com.alpha.app", frame: .zero),
        ]
        let collected = WindowPicker.appWindows(ofBundleID: "com.alpha.app", from: windows)
        XCTAssertEqual(collected.map(\.windowID), [10, 11],
                       "filter 入参 = 该 App 的全部可录窗口（与选择器同一可见口径、确定性排序）")
    }
}
