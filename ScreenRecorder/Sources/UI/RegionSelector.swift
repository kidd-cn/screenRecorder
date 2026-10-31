import AppKit

// MARK: - 坐标系纯函数（无头测试钉死：Y 翻转、多屏偏移、边界 clamp）

/// 区域选择的几何纯函数。坐标系契约（本任务最大的坑）：
/// 返回 rect 必须与 `CaptureMode.region` 的 rect 同一口径——`SCStreamConfiguration.sourceRect`
/// 期望的「points、显示器逻辑坐标系」（SCK/CG 全局系：主屏左上原点、y 向下，含多屏偏移，
/// 即 `CGDisplayBounds(displayID)` 所在空间）。
///
/// 推导：`NSScreen.frame` 与 `CGDisplayBounds(displayID)` 是同一台显示器在两个全局系里的描述
///（Cocoa：主屏**左下**原点、y 向上；CG：主屏**左上**原点、y 向下）。同一物理点在两系里
/// x 相同、「到该屏顶边的距离」相同，故以目标屏为锚做平移：
///
///     cgX = cgDisplayOrigin.x + (cocoaX - screenFrame.minX)
///     cgY = cgDisplayOrigin.y + (screenFrame.maxY - cocoaTop)
///
///（`cgDisplayOrigin` = `CGDisplayBounds(displayID).origin`）。代入整屏 frame 恒等还原
/// CGDisplayBounds（测试钉死）；副屏 frame.origin 非零时偏移不丢。
/// NSEvent.mouseLocation 在窗口事件回调里不可靠，本链路全程不用：事件取
/// `locationInWindow`（窗口基坐标）→ 加窗口 frame.origin（Cocoa 全局）→ 本枚举换 CG 系。
/// clamp 同样抽纯函数：拖拽全程把点钉在目标屏内、收尾再把矩形与屏 frame 求交。
enum RegionSelectorMath {
    /// Cocoa 全局 rect → CG 显示器全局 rect（Y 翻转 + 目标屏偏移，尺寸不变）。
    static func cgRect(fromCocoaRect rect: CGRect, screenFrame: CGRect, cgDisplayOrigin: CGPoint) -> CGRect {
        CGRect(
            x: cgDisplayOrigin.x + (rect.minX - screenFrame.minX),
            y: cgDisplayOrigin.y + (screenFrame.maxY - rect.maxY),
            width: rect.width,
            height: rect.height)
    }

    /// 窗口基坐标 rect → Cocoa 全局 rect（borderless 窗口铺满目标屏：加窗口 frame.origin）。
    static func cocoaRect(fromWindowRect rect: CGRect, windowOrigin: CGPoint) -> CGRect {
        rect.offsetBy(dx: windowOrigin.x, dy: windowOrigin.y)
    }

    /// CG 全局 rect（主屏左上原点）→ Cocoa 全局 rect（主屏左下原点）：x 与尺寸不动，y 按
    ///「到主屏下边距离」翻转（`ClickHighlightTracker.cgGlobalPoint` 的 rect 版逆变换）。
    /// P3b 装配层用：SCWindow.frame（CG 全局口径）→ 窗口区域遮罩 NSWindow 的 frame（Cocoa 全局）。
    static func cocoaRect(fromCGRect cgRect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: cgRect.minX,
            y: primaryScreenHeight - cgRect.maxY,
            width: cgRect.width,
            height: cgRect.height)
    }

    /// 拖拽起止点 → 正尺寸 rect（支持任意方向起拖）。
    static func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(start.x - end.x),
            height: abs(start.y - end.y))
    }

    /// 点 clamp 到目标屏 frame 内（拖出屏边界时钉回边界上）。
    static func clamped(point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    /// rect clamp 到目标屏 frame 内（与屏 frame 求交；完全在外剪成空）。
    static func clamped(rect: CGRect, to bounds: CGRect) -> CGRect {
        bounds.intersection(rect)
    }

    /// 点击无拖动判定：宽或高不足 1pt 视为误触/取消（零面积 rect 无法作为录制区域）。
    static func isMeaningfulSelection(_ rect: CGRect) -> Bool {
        rect.width >= 1 && rect.height >= 1
    }

    /// 尺寸标签 `W×H`（points，四舍五入到整数）。
    static func sizeLabel(width: CGFloat, height: CGFloat) -> String {
        "\(Int(width.rounded()))×\(Int(height.rounded()))"
    }
}

