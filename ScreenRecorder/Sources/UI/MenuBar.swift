import AppKit
import CoreGraphics
import SwiftUI

/// 菜单栏主面板（2026-11-14 Omi 化改版）：由 NSMenu 式菜单改为 `.menuBarExtraStyle(.window)`
/// 卡片面板（系统 scene 窗，SwiftUI 控件激活通道可用；装配闭包缝 T17 原样保留）。
/// 结构（对照 OmniRecorder RecordingStatusBarVC 的面板形态）：
/// - 状态头卡（状态磁贴 + 标题/副标题 + 录制中 elapsed）；
/// - 录制模式宫格（全屏=显示器列表 Menu / 窗口 / App / 区域 / 窗口区域 / 仅声音 / 仅摄像头，
///   非会话态置灰）、截图宫格（区域 / 全屏=显示器列表 Menu）（Q1/P3/P7 同语义）；
/// - 会话控制行（暂停/恢复、重新录制 Q3、停止——仅会话活动态出现）；
/// - 功能列表卡（定时录制 P6b、取消定时[条件]、画中画开关、文件列表、偏好设置、关于、退出）。
/// 交互全部走 Button/Toggle/Menu（控件激活 + 系统弹层）；`.window` 面板点击外部收起
///（原生菜单的「点击即收」语义由面板外点承接，已知行为，可接受）。
struct MenuBarView: View {
    @ObservedObject var controller: CaptureController
    /// 摄像头画中画开关绑定（T15 同一 `@Published`：菜单与偏好设置窗口同源实时同步）。
    /// 快照语义：翻转只影响下一场录制（开始时刻由装配层读入 config）。
    @ObservedObject var settings: SettingsStore
    /// 定时录制调度器（P6b）：排程态（`active`）驱动「取消定时录制」项的显隐；呈现与
    /// 取消都走装配层闭包缝（窗口所有权与调度器所有权归 AppAssembly，同 T17 装配红线）。
    @ObservedObject var scheduler: RecordingScheduler
    /// 开始全屏录制指定显示器（「全屏」磁贴的显示器列表 Menu 项）。
    let onStartDisplay: (CGDirectDisplayID) -> Void
    /// 打开窗口选择器、选定即开始录制（复用 ⇧⌘W 的选择器路径，T20）。
    let onStartWindowPicker: () -> Void
    /// 打开 App 选择器（P3a，App 范围）、选定 bundleID 即开始录制。
    let onStartAppPicker: () -> Void
    /// 区域录制：RegionSelector 拖拽选区后开录（选区交互逻辑归 RegionSelector，不在此复制）。
    let onStartRegion: () -> Void
    /// 窗口区域录制（P3b）：窗口选择器（窗口范围）→ 窗口内拖框 → 按所选窗口 + 窗口相对
    /// rect 开录（编排归 AppAssembly，同其他入口）。
    let onStartWindowRegion: () -> Void
    /// 仅声音录制（P7a）：不采集视频，落盘纯音轨 .m4a（编排归 AppAssembly，同其他入口）。
    let onStartAudioOnly: () -> Void
    /// 仅摄像头录制（P7b）：录制源是前置摄像头，落盘 mp4 视频文件（编排归 AppAssembly，
    /// 同其他入口）。
    let onStartCameraOnly: () -> Void
    /// 重新录制（Q3）：丢弃当前录制并立即重开同模式（编排归 AppAssembly，浮条按钮同出口；
    /// 可用窗口同暂停/停止——仅 recording/paused）。
    let onRestartRecording: () -> Void
    /// 区域截图（Q1）：RegionSelector 拖框后裁剪落盘 PNG（编排归 AppAssembly，同区域录制）。
    let onTakeRegionScreenshot: () -> Void
    /// 全屏截图指定显示器（Q1，显示器列表 Menu 项，编排归 AppAssembly）。
    let onTakeFullScreenScreenshot: (CGDirectDisplayID) -> Void
    /// 打开文件列表窗口（T18，窗口与控制器归 AppAssembly，见 T17 装配红线）。
    let onOpenRecordingList: () -> Void
    /// 打开定时录制面板（P6b，窗口归 AppAssembly，见 openScheduledRecordingPanel）。
    let onOpenScheduledPanel: () -> Void
    /// 取消当前定时排程（仅排程等待期出现；调度器 cancel 即清排程与停录等待）。
    let onCancelScheduled: () -> Void
    /// 打开偏好设置窗口（窗口与控制器归 AppAssembly，见 T17 装配红线）。
    let onOpenPreferences: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: OmiStyle.sectionSpacing) {
            headerCard
            if isSessionActive {
                sessionControlsCard
            }
            OmiCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("开始录制").font(.caption).foregroundStyle(.secondary)
                    modeGrid
                    Text("截图").font(.caption).foregroundStyle(.secondary)
                        .padding(.top, 4)
                    screenshotGrid
                }
            }
            functionListCard
        }
        .padding(12)
        .frame(width: 312)
        .background(OmiStyle.panelBackground)
        .background(PanelWindowMarker()) // 面板窗口标识（dismissPanelWindow 定位用）
        // 起录自动收面板（2026-11-14 用户目验裁定「开始录制后只留浮条」）：状态离开
        // idle 即收起——覆盖宫格各入口与全局快捷键/定时起录（面板开着时）。收起只对
        // 本面板窗口 orderOut，不触碰其它窗口。
        .onChange(of: controller.state) { newState in
            if newState != .idle {
                dismissPanelWindow()
            }
        }
    }

    /// 收起本面板（MenuBarExtra `.window` 无编程关闭 API）。面板窗口由
    /// `PanelWindowMarker` 打上 `SRMenuBarPanel` identifier（不依赖宿主泛型名），
    /// 面板未开时为无操作。先投 Escape（优先原生取消路径），orderOut 兜底。
    private func dismissPanelWindow() {
        guard let panel = NSApp.windows.first(where: {
            $0.identifier?.rawValue == "SRMenuBarPanel"
        }) else { return }
        if let escape = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53) {
            NSApp.postEvent(escape, atStart: false)
        }
        panel.orderOut(nil)
    }

    // MARK: 状态头卡（裁定 2：面板反映状态机）

    /// 会话活动态（暂停/恢复与停止的可用窗口）。
    private var isSessionActive: Bool {
        controller.state == .recording || controller.state == .paused
    }

    private var headerCard: some View {
        HStack(spacing: 10) {
            OmiTileIcon(icon: headerTile.icon, tint: headerTile.tint, tileSize: 40, symbolSize: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTile.title).font(.callout.weight(.semibold))
                if let subtitle = headerTile.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if controller.state == .recording || controller.state == .paused {
                Text(FloatingControlBar.elapsedText(controller.elapsed))
                    .font(.system(.callout, design: .monospaced).weight(.medium))
                    .foregroundStyle(controller.state == .paused ? Color.secondary : OmiStyle.accent)
            }
        }
        .padding(OmiStyle.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: OmiStyle.cardRadius)
                .fill(OmiStyle.cardBackground))
    }

    /// 头卡磁贴逐态映射（MenuBarStatusIcon 同一状态机，面板内的放大表达）。
    private var headerTile: (icon: String, tint: OmiStyle.TileTint, title: String, subtitle: String?) {
        switch controller.state {
        case .idle:
            return scheduler.active != nil
                ? ("timer", .orange, "定时待录", "排程已就绪，到点自动开始")
                : ("record.circle", .red, "待命", "选择下方模式开始录制")
        case .countdown(let secondsLeft):
            return ("timer", .orange, "倒计时中…（\(secondsLeft)s）", "即将开始录制")
        case .recording:
            return ("dot.radiowaves.left.and.right", .red, "录制中", nil)
        case .paused:
            return ("pause.circle", .orange, "已暂停", "时长不含暂停段")
        case .finishing:
            return ("hourglass", .gray, "收尾中…", "正在落盘成片")
        }
    }

    // MARK: 会话控制卡（暂停/恢复 · 重新录制（两击确认） · 停止）

    /// 重录两击确认真源（浮条 `FloatingControlBar` 同一 `DiscardConfirmation` 类——
    /// 2026-11-14 用户目验裁定：主面板与浮条行为必须一致，单击直执行会无确认丢弃成片）。
    @StateObject private var restartConfirmation = DiscardConfirmation()
    /// 武装态 5s 自动解除驱动（浮条 scheduleRestartAutoDisarm 同构）。
    @State private var restartAutoDisarmTask: Task<Void, Never>?

    private var sessionControlsCard: some View {
        HStack(spacing: 8) {
            controlPill(
                title: controller.state == .paused ? "恢复" : "暂停",
                icon: controller.state == .paused ? "play.fill" : "pause.fill",
                tint: .blue) {
                if controller.state == .paused {
                    controller.resume()
                } else {
                    controller.pause()
                }
            }
            // 重录 = 丢弃已录内容（破坏性）：两击确认，武装视觉与浮条逐字同款
            //（红底胶囊白字「再次点击确认重录」，lineLimit(1)+fixedSize 防约束循环）。
            Button {
                handleRestartTap()
            } label: {
                if restartConfirmation.isArmed {
                    Text("再次点击确认重录")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.red))
                } else {
                    controlPillLabel("重录", icon: "arrow.counterclockwise", tint: .purple)
                }
            }
            .buttonStyle(.plain)
            .help("重新录制会丢弃已录制的内容，再次点击确认")
            .accessibilityLabel(restartConfirmation.isArmed ? "再次点击确认重录" : "重新录制")
            Spacer()
            controlPill(title: "停止", icon: "stop.fill", tint: .red, filled: true) {
                controller.stop()
            }
        }
        .onChange(of: controller.state) { newState in
            // 离开录制/暂停（面板即将随会话收场）即解除武装——与浮条同一纪律。
            if newState != .recording && newState != .paused {
                restartConfirmation.disarm()
                cancelRestartAutoDisarm()
            }
        }
    }

    /// 两击判定（handleRestartTap 同构）：首击武装 + 调度 5s 自动解除；窗口内再击确认
    /// → 出口重录编排。时钟注入与过期自校验收在 `DiscardConfirmation`。
    private func handleRestartTap() {
        let now = ProcessInfo.processInfo.systemUptime
        if restartConfirmation.tap(at: now) {
            cancelRestartAutoDisarm()
            onRestartRecording()
        } else {
            scheduleRestartAutoDisarm()
        }
    }

    private func scheduleRestartAutoDisarm() {
        restartAutoDisarmTask?.cancel()
        restartAutoDisarmTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(DiscardConfirmation.disarmWindow * 1_000_000_000))
            guard !Task.isCancelled else { return }
            restartConfirmation.tick(at: ProcessInfo.processInfo.systemUptime)
        }
    }

    private func cancelRestartAutoDisarm() {
        restartAutoDisarmTask?.cancel()
        restartAutoDisarmTask = nil
    }

    /// 胶囊控制钮（磁贴同语言的横排形态；filled = 主红底白字，停止语义）。
    private func controlPill(title: String, icon: String, tint: OmiStyle.TileTint,
                             filled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            controlPillLabel(title, icon: icon, tint: tint,
                             filled: filled)
        }
        .buttonStyle(.plain)
    }

    private func controlPillLabel(_ title: String, icon: String, tint: OmiStyle.TileTint,
                                  filled: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
            Text(title).font(.callout.weight(.medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(filled
                ? Color(nsColor: OmiStyle.tintNS(tint))
                : Color(nsColor: OmiStyle.tintNS(tint)).opacity(0.14)))
        .foregroundStyle(filled
            ? Color.white
            : Color(nsColor: OmiStyle.tintNS(tint)))
    }

    // MARK: 模式宫格（录制 7 模式 + 截图 2 入口；非会话态整体置灰）

    private var modeGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                  spacing: 10) {
            displayMenuTile("全屏", icon: "display", tint: .blue) { onStartDisplay($0) }
            OmiTileButton(title: "窗口", icon: "macwindow", tint: .blue,
                          isEnabled: isIdle) { onStartWindowPicker() }
            OmiTileButton(title: "App", icon: "square.grid.2x2", tint: .indigo,
                          isEnabled: isIdle) { onStartAppPicker() }
            OmiTileButton(title: "区域", icon: "crop", tint: .teal,
                          isEnabled: isIdle) {
                dismissPanelWindow() // 全屏选区遮罩不被面板遮挡
                onStartRegion()
            }
            OmiTileButton(title: "窗口区域", icon: "rectangle.on.rectangle", tint: .teal,
                          isEnabled: isIdle) {
                dismissPanelWindow() // 窗口选择→窗内拖框，遮罩链不被面板遮挡
                onStartWindowRegion()
            }
                .accessibilityLabel("窗口区域录制：选择一个窗口后，在其内部拖框选定录制范围")
            OmiTileButton(title: "仅声音", icon: "waveform", tint: .purple,
                          isEnabled: isIdle) { onStartAudioOnly() }
                .accessibilityLabel("仅声音录制：只录系统声音与麦克风，输出 m4a 音频文件")
            OmiTileButton(title: "仅摄像头", icon: "video", tint: .orange,
                          isEnabled: isIdle) { onStartCameraOnly() }
        }
    }

    private var screenshotGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                  spacing: 10) {
            OmiTileButton(title: "区域截图", icon: "viewfinder", tint: .green,
                          isEnabled: isIdle) {
                dismissPanelWindow() // 全屏选区遮罩不被面板遮挡
                onTakeRegionScreenshot()
            }
            displayMenuTile("全屏截图", icon: "photo", tint: .green) {
                dismissPanelWindow() // 整屏截图不收面板会把自己拍进去（CG 路径即刻取帧）
                onTakeFullScreenScreenshot($0)
            }
        }
    }

    private var isIdle: Bool { controller.state == .idle }

    /// 显示器列表磁贴（多显示器选择语义保留）。命名同旧菜单：本地化屏名 + points，
    /// 主屏追加「（主）」。标签与 OmiTileButton 共用 `OmiTileLabel`（逐字同构）。
    private func displayMenuTile(_ title: String, icon: String, tint: OmiStyle.TileTint,
                                 action: @escaping (CGDirectDisplayID) -> Void) -> some View {
        DisplayMenuTile(
            title: title, icon: icon, tint: tint, isIdle: isIdle,
            options: displayOptions.map { ($0.name, $0.isMain, $0.displayID) },
            onSelect: action)
    }

    // MARK: 功能列表卡（定时 / 画中画 / 文件列表 / 偏好设置 / 关于 / 退出）

    private var functionListCard: some View {
        OmiCard {
            VStack(alignment: .leading, spacing: 2) {
                functionRow(icon: "calendar", tint: .orange, title: "定时录制…") {
                    onOpenScheduledPanel()
                }
                if scheduler.active != nil {
                    functionRow(icon: "xmark.circle", tint: .red, title: "取消定时录制") {
                        onCancelScheduled()
                    }
                }
                // 开关行与 functionRow 同构（OmiRowIcon 磁贴 + 文字 + 尾随开关）——修
                // 「画中画行裸符号+小号开关、开关不靠右」的风格漂移（2026-11-14 目验反馈）。
                Toggle(isOn: $settings.pipEnabled) {
                    HStack(spacing: 8) {
                        OmiRowIcon(icon: "person.crop.rectangle", tint: .blue)
                        Text("摄像头画中画").font(.callout)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .toggleStyle(.switch)
                .padding(.vertical, 4)
                .accessibilityLabel("摄像头画中画开关：翻转只影响下一场录制")
                Divider()
                functionRow(icon: "list.bullet", tint: .blue, title: "文件列表…") {
                    onOpenRecordingList()
                }
                functionRow(icon: "gearshape", tint: .gray, title: "偏好设置…") {
                    onOpenPreferences()
                }
                Divider()
                HStack(spacing: 16) {
                    functionRow(icon: "info.circle", tint: .gray, title: "关于") {
                        NSApplication.shared.orderFrontStandardAboutPanel(nil)
                    }
                    functionRow(icon: "power", tint: .red, title: "退出") {
                        NSApplication.shared.terminate(nil)
                    }
                    Spacer()
                }
            }
        }
    }

    /// 功能行（列表卡内的小行钮；OmiRowIcon 磁贴 + 文本）。
    private func functionRow(icon: String, tint: OmiStyle.TileTint, title: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                OmiRowIcon(icon: icon, tint: tint)
                Text(title).font(.callout)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
    }

    // MARK: 显示器列表（「全屏」与「全屏截图」共用同一数据源与命名，旧菜单同源零复制）

    /// `NSScreen` → 菜单项的最小展示模型（Identifiable 用 displayID，屏列表变化由菜单
    /// 每次打开重建覆盖）。
    private struct DisplayOption: Identifiable {
        let displayID: CGDirectDisplayID
        let name: String
        let isMain: Bool
        var id: CGDirectDisplayID { displayID }
    }

    private var displayOptions: [DisplayOption] {
        NSScreen.screens.compactMap { screen in
            guard let displayID = Self.displayID(of: screen) else { return nil }
            return DisplayOption(
                displayID: displayID,
                name: "\(screen.localizedName)（\(Int(screen.frame.width))×\(Int(screen.frame.height))）",
                isMain: displayID == CGMainDisplayID())
        }
    }

    /// 与 `RegionSelector` 同口径的 displayID 读取（deviceDescription NSScreenNumber）。
    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// 显示器列表磁贴（多显示器选择入口）：点击经 `NSMenu.popUp` 就地弹出列表——系统
/// 弹层恒在面板之上（2026-11-14 用户目验裁定「弹出框必须在主界面之上」；SwiftUI
/// `Menu` 在 MenuBarExtra `.window` 内的弹层会被面板压住，弃用）。条目分发复用
/// 列表窗的 `RetainingMenu`/`MenuActionProxy`（target 弱引用 → 菜单子类强持有同寿命）。
/// 磁贴视觉与 `OmiTileButton` 共用 `OmiTileLabel`。
private struct DisplayMenuTile: View {
    let title: String
    let icon: String
    let tint: OmiStyle.TileTint
    let isIdle: Bool
    /// 显示器列表（名称 / 主屏标记 / displayID）。
    let options: [(name: String, isMain: Bool, displayID: CGDirectDisplayID)]
    let onSelect: (CGDirectDisplayID) -> Void

    /// 磁贴在窗口系（SwiftUI .global，左上原点）的 frame——弹出锚点用。
    @State private var tileFrame: CGRect = .zero

    var body: some View {
        Button {
            presentDisplayMenu()
        } label: {
            OmiTileLabel(title: title, icon: icon, tint: tint, isEnabled: isIdle)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { tileFrame = geo.frame(in: .global) }
                            .onChange(of: geo.frame(in: .global)) { tileFrame = $0 }
                    })
        }
        .buttonStyle(.plain)
        .disabled(!isIdle)
    }

    private func presentDisplayMenu() {
        guard let panel = NSApp.windows.first(where: {
            $0.identifier?.rawValue == "SRMenuBarPanel"
        }), let content = panel.contentView else { return }
        let menu = RetainingMenu()
        menu.autoenablesItems = false
        var proxies: [MenuActionProxy] = []
        for option in options {
            let displayID = option.displayID
            let proxy = MenuActionProxy { onSelect(displayID) }
            let item = NSMenuItem(
                title: option.isMain ? "\(option.name)（主）" : option.name,
                action: #selector(MenuActionProxy.picked), keyEquivalent: "")
            item.target = proxy
            menu.addItem(item)
            proxies.append(proxy)
        }
        menu.retainedProxies = proxies
        // 磁贴左下角（flipped 系里 y 取 maxY）——弹层自磁贴下缘向下展开。
        menu.popUp(positioning: nil, at: CGPoint(x: tileFrame.minX, y: tileFrame.maxY), in: content)
    }
}

/// 面板窗口标识器：随本视图挂进 MenuBarExtra 面板窗口，给窗口打上
/// `SRMenuBarPanel` identifier——`dismissPanelWindow` 据此定位（`.window` 面板无
/// 编程关闭 API，窗口也不便按宿主泛型名识别）。同窗口补 `sharingType = .none`
/// 显式采集排除（二期教训：SCK 不隐式排除本进程窗口；面板是浮窗/浮条/全屏视图
/// 之外的第四类悬浮 UI——否则面板入成片/入整屏截图，2026-11-14 用户目验）。
private struct PanelWindowMarker: NSViewRepresentable {
    static let identifier = NSUserInterfaceItemIdentifier("SRMenuBarPanel")

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            view?.window?.identifier = Self.identifier
            view?.window?.sharingType = .none
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.window?.identifier = Self.identifier
        view.window?.sharingType = .none
    }
}

