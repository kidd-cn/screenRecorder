import CoreGraphics
import Foundation

/// 复用 `SettingsStore.VideoCodec`（h264/hevc → `AVVideoCodecType`）。
/// 同型别名而非重定义：既有定义保持唯一，`RecordingConfiguration` 的 API 面按 brief 写作 `codec: VideoCodec`。
typealias VideoCodec = SettingsStore.VideoCodec

/// 捕获目标模式：整块显示器 / 单个独立窗口 / 显示器上的一块区域 / 一个应用的全部窗口。
/// region 的 rect 为显示器逻辑坐标系（points），与 `SCStreamConfiguration.sourceRect` 同一口径。
/// Codable（关联值均可编码）：`SettingsStore.lastCaptureMode`（T17，⇧⌘R 上次使用模式）
/// 以 JSON 整只落库 UserDefaults。
enum CaptureMode: Equatable, Codable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    case region(rect: CGRect, displayID: CGDirectDisplayID)
    /// App 内容录制（P3a）：一个应用的全部普通层窗口合成单一采集源。bundleID 是解析
    /// 锚点——start 时经 WindowPicker 现场枚举该 bundle 的窗口建
    /// `SCContentFilter(desktopIndependentWindows:)`（零窗口 → 走 begin 失败路径）；
    /// 录制期新开窗口不入画、部分关闭继续录、全部关闭走源丢失自动保存（规格画布纪律）。
    case app(bundleID: String)
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
    /// 点击自动缩放总开关（P1a 开录快照语义，同 clickHighlightEnabled）。缺省关。
    var autoZoomEnabled: Bool = false
    /// 缩放档位快照（1.35/1.6/1.9；`SettingsStore.autoZoomLevel` 载入/didSet 双钳制）。
    /// 缺省 1.6（默认档）。
    var autoZoomLevel: Double = 1.6
    /// 点击音效开关（P1b 开录快照语义，同 autoZoomEnabled）：开启时录制必有音轨——
    /// 双源全关 + 本项开启建「效果专用音轨」（音轨存在条件见
    /// `SCStreamRecorder.includesAudioTrack`）。缺省关。
    var clickSoundEnabled: Bool = false
}
