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

    @Published var clickHighlightEnabled: Bool {
        didSet { defaults.set(clickHighlightEnabled, forKey: Self.clickHighlightEnabledKey) }
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
        if let path = userDefaults.string(forKey: Self.outputDirectoryKey) {
            self.outputDirectory = URL(fileURLWithPath: path)
        } else {
            self.outputDirectory = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ScreenRecorder", isDirectory: true)
        }
        self.countdownSeconds = Self.normalizedCountdown(userDefaults.object(forKey: Self.countdownSecondsKey) as? Int)
        self.pipEnabled = userDefaults.object(forKey: Self.pipEnabledKey) as? Bool ?? false
        // T16 裁定：点击高亮默认关（opt-in）；早期脚手架曾以 true 落库，随本任务翻转为 false
        //（真源仍是 UserDefaults：外部 defaults write com.screenrecorder.app clickHighlightEnabled -bool true 开启）。
        self.clickHighlightEnabled = userDefaults.object(forKey: Self.clickHighlightEnabledKey) as? Bool ?? false
        // T17：上次使用的采集模式（⇧⌘R 开录用）；缺省/解码失败回退全屏（主显示器）。
        if let data = userDefaults.data(forKey: Self.lastCaptureModeKey),
           let mode = try? JSONDecoder().decode(CaptureMode.self, from: data) {
            self.lastCaptureMode = mode
        } else {
            self.lastCaptureMode = .display(CGMainDisplayID())
        }
    }

    private static let fpsKey = "fps"
    private static let videoCodecKey = "videoCodec"
    private static let captureSystemAudioKey = "captureSystemAudio"
    private static let captureMicrophoneKey = "captureMicrophone"
    private static let micVolumeKey = "micVolume"
    private static let outputDirectoryKey = "outputDirectory"
    private static let countdownSecondsKey = "countdownSeconds"
    private static let pipEnabledKey = "pipEnabled"
    private static let clickHighlightEnabledKey = "clickHighlightEnabled"
    private static let lastCaptureModeKey = "lastCaptureMode"

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
}
