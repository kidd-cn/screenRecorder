import AppKit
import CoreGraphics
import KeyboardShortcuts
import SwiftUI
import VideoToolbox

// MARK: - 全局快捷键名（T17 brief Produces 逐字）

extension KeyboardShortcuts.Name {
    /// 开始/停止录制（默认 ⇧⌘R）：idle/倒计时 → 按上次使用的模式开始，录制/暂停 → 停止。
    /// 经 Carbon `RegisterEventHotKey` 注册（KeyboardShortcuts 包机制），不产生新 TCC 权限。
    static let startStopRecording = Self(
        "startStopRecording",
        default: .init(.r, modifiers: [.shift, .command]))
    /// 暂停/恢复录制（默认 ⇧⌘P）：录制中 → 暂停，暂停中 → 恢复。
    static let pauseResumeRecording = Self(
        "pauseResumeRecording",
        default: .init(.p, modifiers: [.shift, .command]))
    /// 录制所选窗口（默认 ⇧⌘W，T20）：解析持久化的窗口目标直接开录；无目标/目标失效 →
    /// 打开选择器（选定即持久化并开始，取消不动既有目标）。
    static let startWindowRecording = Self(
        "startWindowRecording",
        default: .init(.w, modifiers: [.shift, .command]))
    /// 边录边标记工具开关（默认 ⇧⌘M，Task 5）：录制/暂停中 → 切换标记覆盖层与工具条；
    /// 其余状态 no-op（覆盖层只在录制期存在）。
    static let toggleMarkingTools = Self(
        "toggleMarkingTools",
        default: .init(.m, modifiers: [.shift, .command]))

    // MARK: 逐操作快捷键（2026-11-14 用户要求「每个录屏/截图操作都配快捷键」）
    //
    // 档位设计：统一 ⇧⌃（Shift+Control）系列——避开系统截图三键（⇧⌘3/4/5，会被
    // SystemUIServer 抢占）与各 App 常用 ⌥⌘ 组合；全局注册（Carbon），冲突面最小。

    /// 全屏录制（主显示器）：⇧⌃F。多显示器选屏仍走面板/菜单。
    static let startFullScreenRecording = Self(
        "startFullScreenRecording",
        default: .init(.f, modifiers: [.shift, .control]))
    /// App 录制（打开 App 选择器）：⇧⌃A。
    static let startAppRecording = Self(
        "startAppRecording",
        default: .init(.a, modifiers: [.shift, .control]))
    /// 区域录制（拖框选区）：⇧⌃R。
    static let startRegionRecordingShortcut = Self(
        "startRegionRecordingShortcut",
        default: .init(.r, modifiers: [.shift, .control]))
    /// 窗口区域录制（选窗口 → 窗内拖框）：⇧⌃B。
    static let startWindowRegionRecordingShortcut = Self(
        "startWindowRegionRecordingShortcut",
        default: .init(.b, modifiers: [.shift, .control]))
    /// 仅声音录制（m4a）：⇧⌃U。
    static let startAudioOnlyRecordingShortcut = Self(
        "startAudioOnlyRecordingShortcut",
        default: .init(.u, modifiers: [.shift, .control]))
    /// 仅摄像头录制（mp4 + 预览窗）：⇧⌃V。
    static let startCameraOnlyRecordingShortcut = Self(
        "startCameraOnlyRecordingShortcut",
        default: .init(.v, modifiers: [.shift, .control]))
    /// 区域截图（拖框裁剪 PNG）：⇧⌃S。
    static let takeRegionScreenshotShortcut = Self(
        "takeRegionScreenshotShortcut",
        default: .init(.s, modifiers: [.shift, .control]))
    /// 全屏截图（主显示器整屏）：⇧⌃D。
    static let takeFullScreenScreenshotShortcut = Self(
        "takeFullScreenScreenshotShortcut",
        default: .init(.d, modifiers: [.shift, .control]))
}

// MARK: - HEVC 硬件编码能力（裁定 5）

/// HEVC 硬件编码器可用性：以 `VTCopyVideoEncoderList` 判定（编码器列表，而非解码侧的
/// `VTIsHardwareDecodeSupported`）。进程内硬件能力不变，首次调用后以静态常量缓存。
enum HEVCEncoderCapability {
    static let hevcHardwareEncodingAvailable: Bool = {
        var list: CFArray?
        guard VTCopyVideoEncoderList(nil, &list) == noErr, let list else { return false }
        for case let encoder as NSDictionary in list as NSArray {
            guard isCodecHEVC(encoder), isHardwareAccelerated(encoder) else { continue }
            return true
        }
        return false
    }()

