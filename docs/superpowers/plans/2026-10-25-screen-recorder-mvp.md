# ScreenRecorder MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** macOS 菜单栏录屏应用：全屏/窗口/区域录制 + 系统声音 + 麦克风混音 + 摄像头画中画 + 点击高亮 + 倒计时 + 浮条控制 + 全局快捷键 + 文件列表。

**Architecture:** ScreenCaptureKit 的 SCStream 产出视频帧与系统声音 PCM；摄像头经 AVCaptureSession videoDataOutput 产出 CIImage，与点击高亮一起由 CoreImage 合成到每帧上；音频两路在 AVAudioEngine 图中混为一路；全部写入单个 AVAssetWriter（MP4/H.264+AAC）。暂停采用"丢弃帧 + 记账时间戳平移"方案。

**Tech Stack:** Swift 5.9 / SwiftUI + AppKit / ScreenCaptureKit / AVFoundation / CoreImage / XcodeGen / sindresorhus/KeyboardShortcuts (SPM)

**Spec:** `docs/superpowers/specs/2026-10-25-screen-recorder-design.md`（本计划所有行为决策均出自该文档，含 5.1 中断处理矩阵）

## Global Constraints

- 最低 macOS 13.0（deployment target 精确 `13.0`）
- 不开 App Sandbox（无 entitlements 沙盒键）；非 App Store 分发
- 输出：MP4；视频 H.264 默认 / HEVC 可选（仅硬件编码器可用时开放）；音频 AAC
- 输出目录默认 `~/Movies/ScreenRecorder`，可在偏好设置更改
- 文件名格式：`录屏_2026-10-25_14-30-05.mp4`（时间部分用 `-` 不用 `:`）
- 界面文案简体中文
- LSUIElement = true（纯菜单栏应用，无 Dock 图标）
- 录制中持 `kIOPMAssertionTypeNoIdleSleep` 电源断言
- 点击高亮用 NSEvent 全局监听（listen-only），不得引入辅助功能权限
- 构建/测试统一命令（所有任务相同，下文简称 **BUILD** / **TEST**；因 `xcode-select` 指向 CLT，所有 xcodebuild/xcrun/swift 调用必须带 `DEVELOPER_DIR` 前缀）：
  - 生成工程：`xcodegen generate`
  - BUILD：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project ScreenRecorder.xcodeproj -scheme ScreenRecorder -configuration Debug -derivedDataPath .build build 2>&1 | tail -5`
  - TEST：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project ScreenRecorder.xcodeproj -scheme ScreenRecorder -configuration Debug -derivedDataPath .build -destination 'platform=macOS' 2>&1 | tail -20`
  - 手动运行：`open .build/Build/Products/Debug/ScreenRecorder.app`
- 已知摩擦：开发构建（本地签名）每次 hash 变化可能要求重新授予屏幕录制权限，属正常现象

## Review Focus

按"最可能坑到真实用户"排序；每条已在归属任务的步骤中钉上测试或手动验收项：

1. **暂停→恢复后音画渐近漂移**（时间戳平移错 1 帧，1 小时后漂移数秒）→ Task 4 单测 + Task 10 手动验收（暂停 5 次后音画同步）
2. **蓝牙麦克风会议中断连** → 静音继续而不是断录/崩溃 → Task 18 手动验收（录制中关闭耳机）
3. **磁盘写满** → 自动收尾产出可播文件而不是死文件 → Task 5 单测（阈值）+ Task 19 终验⑥
4. **全部音频源关闭仍产出有效 MP4**（writer 音频输入缺失路径）→ Task 9 手动验收
5. **>1 小时长录内存稳定** → 帧缓冲不得堆积 → Task 19 验收清单（Activity Monitor 对照）

---

### Task 1: 工程脚手架（XcodeGen + 菜单栏空壳 + 测试 target）

**Files:**
- Create: `project.yml`
- Create: `.gitignore`
- Create: `ScreenRecorder/Sources/App/ScreenRecorderApp.swift`
- Create: `ScreenRecorder/Sources/UI/MenuBar.swift`
- Test: `ScreenRecorderTests/SmokeTests.swift`

**Interfaces:**
- Produces: 可 BUILD/TEST 的工程；app 名 `ScreenRecorder`；scheme 含测试 target

- [ ] **Step 1: 安装/确认 XcodeGen**（`which xcodegen || brew install xcodegen`），`git init` + 写入 `.gitignore`（`.build/`, `*.xcodeproj`, `.DS_Store`）

- [ ] **Step 2: 写 `project.yml`**——要点全部钉死：targets `ScreenRecorder`（type application, platform macOS, deploymentTarget "13.0", sources [ScreenRecorder/Sources], LSUIElement true, 三个 usage description 中文文案：`NSMicrophoneUsageDescription`/`NSCameraUsageDescription`/`NSScreenRecordingUsageDescription` 均为"用于录制会议和教程"，LSApplicationCategoryType `public.app-category.productivity`）、`ScreenRecorderTests`（type bundle.unit-test, 依赖 ScreenRecorder）。scheme `ScreenRecorder` 含 build/test/testTargets

- [ ] **Step 3: 写 `ScreenRecorderApp.swift`**——`@main struct ScreenRecorderApp: App`，`body` 仅含 `MenuBar(content: MenuBarView())` 所需最小壳（MenuExtra 直接写在 body 里也可），无其他逻辑

