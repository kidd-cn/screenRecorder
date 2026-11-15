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


// MARK: - 偏好设置行构造（两页共享同一几何，2026-11-15）

/// 分区容器（粗体标题 + 行栈）。
private func settingSection<Content: View>(
    _ title: LocalizedStringKey,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        Text(title)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.primary)
        content()
    }
    .padding(.horizontal, 4)
}

/// 行标签（96pt 右对齐——容纳最长标签「点击自动缩放」，全页统一列宽）。
private func rowLabel(_ title: LocalizedStringKey) -> some View {
    Text(title)
        .lineLimit(1)
        .frame(width: 96, alignment: .trailing)
}

/// 开关行（checkbox 在内容列）。
private func toggleRow(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
    HStack(spacing: 8) {
        rowLabel(title)
        Toggle("", isOn: isOn)
            .toggleStyle(.checkbox)
            .labelsHidden()
        Spacer(minLength: 0)
    }
}

/// 选择器行（标签 + 菜单/下拉，内容列定宽）。
private func pickerRow<S: Hashable, C: View>(
    _ title: LocalizedStringKey,
    selection: Binding<S>,
    width: CGFloat = 160,
    @ViewBuilder content: () -> C
) -> some View {
    HStack(spacing: 8) {
        rowLabel(title)
        Picker("", selection: selection) { content() }
            .labelsHidden()
            .frame(width: width, alignment: .leading)
    }
}

// MARK: - 偏好设置界面

/// 偏好设置（T17）：TabView 三页——通用（输出目录/倒计时/帧率/编码）、录制源（系统声音/
/// 麦克风/画中画/点击高亮）、快捷键（四个 RecorderCocoa 系录制控件，P2 增 ⇧⌘M）。
/// 输出目录变更经 `onOutputDirectoryChange` 回到装配层（换 fileStore + 控制器 store），
/// 视图不做装配副作用。
struct PreferencesView: View {
    @ObservedObject var settings: SettingsStore
    var onOutputDirectoryChange: (URL) -> Void
    /// 打开窗口选择器（T20「窗口捕获」区「选择窗口…」入口）：呈现归装配层
    ///（`openWindowPicker`，选定只持久化、不开录），视图不做装配副作用。
    var onPickWindowTarget: () -> Void

