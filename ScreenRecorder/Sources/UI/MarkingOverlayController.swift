import AppKit
import CoreGraphics
import Foundation

// MARK: - MarkingStrokeStore（MainActor 写 / video 队列读的快照桥）

/// 笔画快照桥（PiPFrameStore 同款锁纪律）：画布在主 actor（`MarkingCanvas` @MainActor），
/// 合成取数缝在 SCStream video 队列——NSLock 保护单个不可变快照，锁内一次结构体拷贝，
/// 合成热路径零分配（快照空时读 nil = 合成器直通）。装配层订阅 `canvas.$strokes` 灌入。
@MainActor
final class MarkingStrokeStore {
    private let lock = NSLock()
    /// 最新快照（nil = 无笔画：开关关 / 未画 / 已清空）。
    nonisolated(unsafe) private var snapshot: MarkingStrokeSnapshot?

    /// 覆写最新快照（主 actor：canvas.$strokes 订阅回调）。空快照归一为 nil——
    /// 「开着开关还没画」与「开关关」走同一条合成直通路。
    func update(_ snapshot: MarkingStrokeSnapshot) {
        let effective = snapshot.strokes.isEmpty ? nil : snapshot
        lock.lock()
        self.snapshot = effective
        lock.unlock()
    }

    /// video 队列读缝（非隔离）：锁内取不可变快照，锁外消费。
    nonisolated func currentSnapshot() -> MarkingStrokeSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }
}

// MARK: - 标记覆盖层视图（事件泵）

/// 全屏透明覆盖视图：把鼠标拖拽三拍原样上抛（窗口坐标），换算与画布写全在控制器。
/// 不绘制任何内容（画布出图在合成器）；rightMouse 同样不关心（覆盖层无右键语义）。
private final class MarkingOverlayView: NSView {
    var onMouseDown: ((CGPoint) -> Void)?
    var onMouseDragged: ((CGPoint) -> Void)?
    var onMouseUp: ((CGPoint) -> Void)?

    override func mouseDown(with event: NSEvent) { onMouseDown?(event.locationInWindow) }
    override func mouseDragged(with event: NSEvent) { onMouseDragged?(event.locationInWindow) }
    override func mouseUp(with event: NSEvent) { onMouseUp?(event.locationInWindow) }

    override var acceptsFirstResponder: Bool { false }
}

// MARK: - MarkingOverlayController（简报 Produces：每被录显示器一张透明覆盖 NSPanel）

/// 边录边标记的覆盖层控制器（Task 5）：
/// - **显隐**：`markingEnabled && (state == .recording || .paused)`——装配层在
///   `controller.$state` / `$markingEnabled` 变化时调 `refreshVisibility(enabled:state:)`，
///   以 CombineLatest **发射值直传**重估（sink 在 @Published willSet 阶段同步执行，此刻
///   属性与 provider 回拉都是旧值——修复轮2 Critical 1；拉取式 `shouldShowOverlays()`
///   保留为测试缝）。暂停态保持可见（spec §5 P2：暂停中可继续画，画的内容恢复后可见
///   ——无暂停门控）。
/// - **面板**：每场录制一张（当前各捕获模式至多一个被录显示器），铺满被录显示器 bounds
///   （全屏 = 该显示器；区域 = 所在显示器——越出采集 rect 的点由换算层丢弃，见下）；
///   nonactivating borderless NSPanel，接事件不夺焦点（浮条宿主同款 styleMask），
///   level 略低于浮条（浮条/工具条保持可点）。
/// - **事件泵**：mouseDown/Dragged/Up → 屏幕（Cocoa 全局）→ 底帧归一化 → canvas
///   begin/extend/end。`endStroke` 在 mouseUp 与收起时兜底调用（幂等）。
/// - **坐标管线**（`normalizedStrokePoint`，与 Task 2 feedZoomClick 同源换算 + Task 4
///   逆映射步）：Cocoa 全局 →（主屏翻转）→ CG 全局 →（几何平移缩放）→ 捕获像素 →
///   viewport 归一化（CI 画布 y 向上口径，缩放仿射的作用域）→ `baseFramePoint`
///   逆映射 → 底帧归一化（y 向下 0…1）。生产恒传 identity：绘制面呈现**底帧内容**
///   （缩放只存在于成片合成侧，用户桌面不被缩放），屏幕点即底帧点；参数留作缝
///   （若未来出现预览式绘制面再喂当前变换）。
/// - **越界丢弃**：归一化越出 0…1（含 NaN/∞）返回 nil，上游丢弃该点——覆盖层铺满
///   显示器而采集 rect 只占其一角时，rect 外拖拽不成笔（配合画布 closed-0…1 规则双保险）。
/// - **点击系抑制**（spec §5 P2：绘图拖拽不得触发点击高亮/缩放/音效）：覆盖层是本 App
///   自己的窗口，全局 monitor 收不到（计划钉定假设成立）；但 tracker 的**本地 monitor
///   收得到**本 App 窗口的 mouseDown——经 `ClickHighlightTracker.isLocalClickSuppressed`
///   缝按窗口 identifier 过滤（装配层接线，见 ScreenRecorderApp）。
@MainActor
final class MarkingOverlayController: ObservableObject {
    /// 覆盖层窗口标识（点击系抑制缝按此识别本类面板）。
    static let overlayWindowIdentifier = NSUserInterfaceItemIdentifier(rawValue: "com.screenrecorder.marking-overlay")