    /// `kVTVideoEncoderList_CodecType` 为 CFNumber（FourCharCode）。
    private static func isCodecHEVC(_ encoder: NSDictionary) -> Bool {
        guard let raw = encoder[kVTVideoEncoderList_CodecType] as? NSNumber else { return false }
        return raw.uint32Value == kCMVideoCodecType_HEVC
    }

    /// `kVTVideoEncoderList_IsHardwareAccelerated` 为 CFBoolean（非 toll-free），
    /// 按 CFTypeID 显式分派（unsafeDowncast 无运行时检查，不产生 as! 强转告警），
    /// 其余形态回退 NSNumber 桥接。
    private static func isHardwareAccelerated(_ encoder: NSDictionary) -> Bool {
        guard let raw = encoder[kVTVideoEncoderList_IsHardwareAccelerated] else { return false }
        if CFGetTypeID(raw as CFTypeRef) == CFBooleanGetTypeID() {
            return CFBooleanGetValue(unsafeDowncast(raw as AnyObject, to: CFBoolean.self))
        }
        return (raw as? NSNumber)?.boolValue ?? false
    }
}


// MARK: - Omi 风格页内行构造（四页共享，2026-11-15 像素级仿制）

/// Omi 分组行：185pt 右对齐标签（含冒号）+ 内容列；组间距与行距一致。
private func omiGroup<Content: View>(
    _ label: LocalizedStringKey,
    @ViewBuilder content: () -> Content
) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(label)
            .frame(width: 185, alignment: .trailing)
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        Spacer(minLength: 0)
    }
    .padding(.vertical, 6)
}

/// Omi 勾选行（checkbox + 文字，行高 22 与下拉/滑杆一致）。
private func omiCheckRow(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
    Toggle(isOn: isOn) {
        Text(title)
    }
    .toggleStyle(.checkbox)
    .frame(height: 22)
}

/// Omi 下拉行（200pt 菜单选择器）。
private func omiPickerRow<S: Hashable, C: View>(
    _ label: LocalizedStringKey,
    selection: Binding<S>,
    width: CGFloat = 200,
    @ViewBuilder content: () -> C
) -> some View {
    Picker(selection: selection) {
        content()
    } label: {
        Text(label)
    }
    .labelsHidden()
    .frame(width: width, height: 22, alignment: .leading)
}

/// Omi 快捷键行（右侧 KeyboardShortcuts 录制器）。
private func omiRecorderRow(
    _ label: LocalizedStringKey,
    _ name: KeyboardShortcuts.Name
) -> some View {
    HStack(spacing: 8) {
        Text(label)
            .frame(width: 185, alignment: .trailing)
        KeyboardShortcuts.Recorder("", name: name)
        Spacer(minLength: 0)
    }
    .frame(height: 22)
    // 与 omiGroup 的组内/组间节奏一致（2026-11-15）：行自身承担上下 6pt。
    .padding(.vertical, 6)
}

/// Omi 提示文字（内容列缩进 185+8）。
private func omiNote(_ text: LocalizedStringKey) -> some View {
    Text(text)
        .font(.footnote)
        .foregroundStyle(OmiStyle.subtleText)
        .padding(.leading, 185 + 8)
}

// MARK: - 偏好设置界面