- [ ] **Step 4: 写 `MenuBar.swift`**——`struct MenuBarView: View`，Label 系统图标 `record.circle`，菜单项：「关于」「退出」仅两项占位

- [ ] **Step 5: 写冒烟测试**——`func testSmoke() { XCTAssertTrue(true) }`（验证测试 target 可运行）

- [ ] **Step 6: `xcodegen generate` 后跑 BUILD 和 TEST**，均须通过

- [ ] **Step 7: 手动运行** `open .build/Build/Products/Debug/ScreenRecorder.app`——菜单栏出现录制图标，App 无 Dock 图标

- [ ] **Step 8: Commit** `git add -A && git commit -m "chore: XcodeGen 工程脚手架 + 菜单栏空壳"`

### Task 2: SettingsStore（TDD）

**Files:**
- Create: `ScreenRecorder/Sources/Core/SettingsStore.swift`
- Test: `ScreenRecorderTests/SettingsStoreTests.swift`

**Interfaces:**
- Produces: `final class SettingsStore`（`ObservableObject`，`@Published` 属性，init(userDefaults: UserDefaults = .standard)，测试用 `UserDefaults(suiteName:)`）；属性与默认值：`fps: Int = 30`、`videoCodec: VideoCodec = .h264`、`captureSystemAudio: Bool = true`、`captureMicrophone: Bool = true`、`micVolume: Double = 1.0`（0…1，浮条/偏好可调——spec 目标 2「可调音量」）、`outputDirectory: URL`（默认 `~/Movies/ScreenRecorder`，不存在时惰性创建）、`countdownSeconds: Int = 5`（合法值 0/3/5/10）、`pipEnabled: Bool = false`、`clickHighlightEnabled: Bool = true`；`enum VideoCodec: String { case h264, hevc }`（含 `var avCodecKey: AVVideoCodecType`）

- [ ] **Step 1: 写失败测试**——断言：新实例各属性等于上述默认值；修改 `fps` 后从同一 suite 新建实例能读回 60；`VideoCodec.hevc.avCodecKey == .hevc`

- [ ] **Step 2: TEST 确认 FAIL**（类型未定义）

- [ ] **Step 3: 实现 SettingsStore**（UserDefaults 持久化，`@AppStorage` 不用——需要注入 suite）

- [ ] **Step 4: TEST 确认 PASS**

- [ ] **Step 5: Commit** `feat: SettingsStore 带默认值持久化`

### Task 3: RecordingFileStore + RecordingListViewModel（TDD）

**Files:**
- Create: `ScreenRecorder/Sources/Core/RecordingFileStore.swift`
- Create: `ScreenRecorder/Sources/Core/RecordingListViewModel.swift`
- Test: `ScreenRecorderTests/RecordingFileStoreTests.swift`
- Test: `ScreenRecorderTests/RecordingListViewModelTests.swift`

**Interfaces:**
- Produces: `struct RecordingFileStore`：`init(baseDirectory: URL)`；`func ensureDirectory() throws`；`static func fileName(for date: Date, extension ext: String = "mp4") -> String`；`func nextFileURL(now: Date = Date()) -> URL`（同名冲突追加 `" (2)"` 递增）；`func contents() -> [RecordingFileMetadata]`；`func delete(_ url: URL)`；`func rename(_ url: URL, toName: String) throws`
- Produces: `struct RecordingFileMetadata: Identifiable`（`id: URL`、`url`、`name`、`sizeBytes: Int64`、`createdAt: Date?`、`duration: TimeInterval?`）
- Produces: `@MainActor final class RecordingListViewModel: ObservableObject`：`@Published var items: [RecordingFileMetadata]`；`init(store: RecordingFileStore, durationProvider: @escaping (URL) async -> TimeInterval? = { try await AVURLAsset(url: $0).load(.duration).seconds }`——默认实现放闭包便于测试注入）；`func refresh() async`；`func delete(_ item:)`；`func rename(_ item:, to:) async throws`；`func revealInFinder(_ item:)`

- [ ] **Step 1: 写失败测试（Store）**——用 `FileManager.temporaryDirectory` 下新目录：`fileName(for:)` 对固定 Date（`2026-10-25 14:30:05`，用 `DateComponents` 构造，calendar/current timezone）返回 `录屏_2026-10-25_14-30-05.mp4`；`nextFileURL` 连续两次调用不冲突；`ensureDirectory` 后目录存在；`rename` 后 `contents()` 反映新名字
- [ ] **Step 2: TEST FAIL**
- [ ] **Step 3: 实现 RecordingFileStore**
- [ ] **Step 4: TEST PASS**
- [ ] **Step 5: 写失败测试（VM）**——临时目录放 2 个假 .mp4 文件，`durationProvider` 注入返回固定 42.0；`await vm.refresh()` 后 `items.count == 2` 且 duration 均为 42.0；`vm.delete(items[0])` 后 `contents` 少一个
- [ ] **Step 6: TEST FAIL**
- [ ] **Step 7: 实现 RecordingListViewModel**
- [ ] **Step 8: TEST PASS**
- [ ] **Step 9: Commit** `feat: 录制文件存储与列表模型`

### Task 4: PauseTimeTracker（TDD）——Review Focus #1