// MARK: - 选区视图（遮罩 + 亮框 + W×H 标签）

/// 全屏遮罩视图：暗色半透明整屏盖底，拖出的选区用 `.clear` 混合挖洞（实屏内容原亮度透出）
/// + 白色边框，选区中央浮 `W×H`（points）尺寸标签。事件只转发不决策（拖拽语义在
/// `RegionSelectionSession`）；坐标为窗口基坐标（视图铺满窗口，二者重合）。
/// internal 供无头测试断言 `selectionRect`。
final class RegionSelectionOverlayView: NSView {
    /// 当前选区（视图坐标）；零 = 尚未拖出。
    var selectionRect: CGRect = .zero { didSet { needsDisplay = true } }
    var onMouseDown: ((CGPoint) -> Void)?
    var onMouseDragged: ((CGPoint) -> Void)?
    var onMouseUp: ((CGPoint) -> Void)?

    override func mouseDown(with event: NSEvent) { onMouseDown?(event.locationInWindow) }
    override func mouseDragged(with event: NSEvent) { onMouseDragged?(event.locationInWindow) }
    override func mouseUp(with event: NSEvent) { onMouseUp?(event.locationInWindow) }

    override func draw(_ dirtyRect: NSRect) {
        guard let cgContext = NSGraphicsContext.current?.cgContext else { return }
        NSColor.black.withAlphaComponent(0.3).setFill()
        bounds.fill()
        guard !selectionRect.isEmpty else { return }
        // 抠亮：clear 混合把选区内的遮罩擦成透明，被选画面原亮度透出
        cgContext.saveGState()
        cgContext.setBlendMode(.clear)
        cgContext.fill(selectionRect)
        cgContext.restoreGState()
        // 亮框描边
        let border = NSBezierPath(rect: selectionRect.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        NSColor.white.setStroke()
        border.stroke()
        drawSizeLabel()
    }

    /// 选区中央的 `W×H` 尺寸标签（深色圆角芯片 + 白色等宽数字，任意底色可读）。
    private func drawSizeLabel() {
        let text = NSAttributedString(
            string: RegionSelectorMath.sizeLabel(width: selectionRect.width, height: selectionRect.height),
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.white,
            ])
        let textSize = text.size()
        let chip = NSRect(
            x: selectionRect.midX - textSize.width / 2 - 8,
            y: selectionRect.midY - textSize.height / 2 - 5,
            width: textSize.width + 16,
            height: textSize.height + 10)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: chip, xRadius: 6, yRadius: 6).fill()
        text.draw(at: chip.origin)
    }
}

// MARK: - 选区会话（一次 selectRegion 调用的生命周期）

/// 一次拖拽选区的完整会话：持窗（逐次创建、不复用）、转发视图事件、ESC 本地 monitor、
/// 窗口关闭观察，三条出口（拖拽完成 / ESC / 窗口被外部关闭）经 `finish` 收敛到唯一回调
///——phase 闩防重入，`onFinish` 恰调一次（即 `selectRegion` continuation 恰一次 resume）。
/// internal（非 private）供无头测试驱动拖拽生命周期。
@MainActor
final class RegionSelectionSession {
    private enum Phase { case selecting, finished }

    let screenFrame: CGRect
    let cgDisplayOrigin: CGPoint
    let overlayView = RegionSelectionOverlayView(frame: .zero)

