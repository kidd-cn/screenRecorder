# ScreenRecorder 设计文档

日期：2026-10-25
状态：已批准（用户确认方向、macOS 13 底线、默认决策表及 6 项运行时行为拍板）

## 1. 意图与背景

为 macOS 打造一个录屏工具，核心场景是**录制教程**和**录制会议**。参考对象是商业应用 OmniRecorder（Omi录屏专家，v1.4.6，已做完整逆向分析，架构证据见附录），复刻其核心录制能力，砍掉商业化与重型编辑功能。

录制教程：录屏幕画面 + 麦克风解说，倒计时让开场从容，鼠标点击高亮让观众看清操作。
录制会议：屏幕 + 系统声音（对方发言）+ 麦克风（自己发言），可选摄像头画中画露脸。

## 2. 目标 / 非目标 / 反目标

### 目标（MVP，一期）
1. **三种画面模式**：全屏（可选显示器）、单个窗口、自定义区域
2. **三路音视频源**：系统声音、麦克风（可单独开关、可调音量）、摄像头画中画（可开关，位置/大小可调）
3. **录制控制**：菜单栏图标 + 浮动控制条（开始/暂停/恢复/停止/丢弃、录制时长显示）、3/5/10 秒倒计时
4. **全局快捷键**：开始/停止、暂停/恢复（默认给出，可自定义）
5. **鼠标点击高亮**：点击时刻在画面上叠加圆圈高亮
6. **文件管理**：录制完成自动保存；文件列表面板（回放、重命名、删除、在 Finder 中显示）
7. **设置**：输出目录（默认 `~/Movies/ScreenRecorder`）、帧率（30 默认/60）、画质、格式、快捷键、摄像头小窗参数
8. **稳健性**：录制期间阻止系统睡眠；磁盘空间监控与安全收尾；录制源消失时自动保存（详见 5.1 中断处理矩阵）

### 非目标（明确不做）
- 商业化：IAP、水印、许可、促销弹窗
- 视频编辑器（缩放分段、剪辑导出）
- 摄像头虚拟背景
- 定时/计划录制
- 纯声音录制模式、纯摄像头录制模式
- Windows/Linux 支持
- 视频转换/压缩工具

### 反目标（出现即失败）
- 录出来的系统声音与画面不同步超过 100ms
- 长时间录制（>1 小时）出现内存无限增长或丢帧加剧
- 暂停/恢复后时间线错乱（暂停时长被计入视频）
- 需要安装任何驱动（内核扩展、虚拟声卡）才能录系统声音

## 3. 约束

- **最低系统：macOS 13**（用户明确决定）。这允许使用 ScreenCaptureKit 的 `SCStreamConfiguration.capturesAudio` 直接捕获系统声音，无需虚拟声卡驱动（OmniRecorder 因兼容 10.13 才需要驱动；我们不需要，架构因此大幅简化）
- 开发语言：Swift 5.9+；UI：SwiftUI + AppKit（菜单栏、浮条需要 AppKit）
- **不分发 App Store**：直接分发（Developer ID），**不开 App Sandbox**——全局快捷键、任意输出目录读写因此不受限。摄像头/麦克风/屏幕录制三大 TCC 权限流程仍需完整实现
- 输出格式：MP4 容器；视频 H.264（默认）/ HEVC（可选）；音频 AAC
- 文件名：`录屏_2026-10-25_14-30-05.mp4` 风格时间戳命名
- 硬件底线：Apple Silicon 优先（universal binary 照编，Intel 可跑但非优化重点）；HEVC 仅在硬件编码器可用时启用
- 签名与公证不进 MVP（自用不强制；构建脚本预留 Developer ID 参数）
- 点击高亮使用免权限的 NSEvent 全局鼠标监听（listen-only），不引入"辅助功能"TCC 权限

## 4. 参考架构（来自 OmniRecorder 逆向证据，作为分层蓝本）

OmniRecorder 的类分层（逆向所得）与本项目的对应设计：

| OmniRecorder 类（证据） | 本项目对应 |
|---|---|
| `OMCaptureController`（总控生命周期） | `CaptureController`：模式选择、权限检查、倒计时、启停状态机 |
| `OMCaptureWindow` + SCStream/AVAssetWriter | `SCStreamRecorder`：SCStream → AVAssetWriter 管线 |
| `OMScreenDisplayCaptureController`（displayID 维度重建配置） | `DisplayCaptureSource` |
| `OMWindowCaptureController` / `OMWindowCaptureEngine` | `WindowCaptureSource`（SCContentFilter 按窗口构建） |
| （OmniRecorder 的区域模式） | `RegionCaptureSource`（SCContentFilter::rect） |
| `OMScreenAudioCaptureController`（音量、后处理） | 系统声音：SCStream 音频输出；麦克风：AVAudioEngine |
| `OMAVCaptureSession` / `OMAVPreviewSession` | `CameraCaptureSource`（AVCaptureSession videoDataOutput） |
| Metal `PiPMixer.metal`（画中画合成） | CoreImage 合成（底层同为 Metal；MVP 用 CI 的便利层，性能不够再下沉自写 shader——留给构建者判断） |
| "SCStream Pause Total Time" 暂停记账 | `PauseTimeTracker`：暂停区间记账，恢复时平移时间戳 |
| `startCaptureOutputTimer` 时长统计 | 浮条计时器（仅 UI 显示，不参与写入） |

关键管线（与 OmniRecorder 证据一致的现代简化版）：