    var body: some View {
        TabView {
            GeneralTab(
                settings: settings,
                onOutputDirectoryChange: onOutputDirectoryChange,
                onPickWindowTarget: onPickWindowTarget)
                .tabItem { Label("通用", systemImage: "gearshape") }
            ShortcutsTab()
                .tabItem { Label("快捷键", systemImage: "keyboard") }
            KeyboardTab(settings: settings)
                .tabItem { Label("键盘事件", systemImage: "keyboard.badge.ellipsis") }
            BackgroundTab(settings: settings)
                .tabItem { Label("虚拟背景", systemImage: "person.crop.rectangle.badge.plus") }
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
                generalGroup("录制文件保存目录：") {
                    folderPickerButton
                    Text("所有录制的文件会默认保存到该目录下。")
                        .font(.footnote)
                        .foregroundStyle(OmiStyle.subtleText)
                }
                Divider()
                generalGroup("录制时：") {
                    checkRow("录制光标", isOn: $settings.captureMouseCursor)
                    checkRow("点击音效", isOn: $settings.clickSoundEnabled)
                    checkRow("点击高亮", isOn: $settings.clickHighlightEnabled)
                    checkRow("点击自动缩放", isOn: $settings.autoZoomEnabled)
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
                    checkRow("系统声音", isOn: $settings.captureSystemAudio)
                    checkRow("包含麦克风", isOn: $settings.captureMicrophone)
                    checkRow("录制中静音", isOn: $settings.micMuted)
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
                generalGroup("录制完成后：") {
                    checkRow("显示文件列表", isOn: $settings.recordCompletedShowList)
                }
                Divider()
                generalGroup("编辑完成后：") {
                    checkRow("打开所在目录", isOn: $settings.editorPostExportRevealInFinder)
                    checkRow("删除原始文件", isOn: $settings.editorPostExportDeleteOriginal)
                }
                Divider()
                generalGroup("Dock栏App图标：") {
                    checkRow("隐藏", isOn: $settings.dockIconHidden)
                }
                Divider()
                generalGroup("录制提醒间隔：") {
                    pickerGeneral("录制提醒间隔", selection: $settings.recordingReminderIntervalHours, width: 200) {
                        Text("1 小时（默认）").tag(1)
                        Text("2 小时").tag(2)
                        Text("3 小时").tag(3)
                        Text("从不").tag(0)
                    }
                }
                Divider()
                generalGroup("默认屏幕录制分辨率：") {
                    pickerGeneral("分辨率", selection: $settings.captureQuality, width: 200) {
                        Text("原始分辨率").tag(CaptureQuality.source)
                        Text("1080p").tag(CaptureQuality.p1080)
                        Text("720p").tag(CaptureQuality.p720)
                    }
                }
                generalGroup("默认屏幕录制帧率：") {
                    pickerGeneral("帧率", selection: $settings.fps, width: 200) {
                        Text("30FPS").tag(30)
                        Text("60FPS").tag(60)
                    }
                }
                generalGroup("默认屏幕录制倒计时时长：") {
                    pickerGeneral("倒计时时长", selection: $settings.countdownSeconds, width: 200) {
                        Text("无").tag(0)
                        Text("3 秒").tag(3)
                        Text("5 秒").tag(5)
                        Text("10 秒").tag(10)
                    }
                }
                generalGroup("默认视频编码：") {
                    pickerGeneral("编码", selection: $settings.videoCodec, width: 200) {
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
                generalGroup("窗口捕获：") {
                    windowTargetRow
                    Button("选择窗口…") { onPickWindowTarget() }
                }
            }
        }
    }

    /// Omi「通用」页分组行（标签列右对齐 + 内容列，2026-11-15 像素级仿制）。
    private func generalGroup<Content: View>(
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
        .padding(.vertical, 12)
    }

    /// 勾选行（Omi 同款：checkbox + 文字，堆叠于内容列）。行高统一 22pt（2026-11-15
    /// 用户目验「行与行间隔不一致」——勾选行/下拉行/滑杆行原生高度不同，混排即参差）。
    private func checkRow(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
        }
        .toggleStyle(.checkbox)
        .frame(height: 22)
    }

    /// 通用页下拉行（标签 + 200pt 菜单选择器，表单外自绘）。行高 22pt 与勾选行一致。
    private func pickerGeneral<S: Hashable, C: View>(
        _ label: LocalizedStringKey,
        selection: Binding<S>,
        width: CGFloat,
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

    /// 窗口捕获行（96pt 标签列沿用录制源页行构造，当前目标值截断规则同前）。
    private var windowTargetRow: some View {
        HStack(spacing: 8) {
            rowLabel("当前目标")
            if let target = settings.windowCaptureTarget {
                let display = "\(target.ownerAppIdentifier) — \(target.windowTitle.isEmpty ? NSLocalizedString("（无标题）", comment: "Untitled window") : target.windowTitle)"
                Text(display)
                    .foregroundStyle(OmiStyle.subtleText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(display)
            } else {
                Text("未设置")
                    .foregroundStyle(OmiStyle.subtleText)
            }
            Spacer(minLength: 0)
        }
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

/// 键盘事件页（Omi Tab 名「键盘事件」）：按键可视化全部行——启用 / 面板颜色 / 字号 /
/// 停留时长（live 语义：键帽样式逐帧经 provider 读当前设置）。
private struct KeyboardTab: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                settingSection("按键可视化") {
                    toggleRow("启用", isOn: $settings.keyboardOverlayEnabled)
                    HStack(spacing: 8) {
                        rowLabel("颜色")
                        Picker("", selection: $settings.keyboardOverlayColorIsAlternate) {
                            Text("主色").tag(false)
                            Text("备选色").tag(true)
                        }
                        .pickerStyle(.radioGroup)
                        .horizontalRadioGroupLayout()
                        .labelsHidden()
                        .disabled(!settings.keyboardOverlayEnabled)
                    }
                    HStack(spacing: 8) {
                        rowLabel("字号")
                        Picker("", selection: $settings.keyboardOverlayFontSize) {
                            Text("12").tag(12)
                            Text("14").tag(14)
                            Text("18").tag(18)
                        }
                        .labelsHidden()
                        .frame(width: 160, alignment: .leading)
                        .disabled(!settings.keyboardOverlayEnabled)
                    }
                    HStack(spacing: 8) {
                        rowLabel("停留时长")
                        Picker("", selection: $settings.keyboardOverlayLingerSeconds) {
                            Text("1 秒").tag(1.0)
                            Text("2 秒").tag(2.0)
                            Text("3 秒").tag(3.0)
                        }
                        .labelsHidden()
                        .frame(width: 160, alignment: .leading)
                        .disabled(!settings.keyboardOverlayEnabled)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }
}

/// 虚拟背景页（Omi Tab 名「虚拟背景」）：摄像头画中画 + 背景模式（live 语义）+
/// Omi 同款性能提示。
private struct BackgroundTab: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                settingSection("虚拟背景") {
                    toggleRow("画中画摄像头", isOn: $settings.pipEnabled)
                    HStack(spacing: 8) {
                        rowLabel("背景")
                        Picker("", selection: $settings.cameraBackground) {
                            Text("无").tag(CameraBackgroundMode.off)
                            Text("模糊").tag(CameraBackgroundMode.blur)
                            Text("暖渐变").tag(CameraBackgroundMode.builtin(.gradientWarm))
                            Text("冷渐变").tag(CameraBackgroundMode.builtin(.gradientCool))
                            Text("纯色灰蓝").tag(CameraBackgroundMode.builtin(.solidSlate))
                        }
                        .labelsHidden()
                        .frame(width: 160, alignment: .leading)
                        .disabled(!settings.pipEnabled)
                    }
                }
                Text("开启此选项后，由于性能原因，部分设备可能导致录屏失败。")
                    .font(.footnote)
                    .foregroundStyle(OmiStyle.subtleText)
                    .padding(.leading, 96 + 8)
            }
            .padding(.vertical, 8)
        }
    }
}

/// 快捷键页：四个录制控件（`KeyboardShortcuts.Recorder` 内含 `RecorderCocoa`），
/// 取值/落库由包自理（UserDefaults）。⇧⌘M（Task 5）：边录边标记工具开关，spec §5 P2
/// 「默认 ⇧⌘M 且可改」的用户面落点——与其他三键同款 Recorder 行。
private struct ShortcutsTab: View {
    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                settingSection("录制控制") {
                    shortcutRow("开始/停止", .startStopRecording)
                    shortcutRow("暂停/恢复", .pauseResumeRecording)
                    shortcutRow("边录边标记", .toggleMarkingTools)
                }
                settingSection("录制模式") {
                    shortcutRow("全屏", .startFullScreenRecording)
                    shortcutRow("窗口", .startWindowRecording)
                    shortcutRow("App", .startAppRecording)
                    shortcutRow("区域", .startRegionRecordingShortcut)
                    shortcutRow("窗口区域", .startWindowRegionRecordingShortcut)
                    shortcutRow("仅声音", .startAudioOnlyRecordingShortcut)
                    shortcutRow("仅摄像头", .startCameraOnlyRecordingShortcut)
                }
                settingSection("截图") {
                    shortcutRow("区域截图", .takeRegionScreenshotShortcut)
                    shortcutRow("全屏截图", .takeFullScreenScreenshotShortcut)
                }
                Text("全局生效，可点按右侧键位修改。")
                    .font(.footnote)
                    .foregroundStyle(OmiStyle.subtleText)
                    .padding(.leading, 96 + 8)
            }
            .padding(.vertical, 8)
        }
    }

    /// 快捷键行（与其余设置页同几何：96pt 右对齐标签列 + 录制控件在内容列）。
    private func shortcutRow(
        _ title: LocalizedStringKey,
        _ name: KeyboardShortcuts.Name
    ) -> some View {
        HStack(spacing: 8) {
            rowLabel(title)
            KeyboardShortcuts.Recorder("", name: name)
            Spacer(minLength: 0)
        }
    }
}