**Files:**
- Create: `ScreenRecorder/Sources/Core/PauseTimeTracker.swift`
- Test: `ScreenRecorderTests/PauseTimeTrackerTests.swift`

**Interfaces:**
- Produces: `struct PauseTimeTracker`：`private(set) var accumulatedPause: CMTime`（初始 `.zero`）；`mutating func pause(at: CMTime)`；`mutating func resume(at: CMTime)`（`accumulatedPause += resume.at − pause.at`，重复 pause 幂等）；`func shifted(_ t: CMTime) -> CMTime`（`t − accumulatedPause`，结果不允许为负，负则返回 `.zero`）

- [ ] **Step 1: 写失败测试**——用 `CMTime(seconds:exact:)`：pause(10s)/resume(40s) 后 `shifted(50s) == 20s`；两次 pause/resume 累加（10-40、60-90 → shifted(100s)==20s）；未暂停时 shifted 恒等；shifted 结果不为负
- [ ] **Step 2: TEST FAIL**
- [ ] **Step 3: 实现**（CMTimeAdd/CMTimeSubtract，注意 timescale 一致性——统一乘算即可，CMTime 运算符已处理）
- [ ] **Step 4: TEST PASS**
- [ ] **Step 5: Commit** `feat: 暂停时间记账与时间戳平移`

### Task 5: DiskSpaceMonitor + PowerAssertionKeeper（TDD 监控器）——Review Focus #3

**Files:**
- Create: `ScreenRecorder/Sources/Core/DiskSpaceMonitor.swift`
- Create: `ScreenRecorder/Sources/Capture/PowerAssertionKeeper.swift`
- Test: `ScreenRecorderTests/DiskSpaceMonitorTests.swift`

**Interfaces:**
- Produces: `protocol DiskFreeSpaceProviding { func freeBytes(at: URL) -> Int64? }`（真实实现 `VolumeFreeSpaceProvider` 用 `URLResourceKey.volumeAvailableCapacityForImportantUsageKey`）
- Produces: `final class DiskSpaceMonitor`：`init(provider: DiskFreeSpaceProviding, url: URL, warnBelow: Int64 = 2_000_000_000, stopBelow: Int64 = 500_000_000, pollInterval: TimeInterval = 30)`；`var onWarn: (() -> Void)?`、`var onStop: (() -> Void)?`（均由实现方保证在主队列回调）；`func checkNow()`；`func startMonitoring()` / `func stopMonitoring()`（DispatchSourceTimer）；状态：warn 每轮最多触发一次直到空间回升越过 warnBelow+hysteresis（500MB）
- Produces: `final class PowerAssertionKeeper`：`func activate(reason: String)`（`IOPMAssertionCreateWithName(kIOPMAssertionTypeNoIdleSleep)`）/ `func deactivate()`

- [ ] **Step 1: 写失败测试**——Fake provider 可编程：初始 3GB 无回调；降到 1.5GB `checkNow()` 触发 `onWarn` 一次；降到 400MB 触发 `onStop`；连续两次 400MB 只触发一次 `onStop`；`provider` 返回 nil（路径不存在）不崩溃、不回调
- [ ] **Step 2: TEST FAIL**
- [ ] **Step 3: 实现 DiskSpaceMonitor + PowerAssertionKeeper**
- [ ] **Step 4: TEST PASS**
- [ ] **Step 5: Commit** `feat: 磁盘空间监控与防睡眠断言`

### Task 6: PermissionChecker + 权限引导界面

**Files:**
- Create: `ScreenRecorder/Sources/Capture/Permissions.swift`
- Create: `ScreenRecorder/Sources/UI/PermissionOnboardingView.swift`

**Interfaces:**
- Produces: `struct PermissionStatus { var screen: Bool; var microphone: AVAuthorizationStatus; var camera: AVAuthorizationStatus }`
- Produces: `enum PermissionChecker`：`static func currentStatus() -> PermissionStatus`（screen 用 `CGPreflightScreenCaptureAccess()`；mic/camera 用 `AVCaptureDevice.authorizationStatus`）；`static func requestMissing(from status: PermissionStatus) async -> PermissionStatus`（mic/camera 走 `AVCaptureDevice.requestAccess`；screen 走 `CGRequestScreenCaptureAccess()` 后引导用户去系统设置）
- Produces: `struct PermissionOnboardingView: View`——列出屏幕/麦克风/摄像头三行状态（已授权绿色/去授权按钮），「打开系统设置」按钮（`NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)` 对应权限页），全部就绪后回调 `onAllGranted`

- [ ] **Step 1: 实现 Permissions.swift**（screen 权限无异步 API，request 后轮询 `CGPreflightScreenCaptureAccess` 直至 true 或用户取消，轮询间隔 1s、上限 60 次，放在 Task 内明确的 `pollScreenPermission()` 私有函数）
- [ ] **Step 2: 实现 PermissionOnboardingView**（SwiftUI，仅当 `!status.screen` 时主窗口展示；状态行样式自定）
- [ ] **Step 3: BUILD 通过；手动验收**——首次运行 App 触发屏幕录制权限系统弹窗；拒绝后在引导界面看到未授权状态，「打开系统设置」能跳到正确面板
- [ ] **Step 4: Commit** `feat: 三大权限检测与引导`

