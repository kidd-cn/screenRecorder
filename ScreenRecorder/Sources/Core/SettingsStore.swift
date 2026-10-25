import AVFoundation
import Combine
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

    /// 默认 ~/Movies/ScreenRecorder，不存在时惰性创建
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

    private let defaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
        self.fps = userDefaults.object(forKey: Self.fpsKey) as? Int ?? 30
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
        self.countdownSeconds = userDefaults.object(forKey: Self.countdownSecondsKey) as? Int ?? 5
        self.pipEnabled = userDefaults.object(forKey: Self.pipEnabledKey) as? Bool ?? false
        self.clickHighlightEnabled = userDefaults.object(forKey: Self.clickHighlightEnabledKey) as? Bool ?? true
        createOutputDirectoryIfNeeded()
    }

    private func createOutputDirectoryIfNeeded() {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
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
}
