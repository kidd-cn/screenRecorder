import AppKit
import XCTest

@testable import ScreenRecorder

// MARK: - 测试夹具

/// 收集 finish 回调（「恰一次 resume」断言用）。
private final class RecordingFinishBox {
    var results: [CGRect?] = []

    /// 恰一次断言通过后的唯一结果（count != 1 时返回 nil，不炸下标；
    /// 也避免 `results.first`（CGRect??）装盒进 Any? 破坏 XCTAssertNil/XCTAssertEqual 语义）。
    var soleResult: CGRect? { results.count == 1 ? results[0] : nil }
}

/// 不真正上屏的记录窗口：orderFrontRegardless/orderOut 只计数（与 CountdownOverlayControllerTests
/// 的 SpyOverlayWindow 同款纪律，测试期不打扰用户桌面）；borderless 下 contentRect == frame，
/// 即 frame.origin == 目标屏 frame.origin（坐标换算测试的输入前提）。
private final class SpyRegionWindow: NSWindow {
    var orderFrontCount = 0
    var orderOutCount = 0

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless], backing: .buffered, defer: false)
    }

    override func orderFrontRegardless() { orderFrontCount += 1 }
    override func orderOut(_ sender: Any?) { orderOutCount += 1 }
}

// MARK: - 坐标换算 / clamp 纯函数（T13 钉死重点：Y 翻转、多屏偏移、边界 clamp）

/// 坐标系夹具推导（两套全局系描述同一台显示器）：
/// - 主屏：Cocoa frame (0,0,1440,900) ↔ CGDisplayBounds 原点 (0,0)。
/// - 副屏（主屏右侧、底边低于主屏）：Cocoa frame (1440,200,1920,1080) ↔
///   CGDisplayBounds 原点 (primaryH - frame.maxY, 即 900 - 1280 = -380) → (1440,-380)。
final class RegionSelectorMathTests: XCTestCase {
    private let primaryFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let secondaryFrame = CGRect(x: 1440, y: 200, width: 1920, height: 1080)
    private let secondaryCGOrigin = CGPoint(x: 1440, y: -380)

    // MARK: Cocoa 全局（左下原点）→ CG 显示器全局（左上原点）

    func testCGRectOnPrimaryDisplayFlipsYKeepsXAndSize() {
        let cg = RegionSelectorMath.cgRect(
            fromCocoaRect: CGRect(x: 100, y: 200, width: 300, height: 400),
            screenFrame: primaryFrame,
            cgDisplayOrigin: .zero)
        // cocoa 顶边 y=600 → 距屏顶 900-600=300
        XCTAssertEqual(cg, CGRect(x: 100, y: 300, width: 300, height: 400), "y 应按「距屏顶距离」翻转，x 与尺寸不动")
    }

    func testCGRectOnSecondaryDisplayAppliesMultiScreenOffset() {
        let cg = RegionSelectorMath.cgRect(
            fromCocoaRect: CGRect(x: 2000, y: 400, width: 300, height: 200),
            screenFrame: secondaryFrame,
            cgDisplayOrigin: secondaryCGOrigin)
        // x：1440 + (2000-1440) = 2000；y：-380 + (1280-600) = 300
        XCTAssertEqual(cg, CGRect(x: 2000, y: 300, width: 300, height: 200),
                       "该屏 frame.origin 非零时结果须落在 CG 全局系（含偏移），不得丢失副屏偏移")
    }

    func testCGRectOfFullScreenCocoaFrameEqualsDisplayBounds() {
        let cg = RegionSelectorMath.cgRect(
            fromCocoaRect: secondaryFrame,
            screenFrame: secondaryFrame,
            cgDisplayOrigin: secondaryCGOrigin)
        XCTAssertEqual(cg, CGRect(x: 1440, y: -380, width: 1920, height: 1080),
                       "整屏 frame 换算恒等还原 CGDisplayBounds（换算式的自洽性锚点）")
    }

    // MARK: 窗口基坐标 → Cocoa 全局

    func testCocoaRectFromWindowRectTranslatesByWindowOrigin() {
        let cocoa = RegionSelectorMath.cocoaRect(
            fromWindowRect: CGRect(x: 10, y: 20, width: 30, height: 40),
            windowOrigin: CGPoint(x: 1440, y: 200))
        XCTAssertEqual(cocoa, CGRect(x: 1450, y: 220, width: 30, height: 40))
    }

    // MARK: 拖拽归一化（任意方向起拖）