    private let onFinish: (CGRect?) -> Void
    private let window: NSWindow
    private var phase: Phase = .selecting
    /// begin 恰一次闩：二次 begin 会导致 monitor/光标重复装（pop 只平衡一次）。
    private var hasBegun = false
    /// 会话自持：`selectRegion` 的 continuation 体返回后无人再持会话，若不自持，会话
    ///（连同 continuation）在选择期间即释放 → continuation 永不 resume（checked continuation
    /// 视为误用直接崩溃）。本引用在 finish 末尾断开：会话恰存活到三条出口之一收尾，无泄漏。
    private var selfRetainer: RegionSelectionSession?
    /// 拖拽起点（窗口基坐标 == 内容视图坐标）；nil = 未按下。
    private var dragStart: CGPoint?
    private var keyMonitor: Any?
    private var closeObserver: NSObjectProtocol?

    /// - Parameters:
    ///   - screenFrame: 目标屏 `NSScreen.frame`（Cocoa 全局、左下原点）。
    ///   - cgDisplayOrigin: 目标屏 `CGDisplayBounds(displayID).origin`（CG 全局系锚点）。
    ///   - onFinish: 唯一收尾回调（nil = 取消）；由 phase 闩保证恰调一次。
    ///   - windowFactory: 测试缝——无头测试注入只计数的记录窗口。
    ///     （`@MainActor` 标注：会话全主 actor，工厂闭包同域，免 MainActor 隔离丢失转换告警。）
    init(screenFrame: CGRect,
         cgDisplayOrigin: CGPoint,
         onFinish: @escaping (CGRect?) -> Void,
         windowFactory: @MainActor @escaping (CGRect) -> NSWindow = RegionSelector.makeOverlayWindow) {
        self.screenFrame = screenFrame
        self.cgDisplayOrigin = cgDisplayOrigin
        self.onFinish = onFinish
        self.window = windowFactory(screenFrame)
    }

    func begin() {
        guard phase == .selecting, !hasBegun else { return }
        hasBegun = true
        selfRetainer = self
        overlayView.frame = NSRect(origin: .zero, size: screenFrame.size)
        overlayView.onMouseDown = { [weak self] in self?.dragBegan(at: $0) }
        overlayView.onMouseDragged = { [weak self] in self?.dragMoved(to: $0) }
        overlayView.onMouseUp = { [weak self] in self?.dragEnded(at: $0) }
        window.contentView = overlayView
        window.orderFrontRegardless() // 不夺焦点（配合 canBecomeKey == false）
        NSCursor.crosshair.push()
        // ESC 本地 monitor（覆盖层不 key、keyDown 须走应用分发口；同 CountdownOverlay 纪律）
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, CountdownOverlayController.isEscapeKey(event) else { return event }
            self.performCancel()
            return nil // ESC 消费掉
        }
        // 窗口被外部关闭（NSApp 收尾 / AppleScript 等）→ 收敛到唯一 finish(nil)
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.performCancel() }
        }
    }

    // MARK: 拖拽生命周期（视图回调与无头测试共用；点为窗口基坐标）

    func dragBegan(at point: CGPoint) {
        guard phase == .selecting else { return }
        dragStart = RegionSelectorMath.clamped(point: point, to: overlayView.bounds)
        overlayView.selectionRect = .zero
    }

    func dragMoved(to point: CGPoint) {
        guard phase == .selecting else { return }
        applyDrag(to: point)
    }

    /// 松开算完成：clamp → 归一化 → 点击无拖动按取消 → 换 CG 系 rect 收尾。
    func dragEnded(at point: CGPoint) {
        guard phase == .selecting, let start = dragStart else { return }
        let rect = RegionSelectorMath.clamped(
            rect: RegionSelectorMath.normalizedRect(
                from: start,
                to: RegionSelectorMath.clamped(point: point, to: overlayView.bounds)),
            to: overlayView.bounds)
        guard RegionSelectorMath.isMeaningfulSelection(rect) else {
            performCancel() // 点击无拖动：按取消处理（本任务裁定，见 task-13-report）
            return
        }
        let cocoaRect = RegionSelectorMath.cocoaRect(fromWindowRect: rect, windowOrigin: window.frame.origin)
        finish(with: RegionSelectorMath.cgRect(
            fromCocoaRect: cocoaRect,
            screenFrame: screenFrame,
            cgDisplayOrigin: cgDisplayOrigin))
    }

    private func applyDrag(to point: CGPoint) {
        guard let start = dragStart else { return }
        let clamped = RegionSelectorMath.clamped(point: point, to: overlayView.bounds)
        overlayView.selectionRect = RegionSelectorMath.normalizedRect(from: start, to: clamped)
    }

    // MARK: 三条出口收敛的唯一收尾

    /// ESC（monitor）与窗口被外部关闭（willClose 观察者）与点击无拖动的共用取消入口。
    func performCancel() {
        finish(with: nil)
    }

    var isFinished: Bool { phase == .finished }

    /// 恰一次 resume 的收敛点：phase 闩防重入，任何后续出口（重复 ESC、迟到的松开、
    /// 关闭后再取消）一律 no-op；回调即 `selectRegion` 的 `continuation.resume`。
    private func finish(with result: CGRect?) {
        guard phase == .selecting else { return }
        phase = .finished
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        overlayView.onMouseDown = nil
        overlayView.onMouseDragged = nil
        overlayView.onMouseUp = nil
        NSCursor.pop()
        window.orderOut(nil)
        onFinish(result)
        selfRetainer = nil // 断开自持：会话自此释放（窗口已收起，无泄漏）
    }
}