### Task 7: 视频录制主干——SCStream 显示器捕获 → AVAssetWriter

**Files:**
- Create: `ScreenRecorder/Sources/Core/Models.swift`（`CaptureMode`、`RecordingConfiguration`、`CaptureState`，见 Task 11 Interfaces）
- Create: `ScreenRecorder/Sources/Capture/AssetWriterSession.swift`
- Create: `ScreenRecorder/Sources/Capture/SCStreamRecorder.swift`

**Interfaces:**
- Consumes: `RecordingFileStore.nextFileURL`（Task 3）、`SettingsStore`（Task 2）
- Produces: `struct RecordingConfiguration`：`var mode: CaptureMode`、`var captureSystemAudio: Bool`、`var captureMicrophone: Bool`、`var includeCamera: Bool`、`var fps: Int`、`var codec: VideoCodec`、`var outputURL: URL`、`var clickHighlightEnabled: Bool`
- Produces: `enum CaptureMode: Equatable { case display(CGDirectDisplayID); case window(CGWindowID); case region(rect: CGRect, displayID: CGDirectDisplayID) }`
- Produces: `final class AssetWriterSession`：`init(config: RecordingConfiguration, pixelSize: CGSize)`；`func addVideoInput(with sourceFormatHint: CMVideoFormatDescription?) throws`；`func addAudioInput(with format: AVAudioFormat) throws`；`func startWriting()`；`func appendVideo(_ pixelBuffer: CVPixelBuffer, at pts: CMTime) throws`；`func appendAudio(_ sampleBuffer: CMSampleBuffer) throws`；`func finish() async throws -> URL`；`var isReadyForVideoMediaTime: CMTime`（供合成管线取起始时间戳）
- Produces: `final class SCStreamRecorder`：`init(config: RecordingConfiguration)`；`func start() async throws`（按 mode 构造 `SCContentFilter`：display→display filter；window→`SCShareableContent` 查找对应窗口 filter；region→`filterWithRect`；`SCStreamConfiguration` 宽高=pixelSize、`minimumFrameInterval = CMTime(value:1, timescale:fps)`、`queueDepth = 3`、`showsCursor = true`；macOS 13 音频字段 `capturesAudio = config.captureSystemAudio`、`excludesCurrentProcessAudio = true`、`sampleRate = 48000`、`channelCount = 2`）；实现 `SCStreamOutput` 两个队列：video 队列逐帧回调→（Task 15 前直接 append，之后改走合成管线）；audio 队列→Task 8 前丢弃，之后送 SystemAudioMixer；`func stop() async`（`stopCapture` + `writer.finish`）；`var onStreamFailure: ((Error) -> Void)?`（Task 18 用）

- [ ] **Step 1: 实现 Models.swift + AssetWriterSession**（writer `movieFragmentInterval` 不用；`appendVideo` 直接走 `AVAssetWriterInputPixelBufferAdaptor`；`finish` 调 `markAsFinished` 前等待 `input.isReadyForMoreMediaData`）
- [ ] **Step 2: 实现 SCStreamRecorder（仅视频路径）**
- [ ] **Step 3: BUILD 通过**
- [ ] **Step 4: 手动验收**——临时在 MenuBar 加调试菜单项「调试：录全屏 10 秒」（起 SCStreamRecorder 计 10s 自动 stop）；运行后：文件生成于 `~/Movies/ScreenRecorder`、可播、有视频轨、时长≈10s、帧率≈设置值；录一半移动窗口画面正常
- [ ] **Step 5: 移除调试菜单项，Commit** `feat: SCStream→AVAssetWriter 视频录制主干`

### Task 8: 系统声音入轨

**Files:**
- Modify: `ScreenRecorder/Sources/Capture/SCStreamRecorder.swift`（audio 队列回调接 SystemAudioMixer）
- Create: `ScreenRecorder/Sources/Capture/SystemAudioMixer.swift`

**Interfaces:**
- Consumes: `AssetWriterSession.addAudioInput/appendAudio`
- Produces: `final class SystemAudioMixer`：`init(masterFormat: AVAudioFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!)`；`func start(engine: AVAudioEngine, output: @escaping (CMSampleBuffer) -> Void) throws`（mainMixer 挂 tap → `AVAudioConverter` 转 masterFormat → 打包 CMSampleBuffer 输出）；`func enqueueSystemAudio(_ pcm: AVAudioPCMBuffer)`（SCStream 音频经 `AVAudioConverter` 从设备格式转 masterFormat 后塞进 `AVAudioSourceNode` 的 ring buffer——source node 的 render 回调从 ring buffer 取数）；`func setMicrophoneInput(_ format: AVAudioFormat)`（Task 9 用：inputNode tap 直连 mixer）；`func stop()`
- 本 Task 中 SystemAudioMixer 仅接系统声音一路（AVAudioSourceNode）

- [ ] **Step 1: 实现 SystemAudioMixer（仅系统声音路径 + AVAudioSourceNode ring buffer，ring buffer 容量 1s，溢出丢最旧）**
- [ ] **Step 2: SCStreamRecorder.audio 队列：CMSampleBuffer → AVAudioPCMBuffer → `enqueueSystemAudio`；writer 启动时 `addAudioInput(with: masterFormat)`**
- [ ] **Step 3: BUILD 通过**
- [ ] **Step 4: 手动验收**——录 15s 期间播放音乐：成片有声、音画起点同步（误差 <100ms，开头静音段 ≤1s）；不播音乐时录制：成片仍是**有效 MP4**（静音轨或无音轨均可播）
- [ ] **Step 5: Commit** `feat: SCStream 系统声音采集混入`

