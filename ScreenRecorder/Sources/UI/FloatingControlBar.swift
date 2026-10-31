import AppKit
import Combine
import SwiftUI

/// 浮动控制条（T11 Step 5）：红点（录制中呼吸动画）、elapsed（mm:ss）、暂停/恢复、停止、
/// 丢弃（二次点击确认，tooltip 与 OmniRecorder 一致）。仅承载语义与交互，窗口挂载见
/// `FloatingControlBarPanel`；数据直接读 `CaptureController`（elapsed 已排除暂停时长）。
/// 验收修复（2026-10）：丢弃武装逻辑抽出为 `DiscardConfirmation`（本文件，headless 可测）；
/// 武装视觉改红底胶囊白字「再次点击确认丢弃」、disarm 窗口 5s；拖动与位置保留见面板层。
struct FloatingControlBar: View {
    @ObservedObject var controller: CaptureController
    /// 丢弃两击确认唯一真源（抽出的可观察逻辑）：armed 视觉与面板尺寸跟随都订阅它。
    @ObservedObject var discardConfirmation: DiscardConfirmation
    /// 交互热区登记簿（拖拽分流裁定 1）：按钮 frame 上报，宿主视图 mouseDown 据此分流。
    let regionRegistry: InteractiveRegionRegistry
    /// P2 边录边标记：画笔按钮的开关态与切换出口。由 `FloatingControlBarPanel.attachMarkingToggle`
    /// 在装配层接线（rootView 整只换装驱动换装），缺省关闭态/空出口（面板尺寸探测同构）。
    var isMarkingEnabled: Bool = false
    var onToggleMarking: () -> Void = {}
    @State private var autoDisarmTask: Task<Void, Never>?
    @State private var breathing = false

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .scaleEffect(breathing ? 1.35 : 1.0)
                .opacity(controller.state == .paused ? 0.35 : (breathing ? 0.7 : 0.9))
            Text(Self.elapsedText(controller.elapsed))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .frame(minWidth: 46, alignment: .center)
                .help("已录制时长（不含暂停）")
            // P2 边录边标记开关：切换覆盖层与工具条（显隐条件在装配层，spec §5 P2）。
            Button {
                onToggleMarking()
            } label: {
                Image(systemName: isMarkingEnabled ? "paintbrush.pointed.fill" : "paintbrush.pointed")
                    .frame(width: 18, height: 18)
            }
            .help(isMarkingEnabled ? "关闭边录边标记" : "边录边标记")
            .accessibilityLabel(isMarkingEnabled ? "关闭边录边标记" : "边录边标记")
            .reportingInteractiveRegion(to: regionRegistry)
            Button {
                if controller.state == .paused {
                    controller.resume()
                } else {
                    controller.pause()
                }
            } label: {
                Image(systemName: controller.state == .paused ? "play.fill" : "pause.fill")
                    .frame(width: 18, height: 18)
            }
            .help(controller.state == .paused ? "恢复录制" : "暂停录制")
            .accessibilityLabel(controller.state == .paused ? "恢复录制" : "暂停录制")
            .reportingInteractiveRegion(to: regionRegistry)
            Button {
                controller.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .foregroundStyle(.red)
                    .frame(width: 18, height: 18)
            }
            .help("停止并保存录制")
            .accessibilityLabel("停止并保存录制")
            .reportingInteractiveRegion(to: regionRegistry)
            Button {
                handleDiscardTap()
            } label: {
                // 武装视觉（裁定 4）：红底胶囊 + 白字「再次点击确认丢弃」——不可错过；
                // 面板尺寸随本态跟随（FloatingControlBarPanel.updatePanelSize），不再被
                // 钉死的 idle 宽度裁剪。
                if discardConfirmation.isArmed {
                    Text("再次点击确认丢弃")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.red))
                } else {
                    Image(systemName: "trash")
                        .frame(width: 18, height: 18)
                }
            }
            .help("取消录制会丢弃已录制的内容，再次点击确认")
            .accessibilityLabel("丢弃录制")
            .reportingInteractiveRegion(to: regionRegistry)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Capsule().fill(.regularMaterial).shadow(radius: 3))
        // 交互热区汇总上报（按钮 frame 变化——如武装换装后丢弃按钮变宽——即重报）。
        .onPreferenceChange(InteractiveRegionPreferenceKey.self) { regions in
            regionRegistry.replace(regions: regions)
        }
        .onAppear { updateBreathing() }
        .onChange(of: controller.state) { newState in
            updateBreathing()
            // 修复轮 1 Minor #5（保留）：离开录制/暂停（浮条即将隐藏或收尾）即解除丢弃武装，
            // 防止「武装后浮条隐藏 → 新录制重现浮条」时一击即丢。
            if newState != .recording && newState != .paused {
                discardConfirmation.disarm()
                autoDisarmTask?.cancel()
                autoDisarmTask = nil
            }
        }
    }

    private func handleDiscardTap() {
        let now = ProcessInfo.processInfo.systemUptime
        if discardConfirmation.tap(at: now) {
            // 裁定 5：每次弃置 tap 一行可辨日志（真机排查缺陷②机制用——armed 与 confirmed
            // 两行的时间差可判别「双投递 / 首击被吞 / 过期误确认」）。
            NSLog("FloatingBar discard: confirmed")
            autoDisarmTask?.cancel()
            autoDisarmTask = nil
            controller.cancelAndDiscard()
        } else {
            NSLog("FloatingBar discard: armed")
            scheduleAutoDisarm()
        }
    }

    /// 5s 自动解除（裁定 4）的驱动源：只负责到点喂 tick，窗口过期判定收在
    /// `DiscardConfirmation`（定时漂移最多晚解除，不会误确认）。
    private func scheduleAutoDisarm() {
        autoDisarmTask?.cancel()
        autoDisarmTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(DiscardConfirmation.disarmWindow * 1_000_000_000))
            guard !Task.isCancelled else { return }
            discardConfirmation.tick(at: ProcessInfo.processInfo.systemUptime)
        }
    }

    private func updateBreathing() {
        let shouldBreath = controller.state == .recording
        guard breathing != shouldBreath else { return }
        withAnimation(shouldBreath
            ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
            : .easeOut(duration: 0.2)) {
            breathing = shouldBreath
        }
    }

    /// mm:ss（分钟可超 59，长录制不换制式）。
    static func elapsedText(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded(.down))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - 丢弃两击确认（验收修复缺陷②抽出逻辑）