```
SCStream ─(视频 CMSampleBuffer)─┐
Camera  ─(CIImage 合成 PiP)─────┼─→ AVAssetWriterInput(H.264/HEVC)
点击高亮(overlay)───────────────┘
SCStream ─(系统声音 PCM)─┐
Mic      ─(AVAudioEngine)─┴→ 混音 → AVAssetWriterInput(AAC)
```

## 5. 已定决策（用户决定 or 本文档代定，标注出处）

| 决策 | 值 | 出处 |
|---|---|---|
| 用途 | 教程 + 会议 | 用户 |
| 最低 macOS | 13.0 | 用户 |
| 技术栈 | Swift + SwiftUI/AppKit + ScreenCaptureKit | 本文档（用户认可的默认方案） |
| 分发/沙盒 | 非 App Store，不开沙盒 | 本文档 |
| 输出目录 | `~/Movies/ScreenRecorder` 默认，可改 | 本文档 |
| 视频编码 | H.264 默认，HEVC 可选；音频 AAC | 本文档 |
| 标记画笔、点击自动缩放 | 二期 | 本文档（用户接受砍到二期） |
| 点击高亮 | 一期做简单圆圈版 | 本文档 |
| 界面语言 | 简体中文为主 | 本文档 |
| 录制中断 | 持电源断言阻止睡眠；窗口/显示器消失→自动停止保存+通知；锁屏继续录 | 构建审查拍板 |
| 录制中可调性 | 区域/画布开始时锁定；唯一例外：PiP 小窗位置录制中可拖动；摄像头中途开关→二期 | 构建审查拍板 |
| 崩溃数据安全 | MVP 接受崩溃=文件不可播；磁盘空间监控（<2GB 预警、<500MB 自动安全收尾）；分段恢复→二期 | 构建审查拍板 |
| 麦克风热插拔 | 监听音频路由变化，自动跟随新默认输入设备，录制不中断 | 构建审查拍板 |
| 点击捕获权限 | NSEvent 全局鼠标监听（listen-only），不引入"辅助功能"权限 | 构建审查拍板 |
| Intel/公证 | Apple Silicon 优先（universal 照编）；签名公证不进 MVP，构建脚本预留参数 | 构建审查拍板 |

### 5.1 中断处理矩阵

| 事件 | 行为 |
|---|---|
| 系统将要睡眠 | IOPMAssertion 阻止（屏幕可变暗，系统不睡） |
| 被录窗口/App 被关闭 | 自动停止并保存已录内容 + 系统通知 |
| 被录窗口最小化/遮挡 | 继续录制（SCContentFilter 跟踪窗口；最小化时输出行为以实现期实测为准） |
| 捕获显示器被拔出 | 该屏为当前捕获源→自动停止并保存+通知；否则继续 |
| 锁屏/屏保 | 继续录制，不中断 |
| 磁盘剩余 <2GB | 浮条与系统通知预警 |
| 磁盘剩余 <500MB | 自动安全收尾（finishWriting）保存已录内容 |
| 麦克风设备断开/切换 | AVAudioEngine 配置变化回调中重建输入，无缝跟随新设备 |

## 6. 留给构建者的部分

- Xcode 工程结构、target 组织、具体类/文件划分
- 混音细节：推荐 AVAudioEngine（麦克风 inputNode tap）+ AVAudioSourceNode（SCStream PCM 送入）→ mainMixer tap → writer；若实现中发现格式转换坑多，允许改为「双 AAC 轨道」方案，但需在 PR 说明同步性权衡
- 暂停/恢复的时间戳平移策略（参照 OmniRecorder 的暂停记账思路：记录累计暂停时长，恢复后 CMSampleBuffer 时间戳减去累计值）
- 窗口选择器 UI（SCShareableContent 枚举 + 缩略图；macOS 13 上缩略图可用 CGWindowListCreateImage，14+ 可用 SCScreenshotManager）
- 权限引导界面（屏幕录制/麦克风/摄像头的 TCC 状态检测与引导跳转）
- 单元测试覆盖纯逻辑（暂停记账、文件命名、设置存储）；采集管线以真机手动验收清单验收（含 1 小时长录、多显示器、HiDPI/外接屏、暂停 10 次等场景）
- 全局快捷键实现建议用 sindresorhus/KeyboardShortcuts（非沙盒可用，带偏好设置 UI 组件）；构建者可换自研 NSEvent 全局监听

## 7. 二期范围（本期不实现，记录以防范围蔓延）

画笔标记工具、点击自动缩放（录制后可编辑缩放分段）、视频压缩/转码、定时录制、声音/摄像头独立模式、引导教程页

## 附录 A：OmniRecorder 逆向证据摘要

- 二进制符号：`So8SCStreamC`、`So21SCStreamConfigurationC`、`So15SCContentFilterCSg`、`SCStreamDelegate/SCStreamOutput`、"OMCaptureWindow: SCStream asset writer failed" → SCStream + AVAssetWriter 管线
- 聚合音频设备字符串 "Omi Recorder Aggregate Input Device"、"createAggregateInputAudioDevice, audio driver not installed"、安装/卸载/更新声音驱动菜单 → 旧系统虚拟声卡方案（本项目用 macOS 13+ SCStream 音频捕获替代）
- Metal 着色器 `PiPMixer.metal`、`Flipper.metal` → 画中画 GPU 合成
- 沙盒 entitlements：`movies.read-write`、`audio-input`、`camera`、`network.client`（App Store 分发约束所致；本项目非商店分发故不开沙盒）
- 377 条本地化字符串确认功能矩阵：7 种录制模式、点击缩放（1.35x/1.6x/1.9x）、键盘可视化、定时录制、视频编辑器、文件列表、IAP（年订阅+终身）