### Task 9: 麦克风接入 + 双路混音——Review Focus #4

**Files:**
- Modify: `ScreenRecorder/Sources/Capture/SystemAudioMixer.swift`
- Modify: `ScreenRecorder/Sources/Capture/SCStreamRecorder.swift`（组装 engine）

**Interfaces:**
- Consumes: `SystemAudioMixer.setMicrophoneInput`（Task 8 已定义）
- Produces: SystemAudioMixer 最终形态：mic inputNode tap 与 system source node 都进 `AVAudioEngine.mainMixer`，输出 tap 打包 CMSampleBuffer → writer 单条 AAC 音轨（44.1k/48k 取 masterFormat）；`func setMicMuted(Bool)`（浮条静音按钮用，直接 disconnect tap）

- [ ] **Step 1: 实现 mic tap 接入与双路混音**（mic 声道数可能为 1——converter 处理；engine `.prepare()` 后 start；`micVolume` 经 inputNode 的 destination mixer `setValue(_:forInputBus: AVAudioNode_bus:0)` 施加增益）
- [ ] **Step 2: BUILD 通过**
- [ ] **Step 3: 手动验收**——音乐+说话双源：成片两路都清晰可闻、无爆音（音量削波检查：masterMixer 输出音量 0.8 封顶）；仅开 mic 关系统声（SettingsStore 开关生效）：成片只有人声；**全关**：成片有效可播（Review Focus #4）
- [ ] **Step 4: Commit** `feat: 麦克风+系统声音双路混音`

### Task 10: 暂停/恢复集成——Review Focus #1

**Files:**
- Modify: `ScreenRecorder/Sources/Capture/SCStreamRecorder.swift`
- Modify: `ScreenRecorder/Sources/Capture/AssetWriterSession.swift`

**Interfaces:**
- Consumes: `PauseTimeTracker`（Task 4）
- Produces: `SCStreamRecorder`：`func pause()` / `func resume()`；内部规则钉死：paused 期间**丢弃**视频帧与音频包、不写 writer；`resume()` 时 `tracker.resume(at: 当前帧PTS)`；此后所有 append 的 PTS 一律 `tracker.shifted(pts)`（视频与音频同一 tracker）；`var isPaused: Bool`

- [ ] **Step 1: 实现暂停丢弃 + 时间戳平移**（音频尤其注意：暂停间隙不补静音，直接时间平移，AAC 编码器接受非连续 PTS）
- [ ] **Step 2: BUILD 通过**
- [ ] **Step 3: 手动验收**——录 60s，其中暂停 3 次（10s/30s/5s）：成片时长 ≈15s；**音画同步**（口播数拍对齐，Review Focus #1）；暂停期间画面静止段不出现；连续暂停恢复 10 次不崩
- [ ] **Step 4: Commit** `feat: 暂停/恢复与时间戳平移`

### Task 11: CaptureController 状态机（TDD）+ 浮动控制条

**Files:**
- Create: `ScreenRecorder/Sources/Capture/CaptureController.swift`
- Create: `ScreenRecorder/Sources/UI/FloatingControlBar.swift`
- Test: `ScreenRecorderTests/CaptureControllerTests.swift`

**Interfaces:**
- Consumes: `SCStreamRecorder`、`RecordingFileStore`、`DiskSpaceMonitor`、`PowerAssertionKeeper`（前序任务）
- Produces: `enum CaptureState: Equatable { case idle; case countdown(secondsLeft: Int); case recording; case paused; case finishing }`
- Produces: `protocol CaptureSessionManaging { func begin(_ config: RecordingConfiguration) async throws; func pause(); func resume(); func finish() async -> URL? }`（真实实现 `RecordingSessionCoordinator` 包 SCStreamRecorder+writer+monitor+keeper；`begin` 里 activate 电源断言、启动 DiskSpaceMonitor；`finish` 里 deactivate+stopMonitoring）
- Produces: `@MainActor final class CaptureController: ObservableObject`：`@Published private(set) var state: CaptureState`、`@Published private(set) var elapsed: TimeInterval`（recording 时每 0.5s 刷新，不含暂停时长）；`init(session: CaptureSessionManaging, store: RecordingFileStore, countdownSeconds: Int, onFinishedFile: @escaping (URL) -> Void)`；`func start(mode: CaptureMode, config: RecordingConfiguration) async`（countdownSeconds>0 → state 走 countdown 递减，每秒可被 `cancelAndDiscard()` 打断回 idle）；`func pause()/resume()/stop()/cancelAndDiscard()`；非法状态转换（如 idle 时 pause）为 no-op；`func handleSessionFailure(_ error: Error)`（自动走 stop 保存路径 + 通知）
- Produces: `struct FloatingControlBar: View`——显示：红点（录制中呼吸动画）、elapsed（mm:ss）、按钮：暂停/恢复、停止、丢弃（丢弃需二次点击确认，tooltip 与 OmniRecorder 一致「取消录制会丢弃已录制的内容，再次点击确认」）；承载于非激活 `NSPanel`（`styleMask: [.borderless, .nonactivatingPanel]`、`level: .floating`），由 `ScreenRecorderApp` 的 `NSPanel` 包装代码挂载，位置默认屏幕顶部居中，可拖动

