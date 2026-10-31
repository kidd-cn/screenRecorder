import AVFoundation
import Combine
import CoreGraphics
import Foundation

/// 录制设置：读写 UserDefaults 并以 `@Published` 暴露给 SwiftUI。
final class SettingsStore: ObservableObject {
    enum VideoCodec: String {
        case h264
        case hevc

        var avCodecKey: AVVideoCodecType {
            switch self {
            case .h264: return .h264
            case .hevc: return .hevc
            }
        }
    }

    @Published var fps: Int {
        didSet { defaults.set(fps, forKey: Self.fpsKey) }
    }

    @Published var videoCodec: VideoCodec {
        didSet { defaults.set(videoCodec.rawValue, forKey: Self.videoCodecKey) }
    }

    @Published var captureSystemAudio: Bool {
        didSet { defaults.set(captureSystemAudio, forKey: Self.captureSystemAudioKey) }
    }

    @Published var captureMicrophone: Bool {
        didSet { defaults.set(captureMicrophone, forKey: Self.captureMicrophoneKey) }
    }

    /// 0…1
    @Published var micVolume: Double {
        didSet { defaults.set(micVolume, forKey: Self.micVolumeKey) }
    }

    /// 麦克风静音（终审 F2，持久化默认 false）：与 `captureMicrophone`（是否包含麦克风，
    /// 开始时刻快照语义）不同——本项是「录制中静音」：翻转即经 live 下发链摘/回装混音器
    /// inputNode tap（实时生效），同时作为每场开录 config 的静音快照（开录即静音）。
    @Published var micMuted: Bool {
        didSet { defaults.set(micMuted, forKey: Self.micMutedKey) }
    }

    /// 默认 ~/Movies/ScreenRecorder（目录创建由 RecordingFileStore.ensureDirectory 负责）
    @Published var outputDirectory: URL {
        didSet { defaults.set(outputDirectory.path, forKey: Self.outputDirectoryKey) }
    }

    /// 合法值 0/3/5/10
    @Published var countdownSeconds: Int {
        didSet { defaults.set(countdownSeconds, forKey: Self.countdownSecondsKey) }
    }

    @Published var pipEnabled: Bool {
        didSet { defaults.set(pipEnabled, forKey: Self.pipEnabledKey) }
    }

    /// 摄像头画中画背景（P5，默认 off 原画面）：off/blur/builtin 三态枚举整只 JSON 落库
    ///（lastCaptureMode 同款 Codable 模式；枚举无野值档位，解码失败回退默认）。开录快照
    /// 语义（同 pipEnabled——下一场录制生效），录制中改设置不影响进行中的录制。
    @Published var cameraBackground: CameraBackgroundMode {
        didSet {
            if let data = try? JSONEncoder().encode(cameraBackground) {
                defaults.set(data, forKey: Self.cameraBackgroundKey)
            }
        }
    }

    @Published var clickHighlightEnabled: Bool {
        didSet { defaults.set(clickHighlightEnabled, forKey: Self.clickHighlightEnabledKey) }
    }

    /// 点击自动缩放总开关（P1a，opt-in 默认关；开录快照语义同 clickHighlightEnabled）。
    @Published var autoZoomEnabled: Bool {
        didSet { defaults.set(autoZoomEnabled, forKey: Self.autoZoomEnabledKey) }
    }

    /// 缩放档位（P1a，合法 1.35/1.6/1.9 默认 1.6）：越界 didSet 钳回 1.6，载入野值
    /// 同样钳制——沿用 fps/countdownSeconds 钳制模式。注意 `@Published` 包装器的每次
    /// 赋值（didSet 内再赋值、含同值赋值）都会重入 didSet——无条件再赋值即无限递归；
    /// 普通存储属性在 didSet 内再赋值则按 Swift 语义静默替换、不重入（两者已用独立
    /// 脚本在本工具链实证）。T8/T12 复制本钳制模式须用「不等才收敛赋值一次、重入轮
    /// 落库」写法。
    @Published var autoZoomLevel: Double {
        didSet {
            let normalized = Self.normalizedAutoZoomLevel(autoZoomLevel)
            guard normalized != autoZoomLevel else {
                defaults.set(autoZoomLevel, forKey: Self.autoZoomLevelKey)
                return
            }
            autoZoomLevel = normalized
        }
    }

