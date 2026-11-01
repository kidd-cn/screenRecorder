import AppKit
import CoreGraphics
import XCTest

@testable import ScreenRecorder

// MARK: - 测试夹具（与 CountdownOverlayControllerTests 同款：注入 provider + 记录面板）

/// provider 取数盒：喂控制器 init 钉定缝（mode/state/enabled/geometry 读缝）；显隐驱动
/// 走 `refreshVisibility(enabled:state:)` 发射值直传（修复轮2），盒值仅在拉取式缝断言段同步。
@MainActor
private final class VisibilityStateBox {
    var mode: CaptureMode? = .display(1)
    var state: CaptureState = .idle
    var markingEnabled = false
    var geometry: PiPCaptureGeometry?
}

/// 不真正上屏的记录面板：orderFrontRegardless/orderOut 只计数（测试期不打扰用户桌面）。
private final class SpyMarkingPanel: NSPanel {
    var orderFrontCount = 0
    var orderOutCount = 0

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
    }

    override func orderFrontRegardless() { orderFrontCount += 1 }
    override func orderOut(_ sender: Any?) { orderOutCount += 1 }
}

// MARK: - 标记覆盖层（Task 5）无头钉测：坐标换算 + 显隐逻辑

@MainActor
final class MarkingOverlayControllerTests: XCTestCase {
    private static let accuracy: CGFloat = 1e-9

    // MARK: 坐标换算（testScreenPointToNormalizedMapping，简报 Step 1 逐字）

    /// 显示器模式夹具：主屏 1512×982 点 2x Retina（3024×1964 捕获像素），CG 原点 (0,0)；
    /// 主屏 Cocoa 高度 900（Y 翻转入口注入，与 ClickHighlightTracker 测试同推导）。
    private let displayGeometry = PiPCaptureGeometry(
        captureOriginInCGPoints: CGPoint(x: 0, y: 0),
        scale: 2,
        capturePixelSize: CGSize(width: 3024, height: 1964))
    private let flipHeight: CGFloat = 900

    /// 区域模式夹具：采集 rect 原点 (500,300)、尺寸 800×600（1x 采样，T7 台账口径）。
    private let regionGeometry = PiPCaptureGeometry(
        captureOriginInCGPoints: CGPoint(x: 500, y: 300),
        scale: 1,
        capturePixelSize: CGSize(width: 800, height: 600))