- [ ] **Step 1: 写失败测试（状态机）**——注入 FakeSession：`countdownSeconds: 0` 时 `start` 直接 → `.recording`；`pause` → `.paused`；`resume` → `.recording`；`stop` → `.finishing` 后回 `.idle` 且 `onFinishedFile` 收到 Fake 返回的 URL；idle 时 `pause` no-op（state 不变）；`countdownSeconds: 2` 时 start → `.countdown(2)`、推进后 `.countdown(1)`、`cancelAndDiscard` → `.idle` 且 session.begin 未被调
- [ ] **Step 2: TEST FAIL**
- [ ] **Step 3: 实现 CaptureController + RecordingSessionCoordinator**
- [ ] **Step 4: TEST PASS**
- [ ] **Step 5: 实现 FloatingControlBar + NSPanel 挂载**（ elapsed 用 Task 计时器，暂停时不累计——直接读 `CaptureController.elapsed`）
- [ ] **Step 6: BUILD 通过；手动验收**——从菜单「开始录制（全屏）」：倒计时后浮条出现、计时走动；暂停/恢复/丢弃/停止全部符合上述行为；丢弃后无文件、停止后有文件且通知弹出（通知用 `UNUserNotificationCenter`，Info.plist 无需额外键）
- [ ] **Step 7: Commit** `feat: 录制状态机与浮动控制条`

### Task 12: 倒计时覆盖层

**Files:**
- Create: `ScreenRecorder/Sources/UI/CountdownOverlay.swift`
- Modify: `ScreenRecorder/Sources/Capture/CaptureController.swift`（state 变化驱动覆盖层）

**Interfaces:**
- Consumes: `CaptureState.countdown`
- Produces: `final class CountdownOverlayController`：`func show(seconds: Int, onCancel: @escaping () -> Void)`（全屏透明 `NSWindow` + 大号数字动画，点击或 ESC 取消）；`func hide()`

- [ ] **Step 1: 实现 CountdownOverlayController**（每屏一个窗口或主屏一个——主屏即可，YAGNI）
- [ ] **Step 2: BUILD；手动验收**——倒计时设 5s：数字 5→1 逐秒动画；ESC 取消后不开始录制；数字显示在最上层且不抢焦点（点其他 App 不失焦）
- [ ] **Step 3: Commit** `feat: 倒计时覆盖层`

### Task 13: 自定义区域选择器

**Files:**
- Create: `ScreenRecorder/Sources/UI/RegionSelector.swift`

**Interfaces:**
- Produces: `final class RegionSelector`：`static func selectRegion(on displayID: CGDirectDisplayID) async -> CGRect?`——全屏暗色遮罩窗口（该 displayID 坐标空间），鼠标拖拽亮框，松开返回 CGRect（屏幕 point 坐标），ESC 返回 nil；框尺寸实时显示 `W×H`

- [ ] **Step 1: 实现 RegionSelector**（`NSWindow` + overlay view + `NSEvent` 本地 monitor；Retina 下 point↔pixel 换算在 SCStreamRecorder 侧做，此处只产 point rect）
- [ ] **Step 2: BUILD；手动验收**——选区拖拽流畅、ESC 可退、跨屏时选的是目标屏、返回 rect 合理（拖出边界 clamp 在屏内）
- [ ] **Step 3: Commit** `feat: 区域选择器`

### Task 14: 窗口选择器 + 窗口捕获源

**Files:**
- Create: `ScreenRecorder/Sources/UI/WindowPicker.swift`
- Modify: `ScreenRecorder/Sources/Capture/SCStreamRecorder.swift`（window filter 路径若 Task 7 已实现则仅核对）

**Interfaces:**
- Consumes: `CaptureMode.window(CGWindowID)`
- Produces: `struct WindowCandidate: Identifiable { var id: CGWindowID; var title: String; var appName: String; var thumbnail: NSImage? }`
- Produces: `enum WindowPicker`：`static func availableWindows() async -> [WindowCandidate]`（`SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)`；缩略图 macOS 13 用 `CGWindowListCreateImage`（`[.bestResolution]`，128pt 上限），系统窗口（自身面板）过滤掉 bundle id == 本 App）；`struct WindowPickerView: View`——两列（App 名/窗口名 + 缩略图），双击选择回调 `onSelect(CGWindowID)`

- [ ] **Step 1: 实现 WindowPicker**
- [ ] **Step 2: BUILD；手动验收**——列表覆盖所有可见窗口、缩略图清晰、选中后录制成片只有该窗口内容（窗口被遮挡仍录到完整内容）；自己 App 的窗口不在列表
- [ ] **Step 3: Commit** `feat: 窗口选择器与窗口捕获`

### Task 15: 摄像头画中画（CoreImage 合成 + 可拖动浮窗）

**Files:**
- Create: `ScreenRecorder/Sources/Capture/CameraPiPController.swift`
- Create: `ScreenRecorder/Sources/Capture/PiPCompositor.swift`
- Modify: `ScreenRecorder/Sources/Capture/SCStreamRecorder.swift`（视频帧改走合成管线）
- Modify: `ScreenRecorder/Sources/UI/FloatingControlBar.swift`（PiP 小窗拖动锚点）