/// 偏好设置（T17）：TabView 三页——通用（输出目录/倒计时/帧率/编码）、录制源（系统声音/
/// 麦克风/画中画/点击高亮）、快捷键（四个 RecorderCocoa 系录制控件，P2 增 ⇧⌘M）。
/// 输出目录变更经 `onOutputDirectoryChange` 回到装配层（换 fileStore + 控制器 store），
/// 视图不做装配副作用。
struct PreferencesView: View {
    @ObservedObject var settings: SettingsStore
    /// 键帽预览控制器（Omi「开启预览」）：按钮观察其 isActive 换文案，经
    /// onToggleKeyboardPreview 回装配层开/停（预览窗归装配层，视图不做装配副作用）。
    @ObservedObject var keyboardPreview: KeyboardPreviewController
    /// 虚拟背景页摄像头预览（Omi 页复刻）：页面 onAppear/onDisappear 驱动启停，
    /// 装配层持有（窗口所有权归装配层）。
    @ObservedObject var virtualBackgroundPreview: VirtualBackgroundPreviewController
    /// 自定义背景库（⊕/⊖ 与网格缩略图的文件真源；装配层同一实例）。
    let customBackgroundStore: CustomBackgroundStore
    var onOutputDirectoryChange: (URL) -> Void
    /// 打开窗口选择器（T20「窗口捕获」区「选择窗口…」入口）：呈现归装配层
    ///（`openWindowPicker`，选定只持久化、不开录），视图不做装配副作用。
    var onPickWindowTarget: () -> Void
    /// 键帽预览开/停（装配层互翻：活跃即停、空闲才可开）。
    var onToggleKeyboardPreview: () -> Void
    /// 当前页签（默认通用页）。
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralTab(
                settings: settings,
                onOutputDirectoryChange: onOutputDirectoryChange,
                onPickWindowTarget: onPickWindowTarget)
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag(0)
            ShortcutsTab()
                .tabItem { Label("快捷键", systemImage: "keyboard") }
                .tag(1)
            KeyboardTab(settings: settings, keyboardPreview: keyboardPreview,
                        onTogglePreview: onToggleKeyboardPreview)
                .tabItem { Label("键盘事件", systemImage: "keyboard.badge.ellipsis") }
                .tag(2)
            BackgroundTab(
                settings: settings,
                preview: virtualBackgroundPreview,
                backgroundStore: customBackgroundStore)
                .tabItem { Label("虚拟背景", systemImage: "person.crop.rectangle.badge.plus") }
                .tag(3)
        }
        .padding()
        // 尺寸（2026-11-14 用户目验：录制源页内容装不下）：原 480×320 固定尺寸早于
        // 三期/二期后期设置项的增长，录制源页（麦克风/画中画/光标/高亮/缩放/音效/键帽/
        // 窗口捕获）整体溢出且无滚动。三页各自包 ScrollView（见各 tab），窗口放大到
        // 520×560——内容仍超出时滚动可达。
        .frame(width: 520, height: 560)
    }
}