    /// 简报钉定线宽两档（底帧短边归一，MarkingCanvas 文档口径；画布不持档位常量）。
    static let thinStrokeWidth: Double = 0.004
    static let thickStrokeWidth: Double = 0.008

    /// 工具态（工具条视图 ObservedObject）：色二选黑/红、粗细二档。
    @Published var toolColor: MarkingColor = .black
    @Published var isThickWidth = false
    var toolWidth: Double { isThickWidth ? Self.thickStrokeWidth : Self.thinStrokeWidth }

    let canvas: MarkingCanvas
    private let modeProvider: () -> CaptureMode?
    private let stateProvider: () -> CaptureState
    private let markingEnabledProvider: () -> Bool
    private let geometryProvider: () -> PiPCaptureGeometry?
    private let panelFactory: (@MainActor () -> NSPanel)
    private var overlayPanel: NSPanel?
    private(set) var isShowingOverlays = false

    /// - Parameters:
    ///   - canvas: 笔画真源（Task 4）。
    ///   - modeProvider: 当前捕获模式（面板铺满被录显示器 bounds 用）。
    ///   - stateProvider: 录制状态机读缝（显隐条件之一）。
    ///   - markingEnabledProvider: 标记开关读缝（AppAssembly @Published，会话态不持久化）。
    ///   - geometryProvider: 当次录制采集几何读缝（坐标换算用；nil = 换算不可得，点丢弃）。
    ///   - panelFactory: 测试缝——无头测试注入不真正上屏的记录面板（同 CountdownOverlayController）。
    init(canvas: MarkingCanvas,
         modeProvider: @escaping () -> CaptureMode?,
         stateProvider: @escaping () -> CaptureState,
         markingEnabledProvider: @escaping () -> Bool = { false },
         geometryProvider: @escaping () -> PiPCaptureGeometry? = { nil },
         panelFactory: @escaping @MainActor () -> NSPanel = { MarkingOverlayController.makeOverlayPanel() }) {
        self.canvas = canvas
        self.modeProvider = modeProvider
        self.stateProvider = stateProvider
        self.markingEnabledProvider = markingEnabledProvider
        self.geometryProvider = geometryProvider
        self.panelFactory = panelFactory
    }

    // MARK: 显隐（装配层在 state / markingEnabled 变化时以发射值直传重估）

    /// 显隐判定（纯函数，headless 钉测点）：开关开 且 录制/暂停中。
    static func isVisible(enabled: Bool, state: CaptureState) -> Bool {
        guard enabled else { return false }
        switch state {
        case .recording, .paused:
            return true
        case .idle, .countdown, .finishing:
            return false
        }
    }

    /// 拉取式判定（provider 读缝便捷面，headless 钉测 / 自检用）。装配热路径不走此门：
    /// sink 在 @Published willSet 阶段同步触发，此刻回拉 provider 拿到的是旧值（修复轮2
    /// Critical 1）——生产一律走 `refreshVisibility(enabled:state:)` 发射值直传。
    func shouldShowOverlays() -> Bool {
        Self.isVisible(enabled: markingEnabledProvider(), state: stateProvider())
    }

