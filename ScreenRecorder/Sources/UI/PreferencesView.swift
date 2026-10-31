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
            GeneralTab(settings: settings, onOutputDirectoryChange: onOutputDirectoryChange)
                .tabItem { Label("通用", systemImage: "gearshape") }
            RecordingSourcesTab(settings: settings, onPickWindowTarget: onPickWindowTarget)
                .tabItem { Label("录制源", systemImage: "slider.horizontal.3") }
            ShortcutsTab()
                .tabItem { Label("快捷键", systemImage: "keyboard") }
        }
        .padding()
        .frame(width: 480, height: 320)
    }
}

/// 通用页：输出目录（NSOpenPanel 选择）、倒计时 0/3/5/10、帧率 30/60、编码 H.264/HEVC
/// （HEVC 硬件编码器不可用时禁用并标注「需硬件编码器」）。
private struct GeneralTab: View {
    @ObservedObject var settings: SettingsStore
    var onOutputDirectoryChange: (URL) -> Void

    var body: some View {
        Form {
            outputDirectoryRow
            Picker("倒计时", selection: $settings.countdownSeconds) {
                Text("无").tag(0)
                Text("3 秒").tag(3)
                Text("5 秒").tag(5)
                Text("10 秒").tag(10)
            }
            Picker("帧率", selection: $settings.fps) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
            codecPicker
            // P6a 开机自启：只有开关本身——副作用（SMAppService 注册/注销、失败回翻
            // + 失败通知）在装配层 sink（LaunchAtLoginCoordinator），视图不做装配副作用。
            Toggle("开机自启", isOn: $settings.launchAtLogin)
        }
    }