    /// 全屏与区域两种 mode 的换算 + 越界丢弃。管线与 feedZoomClick 同源（Cocoa 全局 →
    /// CG 全局 → 捕获像素），最后经 viewport 归一化（CI 画布 y 向上口径）+ Task 4 逆映射
    ///（identity = 直通）落底帧归一化（y 向下 0…1）。越出采集 rect（归一化越出 0…1）
    /// 返回 nil——上游过滤，配合画布 closed-0…1 规则双保险。
    func testScreenPointToNormalizedMapping() throws {
        // 全屏：cocoa (100,200) → CG (100,700) → 捕获像素 (200,1400) → CI (200,564)
        // → identity 逆映射直通 → 归一化 (200/3024, 1 − 564/1964)（y 翻转回落 y 向下口径）。
        let full = try XCTUnwrap(MarkingOverlayController.normalizedStrokePoint(
            fromCocoaGlobalPoint: CGPoint(x: 100, y: 200),
            geometry: displayGeometry,
            flipHeight: flipHeight,
            zoomTransform: .identity))
        XCTAssertEqual(full.x, 200 / 3024, accuracy: Self.accuracy, "全屏 x：捕获像素 ÷ 画布宽")
        XCTAssertEqual(full.y, 1 - 564 / 1964, accuracy: Self.accuracy, "全屏 y：CI 翻转后归一化，(0,0) 为底帧左上")

        // 区域：cocoa (600,400) → CG (600,500) → 捕获像素 (100,200)（先减采集区原点）
        // → CI (100,400) → 归一化 (0.125, 1/3)。
        let region = try XCTUnwrap(MarkingOverlayController.normalizedStrokePoint(
            fromCocoaGlobalPoint: CGPoint(x: 600, y: 400),
            geometry: regionGeometry,
            flipHeight: flipHeight,
            zoomTransform: .identity))
        XCTAssertEqual(region.x, 100 / 800, accuracy: Self.accuracy, "区域 x：相对采集 rect 原点后归一化")
        XCTAssertEqual(region.y, 1 - 400 / 600, accuracy: Self.accuracy, "区域 y 同一翻转口径")

        // 越界丢弃（区域右外侧）：cocoa (2000,50) → 捕获像素 (1500,550) → x=1.875 越出 0…1 → nil。
        XCTAssertNil(MarkingOverlayController.normalizedStrokePoint(
            fromCocoaGlobalPoint: CGPoint(x: 2000, y: 50),
            geometry: regionGeometry,
            flipHeight: flipHeight,
            zoomTransform: .identity), "越出采集 rect 右侧的点必须丢弃")

        // 越界丢弃（顶外侧、Y 翻转入负）：cocoa (450,999) → CG y=−99 → 捕获像素 y=−399 → nil。
        XCTAssertNil(MarkingOverlayController.normalizedStrokePoint(
            fromCocoaGlobalPoint: CGPoint(x: 450, y: 999),
            geometry: regionGeometry,
            flipHeight: flipHeight,
            zoomTransform: .identity), "越出采集 rect 上侧（翻转后为负）的点必须丢弃")

        // 闭区间边界：恰在采集 rect 右缘 → 归一化 x = 1.0 属 0…1 闭区间，保留（与画布规则一致）。
        let edge = try XCTUnwrap(MarkingOverlayController.normalizedStrokePoint(
            fromCocoaGlobalPoint: CGPoint(x: 1300, y: 400),
            geometry: regionGeometry,
            flipHeight: flipHeight,
            zoomTransform: .identity))
        XCTAssertEqual(edge.x, 1.0, accuracy: Self.accuracy, "右缘点 x=1.0 属闭区间，不丢弃")

        // 逆映射步（缝契约）：换算在 CI 画布空间施加 zoomTransform 的逆（Task 4 baseFramePoint）。
        // 生产恒传 identity（绘制面呈现底帧内容，缩放只存在于成片合成侧）；本钉测以真实变换
        // 验证缝的数学：存储点经同一变换回投应落回原绘制点（viewport→base→viewport 往返）。
        let canvasBounds = CGRect(origin: .zero, size: regionGeometry.capturePixelSize)
        let transform = try XCTUnwrap(ZoomTransforms.contentTransform(
            center: CGPoint(x: 0.5, y: 0.5), level: 1.6, progress: 1, in: canvasBounds))
        let zoomed = try XCTUnwrap(MarkingOverlayController.normalizedStrokePoint(
            fromCocoaGlobalPoint: CGPoint(x: 600, y: 400),
            geometry: regionGeometry,
            flipHeight: flipHeight,
            zoomTransform: transform))
        let drawnCI = CGPoint(x: 100, y: 600 - 200) // 原绘制点在 CI 画布空间（y 向上）的读数
        let storedCI = CGPoint(x: zoomed.x * 800, y: (1 - zoomed.y) * 600)
        let roundTripped = storedCI.applying(transform)
        XCTAssertEqual(roundTripped.x, drawnCI.x, accuracy: 1e-6, "存储点经缩放回投应落回原绘制点（逆映射步生效）")
        XCTAssertEqual(roundTripped.y, drawnCI.y, accuracy: 1e-6, "存储点经缩放回投应落回原绘制点（逆映射步生效）")
    }

    // MARK: 显隐逻辑（testPanelVisibilityFollowsState，简报 Step 1 逐字——发射值直传驱动）