/// 丢弃两击确认：`phase` 是武装态唯一真源，视图据此换装、面板据此跟随尺寸；时间由调用方
/// 逐次注入（`PauseMediaClock` 同款时钟注入形状），全部判定确定、无头可测——首击武装、
/// 武装窗口内再击确认并自动复位、过期（tick 或过期 tap 自校验）解除、显式 `disarm`
/// （离开 recording/paused 的 onChange，修复轮 1 Minor #5 语义保留）。
@MainActor
final class DiscardConfirmation: ObservableObject {
    /// idle：未武装；armed：等待第二次点击确认（红底胶囊可见态）。
    enum Phase: Equatable {
        case idle
        case armed
    }

    /// 武装有效期（裁定 4：3s → 5s）。
    static let disarmWindow: TimeInterval = 5

    @Published private(set) var phase: Phase = .idle
    private var armedAt: TimeInterval = 0

    var isArmed: Bool { phase == .armed }

    /// 一次弃置 tap：未武装（或武装已过期）→ 进入武装返回 false；武装窗口内 → 确认
    /// （自动复位回 idle）返回 true，调用方执行丢弃。
    @discardableResult
    func tap(at now: TimeInterval) -> Bool {
        if phase == .armed, now - armedAt < Self.disarmWindow {
            phase = .idle
            armedAt = 0
            return true
        }
        // 过期武装（自动解除 tick 未及运行）按重新武装处理——绝不误确认。
        phase = .armed
        armedAt = now
        return false
    }