// MARK: - 窗口区域选择会话（P3b：窗口锚定拖框）

/// 一次窗口区域拖拽的完整会话（P3b）：遮罩窗口覆盖**目标窗口 frame**（非整屏），拖拽产出
/// **窗口相对系** rect——原点 = 窗口 frame 左上、points、y 向下，即 `CaptureMode.windowRegion`
/// 的坐标契约（`SCContentFilter(desktopIndependentWindow:)` + `sourceRect` 的裁剪口径）。
/// 交互与 `RegionSelectionSession` 同构（拖拽语义、ESC、窗口被外部关闭、恰一次 finish），
/// 复用同一遮罩视图与全部坐标纯函数，三处差异：
/// - 遮罩铺目标窗口 frame，clamp 边界 = 窗口 bounds（拖出窗口即钉回，输出恒在窗口内
///   ——开录钳制在选区即完成）；
/// - 收尾换算只走「窗口基 rect → Cocoa 全局 → 窗口相对左上系」一次平移 + 翻转，不再进
///   显示器全局系（简报 Produces：不经 F3 全局坐标坑）。翻转沿用 `RegionSelectorMath.cgRect`：
///   以窗口 frame 充当「锚屏 frame」、CG 原点取 .zero，算式恰为「顶边距离」的窗口相对化，
///   不另推公式；
/// - 取消语义同款：ESC / 亚点拖动（`isMeaningfulSelection` 一期最小尺寸语义）/ 遮罩窗被
///   外部关闭都收敛到唯一 `finish(nil)`。
/// 结构为与 `RegionSelectionSession` 平行的实现（phase 闩 / 自持 / monitor 三件套逐行同款）：
/// 二者收尾换算的目标系不同，泛化合并需改动一期已验收会话的 private 状态，风险大于收益
///（审阅修复轮 1 Minor 3 停放：一期冻结解除后合并骨架，终审携带）。
/// internal（非 private）供无头测试驱动拖拽生命周期。
@MainActor
final class WindowRegionSelectionSession {
    private enum Phase { case selecting, finished }

    /// 目标窗口的 Cocoa 全局 frame（遮罩铺此 frame；收尾换算的翻转锚点）。
    let anchorFrame: CGRect
    let overlayView = RegionSelectionOverlayView(frame: .zero)

    private let onFinish: (CGRect?) -> Void
    private let window: NSWindow
    private var phase: Phase = .selecting
    /// begin 恰一次闩：二次 begin 会导致 monitor/光标重复装（pop 只平衡一次）。
    private var hasBegun = false
    /// 会话自持：`selectWindowRegion` 的 continuation 体返回后无人再持会话，若不自持，
    /// continuation 永不 resume（checked continuation 误用直接崩溃）。finish 末尾断开。
    private var selfRetainer: WindowRegionSelectionSession?
    /// 拖拽起点（窗口基坐标 == 内容视图坐标）；nil = 未按下。
    private var dragStart: CGPoint?
    private var keyMonitor: Any?
    private var closeObserver: NSObjectProtocol?