    /// 重估显隐（幂等：已显示不重复 orderFront，已隐藏不重复 orderOut）。参数为装配层
    /// CombineLatest 的**发射值直传**——同步、时序确定、headless 可钉；方法体内不得回拉
    /// provider（willSet 阶段属性仍是旧值）。
    func refreshVisibility(enabled: Bool, state: CaptureState) {
        if Self.isVisible(enabled: enabled, state: state) {
            show()
        } else {
            hide()
        }
    }

    private func show() {
        let panel: NSPanel
        if let overlayPanel {
            panel = overlayPanel
        } else {
            panel = panelFactory()
            installEventPump(on: panel)
            overlayPanel = panel
        }
        if let frame = modeProvider().flatMap(Self.recordedDisplayFrame) {
            panel.setFrame(frame, display: false) // 铺满被录显示器（每次显示重定位）
        }
        guard !isShowingOverlays else { return }
        panel.orderFrontRegardless() // 不夺焦点（nonactivatingPanel 语义）
        isShowingOverlays = true
    }

    private func hide() {
        guard isShowingOverlays else { return }
        canvas.endStroke() // 收起时若有进行中笔画就地收笔（幂等）
        overlayPanel?.orderOut(nil)
        isShowingOverlays = false
    }

    // MARK: 事件泵（覆盖层视图 → 画布）

    private func installEventPump(on panel: NSPanel) {
        panel.identifier = Self.overlayWindowIdentifier
        let view = MarkingOverlayView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        view.onMouseDown = { [weak self] point in self?.handleDown(atWindowPoint: point) }
        view.onMouseDragged = { [weak self] point in self?.handleExtend(atWindowPoint: point) }
        view.onMouseUp = { [weak self] _ in self?.canvas.endStroke() }
        panel.contentView = view
    }

    private func handleDown(atWindowPoint windowPoint: CGPoint) {
        guard let strokePoint = normalizedPoint(fromWindowPoint: windowPoint) else { return }
        canvas.beginStroke(color: toolColor, width: toolWidth, at: strokePoint)
    }

    private func handleExtend(atWindowPoint windowPoint: CGPoint) {
        guard let strokePoint = normalizedPoint(fromWindowPoint: windowPoint) else { return }
        canvas.extendStroke(to: strokePoint) // begin 未成功（起点越界）时为安全 no-op
    }

    /// 窗口点 → 底帧归一化点（nil = 几何未就绪 / 越出采集 rect）。
    private func normalizedPoint(fromWindowPoint windowPoint: CGPoint) -> CGPoint? {
        guard let panel = overlayPanel, let geometry = geometryProvider() else { return nil }
        let cocoaPoint = panel.convertToScreen(NSRect(origin: windowPoint, size: .zero)).origin
        return Self.normalizedStrokePoint(
            fromCocoaGlobalPoint: cocoaPoint,
            geometry: geometry,
            flipHeight: ClickHighlightTracker.primaryScreenHeight(),
            zoomTransform: .identity) // 绘制面呈现底帧内容（缩放只在成片侧）——见类文档坐标管线
    }

    // MARK: 坐标换算（纯函数，headless 钉测缝）

    /// 屏幕（Cocoa 全局）点 → 底帧归一化笔画点；越出采集 rect（归一化越出 0…1，NaN/∞
    /// 同判）返回 nil。管线见类文档：与 feedZoomClick 同源换算 + Task 4 `baseFramePoint`
    /// 逆映射步（`zoomTransform` 为当前 viewport→base 的变换，在 CI 画布 y 向上空间作用；
    /// 生产恒 identity）。
    static func normalizedStrokePoint(fromCocoaGlobalPoint cocoaPoint: CGPoint,
                                      geometry: PiPCaptureGeometry,
                                      flipHeight: CGFloat,
                                      zoomTransform: CGAffineTransform) -> CGPoint? {
        let canvasSize = geometry.capturePixelSize
        guard canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        let cgPoint = ClickHighlightTracker.cgGlobalPoint(
            fromCocoaGlobal: cocoaPoint,
            primaryScreenHeight: flipHeight)
        let pixel = geometry.capturePixelPoint(fromCGPoint: cgPoint)
        // viewport 归一化走 CI 画布口径（y 向上）——缩放仿射的作用域（与合成器画布同空间）。
        let canvasBounds = CGRect(origin: .zero, size: canvasSize)
        let viewportCI = CGPoint(x: pixel.x, y: canvasSize.height - pixel.y)
        let baseCI = MarkingCanvas.baseFramePoint(fromViewport: viewportCI,
                                                  zoomTransform: zoomTransform,
                                                  bounds: canvasBounds)
        let normalized = CGPoint(x: baseCI.x / canvasSize.width,
                                 y: 1 - baseCI.y / canvasSize.height)
        guard (0...1).contains(normalized.x), (0...1).contains(normalized.y) else { return nil }
        return normalized
    }

