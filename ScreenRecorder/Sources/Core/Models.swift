import CoreGraphics
import Foundation

/// 复用 `SettingsStore.VideoCodec`（h264/hevc → `AVVideoCodecType`）。
/// 同型别名而非重定义：既有定义保持唯一，`RecordingConfiguration` 的 API 面按 brief 写作 `codec: VideoCodec`。
typealias VideoCodec = SettingsStore.VideoCodec

/// 捕获目标模式：整块显示器 / 单个独立窗口 / 显示器上的一块区域 / 一个应用的全部窗口 /
/// 窗口内的一块区域（P3b）。
/// region 的 rect 为显示器逻辑坐标系（points），与 `SCStreamConfiguration.sourceRect` 同一口径。
/// Codable（关联值均可编码）：`SettingsStore.lastCaptureMode`（T17，⇧⌘R 上次使用模式）
/// 以 JSON 整只落库 UserDefaults。
enum CaptureMode: Equatable, Codable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    case region(rect: CGRect, displayID: CGDirectDisplayID)
    /// App 内容录制（P3a）：一个应用的全部普通层窗口合成单一采集源。bundleID 是解析
    /// 锚点——start 时经 WindowPicker 现场枚举该 bundle 的窗口建
    /// `SCContentFilter(display:including:)`（零窗口 → 走 begin 失败路径）；
    /// 录制期新开窗口不入画、部分关闭继续录、全部关闭走源丢失自动保存（规格画布纪律）。
    case app(bundleID: String)
    /// 窗口区域录制（P3b）：一个窗口内用户拖出的子矩形。rect 为**窗口相对系**——原点 =
    /// 窗口 frame 左上、points、y 向下，即 `SCContentFilter(desktopIndependentWindow:)` +
    /// `SCStreamConfiguration.sourceRect` 的裁剪口径（不经显示器全局系，无多屏偏移/Y 翻转
    /// 坑）。开录时 rect 与窗口 frame 求交钳制一次固定（SCStreamRecorder.resolveTarget）；
    /// 录制中窗口缩小沿用一期窗口模式语义（无 live 重配置，不重钳制）。
    case windowRegion(window: CGWindowID, rect: CGRect)
    /// 仅声音录制（P7a）：不采集任何视频内容——SCStream 只装 `.audio` 输出（filter 锚
    /// 主屏仅为 SCK API 形参要求，无 `.screen` data output 即永无视频帧），落盘为纯音轨
    /// `.m4a`（无视频 input 的 AVAssetWriter 会话）。无关联值：`lastCaptureMode`
    /// （⇧⌘R 上次使用模式）与 Codable 落库同其余模式。
    case audioOnly
    /// 仅摄像头录制（P7b）：录制源是前置摄像头 `AVCaptureSession`（videoDataOutput →
    /// AVAssetWriter，非 SCStream）+ 麦克风经 AVAudioEngine mixer 可混，落盘 `.mp4` 视
    /// 频。规格钉定：PiP 叠加/缩放/标记/点击高亮等屏幕合成效果族在本模式不可用
    ///（`makeConfiguration` 强制全关——无屏幕画布可叠可缩可标注；录制源摄像头不经
    /// `includeCamera`，那是画中画叠加开关）。无关联值：`lastCaptureMode` 与 Codable
    /// 落库同其余模式。
    case cameraOnly
}

/// `CaptureMode` 的画布语义扩展：本模式是否存在「被录制的屏幕视频画布」（单一真源）。
/// audioOnly（P7a）无视频源、cameraOnly（P7b）有视频但源是摄像头**非屏幕**——二者共享
/// 「无视频画布」侧，供标记入口共享判定（MarkingOverlayController / 工具条 / 画笔按钮 /
/// AppAssembly.refreshMarkingSurfaces）与源丢失监视武装门（CaptureController）等消费点
/// 使用，避免各处手写 `mode != .audioOnly && mode != .cameraOnly` 漂移。
extension CaptureMode {
    /// display/window/region/app/windowRegion = 屏幕视频画布在；audioOnly/cameraOnly = 无。
    var hasVideoCanvas: Bool {
        switch self {
        case .display, .window, .region, .app, .windowRegion:
            return true
        case .audioOnly, .cameraOnly:
            return false
        }
    }
}

/// 摄像头画中画的背景模式（P5）：原画面 / 人像模糊 / 内置程序生成背景。开录快照语义
///（同 `includeCamera`——录制中途改设置不影响进行中的录制）。Codable（关联值均可编码）：
/// `SettingsStore.cameraBackground` 以 JSON 整只落库 UserDefaults。Hashable：SwiftUI
/// Picker selection/tag 的约束（与 Equatable/Codable 并存的合成实现，不改值语义）。
enum CameraBackgroundMode: Equatable, Hashable, Codable {
    /// 原画面直通（默认）：帧路径零开销旁路——不建处理器、不调 Vision、缓冲原样入库。
    case off
    /// 人像分割 + 虚化：前景叠「自身高斯模糊」底。
    case blur
    /// 内置程序生成背景（CIImage 渐变/纯色，零素材文件）。
    case builtin(BuiltinBackground)
}

/// 内置背景样式（P5）：全部 CIImage 程序生成，不内置照片素材。
enum BuiltinBackground: Equatable, Hashable, Codable {
    /// 暖渐变（橙 → 绯红对角）。
    case gradientWarm
    /// 冷渐变（青 → 蓝对角）。
    case gradientCool
    /// 纯色灰蓝（slate）。
    case solidSlate
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
    /// 摄像头画中画背景模式（P5 开录快照语义，同 `includeCamera`）。缺省 off（原画面，
    /// 帧路径零开销旁路——不建处理器、不调 Vision）。
    var cameraBackground: CameraBackgroundMode = .off
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