    /// 判定真源：markingEnabled && (state == .recording || .paused)。recording 与 paused
    /// 同样可见（暂停中可继续画，spec §5 P2）；其余状态（idle/countdown/finishing）与
    /// 开关关闭一律不可见。面板复用：一场显隐周期只建一次。驱动走修复轮2 的**参数化
    /// 签名** `refreshVisibility(enabled:state:)`（装配层 CombineLatest 发射值直传）——
    /// 装配层真实 willSet 时序无 headless 位，此处以「provider 滞后旧值 + 参数新值」段
    /// 钉死判定必须取参数不回拉（Critical 1 的判别面）。
    func testPanelVisibilityFollowsState() {
        let box = VisibilityStateBox()
        let spy = SpyMarkingPanel()
        var factoryCalls = 0
        let controller = MarkingOverlayController(
            canvas: MarkingCanvas(),
            modeProvider: { box.mode },
            stateProvider: { box.state },
            markingEnabledProvider: { box.markingEnabled },
            geometryProvider: { box.geometry },
            panelFactory: {
                factoryCalls += 1
                return spy
            })

        // 初始 idle + 关：不显示。
        controller.refreshVisibility(enabled: false, state: .idle)
        XCTAssertEqual(spy.orderFrontCount, 0, "初始 idle 且开关关闭不得显示覆盖层")
        XCTAssertFalse(controller.isShowingOverlays)

        // 录制中但开关关：不显示（开关是必要条件）。
        controller.refreshVisibility(enabled: false, state: .recording)
        XCTAssertEqual(spy.orderFrontCount, 0, "录制中但标记开关关闭不得显示覆盖层")
        XCTAssertFalse(MarkingOverlayController.isVisible(enabled: false, state: .recording),
                       "判定：录制 + 开关关 = 隐藏")

        // 开关开：显示。
        controller.refreshVisibility(enabled: true, state: .recording)
        XCTAssertEqual(spy.orderFrontCount, 1, "录制 + 开关开 = 显示")
        XCTAssertTrue(controller.isShowingOverlays)
        XCTAssertTrue(MarkingOverlayController.isVisible(enabled: true, state: .recording),
                      "判定：录制 + 开关开 = 显示")

        // Critical 1 判别面：sink 在 @Published willSet 阶段同步执行，此刻 provider 回拉
        // 是旧值——参数化签名必须采用**发射值**（enabled: true）而非回拉（box.markingEnabled
        // 仍 false 模拟 willSet 实况），覆盖层才会在「录制中开标记」时如期出现。
        controller.refreshVisibility(enabled: true, state: .recording)
        XCTAssertEqual(spy.orderFrontCount, 1, "provider 滞后时参数值仍驱动显示（幂等不重复前置）")
        XCTAssertTrue(controller.isShowingOverlays, "判定取发射值，不回拉滞后 provider")

        // 暂停：保持可见且不重复 orderFront（暂停中可继续画）。
        controller.refreshVisibility(enabled: true, state: .paused)
        XCTAssertEqual(spy.orderFrontCount, 1, "暂停态保持可见，不得重复前置面板")
        XCTAssertTrue(MarkingOverlayController.isVisible(enabled: true, state: .paused),
                      "判定：暂停 + 开关开 = 显示（spec §5 P2）")

        // 收尾：隐藏。
        controller.refreshVisibility(enabled: true, state: .finishing)
        XCTAssertEqual(spy.orderOutCount, 1, "离开录制/暂停即收起")
        XCTAssertFalse(controller.isShowingOverlays)
        XCTAssertFalse(MarkingOverlayController.isVisible(enabled: true, state: .finishing),
                       "判定：收尾 = 隐藏")

        // 再次录制：重新显示（复用同一面板）。
        controller.refreshVisibility(enabled: true, state: .recording)
        XCTAssertEqual(spy.orderFrontCount, 2, "下一场录制重新显示")
        XCTAssertTrue(controller.isShowingOverlays)

        // 录制中关闭开关：隐藏（发射值 false 直传；同段滞后判别：provider 仍 true 不得回拉）。
        controller.refreshVisibility(enabled: false, state: .recording)
        XCTAssertEqual(spy.orderOutCount, 2, "录制中关闭标记开关即收起")
        XCTAssertFalse(controller.isShowingOverlays, "关闭判定取发射值，不回拉滞后 provider")

        // 面板复用：整个显隐周期工厂只调一次。
        XCTAssertEqual(factoryCalls, 1, "面板懒建且复用，不随显隐周期重建")

        // 判定边界（纯函数）：开关开但倒计时/收尾/idle = 隐藏；开关关 + 录制 = 隐藏。
        XCTAssertFalse(MarkingOverlayController.isVisible(enabled: true, state: .countdown(secondsLeft: 3)),
                       "判定：倒计时 = 隐藏")
        XCTAssertFalse(MarkingOverlayController.isVisible(enabled: true, state: .finishing),
                       "判定：收尾 = 隐藏")
        XCTAssertFalse(MarkingOverlayController.isVisible(enabled: true, state: .idle),
                       "判定：idle = 隐藏")
        XCTAssertFalse(MarkingOverlayController.isVisible(enabled: false, state: .paused),
                       "判定：开关关 = 隐藏（暂停也不可见）")

        // 拉取式缝（provider 读路径）语义一致：真源同步后 shouldShowOverlays 同判。
        box.state = .recording
        box.markingEnabled = true
        XCTAssertTrue(controller.shouldShowOverlays(), "拉取式缝与纯函数同一判定真源")
        box.markingEnabled = false
        XCTAssertFalse(controller.shouldShowOverlays(), "拉取式缝与纯函数同一判定真源")
    }

    // MARK: 实时墨迹（验收 P2 后增强：归一化↔视图坐标互逆 + 绘制/刷新装配）