**Interfaces:**
- Consumes: `AssetWriterSession.appendVideo`
- Produces: `struct PiPFrame { var rectInCapturePixels: CGRect; var cornerRadius: CGFloat = 12 }`
- Produces: `final class CameraPiPController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate`：`func start() throws`（前置广角，`.vga640x480`，videoDataOutput 队列串行）；`func stop()`；`var latestPixelBuffer: CVPixelBuffer?`（锁保护）；`var previewLayer: AVCaptureVideoPreviewLayer?`（浮窗预览用）
- Produces: `final class PiPCompositor`：`init(pixelSize: CGSize)`；`func composite(screenFrame: CVPixelBuffer, pip: CVPixelBuffer?, pipFrame: PiPFrame?, at pts: CMTime, into context: CIContext) -> CVPixelBuffer`（screen 为底，PiP 贴右上角或指定 rect（浮窗在屏坐标的 frame 换算进捕获像素空间，Y 轴翻转注意），CI 连续圆角 mask，无 PiP 时零开销直返原 buffer；点击高亮参数由 Task 16 追加）
- Produces: `final class CameraPiPWindow: NSPanel`——圆形/圆角摄像头预览浮窗，**录制中可拖动**（拖完把 `frameInScreenCoordinates` 提供给合成器）

- [ ] **Step 1: 实现 CameraPiPController + PiPCompositor**（CIContext 复用单个、`useSoftwareRenderer: false`）
- [ ] **Step 2: SCStreamRecorder 帧路径改造：有 PiP 或点击高亮时逐帧 composite 后 append；两者都关时维持原直通路径**
- [ ] **Step 3: 实现 CameraPiPWindow 拖动**
- [ ] **Step 4: BUILD；手动验收**——开 PiP：成片右上角圆角小窗有人脸、说话口型同步；**录制中拖动小窗**：成片里位置实时跟随；关 PiP：画质无回归；60fps + PiP 时不掉帧明显（快速甩动窗口检查）
- [ ] **Step 5: Commit** `feat: 摄像头画中画与帧合成管线`

### Task 16: 点击高亮——Review Focus #5 关联

**Files:**
- Create: `ScreenRecorder/Sources/Capture/ClickHighlightTracker.swift`
- Modify: `ScreenRecorder/Sources/Capture/PiPCompositor.swift`（叠加圆圈）

**Interfaces:**
- Consumes: `PiPCompositor.composite(clickOverlay:)`
- Produces: `struct ClickOverlayState: Equatable { var point: CGPoint; var appearedAt: Date; var radiusInPixels: CGFloat = 24; var fadeDuration: TimeInterval = 0.6 }`
- Produces: `final class ClickHighlightTracker`：`init(enabled: Bool)`；`func start()` / `func stop()`（`NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown])` + 本应用激活期间的 `addLocalMonitorForEvents`；只记录、不拦截）；`func currentState(at date: Date = Date(), inCapturePixelsOf pointConverter: (CGPoint) -> CGPoint) -> ClickOverlayState?`（600ms 内返回带透明度衰减状态，超时 nil）——**状态计算为纯函数抽成 `static func evaluate(click:date:fadeDuration:) -> CGFloat?`（返回透明度）以便单测**
- Test: `ScreenRecorderTests/ClickHighlightTrackerTests.swift`

- [ ] **Step 1: 写失败测试**——`evaluate(click: 0s, date: 0.3s) ≈ 0.5`；`date: 0.7s → nil`；`enabled == false` 时 start 后 monitor 未装（用内部 `isMonitoring` 断言）
- [ ] **Step 2: TEST FAIL → 实现 → TEST PASS**
- [ ] **Step 3: 合成圆圈**（黄色描边半透明圆，CI 椭圆 mask，跟随衰减透明度）
- [ ] **Step 4: BUILD；手动验收**——录屏中点击任意处：成片点击点出现黄圈淡出；系统设置权限无新增要求（未弹任何新权限）
- [ ] **Step 5: Commit** `feat: 鼠标点击高亮`

### Task 17: 全局快捷键 + 偏好设置界面

**Files:**
- Create: `ScreenRecorder/Sources/UI/PreferencesView.swift`
- Modify: `ScreenRecorder/Sources/App/ScreenRecorderApp.swift`（偏好窗口挂载）
- Modify: `project.yml`（SPM 依赖 KeyboardShortcuts，`from: 2.0.0`，产品 `KeyboardShortcuts`）

**Interfaces:**
- Consumes: `SettingsStore`（全部项）、`CaptureController`
- Produces: 快捷键 Name 常量：`startStopRecording = Name("startStopRecording")` 默认 ⇧⌘R、`pauseResumeRecording = Name("pauseResumeRecording")` 默认 ⇧⌘P（`KeyboardShortcuts.Name` + `onKeyUp` 订阅在 App 启动时挂，分别映射 `controller.start(mode:)/stop()` 与 `pause()/resume()`）
- Produces: `struct PreferencesView: View`——Tab：通用（输出目录 NSOpenPanel 选择、倒计时 0/3/5/10、fps 30/60、编码 H.264/HEVC——HEVC 行禁用当 `VTIsHardwareDecodeSupported` 不适用时用 `VTCopyVideoEncoderList` 判定硬件可用性，不可用时禁用并标注"需硬件编码器"）、录制源（系统声音/麦克风开关、PiP 开关、点击高亮开关）、快捷键（两个 `KeyboardShortcuts.RecorderCocoa` 控件）