    /// 时钟 tick（视图的自动解除定时喂入）：窗口已过 → 解除；其余无操作。
    func tick(at now: TimeInterval) {
        guard phase == .armed, now - armedAt >= Self.disarmWindow else { return }
        disarm()
    }

    /// 显式解除（确认复位 / 离开 recording-paused 同走此路），幂等。
    func disarm() {
        phase = .idle
        armedAt = 0
    }
}

// MARK: - 拖拽命中分流（验收修复缺陷①）

/// 拖拽命中分流（裁定 1 的纯逻辑缝）：交互热区（按钮）命中 → false（事件交回 SwiftUI，
/// 按钮照常）；未命中（胶囊背景）→ true（宿主视图显式 `performDrag`）。纯函数无头可测。
enum DragSurfaceRouter {
    static func shouldPerformWindowDrag(point: CGPoint, interactiveRegions: [CGRect]) -> Bool {
        !interactiveRegions.contains { $0.contains(point) }
    }
}

/// 交互热区登记簿：SwiftUI 按钮把自己的 frame（SwiftUI `.global`，窗口左上原点）经
/// PreferenceKey 上报至此；宿主 `FloatingBarHostingView.mouseDown` 据此分流。坐标系约定：
/// `NSHostingView` 为 flipped 视图且作为 borderless 面板 contentView 恰好铺满窗口，故事件点
/// `convert(_:from: nil)` 后与 `.global` 同一空间。
@MainActor
final class InteractiveRegionRegistry {
    private(set) var regions: [CGRect] = []

    func replace(regions: [CGRect]) {
        self.regions = regions
    }
}

private struct InteractiveRegionPreferenceKey: PreferenceKey {
    static var defaultValue: [CGRect] = []

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

private extension View {
    /// 登记本视图为交互热区（背景 GeometryReader 上报 `.global` frame，布局变化即重报）。
    func reportingInteractiveRegion(to registry: InteractiveRegionRegistry) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: InteractiveRegionPreferenceKey.self,
                    value: [proxy.frame(in: .global)])
            }
        )
    }
}

// MARK: - PiP 小窗拖动锚点（T15，未改动）

/// PiP 小窗拖动锚点（T15）：浮窗初始摆放与浮条的避让关系——浮条钉在可视区顶部居中，
/// PiP 锚在右上角；若可视区窄到两者重叠，PiP 整体下移到浮条下方（不遮浮条）。拖动开始后
/// 位置由浮窗自行汇报（frame 变化实时进合成器），本函数只管首次锚点（纯函数，无头钉测）。
enum PiPLacementAnchor {
    /// PiP 浮窗尺寸（points，前置摄像头 4:3）。
    static let pipSize = CGSize(width: 160, height: 120)
    /// 距可视区边缘 / 浮条的留边。
    static let edgeMargin: CGFloat = 12

    /// 初始锚点：可视区右上角；与浮条重叠时下移至浮条下方（仍完整在可视区内）。
    static func defaultFrame(visibleFrame: CGRect, controlBarFrame: CGRect?) -> CGRect {
        var frame = CGRect(
            x: visibleFrame.maxX - pipSize.width - edgeMargin,
            y: visibleFrame.maxY - pipSize.height - edgeMargin,
            width: pipSize.width,
            height: pipSize.height)
        if let bar = controlBarFrame, bar.intersects(frame) {
            frame.origin.y = bar.minY - pipSize.height - edgeMargin
        }
        return frame
    }
}

// MARK: - 浮条宿主视图（验收修复缺陷①：显式拖动）