    /// 点击音效开关（P1b，opt-in 默认关；开录快照语义同 clickHighlightEnabled）。
    @Published var clickSoundEnabled: Bool {
        didSet { defaults.set(clickSoundEnabled, forKey: Self.clickSoundEnabledKey) }
    }

    /// 键盘按键可视化总开关（P4，opt-in 默认关；Task 9 裁定：组合态/样式走 live
    /// provider 逐帧供帧，开录快照语义仅适用于 enabled 初值）。
    @Published var keyboardOverlayEnabled: Bool {
        didSet { defaults.set(keyboardOverlayEnabled, forKey: Self.keyboardOverlayEnabledKey) }
    }

    /// 键帽颜色两色单选（P4）：false = 主色（默认），true = 备选色；取色渲染在
    /// 合成器（Task 9），此处只存布尔档位。
    @Published var keyboardOverlayColorIsAlternate: Bool {
        didSet {
            defaults.set(keyboardOverlayColorIsAlternate,
                         forKey: Self.keyboardOverlayColorIsAlternateKey)
        }
    }

    /// 键帽字号档位（P4，合法 12/14/18 默认 14）：越界 didSet 钳回 14——沿用
    /// autoZoomLevel 的「不等才收敛赋值一次、重入轮落库」写法（@Published 的 didSet
    /// 内再赋值、含同值赋值都会重入 didSet，见 autoZoomLevel 注释定论）。
    @Published var keyboardOverlayFontSize: Int {
        didSet {
            let normalized = Self.normalizedKeyboardOverlayFontSize(keyboardOverlayFontSize)
            guard normalized != keyboardOverlayFontSize else {
                defaults.set(keyboardOverlayFontSize, forKey: Self.keyboardOverlayFontSizeKey)
                return
            }
            keyboardOverlayFontSize = normalized
        }
    }

    /// 键帽停留时长档位（P4，合法 1/2/3 秒默认 2）：越界 didSet 钳回 2，收敛写法
    /// 同字号档位。
    @Published var keyboardOverlayLingerSeconds: Double {
        didSet {
            let normalized = Self.normalizedKeyboardOverlayLingerSeconds(keyboardOverlayLingerSeconds)
            guard normalized != keyboardOverlayLingerSeconds else {
                defaults.set(keyboardOverlayLingerSeconds,
                             forKey: Self.keyboardOverlayLingerSecondsKey)
                return
            }
            keyboardOverlayLingerSeconds = normalized
        }
    }

    /// 上次使用的采集模式（T17 裁定：⇧⌘R「开始/停止」以最后使用的模式开录，每次开始录制时
    /// 由装配层持久化到此处）。默认全屏（主显示器）。`CaptureMode` Codable 编码整只落库，
    /// 解码失败（如枚举演化）回退默认；显示器拓扑变化由下一次开始重新持久化自然覆盖。
    @Published var lastCaptureMode: CaptureMode {
        didSet {
            if let data = try? JSONEncoder().encode(lastCaptureMode) {
                defaults.set(data, forKey: Self.lastCaptureModeKey)
            }
        }
    }