    /// 归一化（y 向下 0…1）→ 覆盖层视图坐标（Cocoa 左下原点）翻转缝：角点/中心/任意点
    /// 与原点无关边界（多屏负坐标 bounds）。与合成器位图翻转同口径，且与
    /// `normalizedStrokePoint` 的归一化互逆——单位方形上往返恒等。
    func testOverlayViewPointMapping() {
        let bounds = CGRect(x: 0, y: 0, width: 1512, height: 982)
        // 角点：左上 (0,1) 归一化 → 视图左下 (0,0)；右下 (1,0) → 右上 (1512,982)。
        let topLeft = MarkingOverlayController.overlayViewPoint(fromNormalized: CGPoint(x: 0, y: 1), in: bounds)
        XCTAssertEqual(topLeft.x, 0, accuracy: Self.accuracy, "归一化 y=1（底帧下缘）= 视图 y=0（下缘）")
        XCTAssertEqual(topLeft.y, 0, accuracy: Self.accuracy)
        let bottomRight = MarkingOverlayController.overlayViewPoint(fromNormalized: CGPoint(x: 1, y: 0), in: bounds)
        XCTAssertEqual(bottomRight.x, 1512, accuracy: Self.accuracy, "归一化 x=1 = 视图右缘")
        XCTAssertEqual(bottomRight.y, 982, accuracy: Self.accuracy, "归一化 y=0（底帧上缘）= 视图上缘")
        // 中心。
        let center = MarkingOverlayController.overlayViewPoint(fromNormalized: CGPoint(x: 0.5, y: 0.5), in: bounds)
        XCTAssertEqual(center.x, 756, accuracy: Self.accuracy)
        XCTAssertEqual(center.y, 491, accuracy: Self.accuracy)
        // 原点无关（多屏负坐标 bounds）：平移一致。
        let offscreen = CGRect(x: -1920, y: -500, width: 1920, height: 1080)
        let shifted = MarkingOverlayController.overlayViewPoint(fromNormalized: CGPoint(x: 0.25, y: 0.75), in: offscreen)
        XCTAssertEqual(shifted.x, -1920 + 0.25 * 1920, accuracy: Self.accuracy, "x 含 bounds.minX 平移")
        XCTAssertEqual(shifted.y, -500 + 1080 - 0.75 * 1080, accuracy: Self.accuracy, "y 自 bounds.maxY 翻转，负坐标屏安全")
        // 往返恒等：视图点经同一归一化管线应回到原归一化值（与 testScreenPointToNormalizedMapping
        // 的输出口径互逆；此处以纯几何复核翻转互逆性）。
        let normalized = CGPoint(x: 0.4, y: 0.2)
        let viewPoint = MarkingOverlayController.overlayViewPoint(fromNormalized: normalized, in: bounds)
        let roundTripped = CGPoint(x: (viewPoint.x - bounds.minX) / bounds.width,
                                   y: (bounds.maxY - viewPoint.y) / bounds.height)
        XCTAssertEqual(roundTripped.x, normalized.x, accuracy: Self.accuracy, "归一化→视图→归一化往返恒等")
        XCTAssertEqual(roundTripped.y, normalized.y, accuracy: Self.accuracy)
    }

    /// 墨迹装配：首次 show 装事件泵时注入绘制缝 + 画布变更订阅——覆盖层视图就位
    /// （contentView）、`drawInk` 已接、画布 begin/undo 后视图置脏（needsDisplay），
    /// 撤销到空后同样置脏（撤销墨迹即时消失的面）。
    func testInkViewWiringAndRefresh() throws {
        let box = VisibilityStateBox()
        box.geometry = displayGeometry
        let spy = SpyMarkingPanel()
        let canvas = MarkingCanvas()
        let controller = MarkingOverlayController(
            canvas: canvas,
            modeProvider: { box.mode },
            stateProvider: { box.state },
            markingEnabledProvider: { box.markingEnabled },
            geometryProvider: { box.geometry },
            panelFactory: { spy })

        controller.refreshVisibility(enabled: true, state: .recording)
        XCTAssertTrue(controller.isShowingOverlays)
        let inkView = try XCTUnwrap(spy.contentView as? MarkingOverlayView,
                                    "覆盖层视图应为面板 contentView（事件泵装配即注入墨迹绘制）")
        XCTAssertNotNil(inkView.drawInk, "绘制缝必须在事件泵装配时接好")
        // $strokes 订阅按 Combine 语义即发初值（[]）→ 装配时置脏一次，无害的空重绘。
        inkView.needsDisplay = false

        // begin 一笔：$strokes 订阅触发置脏（主 actor 同步）。
        canvas.beginStroke(color: .red, width: 0.008, at: CGPoint(x: 0.5, y: 0.5))
        XCTAssertTrue(inkView.needsDisplay, "画布变更必须置脏覆盖层（实时墨迹）")
        inkView.needsDisplay = false

        // 撤销到空：同样置脏（墨迹即时消失）。
        canvas.undoLast()
        XCTAssertTrue(inkView.needsDisplay, "撤销后必须置脏重绘（清屏）")
        inkView.needsDisplay = false

        // 隐藏面板不拆除墨迹装配（复用面板下一场直接可用）。
        controller.refreshVisibility(enabled: false, state: .recording)
        XCTAssertFalse(controller.isShowingOverlays)
        XCTAssertTrue(spy.contentView === inkView, "隐藏只 orderOut，视图装配保持")
    }
}