/// 通用页：输出目录（NSOpenPanel 选择）、倒计时 0/3/5/10、帧率 30/60、编码 H.264/HEVC
/// （HEVC 硬件编码器不可用时禁用并标注「需硬件编码器」）、长录提醒间隔 1/2/3 小时/从不（Q5）、
/// 编辑导出完成后动作组（Q6：Finder 定位 / 删除原始文件，均默认关，仅缩放分段编辑器导出挂钩）。
private struct GeneralTab: View {
    @ObservedObject var settings: SettingsStore
    var onOutputDirectoryChange: (URL) -> Void
    /// 打开窗口选择器（窗口捕获区「选择窗口…」入口）：选定只持久化、不开录。
    var onPickWindowTarget: () -> Void

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                omiGroup("录制文件保存目录：") {
                    folderPickerButton
                    Text("所有录制的文件会默认保存到该目录下。")
                        .font(.footnote)
                        .foregroundStyle(OmiStyle.subtleText)
                }
                Divider()
                omiGroup("录制时：") {
                    omiCheckRow("录制光标", isOn: $settings.captureMouseCursor)
                    omiCheckRow("点击音效", isOn: $settings.clickSoundEnabled)
                    omiCheckRow("点击高亮", isOn: $settings.clickHighlightEnabled)
                    omiCheckRow("点击自动缩放", isOn: $settings.autoZoomEnabled)
                    HStack(spacing: 8) {
                        Text("缩放档位")
                            .foregroundStyle(OmiStyle.subtleText)
                        Picker("", selection: $settings.autoZoomLevel) {
                            Text("1.35x").tag(1.35)
                            Text("1.6x").tag(1.6)
                            Text("1.9x").tag(1.9)
                        }
                        .labelsHidden()
                        .frame(width: 160, alignment: .leading)
                        .disabled(!settings.autoZoomEnabled)
                    }
                    .frame(height: 22)
                    omiCheckRow("系统声音", isOn: $settings.captureSystemAudio)
                    omiCheckRow("包含麦克风", isOn: $settings.captureMicrophone)
                    omiCheckRow("录制中静音", isOn: $settings.micMuted)
                    HStack(spacing: 8) {
                        Text("麦克风音量")
                            .foregroundStyle(OmiStyle.subtleText)
                        Slider(value: $settings.micVolume, in: 0...1)
                            .frame(width: 160)
                            .disabled(!settings.captureMicrophone)
                        Text("\(Int((settings.micVolume * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(minWidth: 40, alignment: .trailing)
                    }
                    .frame(height: 22)
                }
                Divider()
                omiGroup("录制完成后：") {
                    omiCheckRow("显示文件列表", isOn: $settings.recordCompletedShowList)
                }
                Divider()
                omiGroup("编辑完成后：") {
                    omiCheckRow("打开所在目录", isOn: $settings.editorPostExportRevealInFinder)
                    omiCheckRow("删除原始文件", isOn: $settings.editorPostExportDeleteOriginal)
                }
                Divider()
                omiGroup("Dock栏App图标：") {
                    omiCheckRow("隐藏", isOn: $settings.dockIconHidden)
                }
                Divider()
                omiGroup("录制提醒间隔：") {
                    omiPickerRow("录制提醒间隔", selection: $settings.recordingReminderIntervalHours, width: 200) {
                        Text("1 小时（默认）").tag(1)
                        Text("2 小时").tag(2)
                        Text("3 小时").tag(3)
                        Text("从不").tag(0)
                    }
                }
                Divider()
                omiGroup("默认屏幕录制分辨率：") {
                    omiPickerRow("分辨率", selection: $settings.captureQuality, width: 200) {
                        Text("原始分辨率").tag(CaptureQuality.source)
                        Text("1080p").tag(CaptureQuality.p1080)
                        Text("720p").tag(CaptureQuality.p720)
                    }
                }
                omiGroup("默认屏幕录制帧率：") {
                    omiPickerRow("帧率", selection: $settings.fps, width: 200) {
                        Text("30FPS").tag(30)
                        Text("60FPS").tag(60)
                    }
                }
                omiGroup("默认屏幕录制倒计时时长：") {
                    omiPickerRow("倒计时时长", selection: $settings.countdownSeconds, width: 200) {
                        Text("无").tag(0)
                        Text("3 秒").tag(3)
                        Text("5 秒").tag(5)
                        Text("10 秒").tag(10)
                    }
                }
                omiGroup("默认视频编码：") {
                    omiPickerRow("编码", selection: $settings.videoCodec, width: 200) {
                        Text("H.264").tag(SettingsStore.VideoCodec.h264)
                        if HEVCEncoderCapability.hevcHardwareEncodingAvailable {
                            Text("HEVC").tag(SettingsStore.VideoCodec.hevc)
                        } else {
                            Text("HEVC（需硬件编码器）")
                                .tag(SettingsStore.VideoCodec.hevc)
                                .disabled(true)
                        }
                    }
                }
                Divider()
                omiGroup("窗口捕获：") {
                    windowTargetRow
                    Button("选择窗口…") { onPickWindowTarget() }
                }
            }
        }
    }

    /// 保存目录按钮（Omi 同款：文件夹图标 + 路径，点击弹 NSOpenPanel）。
    private var folderPickerButton: some View {
        Button {
            chooseOutputDirectory()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                Text(displayPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .frame(width: 300, alignment: .leading)
        .help(displayPath)
    }

    private var displayPath: String {
        let home = NSHomeDirectory() as NSString
        let path = settings.outputDirectory.path as NSString
        return path.hasPrefix(home as String)
            ? "~" + path.substring(from: home.length)
            : path as String
    }

    /// 窗口捕获行（Omi 行几何：内容列内单行显示当前目标，超宽中段截断）。
    private var windowTargetRow: some View {
        HStack(spacing: 8) {
            if let target = settings.windowCaptureTarget {
                let display = "\(target.ownerAppIdentifier) — \(target.windowTitle.isEmpty ? NSLocalizedString("（无标题）", comment: "Untitled window") : target.windowTitle)"
                Text(display)
                    .foregroundStyle(OmiStyle.subtleText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(display)
            } else {
                Text("未选择窗口")
                    .foregroundStyle(OmiStyle.subtleText)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 22)
    }

    /// 输出目录选择：仅目录、可新建；确认后交装配层换装（真源仍是 SettingsStore）。
    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.outputDirectory
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            onOutputDirectoryChange(url)
        }
    }
}

/// 键盘事件页（Omi Tab 名「键盘事件」，2026-11-15 像素级复刻 48.png）：仅显示组合按键
/// 勾选行 / 字体大小 / 换行延迟 / 停留时间 / 消失时长 四滑杆（右对齐冒号标签 + 标签下
/// 灰色小注 + 滑杆下 最小·当前值·最大 刻度）/ 面板颜色 / 文字颜色 色井 / 开启预览
/// 按钮 + 试输入提示。所有控件 live 语义（键帽样式逐帧经 provider 读当前设置）。
private struct KeyboardTab: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var keyboardPreview: KeyboardPreviewController
    var onTogglePreview: () -> Void

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                // 首行（Omi 同款：左对齐标签 + 行内勾选框，不用 185pt 列）。
                HStack(spacing: 10) {
                    Text("仅显示组合按键 (⌘,⌥,⌃,⇧)：")
                    Toggle("", isOn: $settings.keyboardOverlayCombosOnly)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    Spacer(minLength: 0)
                }
                .frame(height: 28)
                .padding(.vertical, 6)
                Divider()
                omiSliderRow(
                    label: "字体大小：", subtitle: "面板上的按键大小",
                    value: fontSizeBinding, range: 12...48,
                    minLabel: "最小", maxLabel: "最大")
                omiSliderRow(
                    label: "换行延迟：", subtitle: "换行前的时长",
                    value: $settings.keyboardOverlayWrapDelaySeconds, range: 0...1,
                    minLabel: "短", maxLabel: "长")
                omiSliderRow(
                    label: "停留时间：", subtitle: "文字消失之前的时长",
                    value: $settings.keyboardOverlayLingerSeconds, range: 1...5,
                    minLabel: "短", maxLabel: "长")
                omiSliderRow(
                    label: "消失时长：", subtitle: "消失动画的时长",
                    value: $settings.keyboardOverlayFadeSeconds, range: 0...1,
                    minLabel: "立即", maxLabel: "快速")
                omiColorRow("面板颜色：", color: $settings.keyboardOverlayPanelColor)
                omiColorRow("文字颜色：", color: $settings.keyboardOverlayTextColor)
                // 预览（Omi 同款居中主按钮 + 试输入提示）。
                HStack {
                    Spacer(minLength: 0)
                    Button(keyboardPreview.isActive
                        ? LocalizedStringKey("停止预览")
                        : LocalizedStringKey("开启预览")) { onTogglePreview() }
                        .frame(width: 120)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 10)
                Text("在开启预览后尝试键盘输入")
                    .font(.footnote)
                    .foregroundStyle(OmiStyle.subtleText)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 6)
            }
            .padding(.vertical, 8)
        }
    }

    /// 字号滑杆桥（Int 落库 ↔ Double 滑杆，步进 1）。
    private var fontSizeBinding: Binding<Double> {
        Binding(
            get: { Double(settings.keyboardOverlayFontSize) },
            set: { settings.keyboardOverlayFontSize = Int($0.rounded()) })
    }

    /// Omi 滑杆行（48.png 几何）：185pt 右对齐标签 + 标签下灰色小注（同列右对齐）；
    /// 内容列滑杆 + 下方三刻度（左 最小 / 中 当前值一位小数 / 右 最大）。
    private func omiSliderRow(
        label: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        minLabel: LocalizedStringKey,
        maxLabel: LocalizedStringKey
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(label)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(OmiStyle.subtleText)
            }
            .frame(width: 185, alignment: .trailing)
            VStack(spacing: 2) {
                Slider(value: value, in: range)
                HStack(spacing: 0) {
                    Text(minLabel).font(.footnote).foregroundStyle(OmiStyle.subtleText)
                    Spacer(minLength: 0)
                    Text(String(format: "%.1f", value.wrappedValue))
                        .font(.footnote)
                        .monospacedDigit()
                    Spacer(minLength: 0)
                    Text(maxLabel).font(.footnote).foregroundStyle(OmiStyle.subtleText)
                }
            }
            .frame(width: 250)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    /// Omi 色井行（48.png 几何）：185pt 右对齐标签 + NSColorWell（圆角小色块）。
    private func omiColorRow(
        _ label: LocalizedStringKey,
        color: Binding<KeyboardOverlayColor>
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: 185, alignment: .trailing)
            OmiColorWell(color: color)
                .frame(width: 48, height: 24)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }
}