    func testNormalizedRectSupportsEveryDragDirection() {
        XCTAssertEqual(
            RegionSelectorMath.normalizedRect(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 210)),
            CGRect(x: 10, y: 10, width: 100, height: 200), "右下拖")
        XCTAssertEqual(
            RegionSelectorMath.normalizedRect(from: CGPoint(x: 110, y: 210), to: CGPoint(x: 10, y: 10)),
            CGRect(x: 10, y: 10, width: 100, height: 200), "反方向拖同框")
        XCTAssertEqual(
            RegionSelectorMath.normalizedRect(from: CGPoint(x: 500, y: 500), to: CGPoint(x: 300, y: 200)),
            CGRect(x: 300, y: 200, width: 200, height: 300), "左上拖")
    }

    // MARK: clamp（拖出屏边界钉回该屏 frame 内）

    func testPointClampKeepsInsideAndPullsBackOutside() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertEqual(RegionSelectorMath.clamped(point: CGPoint(x: 5, y: 7), to: bounds), CGPoint(x: 5, y: 7), "屏内不动")
        XCTAssertEqual(RegionSelectorMath.clamped(point: CGPoint(x: -3, y: 9999), to: bounds), CGPoint(x: 0, y: 600), "越界钉回边角")
        XCTAssertEqual(RegionSelectorMath.clamped(point: CGPoint(x: 810, y: -1), to: bounds), CGPoint(x: 800, y: 0))
        XCTAssertEqual(RegionSelectorMath.clamped(point: CGPoint(x: 800, y: 600), to: bounds), CGPoint(x: 800, y: 600), "边界值恰在框上")
    }

    func testRectClampIntersectsBoundsAndYieldsEmptyWhenFullyOutside() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertEqual(
            RegionSelectorMath.clamped(rect: CGRect(x: 700, y: 500, width: 200, height: 200), to: bounds),
            CGRect(x: 700, y: 500, width: 100, height: 100), "部分越界裁到屏内")
        XCTAssertTrue(
            RegionSelectorMath.clamped(rect: CGRect(x: 1000, y: 700, width: 50, height: 50), to: bounds).isNull,
            "完全在外的矩形剪成空")
        XCTAssertEqual(
            RegionSelectorMath.clamped(rect: CGRect(x: 10, y: 10, width: 50, height: 50), to: bounds),
            CGRect(x: 10, y: 10, width: 50, height: 50), "屏内不动")
    }

    // MARK: 点击无拖动判定 / 尺寸标签

    func testMeaningfulSelectionRejectsClickAndSubPointDrags() {
        XCTAssertFalse(RegionSelectorMath.isMeaningfulSelection(.zero), "点击无拖动 = 取消")
        XCTAssertFalse(RegionSelectorMath.isMeaningfulSelection(CGRect(x: 10, y: 10, width: 0.5, height: 100)), "亚点宽不算拖动")
        XCTAssertFalse(RegionSelectorMath.isMeaningfulSelection(CGRect(x: 10, y: 10, width: 100, height: 0.5)))
        XCTAssertTrue(RegionSelectorMath.isMeaningfulSelection(CGRect(x: 10, y: 10, width: 1, height: 1)), "1×1 pt 起算有效选区")
    }

    func testSizeLabelRendersIntegerWxHInPoints() {
        XCTAssertEqual(RegionSelectorMath.sizeLabel(width: 1920, height: 1080), "1920×1080")
        XCTAssertEqual(RegionSelectorMath.sizeLabel(width: 100.4, height: 59.6), "100×60", "四舍五入到整数点")
    }
}

// MARK: - 选区会话（拖拽生命周期 + 三条出口收敛到唯一 finish）

@MainActor
final class RegionSelectionSessionTests: XCTestCase {
    // 坐标系夹具与 RegionSelectorMathTests 同一套推导（主屏原点零、副屏带偏移）
    private let primaryFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let secondaryFrame = CGRect(x: 1440, y: 200, width: 1920, height: 1080)
    private let secondaryCGOrigin = CGPoint(x: 1440, y: -380)

    private var window: SpyRegionWindow!
    private var box: RecordingFinishBox!

    private func makeSession(screenFrame: CGRect, cgOrigin: CGPoint) -> RegionSelectionSession {
        window = SpyRegionWindow(contentRect: screenFrame)
        box = RecordingFinishBox()
        return RegionSelectionSession(
            screenFrame: screenFrame,
            cgDisplayOrigin: cgOrigin,
            onFinish: { [box] in box.results.append($0) },
            windowFactory: { [window] _ in window }
        )
    }