/// 菜单栏状态图标（T19）：随 `CaptureController.state` 实时换装（作为 MenuBarExtra 的
/// label 独立观察控制器，App body 不因录制状态重跑）。逐态选择与理由：
/// - `.idle` → `record.circle`（brief 指定：空心录制圈 = 待命）；**有定时排程等待时
///   （P6b）→ `timer`**（简报钉定：排程等待期状态图标用既有倒计时态——「已排定、
///   即将开始」与倒计时同一视觉语言；active 消费/取消即回空心圈）。
/// - `.countdown` → `timer`（倒计时数字在屏幕覆盖层上，菜单栏用计时器符号给「已触发、
///   即将开始」的反馈；每秒换数字不做——图标语义不变，避免逐秒抖动）。
/// - `.recording` → 红色实心 `stop.circle.fill`（brief 指定：实心 + 红色与 idle 空心形成
///   风格区分；停止=红色语义与浮条停止钮一致）。
/// - `.paused` → 红色 `pause.circle`（会话仍在进行故保留红色，空心 vs 实心区分暂停/录制；
///   与浮条红点 35% 透明度的「弱化呼吸」同思路）。
/// - `.finishing` → `hourglass`（收尾是亚秒~秒级过渡态，中性色沙漏表达「正在落盘」）。
/// 颜色经 `.foregroundStyle` 施加；若菜单栏模板渲染在某些系统版本剥离色彩，形状
///（空心/实心/符号差异）仍承载状态区分（终验清单菜单本体项肉眼确认）。
struct MenuBarStatusIcon: View {
    @ObservedObject var controller: CaptureController
    /// 定时录制排程态（P6b）：`.idle` + 排程等待 → 倒计时态图标。
    @ObservedObject var scheduler: RecordingScheduler

    var body: some View {
        switch controller.state {
        case .idle:
            Image(systemName: scheduler.active != nil ? "timer" : "record.circle")
        case .countdown:
            Image(systemName: "timer")
        case .recording:
            Image(systemName: "stop.circle.fill")
                .foregroundStyle(.red)
        case .paused:
            Image(systemName: "pause.circle")
                .foregroundStyle(.red)
        case .finishing:
            Image(systemName: "hourglass")
        }
    }
}