/// NSColorWell 桥（Omi 同款小色块，macOS 13 target-action 口径）：取色面板变更即
/// 经 Binding 回 SettingsStore 落库（live 语义，键帽逐帧读当前色）。
private struct OmiColorWell: NSViewRepresentable {
    @Binding var color: KeyboardOverlayColor

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSColorWell {
        let well = NSColorWell()
        well.color = Self.nsColor(color)
        well.target = context.coordinator
        well.action = #selector(Coordinator.colorChanged(_:))
        return well
    }

    func updateNSView(_ well: NSColorWell, context: Context) {
        // 取色面板拖动中每拍回写又回流：值同源恒一致，直接对齐（不打断取色面板）。
        well.color = Self.nsColor(color)
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject {
        var parent: OmiColorWell
        init(_ parent: OmiColorWell) { self.parent = parent }

        @objc func colorChanged(_ sender: NSColorWell) {
            let rgb = sender.color.usingColorSpace(.deviceRGB) ?? sender.color
            parent.color = KeyboardOverlayColor(
                red: Double(rgb.redComponent),
                green: Double(rgb.greenComponent),
                blue: Double(rgb.blueComponent),
                alpha: Double(rgb.alphaComponent))
        }
    }

    private static func nsColor(_ color: KeyboardOverlayColor) -> NSColor {
        NSColor(deviceRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}

/// 虚拟背景页（2026-11-15 Omi 52.png 像素级复刻）：全宽摄像头实时预览（所选背景
/// 实时应用）→「虚拟背景」分区 chip + ⊕ 导入 / ⊖ 删除 → 4 列背景瓦片网格（无/模糊/
/// 暖渐变/冷渐变/纯色灰蓝 + 自定义图片，选中绿框）→ 底部「在屏幕录制画中画摄像头中
/// 应用虚拟背景」勾选 + 性能提示。所有选择 live 下发（录制中改动实时生效）。
private struct BackgroundTab: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var preview: VirtualBackgroundPreviewController
    let backgroundStore: CustomBackgroundStore
    /// 自定义背景文件名列表（页内状态：⊕/⊖ 后刷新）。
    @State private var customNames: [String] = []

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                VirtualBackgroundPreview(controller: preview)
                    .frame(maxWidth: .infinity)
                    .frame(height: 264)
                    .padding(.vertical, 6)
                // 分区 chip 行（Omi 同款：灰底圆角 chip + ⊕/⊖ 圆形按钮）
                HStack(spacing: 12) {
                    Text("虚拟背景")
                        .font(.callout.weight(.medium))
                        .frame(width: 140, height: 26)
                        .background(Capsule().fill(Color.primary.opacity(0.14)))
                    Button {
                        addCustomBackground()
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 17))
                            .foregroundStyle(OmiStyle.subtleText)
                    }
                    .buttonStyle(.plain)
                    .help("导入图片作为虚拟背景")
                    Button {
                        removeSelectedCustom()
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 17))
                            .foregroundStyle(isCustomSelected
                                ? Color.primary
                                : OmiStyle.subtleText.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(!isCustomSelected)
                    .help(isCustomSelected ? "删除选中的自定义背景" : "仅自定义背景可删除")
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
                // 背景瓦片网格（4 列，Omi 同款；选中绿框）
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                    spacing: 10
                ) {
                    backgroundTile(mode: .off) {
                        AnyView(
                            ZStack {
                                Rectangle().fill(Color.black)
                                Text("无")
                                    .font(.system(size: 22, weight: .medium))
                                    .foregroundStyle(.white)
                            })
                    }
                    backgroundTile(mode: .blur) {
                        AnyView(Image(nsImage: BackgroundTileArt.thumbnail(
                            for: .blur, size: Self.tileSize)))
                    }
                    backgroundTile(mode: .builtin(.gradientWarm)) {
                        AnyView(Image(nsImage: BackgroundTileArt.thumbnail(
                            for: .builtin(.gradientWarm), size: Self.tileSize)))
                    }
                    backgroundTile(mode: .builtin(.gradientCool)) {
                        AnyView(Image(nsImage: BackgroundTileArt.thumbnail(
                            for: .builtin(.gradientCool), size: Self.tileSize)))
                    }
                    backgroundTile(mode: .builtin(.solidSlate)) {
                        AnyView(Image(nsImage: BackgroundTileArt.thumbnail(
                            for: .builtin(.solidSlate), size: Self.tileSize)))
                    }
                    ForEach(customNames, id: \.self) { name in
                        backgroundTile(mode: .custom(name)) {
                            AnyView(Image(nsImage: BackgroundTileArt.thumbnail(
                                for: .custom(name), store: backgroundStore,
                                size: Self.tileSize)))
                        }
                    }
                }
                .padding(.vertical, 4)
                // 底部勾选（Omi 同款：勾选框 + 标签 + 标签下灰注）
                HStack(alignment: .top, spacing: 8) {
                    Toggle("", isOn: $settings.pipEnabled)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("在屏幕录制画中画摄像头中应用虚拟背景")
                        Text("开启此选项后，由于性能原因，部分设备可能导致录屏失败。")
                            .font(.footnote)
                            .foregroundStyle(OmiStyle.subtleText)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 10)
            }
            .padding(.horizontal, 2)
        }
        .onAppear {
            customNames = backgroundStore.listNames()
            preview.setMode(settings.cameraBackground)
            preview.start()
        }
        .onDisappear {
            preview.stop()
        }
        .onChange(of: settings.cameraBackground) { newMode in
            preview.setMode(newMode)
        }
    }

    /// 瓦片标称尺寸（4 列网格减间距后的自然宽，4:3 前置画幅比）。
    private static let tileSize = NSSize(width: 112, height: 80)

    /// 当前选中是否自定义背景（⊖ 门控）。
    private var isCustomSelected: Bool {
        if case .custom = settings.cameraBackground { return true }
        return false
    }

    /// 背景瓦片（Omi 同款：内容缩放裁切 + 圆角 8 + 选中绿框 2pt；无标注——Omi 瓦片
    /// 不带文字标注，「无」文字在瓦片内容内）。
    private func backgroundTile<C: View>(
        mode: CameraBackgroundMode,
        @ViewBuilder content: () -> C
    ) -> some View {
        Button {
            settings.cameraBackground = mode
        } label: {
            content()
                .frame(width: Self.tileSize.width, height: Self.tileSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            settings.cameraBackground == mode
                                ? Color(nsColor: .systemGreen)
                                : Color.clear,
                            lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    /// ⊕ 导入图片（仅目录、可多选）：拷入背景库并选中新背景。
    private func addCustomBackground() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedFileTypes = CustomBackgroundStore.allowedTypes
        panel.begin { response in
            guard response == .OK else { return }
            var lastAdded: CameraBackgroundMode?
            for url in panel.urls {
                if let name = try? backgroundStore.addImage(from: url) {
                    lastAdded = .custom(name)
                }
            }
            customNames = backgroundStore.listNames()
            if let lastAdded {
                settings.cameraBackground = lastAdded
            }
        }
    }

    /// ⊖ 删除选中的自定义背景（非自定义选中时按钮已禁用）。
    private func removeSelectedCustom() {
        guard case .custom(let name) = settings.cameraBackground else { return }
        backgroundStore.removeImage(named: name)
        customNames = backgroundStore.listNames()
        settings.cameraBackground = .off
    }
}

/// 瓦片缩略图绘制（程序生成，零内置素材文件）：渐变/纯色按处理器同源配色画对角
/// 线性渐变；模糊 = 同构图高斯虚化（CIGaussianBlur）示意；自定义 = 库图 aspect-fill。
enum BackgroundTileArt {
    /// 瓦片缩略图（main 线程绘制；绘制失败回退深灰占位）。
    static func thumbnail(
        for mode: CameraBackgroundMode,
        store: CustomBackgroundStore? = nil,
        size: NSSize
    ) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)
        defer {
            image.unlockFocus()
            _ = image // lock/unlock 平衡（返回值固定）
        }
        let bounds = NSRect(origin: .zero, size: size)
        switch mode {
        case .off, .blur, .builtin(.gradientWarm), .builtin(.gradientCool), .builtin(.solidSlate):
            // 处理器同源配色（CameraBackgroundProcessor 渐变端点/纯色定值）
            let (from, to, blur): (NSColor, NSColor, CGFloat)
            switch mode {
            case .blur:
                from = NSColor(calibratedRed: 0.55, green: 0.58, blue: 0.62, alpha: 1)
                to = NSColor(calibratedRed: 0.30, green: 0.32, blue: 0.38, alpha: 1)
                blur = 6
            case .builtin(.gradientWarm):
                from = NSColor(calibratedRed: 1.00, green: 0.62, blue: 0.35, alpha: 1)
                to = NSColor(calibratedRed: 0.94, green: 0.33, blue: 0.38, alpha: 1)
                blur = 0
            case .builtin(.gradientCool):
                from = NSColor(calibratedRed: 0.22, green: 0.78, blue: 0.86, alpha: 1)
                to = NSColor(calibratedRed: 0.33, green: 0.51, blue: 0.90, alpha: 1)
                blur = 0
            case .builtin(.solidSlate):
                from = NSColor(calibratedRed: 0.42, green: 0.47, blue: 0.58, alpha: 1)
                to = from
                blur = 0
            default:
                from = .darkGray
                to = .darkGray
                blur = 0
            }
            let gradient = NSGradient(starting: from, ending: to)
            gradient?.draw(in: bounds, angle: -45)
            // 模糊示意：细栅格随机光斑高斯虚化（视觉近似虚化背景）
            if blur > 0 {
                for _ in 0..<6 {
                    let light = NSColor.white.withAlphaComponent(0.25)
                    let spot = NSRect(
                        x: CGFloat.random(in: 0...size.width),
                        y: CGFloat.random(in: 0...size.height),
                        width: size.width * 0.35, height: size.height * 0.35)
                    light.setFill()
                    NSBezierPath(ovalIn: spot).fill()
                }
            }
        case .custom(let name):
            if let store,
               let cgImage = CustomBackgroundStore.loadImage(at: store.url(forName: name)) {
                // aspect-fill 裁切（NSGraphicsContext 翻转坐标下绘位图）
                let imageW = CGFloat(cgImage.width)
                let imageH = CGFloat(cgImage.height)
                guard imageW > 0, imageH > 0 else { break }
                let scale = max(size.width / imageW, size.height / imageH)
                let drawW = imageW * scale
                let drawH = imageH * scale
                let drawRect = NSRect(
                    x: (size.width - drawW) / 2,
                    y: (size.height - drawH) / 2,
                    width: drawW, height: drawH)
                NSGraphicsContext.current?.saveGraphicsState()
                NSBezierPath(rect: bounds).addClip()
                NSImage(cgImage: cgImage, size: NSSize(width: imageW, height: imageH))
                    .draw(in: drawRect)
                NSGraphicsContext.current?.restoreGraphicsState()
            } else {
                NSColor.darkGray.setFill()
                NSBezierPath(rect: bounds).fill()
            }
        }
        return image
    }
}