    /// 轮询等待（主 actor Task.yield 让 willClose 观察者的 Task 跳转落地）。
    private func waitFor(
        _ condition: @escaping () -> Bool,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition(), "等待条件超时", file: file, line: line)
    }

    func testBeginOrdersFrontAndDragFinalizesWithClampedConvertedRectExactlyOnce() {
        let session = makeSession(screenFrame: secondaryFrame, cgOrigin: secondaryCGOrigin)
        session.begin()
        session.begin() // 二次 begin 是 no-op（monitor/光标/orderFront 不重复装）
        XCTAssertEqual(window.orderFrontCount, 1)

        session.dragBegan(at: CGPoint(x: 0, y: 0))
        session.dragMoved(to: CGPoint(x: 4000, y: 300)) // 拖出右边界 → clamp 到 (1920,300)
        XCTAssertEqual(session.overlayView.selectionRect, CGRect(x: 0, y: 0, width: 1920, height: 300),
                       "拖动中亮框实时更新且被 clamp 在该屏内")

        session.dragEnded(at: CGPoint(x: 2000, y: 700)) // 松开点无关紧要，clamp 后 (1920,700)
        XCTAssertEqual(box.results.count, 1, "拖拽完成：恰一次 finish")
        XCTAssertEqual(box.soleResult, CGRect(x: 1440, y: 0, width: 1920, height: 700),
                       "窗口基 rect → Cocoa 全局 (1440,200,1920,700) → CG 全局 (1440,0,1920,700)")
        XCTAssertTrue(session.isFinished)
        XCTAssertEqual(window.orderOutCount, 1)

        session.performCancel() // 迟到的出口必须 no-op（防重入闩）
        XCTAssertEqual(box.results.count, 1)
        XCTAssertEqual(window.orderOutCount, 1)
    }

    func testClickWithoutDragIsTreatedAsCancelReturningNil() {
        let session = makeSession(screenFrame: primaryFrame, cgOrigin: .zero)
        session.begin()

        session.dragBegan(at: CGPoint(x: 100, y: 100))
        session.dragEnded(at: CGPoint(x: 100, y: 100)) // 起点==松开：无拖动

        XCTAssertEqual(box.results.count, 1)
        XCTAssertNil(box.soleResult, "点击无拖动按取消处理（本任务裁定），返回 nil 不产零面积 rect")
        session.performCancel()
        XCTAssertEqual(box.results.count, 1)
    }

    func testEscCancelThenLateDragConvergeToSingleNilFinish() {
        let session = makeSession(screenFrame: primaryFrame, cgOrigin: .zero)
        session.begin()

        session.dragBegan(at: CGPoint(x: 10, y: 10))
        session.dragMoved(to: CGPoint(x: 200, y: 200))
        session.performCancel() // ESC 路径

        XCTAssertEqual(box.results.count, 1)
        XCTAssertNil(box.soleResult)

        session.dragMoved(to: CGPoint(x: 300, y: 300)) // 迟到的拖动 no-op
        session.dragEnded(at: CGPoint(x: 400, y: 400)) // 迟到的松开 no-op
        XCTAssertEqual(box.results.count, 1)
        XCTAssertEqual(session.overlayView.selectionRect, CGRect(x: 10, y: 10, width: 190, height: 190),
                       "取消后不再更新选区显示")
        XCTAssertEqual(window.orderOutCount, 1)
    }

    func testDoubleCancelFinishesExactlyOnce() {
        let session = makeSession(screenFrame: primaryFrame, cgOrigin: .zero)
        session.begin()

        session.performCancel()
        session.performCancel()

        XCTAssertEqual(box.results.count, 1, "重复 ESC：finish 只走一次")
        XCTAssertEqual(window.orderOutCount, 1)
    }

    func testWindowWillCloseNotificationConvergesToSingleNilFinish() async {
        let session = makeSession(screenFrame: primaryFrame, cgOrigin: .zero)
        session.begin()

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        await waitFor { self.box.results.count == 1 }

        XCTAssertNil(box.soleResult, "窗口被外部关闭 → nil")
        session.performCancel()
        XCTAssertEqual(box.results.count, 1, "外部关闭后再取消：仍恰一次")
        XCTAssertEqual(window.orderOutCount, 1)
    }

    func testScreenLookupMatchesScreenNumberInDeviceDescription() {
        XCTAssertNotNil(RegionSelector.screen(for: CGMainDisplayID()),
                        "deviceDescription[NSScreenNumber] 应能按 displayID 找回目标屏")
        XCTAssertNil(RegionSelector.screen(for: CGDirectDisplayID(0xDEAD_BEEF)), "无效 displayID 找不到屏")
    }
}

// MARK: - 窗口区域选择（P3b：窗口锚定拖框，输出窗口相对 rect）