/// 浮条宿主视图：borderless + nonactivating NSPanel 上 `isMovableByWindowBackground`
/// 真机不可靠（简报定位的 AppKit 已知行为），改为 `mouseDown` 显式 `performDrag(with:)`
/// ——非激活无边框面板的确定可用方案（裁定 1）。分流：交互热区（按钮）命中交回 SwiftUI
/// （`super`，按钮行为不变），未命中（胶囊背景）启动窗口拖动；`performDrag` 全程不激活
/// App，nonactivating 语义红线不变（裁定 2）。
final class FloatingBarHostingView: NSHostingView<FloatingControlBar> {
    var regionRegistry: InteractiveRegionRegistry?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if DragSurfaceRouter.shouldPerformWindowDrag(
            point: point,
            interactiveRegions: regionRegistry?.regions ?? []) {
            window?.performDrag(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }
}

/// 浮条的 NSPanel 承载（简报：`styleMask: [.borderless, .nonactivatingPanel]`、
/// `level: .floating`、默认屏幕顶部居中、可拖动）。由 ScreenRecorderApp 装配点创建并持有；
/// 显隐随 `CaptureController.state`：`.recording`/`.paused` 显示，其余（idle/countdown/
/// finishing）隐藏。附加裁定：`canJoinAllSpaces + fullScreenAuxiliary`——全屏应用录制时浮条
/// 仍可见且不抢占全屏空间；`orderFrontRegardless` 不夺焦点（配合 nonactivatingPanel）。
/// 验收修复（2026-10）：拖动显式化（宿主视图 `performDrag`，本层关闭 background-move）；
/// 位置会话内保留（裁定 3：首次显示顶部居中，此后保留用户拖过的 frame）；武装态尺寸跟随。
@MainActor
final class FloatingControlBarPanel {
    private let panel: NSPanel
    private let controller: CaptureController
    /// 宿主视图（P2 标记开关接线换装用）：rootView 整只替换驱动 SwiftUI 重新求值。
    private let hostingView: FloatingBarHostingView
    /// 丢弃两击确认真源（视图与面板共享订阅：视图换装、本层跟随尺寸）。
    private let discardConfirmation = DiscardConfirmation()
    private let regionRegistry = InteractiveRegionRegistry()
    private var stateObservation: AnyCancellable?
    private var armedObservation: AnyCancellable?
    /// P2 标记开关接线（attachMarkingToggle 注入；nil = 未接线，按钮呈现关闭态/空出口）。
    private var markingEnabledProvider: (() -> Bool)?
    private var onToggleMarkingAction: (() -> Void)?
    private var isShowing = false
    /// 裁定 3（缺陷①）：位置会话内保留——首次显示定位，此后显示不重置。
    private var hasShownThisSession = false

    /// PiP 拖动锚点（T15）数据源：浮条当前在屏坐标的 frame（PiP 初始摆放避让用）。
    var screenFrame: NSRect { panel.frame }

    init(controller: CaptureController) {
        self.controller = controller
        let hostingView = FloatingBarHostingView(rootView: FloatingControlBar(
            controller: controller,
            discardConfirmation: discardConfirmation,
            regionRegistry: regionRegistry))
        self.hostingView = hostingView
        hostingView.regionRegistry = regionRegistry
        let contentSize = hostingView.fittingSize
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // 缺陷①：该属性在 borderless + nonactivating NSPanel 上真机不可靠（AppKit 已知
        // 行为），拖动改由 FloatingBarHostingView.mouseDown 显式 performDrag；此处置 false
        // 消除双路径（AppKit 自带 background-move 与显式拖动互斥，保证单一定义行为）。
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hostingView

        // @Published state 在主线程发布；Task 主 actor 跳转保序，显隐操作全部回到主 actor。
        stateObservation = controller.$state.sink { [weak self] state in
            Task { @MainActor in self?.apply(state) }
        }
        // 武装态尺寸跟随（缺陷②）：红底胶囊文案比 trash 图标宽，面板若钉死 idle 尺寸，
        // 武装态会被裁剪（真机「无可见确认」的主嫌疑机制，见修复报告）。`$phase` 值流在
        // 变更后投递（对照 objectWillChange 的变更前语义），据此离屏重测 fittingSize。
        armedObservation = discardConfirmation.$phase.sink { [weak self] _ in
            Task { @MainActor in self?.updatePanelSize() }
        }
    }