    private var outputDirectoryRow: some View {
        HStack(alignment: .top) {
            Text("输出目录")
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text(settings.outputDirectory.path)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(settings.outputDirectory.path)
                Button("选择…") { chooseOutputDirectory() }
            }
        }
    }

    /// HEVC 硬件编码器不可用时：HEVC 选项禁用并标注（硬件能力进程内缓存，读取零开销）。
    private var codecPicker: some View {
        Picker("编码", selection: $settings.videoCodec) {
            Text("H.264").tag(SettingsStore.VideoCodec.h264)
            if HEVCEncoderCapability.hevcHardwareEncodingAvailable {
                Text("HEVC").tag(SettingsStore.VideoCodec.hevc)
            } else {
                Text("HEVC（需硬件编码器）")
                    .tag(SettingsStore.VideoCodec.hevc)
                    .disabled(true)
            }
        }
        .pickerStyle(.radioGroup)
        .horizontalRadioGroupLayout()
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

/// 录制源页：系统声音 / 麦克风区（终审 F2：包含麦克风=开始时刻快照；录制中静音=live 下发；
/// 音量滑杆=live 增益）、摄像头画中画（T15）、鼠标点击高亮（T16，默认关）、
/// 点击自动缩放（P1a，默认关；档位三选）、点击音效（P1b，默认关）、
/// 「键盘按键可视化」组（P4：开关 + 两色单选 + 字号档位 + 停留时长档位 + 两行说明）、
/// 「窗口捕获」组（T20：当前目标 + 选择器入口 + 快捷键提示）。
private struct RecordingSourcesTab: View {
    @ObservedObject var settings: SettingsStore
    var onPickWindowTarget: () -> Void

    var body: some View {
        Form {
            Toggle("系统声音", isOn: $settings.captureSystemAudio)
            Section("麦克风") {
                Toggle("包含麦克风", isOn: $settings.captureMicrophone)
                Toggle("录制中静音麦克风", isOn: $settings.micMuted)
                HStack {
                    Text("麦克风音量")
                    Slider(value: $settings.micVolume, in: 0...1)
                        .disabled(!settings.captureMicrophone)
                    Text("\(Int((settings.micVolume * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(minWidth: 44, alignment: .trailing)
                }
                Text("「包含麦克风」在开始录制时生效；「录制中静音麦克风」与音量在录制中改动实时生效。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Toggle("摄像头画中画", isOn: $settings.pipEnabled)
            // P5 摄像头背景：off=原画面、blur=模糊、builtin=三内置（程序生成，零素材）。
            // 开录快照语义（同 pipEnabled——下一场录制生效）；无画中画时背景无意义，
            // 随画中画开关联动禁用。
            Picker("摄像头背景", selection: $settings.cameraBackground) {
                Text("原画面").tag(CameraBackgroundMode.off)
                Text("模糊").tag(CameraBackgroundMode.blur)
                Text("暖渐变").tag(CameraBackgroundMode.builtin(.gradientWarm))
                Text("冷渐变").tag(CameraBackgroundMode.builtin(.gradientCool))
                Text("纯色灰蓝").tag(CameraBackgroundMode.builtin(.solidSlate))
            }
            .disabled(!settings.pipEnabled)
            Text("摄像头背景在开始录制时生效。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Toggle("鼠标点击高亮", isOn: $settings.clickHighlightEnabled)
            // P1a 点击自动缩放：opt-in 默认关（快照语义同点击高亮——下一场录制生效）；
            // 档位三选与 SettingsStore 的钳制档位一一对应。
            Toggle("点击自动缩放", isOn: $settings.autoZoomEnabled)
            Picker("缩放档位", selection: $settings.autoZoomLevel) {
                Text("1.35x").tag(1.35)
                Text("1.6x").tag(1.6)
                Text("1.9x").tag(1.9)
            }
            .disabled(!settings.autoZoomEnabled)
            // P1b 点击音效：opt-in 默认关（快照语义同点击高亮/自动缩放——下一场录制生效）；
            // 音量固定内置（spec 钉不设滑杆），只进录制音轨、绝无实时外放。
            Toggle("点击音效", isOn: $settings.clickSoundEnabled)
            // P4 键盘按键可视化：opt-in 默认关。enabled 是开录快照语义（下一场录制生效）；
            // 颜色/字号/停留时长是 live 语义（键帽样式逐帧经 provider 读当前设置，改动对
            // 进行中的录制即时生效，SettingsStore 载入野值钳回默认档）。
            Section("键盘按键可视化") {
                Toggle("启用", isOn: $settings.keyboardOverlayEnabled)
                Picker("颜色", selection: $settings.keyboardOverlayColorIsAlternate) {
                    Text("主色").tag(false)
                    Text("备选色").tag(true)
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .disabled(!settings.keyboardOverlayEnabled)
                Picker("字号", selection: $settings.keyboardOverlayFontSize) {
                    Text("12").tag(12)
                    Text("14").tag(14)
                    Text("18").tag(18)
                }
                .disabled(!settings.keyboardOverlayEnabled)
                Picker("停留时长", selection: $settings.keyboardOverlayLingerSeconds) {
                    Text("1 秒").tag(1.0)
                    Text("2 秒").tag(2.0)
                    Text("3 秒").tag(3.0)
                }
                .disabled(!settings.keyboardOverlayEnabled)
                // 说明行（简报钉定原文两行，逐字）。
                Text("拼音输入法组合期显示原始字母")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("检测到安全输入时暂停显示")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("窗口捕获") {
                windowTargetRow
                Button("选择窗口…") { onPickWindowTarget() }
                Text("按 ⇧⌘W 录制该窗口（可在快捷键页修改）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 当前目标显示（简报文案：App 名 + 窗口标题，未配置「未设置」）。持久化标识是
    /// bundle id（ownerName 兜底），无独立展示名字段（Produces 三字段钉死），原样展示；
    /// 无标题窗口显示「（无标题）」（与选择器行文案同款）。
    private var windowTargetRow: some View {
        HStack {
            Text("当前目标")
            Spacer()
            if let target = settings.windowCaptureTarget {
                let display = "\(target.ownerAppIdentifier) — \(target.windowTitle.isEmpty ? "（无标题）" : target.windowTitle)"
                Text(display)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(display)
            } else {
                Text("未设置")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 快捷键页：四个录制控件（`KeyboardShortcuts.Recorder` 内含 `RecorderCocoa`），
/// 取值/落库由包自理（UserDefaults）。⇧⌘M（Task 5）：边录边标记工具开关，spec §5 P2
/// 「默认 ⇧⌘M 且可改」的用户面落点——与其他三键同款 Recorder 行。
private struct ShortcutsTab: View {
    var body: some View {
        Form {
            KeyboardShortcuts.Recorder("开始 / 停止录制：", name: .startStopRecording)
            KeyboardShortcuts.Recorder("暂停 / 恢复录制：", name: .pauseResumeRecording)
            KeyboardShortcuts.Recorder("录制所选窗口：", name: .startWindowRecording)
            KeyboardShortcuts.Recorder("边录边标记：", name: .toggleMarkingTools)
            Text("快捷键在任意应用前台时生效（系统级注册，无需额外权限）。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