/// 窗口区域会话夹具推导：目标窗口 Cocoa 全局 frame (200,150,800,500)（主屏内）。
/// 输出契约 = **窗口相对系**：原点在窗口 frame 左上、points、y 向下——`CaptureMode.windowRegion`
/// 的 rect，即 `SCContentFilter(desktopIndependentWindow:)` + `sourceRect` 的裁剪口径。
@MainActor
final class WindowRegionSelectionTests: XCTestCase {
    private let windowFrame = CGRect(x: 200, y: 150, width: 800, height: 500)

    private var window: SpyRegionWindow!
    private var box: RecordingFinishBox!

    private func makeSession() -> WindowRegionSelectionSession {
        window = SpyRegionWindow(contentRect: windowFrame)
        box = RecordingFinishBox()
        return WindowRegionSelectionSession(
            anchorFrame: windowFrame,
            onFinish: { [box] in box.results.append($0) },
            windowFactory: { [window] _ in window }
        )
    }

    /// 简报 Step 1 钉测：屏幕点 → 窗口相对 rect。视图（窗口基、y 向上）(100,100)→(300,250)
    /// 的拖拽，输出原点须落在窗口左上系 (100, 250)——y 按「距窗口顶边距离」翻转
    ///（视图顶边 100+150=250 → 窗口高 500 − 250 = 250），不经显示器全局系。
    func testWindowAnchoredRectIsWindowRelative() {
        let session = makeSession()
        session.begin()

        session.dragBegan(at: CGPoint(x: 100, y: 100))
        session.dragEnded(at: CGPoint(x: 300, y: 250))

        XCTAssertEqual(box.results.count, 1, "拖拽完成：恰一次 finish")
        XCTAssertEqual(box.soleResult, CGRect(x: 100, y: 250, width: 200, height: 150),
                       "视图 rect → Cocoa 全局 (300,250,200,150) → 窗口相对 (100,250,200,150)（左上原点、y 向下）")
    }

    /// 简报 Step 1 钉测：拖出窗口边界 → 拖拽全程钉回窗口内，输出恒落在窗口 bounds 内。
    func testRectClampedToWindowBounds() {
        let session = makeSession()
        session.begin()

        session.dragBegan(at: CGPoint(x: 600, y: 100))
        session.dragMoved(to: CGPoint(x: 1500, y: -50)) // 拖出右/上边界 → 钉回 (800, 0)
        XCTAssertEqual(session.overlayView.selectionRect, CGRect(x: 600, y: 0, width: 200, height: 100),
                       "拖动中亮框实时钳制在窗口 bounds 内")
        session.dragEnded(at: CGPoint(x: 1500, y: -50))

        XCTAssertEqual(box.results.count, 1)
        XCTAssertEqual(box.soleResult, CGRect(x: 600, y: 400, width: 200, height: 100),
                       "窗口相对 rect 仍在窗口 bounds 内（钳制后收尾，不再二次越界）")
        if let rect = box.soleResult {
            XCTAssertTrue(CGRect(origin: .zero, size: windowFrame.size).contains(rect),
                          "窗口相对 rect 必须完全落在窗口 bounds（原点左上、尺寸同窗口）内")
        }
    }

    /// 简报 Step 1 钉测：亚点尺寸拖动沿用一期区域模式最小尺寸语义（宽或高 <1pt = 误触）
    /// → 按取消处理，不产零面积 rect。
    func testDragSmallerThanMinimumIgnored() {
        let session = makeSession()
        session.begin()

        session.dragBegan(at: CGPoint(x: 100, y: 100))
        session.dragMoved(to: CGPoint(x: 100.5, y: 200)) // 宽 0.5pt < 1pt
        session.dragEnded(at: CGPoint(x: 100.5, y: 200))

        XCTAssertEqual(box.results.count, 1)
        XCTAssertNil(box.soleResult, "亚点拖动按取消处理（一期区域模式同语义）")
        session.performCancel()
        XCTAssertEqual(box.results.count, 1, "取消后再取消：恰一次闩不重入")
    }

    /// 装配层锚定遮罩用的换算：SCWindow.frame（CG 全局、左上原点）→ 遮罩 NSWindow 的
    /// Cocoa 全局 frame（主屏左下原点）——x 与尺寸不动，y 按主屏高翻转（rect 版逆变换）。
    func testCocoaRectFromCGRectFlipsYByPrimaryHeight() {
        XCTAssertEqual(
            RegionSelectorMath.cocoaRect(fromCGRect: CGRect(x: 200, y: 300, width: 800, height: 500),
                                         primaryScreenHeight: 900),
            CGRect(x: 200, y: 100, width: 800, height: 500),
            "CG 顶边 y=300 → Cocoa 顶边 y = 900−300 = 600，即 frame.minY = 100（尺寸与 x 不动）")
    }
}
