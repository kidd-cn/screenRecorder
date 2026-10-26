import AppKit
import Combine
import SwiftUI

// MARK: - 视图模型（状态机每秒 tick 的数字快照）

/// 倒计时数字快照：nil = 未显示。show/hide 与逐秒换数都写这里，SwiftUI 据此驱动过渡。
@MainActor
final class CountdownOverlayModel: ObservableObject {
    @Published var secondsLeft: Int?
}

// MARK: - 全屏倒计时视图

/// 大号数字 5→1 逐秒过渡：`.id(secondsLeft)` 令每步数字获得新身份，配合 scale+opacity
/// transition，切换动画由 SwiftUI 承担（每秒 tick 已由 CaptureController 状态机驱动，视图层
/// 只做过渡）。点击任意处取消（窗口 `canBecomeKey == false`，点击不会激活本 App）。
private struct CountdownOverlayView: View {
    @ObservedObject var model: CountdownOverlayModel
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            // 轻遮罩：数字在任何桌面上可读，同时保留「透明覆盖层」观感（不遮挡操作视线）
            Rectangle().fill(Color.black.opacity(0.2))
            if let seconds = model.secondsLeft {
                Text("\(seconds)")
                    .font(.system(size: 240, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.white)
                    .shadow(color: .black.opacity(0.55), radius: 24, y: 4)
                    .id(seconds)
                    .transition(.scale(scale: 1.6).combined(with: .opacity))
            }
            VStack {
                Spacer()
                Text("即将开始录制 · 点击屏幕或按 ESC 取消")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .shadow(color: .black.opacity(0.5), radius: 6)
                    .padding(.bottom, 64)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onCancel() }
        .ignoresSafeArea()
    }
}

// MARK: - 窗口（全屏透明、不抢焦点、最上层）

/// borderless 窗口默认即不可 key；显式钉死「不抢焦点」语义（点覆盖层/其他 App 均不失焦）。
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - CountdownOverlayController

/// 倒计时覆盖层控制器（T12，简报 Produces）：`CaptureController.$state` 驱动（与
/// `FloatingControlBarPanel` 同款订阅模式）——`.countdown` → `show(seconds:onCancel:)`
/// （逐秒 tick 复用显示仅换数字），离开 countdown（取消/完成/失败收尾）→ `hide()`；取消路径
/// 同样经状态变化收束，覆盖层不自行改状态。ESC/点击出口由装配层注入（AppAssembly 接
/// `CaptureController.cancelAndDiscard()`）。简报钉死主屏一屏（YAGNI），以 `NSScreen.main?.frame`
/// 定位。窗口懒创建、多次倒计时复用；所有权归 AppAssembly（修复轮 1 装配纪律）。
@MainActor
final class CountdownOverlayController {
    /// 数字快照（视图 ObservedObject）；internal 供无头测试断言 show/hide 逻辑。
    let model = CountdownOverlayModel()

    private let onCancelAction: () -> Void
    private let windowFactory: () -> NSWindow
    private var window: NSWindow?
    private var stateObservation: AnyCancellable?
    private var keyMonitor: Any?
    private var activeCancel: (() -> Void)?
    private var isShowing = false

    /// - Parameters:
    ///   - controller: 状态源（`$state` 订阅）。
    ///   - onCancelAction: ESC/点击的取消出口（装配层接 `cancelAndDiscard()`；覆盖层不碰状态）。
    ///   - windowFactory: 测试缝——无头测试注入不真正上屏的记录窗口。
    init(controller: CaptureController,
         onCancelAction: @escaping () -> Void,
         windowFactory: @escaping () -> NSWindow = CountdownOverlayController.makeDefaultWindow) {
        self.onCancelAction = onCancelAction
        self.windowFactory = windowFactory
        // @Published state 在主线程发布；Task 主 actor 跳转保序，显隐操作全部回到主 actor。
        stateObservation = controller.$state.sink { [weak self] state in
            Task { @MainActor in self?.apply(state) }
        }
    }

    // MARK: 简报 Produces 逐字

    /// 显示覆盖层（已在显示则只更新数字，不重复 orderFront）；onCancel 为 ESC/点击出口。
    func show(seconds: Int, onCancel: @escaping () -> Void) {
        activeCancel = onCancel
        let window: NSWindow
        if let existing = self.window {
            window = existing
        } else {
            window = windowFactory()
            window.contentView = NSHostingView(
                rootView: CountdownOverlayView(
                    model: model,
                    onCancel: { [weak self] in self?.performCancel() }
                )
            )
            self.window = window
        }
        if let screen = NSScreen.main {
            window.setFrame(screen.frame, display: false) // 主屏全屏；每次显示重定位（主屏可变）
        }
        if !isShowing {
            window.orderFrontRegardless() // 不夺焦点（配合 canBecomeKey == false）
            isShowing = true
            installKeyMonitor()
        }
        setNumber(seconds)
    }

    /// 收起覆盖层：移除 ESC monitor + orderOut + 数字清空。由状态离开 `.countdown` 收束调用。
    func hide() {
        guard isShowing else { return }
        removeKeyMonitor()
        window?.orderOut(nil)
        isShowing = false
        activeCancel = nil
        model.secondsLeft = nil
    }

    /// ESC monitor 与点击手势共用的取消入口：只调注入的取消出口，覆盖层不自行改状态。
    func performCancel() {
        guard isShowing else { return }
        activeCancel?()
    }

    // MARK: 状态驱动

    private func apply(_ state: CaptureState) {
        switch state {
        case .countdown(let secondsLeft):
            show(seconds: secondsLeft, onCancel: onCancelAction)
        case .idle, .recording, .paused, .finishing:
            hide()
        }
    }

    private func setNumber(_ seconds: Int) {
        guard model.secondsLeft != seconds else { return }
        withAnimation(.easeOut(duration: 0.28)) { model.secondsLeft = seconds }
    }

    // MARK: ESC（本地事件 monitor：覆盖层不 key，keyDown 须经全局分发口截获）

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, Self.isEscapeKey(event) else { return event }
            self.performCancel()
            return nil // ESC 消费掉：取消倒计时，不再传给其他响应者
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    /// ESC 判定：keyCode 53（美式布局）或 Unicode 转义符（非美式布局兼容）；monitor 与测试共用。
    nonisolated static func isEscapeKey(_ event: NSEvent) -> Bool {
        event.keyCode == 53 || event.charactersIgnoringModifiers == "\u{1b}"
    }

    // MARK: 默认窗口工厂

    /// 主屏全屏透明窗口：level 取屏保层（1000，高于浮条 `.floating`——倒计时在最上层）；
    /// `canJoinAllSpaces + fullScreenAuxiliary` 与浮条同款（全屏应用之上仍可见、不占全屏空间）。
    private static func makeDefaultWindow() -> NSWindow {
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let window = OverlayWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.ignoresMouseEvents = false
        return window
    }
}