    /// 开机自启（P6a，opt-in 默认关）：只有开关本身——副作用（SMAppService register/
    /// unregister、失败回翻 + 失败通知）在装配层 sink（LaunchAtLoginCoordinator），
    /// 不进 didSet（接线裁定：失败回翻经 sink 写回本属性，@Published didSet 内写回必重入）。
    /// didSet 只做持久化（cameraBackground 先例：纯落库、无自赋值、无重入）——失败回翻
    /// 写回的结果态随之落库，重启后开关与真实注册态一致。
    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Self.launchAtLoginKey) }
    }

    /// 窗口捕获目标（T20）：nil = 未配置。稳定标识 = owner bundle id（取不到 ownerName 兜底）
    /// + 窗口标题（裁定 1，CGWindowID 从不持久化——重启后 id 必变）。Codable JSON 整只落库，
    /// 解码失败回退未配置；置 nil 同时移除落库键（不留死数据）。只在选定时刻写入——
    /// 选择器取消不动既有值（简报行为规格 3）。
    @Published var windowCaptureTarget: WindowCaptureTarget? {
        didSet {
            if let target = windowCaptureTarget, let data = try? JSONEncoder().encode(target) {
                defaults.set(data, forKey: Self.windowCaptureTargetKey)
            } else if windowCaptureTarget == nil {
                defaults.removeObject(forKey: Self.windowCaptureTargetKey)
            }
        }
    }

    private let defaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
        // 审查修复轮 1：defaults 外写野值（如 fps=24 / countdown=7）加载时钳回合法档位——
        // 偏好设置 Picker 恒有匹配 tag，钳后值驱动录制配置（init 内赋值不触发 didSet，
        // 落库的野值原样保留、不回写）。
        self.fps = Self.normalizedFps(userDefaults.object(forKey: Self.fpsKey) as? Int)
        self.videoCodec = VideoCodec(rawValue: userDefaults.string(forKey: Self.videoCodecKey) ?? "") ?? .h264
        self.captureSystemAudio = userDefaults.object(forKey: Self.captureSystemAudioKey) as? Bool ?? true
        self.captureMicrophone = userDefaults.object(forKey: Self.captureMicrophoneKey) as? Bool ?? true
        self.micVolume = userDefaults.object(forKey: Self.micVolumeKey) as? Double ?? 1.0
        self.micMuted = userDefaults.object(forKey: Self.micMutedKey) as? Bool ?? false
        if let path = userDefaults.string(forKey: Self.outputDirectoryKey) {
            self.outputDirectory = URL(fileURLWithPath: path)
        } else {
            self.outputDirectory = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ScreenRecorder", isDirectory: true)
        }
        self.countdownSeconds = Self.normalizedCountdown(userDefaults.object(forKey: Self.countdownSecondsKey) as? Int)
        self.pipEnabled = userDefaults.object(forKey: Self.pipEnabledKey) as? Bool ?? false
        // P5：摄像头画中画背景（默认 off 原画面）；解码失败（枚举演化）回退默认。
        if let data = userDefaults.data(forKey: Self.cameraBackgroundKey),
           let background = try? JSONDecoder().decode(CameraBackgroundMode.self, from: data) {
            self.cameraBackground = background
        } else {
            self.cameraBackground = .off
        }
        // T16 裁定：点击高亮默认关（opt-in）；早期脚手架曾以 true 落库，随本任务翻转为 false
        //（真源仍是 UserDefaults：外部 defaults write com.screenrecorder.app clickHighlightEnabled -bool true 开启）。
        self.clickHighlightEnabled = userDefaults.object(forKey: Self.clickHighlightEnabledKey) as? Bool ?? false
        // P1a：点击自动缩放（opt-in 默认关）；档位载入野值钳回 1.6（init 内赋值不触发
        // didSet，落库的野值原样保留、不回写，与 fps/countdown 同纪律）。
        self.autoZoomEnabled = userDefaults.object(forKey: Self.autoZoomEnabledKey) as? Bool ?? false
        self.autoZoomLevel = Self.normalizedAutoZoomLevel(userDefaults.object(forKey: Self.autoZoomLevelKey) as? Double)
        // P1b：点击音效（opt-in 默认关；快照语义同上）。
        self.clickSoundEnabled = userDefaults.object(forKey: Self.clickSoundEnabledKey) as? Bool ?? false
        // P4：键盘按键可视化（opt-in 默认关）；字号/停留载入野值钳回默认档
        // （init 内赋值不触发 didSet，落库野值原样保留、不回写，与 fps/countdown 同纪律）。
        self.keyboardOverlayEnabled = userDefaults.object(forKey: Self.keyboardOverlayEnabledKey) as? Bool ?? false
        self.keyboardOverlayColorIsAlternate = userDefaults.object(forKey: Self.keyboardOverlayColorIsAlternateKey) as? Bool ?? false
        self.keyboardOverlayFontSize = Self.normalizedKeyboardOverlayFontSize(userDefaults.object(forKey: Self.keyboardOverlayFontSizeKey) as? Int)
        self.keyboardOverlayLingerSeconds = Self.normalizedKeyboardOverlayLingerSeconds(userDefaults.object(forKey: Self.keyboardOverlayLingerSecondsKey) as? Double)
        // T17：上次使用的采集模式（⇧⌘R 开录用）；缺省/解码失败回退全屏（主显示器）。
        if let data = userDefaults.data(forKey: Self.lastCaptureModeKey),
           let mode = try? JSONDecoder().decode(CaptureMode.self, from: data) {
            self.lastCaptureMode = mode
        } else {
            self.lastCaptureMode = .display(CGMainDisplayID())
        }
        // P6a：开机自启（opt-in 默认关）；落库值即上次结果态（注册失败回翻亦落库），
        // 注册态的外部变化（系统设置里移除）不回写落库——与诸开关同纪律，真源补齐
        // 属 SMAppService.status 启动对齐，非本任务范围。
        self.launchAtLogin = userDefaults.object(forKey: Self.launchAtLoginKey) as? Bool ?? false
        // T20：窗口捕获目标（⇧⌘W 开录用）；缺省/解码失败回退未配置（nil）。
        if let data = userDefaults.data(forKey: Self.windowCaptureTargetKey),
           let target = try? JSONDecoder().decode(WindowCaptureTarget.self, from: data) {
            self.windowCaptureTarget = target
        } else {
            self.windowCaptureTarget = nil
        }
    }

    private static let fpsKey = "fps"
    private static let videoCodecKey = "videoCodec"
    private static let captureSystemAudioKey = "captureSystemAudio"
    private static let captureMicrophoneKey = "captureMicrophone"
    private static let micVolumeKey = "micVolume"
    private static let micMutedKey = "micMuted"
    private static let outputDirectoryKey = "outputDirectory"
    private static let countdownSecondsKey = "countdownSeconds"
    private static let pipEnabledKey = "pipEnabled"
    private static let cameraBackgroundKey = "cameraBackground"
    private static let clickHighlightEnabledKey = "clickHighlightEnabled"
    private static let autoZoomEnabledKey = "autoZoomEnabled"
    private static let autoZoomLevelKey = "autoZoomLevel"
    private static let clickSoundEnabledKey = "clickSoundEnabled"
    private static let keyboardOverlayEnabledKey = "keyboardOverlayEnabled"
    private static let keyboardOverlayColorIsAlternateKey = "keyboardOverlayColorIsAlternate"
    private static let keyboardOverlayFontSizeKey = "keyboardOverlayFontSize"
    private static let keyboardOverlayLingerSecondsKey = "keyboardOverlayLingerSeconds"
    private static let lastCaptureModeKey = "lastCaptureMode"
    private static let windowCaptureTargetKey = "windowCaptureTarget"
    private static let launchAtLoginKey = "launchAtLogin"

    /// 合法帧率档位 30/60；越界/缺失回退 30（审查修复轮 1）。
    private static func normalizedFps(_ raw: Int?) -> Int {
        guard let raw, raw == 30 || raw == 60 else { return 30 }
        return raw
    }

    /// 合法倒计时档位 0/3/5/10；越界/缺失回退 5（审查修复轮 1）。
    private static func normalizedCountdown(_ raw: Int?) -> Int {
        guard let raw, [0, 3, 5, 10].contains(raw) else { return 5 }
        return raw
    }

    /// 合法缩放档位 1.35/1.6/1.9；越界/缺失回退 1.6（P1a）。
    private static func normalizedAutoZoomLevel(_ raw: Double?) -> Double {
        guard let raw, raw == 1.35 || raw == 1.6 || raw == 1.9 else { return 1.6 }
        return raw
    }

    /// 合法键帽字号档位 12/14/18；越界/缺失回退 14（P4）。
    private static func normalizedKeyboardOverlayFontSize(_ raw: Int?) -> Int {
        guard let raw, raw == 12 || raw == 14 || raw == 18 else { return 14 }
        return raw
    }

    /// 合法键帽停留时长档位 1/2/3 秒；越界/缺失回退 2（P4）。
    private static func normalizedKeyboardOverlayLingerSeconds(_ raw: Double?) -> Double {
        guard let raw, raw == 1 || raw == 2 || raw == 3 else { return 2 }
        return raw
    }
}