/// 快捷键页：四个录制控件（`KeyboardShortcuts.Recorder` 内含 `RecorderCocoa`），
/// 取值/落库由包自理（UserDefaults）。⇧⌘M（Task 5）：边录边标记工具开关，spec §5 P2
/// 「默认 ⇧⌘M 且可改」的用户面落点——与其他三键同款 Recorder 行。
/// 像素级仿 Omi：185pt 右对齐冒号标签 + 右侧录制器，组间 Divider。
private struct ShortcutsTab: View {
    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                omiRecorderRow("开始 / 停止录制：", .startStopRecording)
                omiRecorderRow("暂停 / 恢复录制：", .pauseResumeRecording)
                omiRecorderRow("边录边标记：", .toggleMarkingTools)
                Divider()
                omiRecorderRow("全屏录制：", .startFullScreenRecording)
                omiRecorderRow("窗口录制：", .startWindowRecording)
                omiRecorderRow("App 录制：", .startAppRecording)
                omiRecorderRow("区域录制：", .startRegionRecordingShortcut)
                omiRecorderRow("窗口区域：", .startWindowRegionRecordingShortcut)
                omiRecorderRow("仅声音：", .startAudioOnlyRecordingShortcut)
                omiRecorderRow("仅摄像头：", .startCameraOnlyRecordingShortcut)
                Divider()
                omiRecorderRow("区域截图：", .takeRegionScreenshotShortcut)
                omiRecorderRow("全屏截图：", .takeFullScreenScreenshotShortcut)
                Divider()
                omiNote("全局生效，可点按右侧键位修改。")
            }
            .padding(.vertical, 8)
        }
    }
}