    /// - Parameters:
    ///   - anchorFrame: 目标窗口 Cocoa 全局 frame（遮罩铺此 frame，输出换算的翻转锚点）。
    ///   - onFinish: 唯一收尾回调（nil = 取消）；由 phase 闩保证恰调一次。
    ///   - windowFactory: 测试缝——无头测试注入只计数的记录窗口。
    init(anchorFrame: CGRect,
         onFinish: @escaping (CGRect?) -> Void,
         windowFactory: @MainActor @escaping (CGRect) -> NSWindow = RegionSelector.makeOverlayWindow) {
        self.anchorFrame = anchorFrame
        self.onFinish = onFinish
        self.window = windowFactory(anchorFrame)
    }

    func begin() {
        guard phase == .selecting, !hasBegun else { return }
        hasBegun = true
        selfRetainer = self
        overlayView.frame = NSRect(origin: .zero, size: anchorFrame.size)
        overlayView.onMouseDown = { [weak self] in self?.dragBegan(at: $0) }
        overlayView.onMouseDragged = { [weak self] in self?.dragMoved(to: $0) }
        overlayView.onMouseUp = { [weak self] in self?.dragEnded(at: $0) }
        window.contentView = overlayView
        window.orderFrontRegardless() // 不夺焦点（配合 canBecomeKey == false）
        NSCursor.crosshair.push()
        // ESC 本地 monitor（覆盖层不 key、keyDown 须走应用分发口；同一期区域选择纪律）
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, CountdownOverlayController.isEscapeKey(event) else { return event }
            self.performCancel()
            return nil // ESC 消费掉
        }
        // 窗口被外部关闭（NSApp 收尾 / AppleScript 等）→ 收敛到唯一 finish(nil)
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.performCancel() }
        }
    }

    // MARK: 拖拽生命周期（视图回调与无头测试共用；点为窗口基坐标，边界 = 窗口 bounds）

    func dragBegan(at point: CGPoint) {
        guard phase == .selecting else { return }
        dragStart = RegionSelectorMath.clamped(point: point, to: overlayView.bounds)
        overlayView.selectionRect = .zero
    }

    func dragMoved(to point: CGPoint) {
        guard phase == .selecting else { return }
        applyDrag(to: point)
    }

    /// 松开算完成：clamp 于窗口 bounds → 归一化 → 亚点拖动按取消 → 换窗口相对 rect 收尾。
    func dragEnded(at point: CGPoint) {
        guard phase == .selecting, let start = dragStart else { return }
        let rect = RegionSelectorMath.clamped(
            rect: RegionSelectorMath.normalizedRect(
                from: start,
                to: RegionSelectorMath.clamped(point: point, to: overlayView.bounds)),
            to: overlayView.bounds)
        guard RegionSelectorMath.isMeaningfulSelection(rect) else {
            performCancel() // 亚点拖动 = 误触：按取消处理（一期区域模式最小尺寸语义）
            return
        }
        // 窗口基 rect →（加遮罩窗 origin）Cocoa 全局 →（窗口 frame 充当锚屏、CG 原点 .zero
        // 的 cgRect 算式）窗口相对左上系。屏幕点仅此一次换算直达契约系。
        let cocoaRect = RegionSelectorMath.cocoaRect(fromWindowRect: rect, windowOrigin: window.frame.origin)
        finish(with: RegionSelectorMath.cgRect(
            fromCocoaRect: cocoaRect,
            screenFrame: anchorFrame,
            cgDisplayOrigin: .zero))
    }

    private func applyDrag(to point: CGPoint) {
        guard let start = dragStart else { return }
        let clamped = RegionSelectorMath.clamped(point: point, to: overlayView.bounds)
        overlayView.selectionRect = RegionSelectorMath.normalizedRect(from: start, to: clamped)
    }

    // MARK: 三条出口收敛的唯一收尾

    /// ESC（monitor）与遮罩窗被外部关闭（willClose 观察者）与亚点拖动的共用取消入口。
    func performCancel() {
        finish(with: nil)
    }

    var isFinished: Bool { phase == .finished }

    /// 恰一次 resume 的收敛点：phase 闩防重入，任何后续出口一律 no-op。
    private func finish(with result: CGRect?) {
        guard phase == .selecting else { return }
        phase = .finished
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        overlayView.onMouseDown = nil
        overlayView.onMouseDragged = nil
        overlayView.onMouseUp = nil
        NSCursor.pop()
        window.orderOut(nil)
        onFinish(result)
        selfRetainer = nil // 断开自持：会话自此释放（窗口已收起，无泄漏）
    }
}

