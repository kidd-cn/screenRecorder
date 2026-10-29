import CoreGraphics
import Foundation

/// 复用 `SettingsStore.VideoCodec`（h264/hevc → `AVVideoCodecType`）。
/// 同型别名而非重定义：既有定义保持唯一，`RecordingConfiguration` 的 API 面按 brief 写作 `codec: VideoCodec`。
typealias VideoCodec = SettingsStore.VideoCodec

/// 捕获目标模式：整块显示器 / 单个独立窗口 / 显示器上的一块区域。
/// region 的 rect 为显示器逻辑坐标系（points），与 `SCStreamConfiguration.sourceRect` 同一口径。
/// Codable（关联值均可编码）：`SettingsStore.lastCaptureMode`（T17，⇧⌘R 上次使用模式）
/// 以 JSON 整只落库 UserDefaults。
enum CaptureMode: Equatable, Codable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    case region(rect: CGRect, displayID: CGDirectDisplayID)
}

/// 一次录制会话的完整参数快照：启动录制时由上层从 `SettingsStore` + `RecordingFileStore` 装配，
/// 之后采集/落盘各环节只读本快照——录制中途改设置不影响进行中的录制。
struct RecordingConfiguration {
    var mode: CaptureMode
    var captureSystemAudio: Bool
    var captureMicrophone: Bool
    /// 麦克风增益 0…1（快照语义：录制中途改设置不影响进行中的录制）。
    /// 来源 `SettingsStore.micVolume`（Double），传给混音器前收敛为 Float。
    var micVolume: Double = 1.0
    /// 麦克风静音快照（终审 F2）：true = 开录即不装 mic tap（混音器空闲态 setMicMuted
    /// 语义）。录制中改「录制中静音麦克风」走 live 下发链，不影响本快照。缺省 false。
    var micMuted: Bool = false
    var includeCamera: Bool
    var fps: Int
    var codec: VideoCodec
    var outputURL: URL
    var clickHighlightEnabled: Bool
}
