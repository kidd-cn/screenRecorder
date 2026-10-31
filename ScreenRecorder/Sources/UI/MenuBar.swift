import AppKit
import CoreGraphics
import SwiftUI

/// 菜单栏菜单最终形态（T19）：开始录制子菜单（全屏=显示器列表 / 窗口… / App…（P3a）/ 区域… /
/// 窗口区域…（P3b）/ 仅声音（P7a））、
/// 暂停/恢复、停止、摄像头画中画开关、文件列表…、偏好设置…、关于、退出。
/// 全部动作走 AppAssembly 闭包缝（T17 装配纪律：配置装配与窗口所有权归装配层）；
/// 菜单项可用性由 `CaptureController.state` 状态机驱动（裁定 2）：开始子菜单仅 `.idle` 可用，
/// 暂停/恢复与停止仅在 `.recording`/`.paused` 可用（控制器侧另有同款自守卫，双保险）。
struct MenuBarView: View {
    @ObservedObject var controller: CaptureController
    /// 摄像头画中画开关绑定（T15 同一 `@Published`：菜单与偏好设置窗口同源实时同步）。
    /// 快照语义：翻转只影响下一场录制（开始时刻由装配层读入 config）。
    @ObservedObject var settings: SettingsStore
    /// 定时录制调度器（P6b）：排程态（`active`）驱动「取消定时录制」项的显隐；呈现与
    /// 取消都走装配层闭包缝（窗口所有权与调度器所有权归 AppAssembly，同 T17 装配红线）。
    @ObservedObject var scheduler: RecordingScheduler
    /// 开始全屏录制指定显示器（「全屏」子菜单的显示器列表项）。
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
    /// 打开文件列表窗口（T18，窗口与控制器归 AppAssembly，见 T17 装配红线）。
    let onOpenRecordingList: () -> Void
    /// 打开定时录制面板（P6b，窗口归 AppAssembly，见 openScheduledRecordingPanel）。
    let onOpenScheduledPanel: () -> Void
    /// 取消当前定时排程（仅排程等待期出现；调度器 cancel 即清排程与停录等待）。
    let onCancelScheduled: () -> Void
    /// 打开偏好设置窗口（窗口与控制器归 AppAssembly，见 T17 装配红线）。
    let onOpenPreferences: () -> Void

    var body: some View {
        // 状态徽标仅非 idle 出现（含其后分隔线）：idle 菜单以「开始录制」子菜单开头，
        // 不留顶部孤悬分隔线。
        if controller.state != .idle {
            stateBadge
            Divider()
        }
        Menu("开始录制") {
            fullScreenSubmenu
            Button("窗口…") {
                onStartWindowPicker()
            }
            Button("App…") {
                onStartAppPicker()
            }
            Button("区域…") {
                onStartRegion()
            }
            Button("窗口区域…") {
                onStartWindowRegion()
            }
            .accessibilityLabel("窗口区域录制：选择一个窗口后，在其内部拖框选定录制范围")
            Button("仅声音") {
                onStartAudioOnly()
            }
            .accessibilityLabel("仅声音录制：只录系统声音与麦克风，输出 m4a 音频文件")
        }
        .disabled(controller.state != .idle)
        Button(pauseResumeTitle, systemImage: pauseResumeIcon) {
            if controller.state == .paused {
                controller.resume()
            } else {
                controller.pause()
            }
        }
        .disabled(!isSessionActive)
        Button("停止录制", systemImage: "stop.fill") {
            controller.stop()
        }
        .disabled(!isSessionActive)
        Divider()
        // 定时录制（P6b）：入口恒可用（录制中也可排未来的场，到点忙路径会跳过并通知）；
        // 已排程时追加「取消定时录制」（仅排程等待期出现——fire 即消费 active）。
        Button("定时录制…") {
            onOpenScheduledPanel()
        }
        if scheduler.active != nil {
            Button("取消定时录制") {
                onCancelScheduled()
            }
        }
        Divider()
        Toggle(isOn: $settings.pipEnabled) {
            Label("摄像头画中画", systemImage: "person.crop.rectangle")
        }
        Divider()
        Button("文件列表…") {
            onOpenRecordingList()
        }
        Button("偏好设置…") {
            onOpenPreferences()
        }
        Divider()
        Button("关于") {
            NSApplication.shared.orderFrontStandardAboutPanel(nil)
        }
        Button("退出") {
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: 状态驱动的菜单项（裁定 2：菜单反映状态机）

    /// 会话活动态（暂停/恢复与停止的可用窗口）。
    private var isSessionActive: Bool {
        controller.state == .recording || controller.state == .paused
    }

    private var pauseResumeTitle: String {
        controller.state == .paused ? "恢复录制" : "暂停录制"
    }

    private var pauseResumeIcon: String {
        controller.state == .paused ? "play.fill" : "pause.fill"
    }

    /// 非 idle 态的状态徽标（菜单顶部只读项）：给「开始子菜单为何置灰」一个直接答案。
    /// elapsed 复用浮条的 mm:ss 格式化（含暂停排除语义，同一真源）。
    @ViewBuilder
    private var stateBadge: some View {
        switch controller.state {
        case .idle:
            EmptyView()
        case .countdown(let secondsLeft):
            Text("倒计时中…（\(secondsLeft)s）")
        case .recording:
            Text("录制中… \(FloatingControlBar.elapsedText(controller.elapsed))")
        case .paused:
            Text("已暂停（\(FloatingControlBar.elapsedText(controller.elapsed))）")
        case .finishing:
            Text("收尾中…")
        }
    }

    // MARK: 全屏子菜单（显示器列表）

    private var fullScreenSubmenu: some View {
        Menu("全屏") {
            ForEach(displayOptions) { option in
                Button(option.isMain ? "\(option.name)（主）" : option.name) {
                    onStartDisplay(option.displayID)
                }
            }
        }
    }

    /// `NSScreen` → 菜单项的最小展示模型（Identifiable 用 displayID，屏列表变化由菜单
    /// 每次打开重建覆盖）。名称 = 系统本地化屏名 + points 分辨率，主屏追加「（主）」。
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
/// （空心/实心/符号差异）仍承载状态区分（终验清单菜单本体项肉眼确认）。
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