- [ ] **Step 1: project.yml 加 SPM 依赖，`xcodegen generate`，BUILD 通过**
- [ ] **Step 2: 实现 PreferencesView + 快捷键订阅**
- [ ] **Step 3: 手动验收**——⇧⌘R 在任意 App 前台时开始/停止录制；⇧⌘P 暂停/恢复；改输出目录后新文件落新目录；HEVC 在本机（Apple Silicon）可选
- [ ] **Step 4: Commit** `feat: 全局快捷键与偏好设置`

### Task 18: 稳健性集成（中断矩阵）+ 文件列表窗口

**Files:**
- Create: `ScreenRecorder/Sources/Capture/SourceLossMonitor.swift`
- Create: `ScreenRecorder/Sources/Capture/MicrophoneRouteWatcher.swift`
- Create: `ScreenRecorder/Sources/UI/RecordingListView.swift`
- Modify: `ScreenRecorder/Sources/Capture/CaptureController.swift`（接 SourceLossMonitor/RouteWatcher/DiskSpaceMonitor.onStop）
- Test: `ScreenRecorderTests/SourceLossMonitorTests.swift`

**Interfaces:**
- Consumes: `CaptureController.handleSessionFailure`（Task 11）、`DiskSpaceMonitor.onStop/onWarn`（Task 5）、`RecordingListViewModel`（Task 3）
- Produces: `final class SourceLossMonitor`：`init(onSourceLost: @escaping () -> Void)`；`func start(displayID: CGDirectDisplayID?)`（CG display 断连通知 `CGDisplayWasRemovedNotification` + `SCStreamRecorder.onStreamFailure` 转接）/ `func stop()`
- Produces: `final class MicrophoneRouteWatcher`：监听 `.AVAudioEngineConfigurationChange`，回调 engine 重建 mic tap（`onRouteChanged: () -> Void`）
- Produces: `struct RecordingListView: View`（`Table` 列：名称/大小/时长/创建时间；行操作：播放 `NSWorkspace.shared.open`、Finder 显示、重命名 inline、删除带确认 `NSAlert`；工具栏「刷新」）

- [ ] **Step 1: 写失败测试（SourceLossMonitor）**——Fake 通知中心不便测则测内部分发逻辑：`simulateDisplayRemoved()` → `onSourceLost` 调用且仅一次；`stop()` 后再 simulate 不调用
- [ ] **Step 2: TEST FAIL → 实现三个类 → TEST PASS**
- [ ] **Step 3: CaptureController 集成四条线**：源丢失/`onStreamFailure` → `handleSessionFailure`（保存+通知「录制已自动保存」）；磁盘 onStop → 同上；onWarn → 用户通知；路由变化 → mixer 重建（无 UI）
- [ ] **Step 4: 实现 RecordingListView + 菜单入口「文件列表」**
- [ ] **Step 5: BUILD；手动验收（中断矩阵逐条过）**——录制中①关掉被录窗口→自动保存+通知；②拔外接显示器（如有多屏）→保存+通知；③锁屏 10s→解锁后录制仍在继续；④录制中关闭蓝牙耳机→声音短暂中断后恢复、录制不崩不断（Review Focus #2）；⑤文件列表：播放/重命名/删除/Finder 全部可用
- [ ] **Step 6: Commit** `feat: 中断处理集成与文件列表`

### Task 19: 菜单整合 + 终验（Review Focus #5）

**Files:**
- Modify: `ScreenRecorder/Sources/UI/MenuBar.swift`
- Modify: `ScreenRecorder/Sources/App/ScreenRecorderApp.swift`

**Interfaces:**
- Consumes: 全部前序能力
- Produces: 菜单栏菜单最终形态：**开始录制**子菜单（全屏(显示器列表)/窗口…/区域…）、暂停/恢复、停止、**摄像头画中画**开关、**文件列表…**、**偏好设置…**、关于、退出；状态图标：idle=`record.circle`、recording=红色实心 `stop.circle.fill` 风格区分

- [ ] **Step 1: 实现完整菜单与图标状态切换**
- [ ] **Step 2: BUILD + TEST 全绿**
- [ ] **Step 3: 终验清单（逐条打勾记录到 commit message 或验收文档）**——①三种模式各录一段可播且内容正确；②双声道+人声会议场景 10 分钟；③**1 小时长录**：期间暂停 5 次，成片时长=有效时长，Activity Monitor 内存增长 <200MB 且趋平（Review Focus #5）；④倒计时 3 种时长；⑤快捷键全流程不碰鼠标；⑥磁盘模拟（临时把 stopBelow 调到剩余空间之上）→ 自动收尾可播；⑦偏好设置改动均持久化（重启 App 复核）
- [ ] **Step 4: Commit** `feat: 菜单整合与终验通过`

---

## 明确不做（本计划范围外，出自 spec 非目标）

IAP/水印、视频编辑器、虚拟背景、定时录制、纯音频/纯摄像头模式、画笔标记、点击自动缩放、崩溃分段恢复、签名公证。