// MARK: - RegionSelector（简报 Produces：静态 async 入口，按需调用、不进装配容器）

/// 自定义区域选择器（T13）：用户在目标屏上拖一个框，产出与 `CaptureMode.region` 同坐标系的
/// rect（points、显示器逻辑坐标系）。逐次调用逐次建窗，无状态、不进 AppAssembly。
@MainActor
final class RegionSelector {
    /// 展示 `displayID` 屏的全屏暗色遮罩并等待拖拽：完成返回 CG 显示器全局系 rect；
    /// ESC / 点击无拖动 / 窗口被外部关闭 / 目标屏不在位 → nil。
    static func selectRegion(on displayID: CGDirectDisplayID) async -> CGRect? {
        guard let screen = screen(for: displayID) else { return nil }
        let screenFrame = screen.frame
        let cgOrigin = cgDisplayOrigin(of: screen)
        return await withCheckedContinuation { (continuation: CheckedContinuation<CGRect?, Never>) in
            let session = RegionSelectionSession(
                screenFrame: screenFrame,
                cgDisplayOrigin: cgOrigin,
                onFinish: { continuation.resume(returning: $0) } // session phase 闩保证恰一次
            )
            session.begin()
        }
    }

    /// 窗口区域选择入口（P3b）：在目标窗口 frame 上铺遮罩等待拖拽，返回**窗口相对系**
    /// rect（原点 = 窗口左上、points、y 向下，`CaptureMode.windowRegion` 契约）；ESC /
    /// 亚点拖动 / 遮罩窗被外部关闭 / frame 零面积 → nil。逐次调用逐次建窗，无状态、不进
    /// AppAssembly（同 selectRegion）。目标窗口本身由装配层选择并解析 frame（SCWindow.frame
    /// 经 `RegionSelectorMath.cocoaRect(fromCGRect:primaryScreenHeight:)` 换算）。
    static func selectWindowRegion(anchorFrame: CGRect) async -> CGRect? {
        guard anchorFrame.width >= 1, anchorFrame.height >= 1 else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<CGRect?, Never>) in
            let session = WindowRegionSelectionSession(
                anchorFrame: anchorFrame,
                onFinish: { continuation.resume(returning: $0) } // session phase 闩保证恰一次
            )
            session.begin()
        }
    }

    /// `NSScreen` 按 displayID 匹配：`deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]`。
    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }

    /// 目标屏在 CG 全局系的 bounds 原点（坐标换算锚点）：取 `CGDisplayBounds` 地面真值；
    /// NSScreenNumber 缺失（实践中不可达）时按「主屏高翻 Y」推算兜底。
    static func cgDisplayOrigin(of screen: NSScreen) -> CGPoint {
        if let displayID = displayID(of: screen), !CGDisplayBounds(displayID).isNull {
            return CGDisplayBounds(displayID).origin
        }
        let primaryHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height ?? screen.frame.height
        return CGPoint(x: screen.frame.origin.x, y: primaryHeight - screen.frame.maxY)
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// 全屏遮罩窗口：level 同倒计时覆盖层（屏保层）；`canJoinAllSpaces + fullScreenAuxiliary`
    /// 与浮条/倒计时同款；borderless 不可 key（不抢焦点，点击不激活本 App）。
    static func makeOverlayWindow(frame: NSRect) -> NSWindow {
        let window = SelectionWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = false
        return window
    }

    /// borderless 窗口默认即不可 key；显式钉死「不抢焦点」语义（同 CountdownOverlay 的 OverlayWindow）。
    private final class SelectionWindow: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
}