    // MARK: 被录显示器 bounds（显示时刻现场解析，无屏幕 API 的纯逻辑由测试另钉）

    /// 捕获模式 → 被录显示器的 Cocoa 全局 frame：display/region = 其所在显示器；
    /// window = 窗口当前落点的显示器（窗口可跨屏移动，显示时刻现场解析）；app（P3a）=
    /// 窗口集 union 包围盒中心落点的显示器（工具条单点摆放，多屏窗口集取主画布近似）。
    /// 取不到回 nil（面板保持原 frame——headless 测试的注入面板不受影响）。
    static func recordedDisplayFrame(for mode: CaptureMode) -> NSRect? {
        let displayID: CGDirectDisplayID?
        switch mode {
        case .display(let id):
            displayID = id
        case .region(_, let id):
            displayID = id
        case .window(let windowID):
            displayID = Self.displayID(containingWindow: windowID)
        case .app(let bundleID):
            displayID = Self.displayID(containingAppBundle: bundleID)
        }
        guard let displayID else { return nil }
        return NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }?.frame
    }

    /// 窗口当前 CG bounds 落点的显示器 id（含窗口中心的显示器；取不到回主屏，再取不到 nil）。
    private static func displayID(containingWindow windowID: CGWindowID) -> CGDirectDisplayID? {
        func screenNumber(_ screen: NSScreen) -> CGDirectDisplayID? {
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        guard let window = list.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }),
              let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { return nil }
        return displayID(containingCGPoint: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    /// App（P3a）union 包围盒中心落点的显示器 id：bundle 的 on-screen 普通层窗口 CG
    /// bounds 取 union 后同窗口逻辑求含点。归属解析同
    /// `SourceLossMonitor.onScreenAppWindowCount`（窗口清单无 bundle id 键，经所有者
    /// PID → NSRunningApplication 解析）；无窗口/清单不可读取返回 nil。
    private static func displayID(containingAppBundle bundleID: String) -> CGDirectDisplayID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        var canvas = CGRect.null
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int ?? 0) == 0 else { continue }
            guard let pid = info[kCGWindowOwnerPID as String] as? Int,
                  NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier == bundleID else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            canvas = canvas.union(bounds)
        }
        guard !canvas.isNull else { return nil }
        return displayID(containingCGPoint: CGPoint(x: canvas.midX, y: canvas.midY))
    }

    /// CG 全局点（左上原点、y 向下）落点的显示器 id；取不到回主屏，再取不到 nil。
    private static func displayID(containingCGPoint center: CGPoint) -> CGDirectDisplayID? {
        func screenNumber(_ screen: NSScreen) -> CGDirectDisplayID? {
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }
        // NSScreen.frame 为 Cocoa 全局（主屏左下原点）；CG 全局 y 翻转后求含点。
        let flipHeight = ClickHighlightTracker.primaryScreenHeight()
        let hit = NSScreen.screens.first { screen in
            let frame = screen.frame
            let cgFrame = CGRect(x: frame.minX,
                                 y: flipHeight - frame.maxY,
                                 width: frame.width,
                                 height: frame.height)
            return cgFrame.contains(center)
        }
        return (hit.flatMap(screenNumber)) ?? NSScreen.screens.first.flatMap(screenNumber)
    }

    // MARK: 默认面板工厂

    /// 全屏透明覆盖 NSPanel：nonactivating borderless（接事件不夺焦点，浮条宿主同款），
    /// level 取浮条之下（浮条/工具条保持可点），canJoinAllSpaces + fullScreenAuxiliary
    /// 与浮条同款（全屏应用录制时覆盖层仍在被录屏上生效）。
    private static func makeOverlayPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = overlayWindowIdentifier
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }
}