    // MARK: 边录边标记开关接线（P2，AppAssembly 在装配完成后调用）

    /// 注入画笔按钮的开关态读缝与切换出口，并按当前值立即换装（装配期一次性挂载，无
    /// 订阅副作用）。开关真源在 AppAssembly（@Published markingEnabled，会话态不持久化）；
    /// **录制中的态变化**走 `refreshMarkingToggle(enabled:)` 发射值直传换装。
    func attachMarkingToggle(provider: @escaping () -> Bool, toggle: @escaping () -> Void) {
        markingEnabledProvider = provider
        onToggleMarkingAction = toggle
        refreshRootView(enabled: provider())
    }

    /// 开关态变化换装（装配层 `refreshMarkingSurfaces` 每次 state/开关变化时调；幂等——
    /// 重复调用仅重赋 rootView，无重挂载副作用）。参数为 CombineLatest **发射值直传**
    /// （willSet 阶段 provider 回拉是旧值，修复轮2 Critical 1 同款约束），不得回拉 provider。
    func refreshMarkingToggle(enabled: Bool) {
        refreshRootView(enabled: enabled)
    }

    private func refreshRootView(enabled: Bool) {
        hostingView.rootView = FloatingControlBar(
            controller: controller,
            discardConfirmation: discardConfirmation,
            regionRegistry: regionRegistry,
            isMarkingEnabled: enabled,
            onToggleMarking: { [weak self] in self?.onToggleMarkingAction?() })
    }

    private func apply(_ state: CaptureState) {
        switch state {
        case .recording, .paused:
            guard !isShowing else { return }
            // 裁定 3（缺陷①）：会话内首次显示定位顶部居中；同会话后续显示保留用户拖过的
            // frame（不再每次重置）。App 重启时本对象随装配容器重建，自然回居中（跨会话
            // 不要求记忆）。
            if !hasShownThisSession, positionTopCenter() {
                hasShownThisSession = true
            }
            panel.orderFrontRegardless()
            isShowing = true
        case .idle, .countdown, .finishing:
            guard isShowing else { return }
            panel.orderOut(nil)
            isShowing = false
        }
    }

    /// 主屏可视区顶部居中；返回是否实际定位——App 启动极早期 NSScreen.main 可能为 nil，
    /// 此时返回 false，由调用方不置位、下次显示兜底重定位。
    @discardableResult
    private func positionTopCenter() -> Bool {
        guard let screen = NSScreen.main else { return false }
        let frame = panel.frame
        let visible = screen.visibleFrame
        panel.setFrameOrigin(
            NSPoint(x: visible.midX - frame.width / 2,
                    y: visible.maxY - frame.height - 12)
        )
        return true
    }

    /// 武装态尺寸跟随：离屏探测视图重测 fittingSize，保持 midX 与 maxY 居中扩缩（不跳位、
    /// 不重置用户拖过的位置）。尺寸未变时为无操作（含订阅初始值投递）。
    private func updatePanelSize() {
        let probe = NSHostingView(rootView: FloatingControlBar(
            controller: controller,
            discardConfirmation: discardConfirmation,
            regionRegistry: regionRegistry))
        let newSize = probe.fittingSize
        guard newSize.width > 0, newSize != panel.frame.size else { return }
        let old = panel.frame
        panel.setFrame(
            NSRect(x: old.midX - newSize.width / 2,
                   y: old.maxY - newSize.height,
                   width: newSize.width,
                   height: newSize.height),
            display: true)
    }
}
