# ScreenRecorder 二期功能（P1–P9）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 补齐 OmniRecorder 全功能矩阵剩余 12 项——按 P1–P9 批次交付点击缩放/音效、边录标记、App/窗口区域模式、键盘可视化、虚拟背景、自启/定时、独立模式、GIF/压缩、编辑器。

**Architecture:** 全部新效果挂进既有「SCStream → 暂停平移 → PiPCompositor → append」热路径：合成器按规格总则 v2 扩展（内容锚定层 → 缩放 → 视口锚定层）；纯逻辑（缩放时间线、笔画画布、键帽聚合、调度、导出核心）全部抽为时钟/依赖注入的 headless 可测类型，接线沿用 SCStreamRecorder 的 provider 闭包注入模式。

**Tech Stack:** Swift 5 · ScreenCaptureKit · AVFoundation（AVAssetReader/Writer/ExportSession/ImageGenerator）· Vision（人像分割）· AppKit（覆盖面板/工具条）· SwiftUI · KeyboardShortcuts

**Spec:** `docs/superpowers/specs/2026-10-30-screen-recorder-phase2-design.md`（本计划从它论证；执行者两份都要读）

## Global Constraints

- 最低系统 **macOS 13.0**；所有新 API 须在 13 可用
- 既有 **274 个测试零修改零弱化**；每任务交付后全量 BUILD+TEST **全绿零告警**：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project ScreenRecorder.xcodeproj -scheme ScreenRecorder -configuration Debug -derivedDataPath .build test 2>&1 | tail -20`（BUILD 用 `build ... | tail -5`；xcodeproj 是 gitignored 的，**新增文件后必须 `xcodegen generate` 再构建**）
- 新纯逻辑一律 headless 可测缝（时钟/依赖注入），沿用仓内 `PauseMediaClock`/`DiscardConfirmation`/`ClickHighlightTracker.evaluate` 模式；UI 不做单测（真机验收覆盖）
- **零新 TCC，唯一已批准例外**：Task 8/9 键盘可视化的「输入监控」权限；授权前静默降级不崩溃
- **合成次序总则 v2**（规格 §5 P2）：内容锚定层（点击环、标记笔画，底帧归一化空间）画在基础帧上 → **统一施加缩放** → 视口锚定层（键盘键帽、PiP）在缩放后叠加；所有效果缺省时热路径零渲染直返原 buffer（与一期逐字节一致）
- **反目标**：效果全开 60fps 长录不得出现可感知掉帧或内存无限增长（逐帧零新分配：合成器缓冲池复用惯例不动）
- **画布开录锁定**：任何模式录制中不做流重配置（P3 画布纪律见规格）
- 音效只进录制音轨、绝无实时监听回放；定时录制**不唤醒 Mac**
- UI 文案简体中文；设置键名 = 属性名（沿用 `pipEnabled`/`clickHighlightEnabled` 惯例）
- **每批次交付时 README 功能清单同步更新（中英两份）**（规格 §6）——由该批最后一个任务或 controller 收尾步骤完成
- 每批次（P1–P9）任务全部合入后，由 controller 生成该批真机验收清单节并交用户验收，**验收通过才开下一批次**（沿用一期惯例）

## Review Focus

1. **效果全开长录平稳性**（反目标#1）：缩放+标记+键盘+背景全开 60fps 连续录制，逐帧分配必须为零（合成器缓冲池）——Task 2 的合成器测试用相同输入连跑两帧断言输出 buffer 复用；真机长录归验收清单。
2. **键盘可视化降级路径**：未授权/安全输入/本地监听三态静默降级——Task 8 状态机测试钉「安全输入标志置位 → snapshot 返回 nil 不抛错」；Task 9 钉「未授权全局监听时本地监听照常」。
3. **缩放中心钳制与连点重定心**：画面边缘/角落点击放大窗口不得越出底帧（Task 1 钳制测试钉四角）；hold 期内新点击重定中心（Task 1 时间线测试）。
4. **音轨存在性矩阵回归**：双源全关+音效开必有音轨（Task 3 gating 测试）；文件列表 m4a 加入后 `.claim/.part` 仍被过滤（Task 13 矩阵测试扩展）。
5. **错过调度不误触发**：睡眠错过 >60s、锁屏、正在录制三条路径都不得自动起录且通知各至多一条（Task 12 调度测试四路径钉死）。

---

### Task 1: AutoZoomState 纯逻辑 + ZoomTransforms 共享缝 + 设置（P1a 核心）

**Files:**
- Create: `ScreenRecorder/Sources/Core/AutoZoomState.swift`
- Create: `ScreenRecorder/Sources/Core/ZoomTransforms.swift`
- Modify: `ScreenRecorder/Sources/Core/SettingsStore.swift`（autoZoomEnabled / autoZoomLevel）
- Modify: `ScreenRecorder/Sources/Core/Models.swift`（RecordingConfiguration 增 `autoZoomEnabled: Bool = false`、`autoZoomLevel: Double = 1.6`）
- Test: `ScreenRecorderTests/AutoZoomStateTests.swift`、`ScreenRecorderTests/SettingsStoreTests.swift`（追加钉测）

**Interfaces:**
- Consumes: 无（纯新增）
- Produces:
  - `enum ZoomTransforms { static func contentTransform(center: CGPoint, level: CGFloat, progress: Double, in bounds: CGRect) -> CGAffineTransform? }`——`center` 为**底帧归一化坐标 0…1**；`progress` 0=原始、1=满档位，缓动在函数内实现（easeInOut）；center 钳制使放大窗口不越出 bounds；参数非法（level≤1、bounds 空）返回 nil。**P9 离线渲染复用此函数（唯一缩放变换真源）**
  - `@MainActor final class AutoZoomState: ObservableObject { init(level: CGFloat, attackDuration: TimeInterval = 0.25, holdDuration: TimeInterval = 1.0, releaseDuration: TimeInterval = 0.4); func click(atNormalizedPoint point: CGPoint, now: TimeInterval); func tick(now: TimeInterval); func currentTransform(in bounds: CGRect, now: TimeInterval) -> CGAffineTransform?; func reset() }`——时间线：attack→hold→release→idle；hold 内再 click 以新中心重启 attack；release 期内再 click 同样重启；点击点先经 `contentTransform` 同款钳制
- SettingsStore：`@Published var autoZoomEnabled: Bool`（默认 false）、`@Published var autoZoomLevel: Double`（默认 1.6；didSet 钳制 `{1.35,1.6,1.9}→1.6`，沿用 fps/countdown 钳制模式）

- [ ] **Step 1: 失败测试**——`AutoZoomStateTests`：`testIdleTransformIsNil`；`testClickAttacksToClampedCenter`（四角点击各一次：transform 平移使放大窗口完全在 bounds 内；level=1.9 bounds=100×100 时中心钳制后放大窗口仍越界为零）；`testHoldThenReclickRecenters`（t=0.2 点击 A、t=0.8 点击 B → t=1.0 的 transform 中心跟随 B）；`testReleaseCompletesToNil`（总时长后 currentTransform 返回 nil）；`testInvalidLevelIsNil`。`SettingsStoreTests` 追加：默认值钉测 + 非法档位钳制钉测（`autoZoomLevel = 99 → 1.6`）
- [ ] **Step 2: 跑测试确认失败**（`xcodebuild ... test`，过滤用 `-only-testing:ScreenRecorderTests/AutoZoomStateTests`；新文件先 `xcodegen generate`）
- [ ] **Step 3: 实现**——`ZoomTransforms.contentTransform` 用 CGAffineTransform（scale 后平移到钳制中心）；`AutoZoomState` 时间线按注入 now 推进，`tick` 仅推进状态不计算变换
- [ ] **Step 4: 全量测试通过零告警**
- [ ] **Step 5: Commit** `feat: P1a 缩放时间线与共享变换缝（AutoZoomState/ZoomTransforms）`

### Task 2: 缩放接入合成热路径 + 偏好 UI（P1a 交付）

**Files:**
- Modify: `ScreenRecorder/Sources/Capture/PiPCompositor.swift`（composite 增 `zoomTransform: CGAffineTransform? = nil` 参数）
- Modify: `ScreenRecorder/Sources/Capture/SCStreamRecorder.swift`（`var zoomStateProvider: (() -> CGAffineTransform?)?`；compositor 构建条件、热路径传参）
- Modify: `ScreenRecorder/Sources/Capture/ClickHighlightTracker.swift`（`var onClick: ((CGPoint, Date) -> Void)?`，recordClick/recordLiveClick 内触发）
- Modify: `ScreenRecorder/Sources/App/ScreenRecorderApp.swift`（AppAssembly 装配：tracker.onClick → zoomState.click（经 `PiPCompositor.capturePixelPoint` 同款换算到归一化底帧坐标）+ makeConfiguration 透传两设置）
- Modify: `ScreenRecorder/Sources/UI/PreferencesView.swift`（录制源 Tab：点击高亮旁新增「点击自动缩放」开关 + 档位三选 1.35x/1.6x/1.9x）
- Test: `ScreenRecorderTests/PiPCompositorTests.swift`（追加 zoom 用例）

**Interfaces:**
- Consumes: Task 1 的 `AutoZoomState.currentTransform(in:now:)` 与 `ZoomTransforms`；一期 `PiPCompositor.composite(screenFrame:pip:pipFrame:clickOverlay:at:into:)`（PiPCompositor.swift:149）与 provider 注入模式（SCStreamRecorder.swift:57-61、构建条件 :105-108）
- Produces: composite 新签名 `composite(screenFrame:pip:pipFrame:clickOverlay:zoomTransform:at:into:) -> CVPixelBuffer`（次序：底帧 → 点击环 → **施加 zoomTransform** → PiP；注意 v2 总则把环挪到缩放之下——一期「环在 PiP 上」的次序在此任务终结）；`zoomStateProvider` 闭包注入惯例与 `clickOverlayProvider` 一致

- [ ] **Step 1: 失败测试**（PiPCompositorTests）：`testZoomAltersOutputPixels`（同一底帧，nil vs 单位外 transform 输出像素可区分）；`testAllEffectsNilReturnsSameBuffer`（全 nil 直返原 buffer——回归守卫）；`testRingRendersUnderZoom`（带 zoom 时环出现在缩放后画面内）；`testPerFrameNoAllocation`（相同输入连跑两帧输出同一 pooled buffer 尺寸命中——Review Focus #1 的代码级钉子）
- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现**——composite 内部重排为 v2 次序；SCStreamRecorder 热路径传 `zoomStateProvider?()`；构建条件 `pipActive || clickActive || zoomActive`
- [ ] **Step 4: 全量测试通过零告警**
- [ ] **Step 5: Commit** `feat: P1a 缩放接入合成热路径与偏好开关`

### Task 3: 点击音效（P1b）

**Files:**
- Modify: `ScreenRecorder/Sources/Capture/SystemAudioMixer.swift`（效果路）
- Modify: `ScreenRecorder/Sources/Capture/SCStreamRecorder.swift`（音轨存在条件 :114 改 `captureSystemAudio || captureMicrophone || clickSoundEnabled`；音效注入装配）
- Modify: `ScreenRecorder/Sources/Core/Models.swift`（RecordingConfiguration 增 `clickSoundEnabled: Bool = false`）
- Modify: `ScreenRecorder/Sources/Core/SettingsStore.swift`（`@Published var clickSoundEnabled: Bool` 默认 false）
- Modify: `ScreenRecorder/Sources/Capture/ClickHighlightTracker.swift`（onClick 已有，Task 2）——无改动则不列
- Create: `ScreenRecorder/Resources/mouse_click.wav`（license-clean 短促音效，实现者自制或生成；≤50KB）
- Modify: `ScreenRecorder/Sources/App/ScreenRecorderApp.swift`（装配：tracker.onClick → mixer.scheduleClickEffect()；makeConfiguration 透传）
- Modify: `ScreenRecorder/Sources/UI/PreferencesView.swift`（录制源 Tab：「点击音效」开关）
- Test: `ScreenRecorderTests/SystemAudioMixerTests.swift`（追加）、makeConfiguration gating 钉测追加到**既有 seam 测试所在文件**（c5d4f85 引入，用 `grep -rn "makeConfiguration" ScreenRecorderTests/` 定位）

**Interfaces:**
- Consumes: Task 2 的 tracker.onClick；一期 SystemAudioMixer（AVAudioEngine 混音→AAC）
- Produces: `SystemAudioMixer.installClickEffect(wavURL: URL) throws`（幂等：重复调用不重复建节点）；`SystemAudioMixer.scheduleClickEffect()`（未 install 时 no-op 不抛错；引擎运行时可连发）；**双源全关+音效开**时 recorder 建纯效果音轨（mixer 无输入 tap、只有效果路）

- [ ] **Step 1: 失败测试**：`testScheduleWithoutInstallIsNoOp`；`testInstallIsIdempotent`（两次 install 后效果节点唯一）；`testConfigAudioTrackMatrix`（RecordingConfiguration 四组合：双开/仅系统/仅麦/双关+音效开 → 音轨存在性分别为 true/true/true/true，双关+音效关 → false）
- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现**——效果路 AVAudioPlayerNode → engine 混音链（tap 于 writer 上游）；暂停期间 schedule 调用方已由 onClick 源保证不触发（tracker stop 于 pause）——实现内不再重复判定
- [ ] **Step 4: 全量测试通过零告警**
- [ ] **Step 5: Commit** `feat: P1b 点击音效与效果专用音轨`

### Task 4: MarkingStroke / MarkingCanvas 纯逻辑（P2 核心）

**Files:**
- Create: `ScreenRecorder/Sources/Core/MarkingStroke.swift`
- Test: `ScreenRecorderTests/MarkingCanvasTests.swift`

**Interfaces:**
- Produces:
  - `struct MarkingColor: Equatable, Codable { var red: Double; var green: Double; var blue: Double }`（预设两色：黑 0,0,0、红 1,0.23,0.19；文档钉定）
  - `struct MarkingStroke: Equatable, Codable { var points: [CGPoint]; var color: MarkingColor; var width: Double }`（points 为**底帧归一化坐标 0…1**；width 归一化于底帧短边，两档 0.004/0.008）
  - `struct MarkingStrokeSnapshot: Equatable { var strokes: [MarkingStroke] }`（合成器每帧入参，值类型）
  - `@MainActor final class MarkingCanvas: ObservableObject { private(set) var strokes: [MarkingStroke]; func beginStroke(color: MarkingColor, width: Double, at point: CGPoint); func extendStroke(to point: CGPoint); func endStroke(); func undoLast(); func clear(); var snapshot: MarkingStrokeSnapshot; static func baseFramePoint(fromViewport point: CGPoint, zoomTransform: CGAffineTransform, bounds: CGRect) -> CGPoint }`——`baseFramePoint` 对当前 zoom 仿射做逆映射（Task 1 变换可逆性依赖）；`extendStroke` 点越出 0…1 时丢弃该点（笔画断续继续，不出界）

- [ ] **Step 1: 失败测试**：`testStrokeAccumulatesPoints`；`testExtendOutsideUnitSquareDropsPoint`；`testUndoRemovesLastStrokeOnly`；`testClearEmptiesAll`；`testBaseFramePointInvertsZoomTransform`（用 `ZoomTransforms.contentTransform` 造变换，viewport 点逆映射回底帧点等于原点——Task 1 消费）；`testSnapshotIsValueCopy`（改 canvas 后旧 snapshot 不变）
- [ ] **Step 2: 跑测试确认失败**（新文件先 `xcodegen generate`）
- [ ] **Step 3: 实现**
- [ ] **Step 4: 全量测试通过零告警**
- [ ] **Step 5: Commit** `feat: P2 标记笔画模型与画布逻辑（MarkingStroke/MarkingCanvas）`

### Task 5: 标记 UI 与合成接入（P2 交付）

**Files:**
- Modify: `ScreenRecorder/Sources/Capture/PiPCompositor.swift`（composite 增 `strokes: MarkingStrokeSnapshot? = nil`；次序：底帧 → 点击环 → 笔画 → 缩放 → PiP）
- Modify: `ScreenRecorder/Sources/Capture/SCStreamRecorder.swift`（`var strokeOverlayProvider: (() -> MarkingStrokeSnapshot?)?`；构建条件并入）
- Create: `ScreenRecorder/Sources/UI/MarkingToolbarPanel.swift`（工具条面板：nonactivating borderless NSPanel，样式对齐浮条——色/宽选择、撤销、清空、关闭；`MarkingHostingView` 同浮条宿主模式）
- Create: `ScreenRecorder/Sources/UI/MarkingOverlayController.swift`（每被录显示器一张透明全屏覆盖 NSPanel 接管拖拽 → canvas.begin/extend/end；坐标换算：屏幕点 → 底帧归一化（全屏=显示器 bounds；区域=采集 rect；越界点丢弃）；标记模式可见条件：`markingEnabled && (state == .recording || .paused)`；**绘图拖拽不触发点击系效果**——面板截获事件即天然不达 tracker 的全局监听（NSEvent 全局监听收不到被本 App 窗口处理的事件），此断言写进测试注释与验收清单）
- Modify: `ScreenRecorder/Sources/App/ScreenRecorderApp.swift`（⇧⌘M：KeyboardShortcuts.Name("toggleMarkingTools") 默认 `shift⌘M`；装配 canvas/provider/面板；state 订阅显隐）
- Modify: `ScreenRecorder/Sources/UI/FloatingControlBar.swift`（录制/暂停态新增画笔图标按钮 → 切换 markingEnabled）
- Test: `ScreenRecorderTests/PiPCompositorTests.swift`（strokes 用例）、`ScreenRecorderTests/MarkingOverlayControllerTests.swift`（坐标换算与显隐逻辑 headless 部分）

**计划代定：标记开关 `markingEnabled` 不持久化**——会话态，AppAssembly 持有 `@Published var markingEnabled`，不进 defaults（每次录制重新开关，避免「上次开着这次忘了」的误烧入）；实现注释里写明。

**Interfaces:**
- Consumes: Task 4 全部；Task 2 的 composite 扩展模式与 provider 注入惯例；一期 FloatingControlBarPanel 面板机制（FloatingControlBar.swift:287）
- Produces: composite 终态参数序 `composite(screenFrame:pip:pipFrame:clickOverlay:strokes:zoomTransform:at:into:)`（Task 9 再追加 keyboardOverlay）；`MarkingOverlayController.init(canvas: MarkingCanvas, modeProvider: @escaping () -> CaptureMode?, stateProvider: @escaping () -> CaptureState)`（seam 便于 headless）

- [ ] **Step 1: 失败测试**：compositor `testStrokesRenderAboveRingsAndUnderZoom`（环+笔画+缩放同帧：像素断言笔画在缩放前的内容空间）；`testAllNilStillReturnsSameBuffer`（回归）；overlay `testScreenPointToNormalizedMapping`（全屏与区域两种 mode 的换算、越界丢弃）；`testPanelVisibilityFollowsState`（recording/paused 可见、其余隐藏——经 stateProvider 注入）
- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现**——面板/覆盖层 UI 照浮条宿主模式；⇧⌘M 订阅沿用 T17 一次挂载门
- [ ] **Step 4: 全量测试通过零告警**
- [ ] **Step 5: Commit** `feat: P2 边录边标记（画笔工具条/覆盖层/合成接入/⇧⌘M）`

### Task 6: App 内容录制模式（P3a）

**Files:**
- Modify: `ScreenRecorder/Sources/Core/Models.swift`（CaptureMode 增 `case app(bundleID: String)`）
- Modify: `ScreenRecorder/Sources/UI/WindowPicker.swift`（`static func availableApps() async -> [AppCandidate]` 与 `static func enumeratedApps(...)` 注入缝——**沿用 enumeratedWindows(:102) 的缝形状**；App 模式 filter 构造：按 bundleID 收集该 App 全部窗口 → `SCContentFilter(desktopIndependentWindows:)`）
- Modify: `ScreenRecorder/Sources/UI/WindowPicker.swift`（WindowPickerView 增「窗口/App」范围切换；App 行=图标+名称+窗口数）
- Modify: `ScreenRecorder/Sources/Capture/SCStreamRecorder.swift` 或相应 filter 构造点（CaptureMode.app → filter）
- Modify: `ScreenRecorder/Sources/UI/MenuBar.swift`（开始录制子菜单加「App…」）
- Modify: `ScreenRecorder/Sources/App/ScreenRecorderApp.swift`（App… 菜单动作 → 选择器（App 范围）→ 起录；last-used 模式联动）
- Modify: `ScreenRecorder/Sources/Capture/SourceLossMonitor.swift` 相关判定（如需：**全部窗口关闭才触发**源丢失——部分关闭继续，规格画布纪律）
- Test: `ScreenRecorderTests/WindowPickerTests.swift`（enumeratedApps 缝测试）、`ScreenRecorderTests/ModelsTests.swift` 若有（CaptureMode 往返）

**Interfaces:**
- Produces: `struct AppCandidate: Equatable { var bundleID: String; var appName: String; var windowCount: Int }`；CaptureMode.app 在 start 时经 WindowPicker 现场解析（选择器已选 bundleID → 起录时枚举该 App 窗口建 filter；零窗口 → 走源丢失路径）

- [ ] **Step 1: 失败测试**：`testEnumeratedAppsGroupsWindowsByBundleID`（注入缝 fixture：3 App 5 窗口 → 计数正确、排除自身）；`testAppModeFilterConstruction`（给定窗口集合 → desktopIndependentWindows filter 的窗口数；filter 类不可构造则以构造入参收集函数为测点——沿用既有 WindowPicker 测试的 fixture 形状）；`testAppExitWithAllWindowsClosedTriggersSourceLoss`（源丢失判定单测）
- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现**——画布纪律照规格（新窗口不入画、部分关闭继续、全关自动保存）
- [ ] **Step 4: 全量测试通过零告警**
- [ ] **Step 5: Commit** `feat: P3a App 内容录制模式（选择器 App 范围/菜单/源丢失联动）`

### Task 7: 窗口区域录制模式（P3b）

**Files:**
- Modify: `ScreenRecorder/Sources/Core/Models.swift`（CaptureMode 增 `case windowRegion(window: CGWindowID, rect: CGRect)`——rect 为**窗口相对系**，原点=窗口内容左上，points）
- Modify: `ScreenRecorder/Sources/UI/RegionSelector.swift`（窗口锚定拖框模式：遮罩覆盖目标窗口 frame、输出窗口相对 rect、钳制于窗口 bounds——沿用 `normalizedRect`/`clamped` 纯函数）
- Modify: `ScreenRecorder/Sources/Capture/SCStreamRecorder.swift`（windowRegion → `SCContentFilter(desktopIndependentWindow:)` + sourceRect=窗口相对 rect 裁剪）
- Modify: `ScreenRecorder/Sources/UI/MenuBar.swift`（开始录制子菜单加「窗口区域…」）
- Modify: `ScreenRecorder/Sources/App/ScreenRecorderApp.swift`（菜单动作 → 窗口选择器 → 窗口内拖框 → 起录）
- Test: `ScreenRecorderTests/RegionSelectorTests.swift`（追加）

**Interfaces:**
- Consumes: 一期 RegionSelector 坐标纯函数（RegionSelector.swift:24-47）、WindowPicker、一期 window 模式的 filter/sourceRect 装配路径
- Produces: windowRegion 的裁剪坐标契约为窗口相对系（**不经 F3 全局坐标坑**）；开录钳制固定（录制中窗口缩小沿用一期窗口模式实测语义，不重配置）

- [ ] **Step 1: 失败测试**：`testWindowAnchoredRectIsWindowRelative`（屏幕点→窗口相对 rect 换算）；`testRectClampedToWindowBounds`（拖出窗口边→钳制）；`testDragSmallerThanMinimumIgnored`（沿用一期区域模式最小尺寸语义）
- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现**
- [ ] **Step 4: 全量测试通过零告警**
- [ ] **Step 5: Commit** `feat: P3b 窗口区域录制（窗口内拖框/窗口相对裁剪）`

### Task 8: KeyboardOverlayState 纯逻辑 + 样式设置（P4 核心）

**Files:**
- Create: `ScreenRecorder/Sources/Core/KeyboardOverlayState.swift`
- Modify: `ScreenRecorder/Sources/Core/SettingsStore.swift`（`@Published var keyboardOverlayEnabled: Bool` 默认 false；`keyboardOverlayColorIsAlternate: Bool` 默认 false（两色单选）；`keyboardOverlayFontSize: Int` 默认 14，钳制 {12,14,18}→14；`keyboardOverlayLingerSeconds: Double` 默认 2，钳制 {1,2,3}→2）
- Test: `ScreenRecorderTests/KeyboardOverlayStateTests.swift`、`ScreenRecorderTests/SettingsStoreTests.swift`（追加）

**Interfaces:**
- Produces:
  - `struct KeyDescriptor: Equatable { var keyCode: UInt64; var characters: String; var modifiers: ModifierFlagsMask }`（纯值，`ModifierFlagsMask` 为 Int 位掩码——不引入 AppKit 类型到 Core）
  - `struct KeyboardOverlayStyle: Equatable { var colorAlternate: Bool; var fontSize: Int }`
  - `struct KeyboardOverlaySnapshot: Equatable { var text: String; var style: KeyboardOverlayStyle }`（合成器入参；text 如 "⌘C"/"A"——修饰符用符号序 ⇧⌃⌥⌘）
  - `@MainActor final class KeyboardOverlayState: ObservableObject { func keyDown(_ key: KeyDescriptor, now: TimeInterval); func keyUp(_ key: KeyDescriptor, now: TimeInterval); func setSecureInputActive(_ active: Bool); func tick(now: TimeInterval); func snapshot(style: KeyboardOverlayStyle, lingerSeconds: Double, now: TimeInterval) -> KeyboardOverlaySnapshot?; func reset() }`——行为：无修饰单键即按即显、停留 linger 后淡出；修饰键按住期间组合持续显示并随新键更新（⌘ 按住再按 C → "⌘C"，再按 V → "⌘V" 覆盖）；松开全部修饰键立即结算进停留期；**secureInputActive 时 snapshot 恒 nil**（静默跳过，Review Focus #2）

- [ ] **Step 1: 失败测试**：`testSingleKeyShowsAndFadesAfterLinger`；`testModifierComboUpdatesWhileHeld`；`testModifierReleaseSettlesCombo`；`testSecureInputSuppressesSnapshot`；`testKeyCodeToGlyphMapping`（⇧⌃⌥⌘ 顺序与符号）；`testStyleParamsRoundTrip`（SettingsStore 钳制钉测）
- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现**
- [ ] **Step 4: 全量测试通过零告警**
- [ ] **Step 5: Commit** `feat: P4 键帽聚合状态机与样式设置（KeyboardOverlayState）`

### Task 9: 键盘监听/权限引导/合成注入（P4 交付）

**Files:**
- Modify: `ScreenRecorder/Sources/Capture/PiPCompositor.swift`（composite 增 `keyboardOverlay: KeyboardOverlaySnapshot? = nil`；次序：… 缩放 → **键盘键帽（底部居中）** → PiP）
- Modify: `ScreenRecorder/Sources/Capture/SCStreamRecorder.swift`（`var keyboardOverlayProvider: (() -> KeyboardOverlaySnapshot?)?`；构建条件并入）
- Create: `ScreenRecorder/Sources/Capture/KeyboardMonitor.swift`（NSEvent 全局+本地 `.keyDown/.keyUp/.flagsChanged` 监听 → KeyDescriptor → KeyboardOverlayState；**Input Monitoring 授权检测**沿用一期 Permissions.swift 模式；授权前仅本地监听降级；`NSEvent.isSecureInputEnabled` 轮询（0.5s timer）驱动 setSecureInputActive；监听生命周期 record-only、跟随录制起停——语义与 ClickHighlightTracker 对称）
- Modify: `ScreenRecorder/Sources/UI/PermissionOnboardingView.swift`（若其权限项结构支持，追加「输入监控」引导项；不支持则新建轻量引导卡——实现者读文件后按最小侵入定）
- Modify: `ScreenRecorder/Sources/UI/PreferencesView.swift`（录制源 Tab：「键盘按键可视化」区：开关+颜色/字号/停留时长；说明行含两条限制文案「拼音输入法组合期显示原始字母」「检测到安全输入时暂停显示」）
- Modify: `ScreenRecorder/Sources/App/ScreenRecorderApp.swift`（装配 monitor/provider；makeConfiguration 无需新增字段——keyboard overlay 走 live provider，开录快照语义仅适用于 enabled 初值）
- Test: `ScreenRecorderTests/PiPCompositorTests.swift`（keyboard 层用例）、`ScreenRecorderTests/KeyboardMonitorTests.swift`（NSEvent 不可 headless——测 Descriptor 换算与生命周期 seam：`KeyboardMonitor` 的 NSEvent 依赖经 `EventSource` 协议注入，测试用假源发事件）

**Interfaces:**
- Consumes: Task 8 全部；一期 Permissions.swift 授权检测模式、ClickHighlightTracker 监听生命周期惯例
- Produces: composite 终态签名 `composite(screenFrame:pip:pipFrame:clickOverlay:strokes:zoomTransform:keyboardOverlay:at:into:)`；`protocol EventSource { func installHandlers(...); }` 形状由实现者按假源测试需求定（缝最小化）

- [ ] **Step 1: 失败测试**：compositor `testKeyboardOverlayRendersBottomCenterAboveZoomUnderPip`；`testAllNilStillReturnsSameBuffer`（回归守卫更新）；monitor `testGlobalHandlerFeedsDescriptorToState`（假源）；`testSecureInputPollSuppresses`；`testLifecycleStopsWithRecording`（start/stop 对称）
- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现**——键帽渲染为圆角键帽样式（CI 文字渲染沿用合成器现有 mask/图像生成惯例）
- [ ] **Step 4: 全量测试通过零告警**
- [ ] **Step 5: Commit** `feat: P4 键盘可视化（全局监听/输入监控引导/键帽合成）`

### Task 10: 摄像头虚拟背景（P5）

**Files:**
- Create: `ScreenRecorder/Sources/Capture/CameraBackgroundProcessor.swift`
- Modify: `ScreenRecorder/Sources/Core/Models.swift`（`enum CameraBackgroundMode: Equatable, Codable { case off; case blur; case builtin(BuiltinBackground) }`、`enum BuiltinBackground: Equatable, Codable { case gradientWarm; case gradientCool; case solidSlate }`——**不内置照片素材**；RecordingConfiguration 增 `cameraBackground: CameraBackgroundMode = .off`）
- Modify: `ScreenRecorder/Sources/Core/SettingsStore.swift`（`@Published var cameraBackground: CameraBackgroundMode` 默认 .off）
- Modify: `ScreenRecorder/Sources/Capture/CameraPiPController.swift`（dataOutput 帧 → processor → pipPixelBufferProvider 上游；processor 旁路：mode==.off 零开销直通）
- Modify: `ScreenRecorder/Sources/UI/PreferencesView.swift`（录制源 Tab 摄像头区：「摄像头背景」四选：原画面/模糊/暖渐变/冷渐变/纯色灰蓝——即 off/blur/三 builtin）
- Test: `ScreenRecorderTests/CameraBackgroundProcessorTests.swift`

**Interfaces:**
- Consumes: 一期 CameraPiPController 管线与四象限 assemblyPlan（**不改其形状**——背景处理挂 dataOutput 帧路径，不动生命周期队列纪律）
- Produces:
  - `protocol PersonSegmenting { func segmentationMask(for pixelBuffer: CVPixelBuffer) async -> CIImage? }`（Vision 实现挂 `VNGeneratePersonSegmentationRequest`；测试缝假实现）
  - `final class CameraBackgroundProcessor { init(mode: CameraBackgroundMode, segmenter: PersonSegmenting); func process(_ frame: CVPixelBuffer) async -> CVPixelBuffer }`——blur=前景叠自身高斯模糊底；builtin=前景叠程序生成渐变/纯色（CIImage 程序生成，零素材文件）；mask 不可得（nil）→ 原帧直通不丢帧

- [ ] **Step 1: 失败测试**：`testOffModePassesThroughSameBuffer`（零开销直通）；`testMaskNilReturnsOriginalFrame`；`testBlurDiffersFromOriginal`（假 segmenter 返回全前景 mask → 输出≠输入）；`testBuiltinBackgroundDiffersFromOriginal`；`testProcessingRetainsFrameDimensions`
- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现**——Vision 请求质量档与队列留给实现者按观感/性能定（规格 §7）
- [ ] **Step 4: 全量测试通过零告警**
- [ ] **Step 5: Commit** `feat: P5 摄像头虚拟背景（人像分割/模糊/内置背景）`

### Task 11: 开机自启（P6a）

**Files:**
- Create: `ScreenRecorder/Sources/Core/LoginItemService.swift`
- Modify: `ScreenRecorder/Sources/Core/SettingsStore.swift`（`@Published var launchAtLogin: Bool` 默认 false）
- Modify: `ScreenRecorder/Sources/UI/PreferencesView.swift`（通用 Tab：「开机自启」开关）
- Modify: `ScreenRecorder/Sources/App/ScreenRecorderApp.swift`（开关变化 → service register/unregister；失败经 UNUserNotificationCenter 通知提示，不弹窗）
- Test: `ScreenRecorderTests/LoginItemServiceTests.swift`

**Interfaces:**
- Produces: `protocol LoginItemRegistering { func setEnabled(_ enabled: Bool) throws }`；`final class SMAppLoginItemService: LoginItemRegistering`（`SMAppService.mainApp` register/unregister 包装）；设置变化时把**结果态**写回 `launchAtLogin`（SMAppService 注册失败时回翻开关——真实态优先于 UI 态）

- [ ] **Step 1: 失败测试**：`testFakeServiceRoundTrip`（假 register 写入结果态）；`testFailureRevertsSettingAndNotifies`（抛错 → 开关回翻 + 通知回调被调）
- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现**
- [ ] **Step 4: 全量测试通过零告警**
- [ ] **Step 5: Commit** `feat: P6a 开机自启（SMAppService）`

### Task 12: 定时录制（P6b）

**Files:**
- Create: `ScreenRecorder/Sources/Core/RecordingScheduler.swift`
- Create: `ScreenRecorder/Sources/UI/ScheduledRecordingPanel.swift`（菜单「定时录制…」面板：开始时刻（日期选择/N 分钟后 stepper）+ 可选时长上限 + 取消）
- Modify: `ScreenRecorder/Sources/UI/MenuBar.swift`（「定时录制…」入口；已排程时显示「取消定时录制」；排程等待期状态图标用倒计时态）
- Modify: `ScreenRecorder/Sources/App/ScreenRecorderApp.swift`（装配：到点 → last-used 模式起录（倒计时默认不加）；时长上限 → 到点自动 `stop()`；错过/忙/锁屏三通知）
- Test: `ScreenRecorderTests/RecordingSchedulerTests.swift`

**Interfaces:**
- Produces: `@MainActor final class RecordingScheduler: ObservableObject { struct Schedule: Equatable { var startAt: Date; var durationLimit: TimeInterval? }; @Published private(set) var active: Schedule?; init(now: @escaping () -> Date, timerFactory: @escaping (@escaping () -> Void) -> AnyCancellable, start: @escaping () async -> Bool, stop: @escaping () -> Void, notify: @escaping (String, String?) -> Void); func schedule(_ s: Schedule); func cancel() }`——四路径（规格钉定）：到点且空闲→start；正在录制/收尾→跳过+notify（不 start）；锁屏→跳过+notify（锁屏检测沿用系统惯例：实现者选 `CGSessionCopyCurrentDictionary` 登录窗判定，抽缝注入便于测试）；触发时刻已过 **>60s**（睡眠错过）→ 不 start、补 notify（标题「定时录制已错过」+ 动作按钮「开始录制」→ start 闭包）；≤60s 视为正常触发。通知每路径**至多一条**（Review Focus #5）

- [ ] **Step 1: 失败测试**：`testFiresWhenIdle`；`testSkipsWhenRecordingNotifiesOnce`；`testSkipsWhenLockedNotifies`；`testMissedByOver60sNotifiesWithStartAction`；`testMissedByUnder60sFiresNormally`；`testCancelPreventsFire`；`testDurationLimitStopsRecording`
- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现**
- [ ] **Step 4: 全量测试通过零告警**
- [ ] **Step 5: Commit** `feat: P6b 定时录制（调度/面板/错过补通知）`

### Task 13: 仅声音录制模式（P7a）

**Files:**
- Modify: `ScreenRecorder/Sources/Core/Models.swift`（CaptureMode 增 `case audioOnly`）
- Modify: `ScreenRecorder/Sources/Capture/SCStreamRecorder.swift`（audioOnly：SCStream 仅音频配置 + AVAssetWriter 纯音轨 `.m4a` 容器——AVAssetWriter outputURL 扩展名 m4a；无视频 input）
- Modify: `ScreenRecorder/Sources/Core/RecordingFileStore.swift`（contents 过滤放宽 `["mp4", "m4a"]`；`.claim/.part` 仍滤；`nextFileURL(now:)` 增 `extension: String = "mp4"` 参数——audioOnly 路径传 "m4a"）
- Modify: `ScreenRecorder/Sources/UI/MenuBar.swift`（开始录制子菜单加「仅声音」）
- Modify: `ScreenRecorder/Sources/App/ScreenRecorderApp.swift`（菜单动作起录；last-used 联动）
- Test: `ScreenRecorderTests/RecordingFileStoreTests.swift`（矩阵扩展）、`ScreenRecorderTests/SCStreamRecorderPauseTests.swift`（audioOnly 音轨钉测，如需）

**Interfaces:**
- Consumes: 一期 SCStream 音频采集（capturesAudio）+ mixer + writer 管线；clickSound 效果路（Task 3）在 audioOnly 下照常可用
- Produces: `.m4a` 成片（QuickLook 原生可播）；文件列表元数据（时长/大小）对 m4a 有效（AVAsset 读取不变）

- [ ] **Step 1: 失败测试**：`testContentsIncludesM4aExcludesClaimAndPart`（五文件矩阵扩为六：mp4×2、m4a、claim、part、txt）；`testNextFileURLExtensionParameter`（默认 mp4 不变；extension: "m4a" → .m4a 名）
- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现**——浮条/暂停/快捷键/通知全兼容（一期路径，无视频分支即自然兼容）
- [ ] **Step 4: 全量测试通过零告警**
- [ ] **Step 5: Commit** `feat: P7a 仅声音录制（m4a 纯音轨/文件列表放宽）`

### Task 14: 仅摄像头录制模式（P7b）

**Files:**
- Modify: `ScreenRecorder/Sources/Core/Models.swift`（CaptureMode 增 `case cameraOnly`）
- Create: `ScreenRecorder/Sources/Capture/CameraOnlyRecorder.swift`（AVCaptureSession videoDataOutput → AssetWriterSession H.264/HEVC MP4；mic 经 AVAudioEngine mixer 照常可混；帧率=设置 fps 的就近支持档（摄像头 30/60 以设备能力为准）；**复用 AssetWriterSession 的 claim/排他纪律**）
- Modify: `ScreenRecorder/Sources/UI/MenuBar.swift`（开始录制子菜单加「仅摄像头」）
- Modify: `ScreenRecorder/Sources/App/ScreenRecorderApp.swift`（菜单动作；此模式下 PiP/缩放/标记/点击高亮入口置灰或忽略——规格钉定不可用）
- Modify: `ScreenRecorder/Sources/Capture/CaptureController.swift`（cameraOnly 的 session 装配分支——实现者读 :321 start 流程后按最小侵入接）
- Test: `ScreenRecorderTests/CameraOnlyRecorderTests.swift`（writer 装配与 lifecycle seam，照 AssetWriterSessionTests/CameraPiPTests 的假源模式）

**Interfaces:**
- Consumes: AssetWriterSession（claim 排他、O_EXCL 纪律）、SystemAudioMixer、CameraPiPController 的摄像头枚举惯例（前置广角）
- Produces: `final class CameraOnlyRecorder { init(config: RecordingConfiguration); func start() async throws; func pause(); func resume(); func finish() async -> URL? }`（生命周期与 SCStreamRecorder 同形，coordinator 可互换装配）

- [ ] **Step 1: 失败测试**：`testStartWritesVideoTrackWithClaim`（假源帧 → finish 后 URL 存在）；`testPauseResumeShiftsTimestamps`（PauseMediaClock 同款断言）；`testEffectsUnavailableInCameraOnly`（makeConfiguration gating：cameraOnly 时 includeCamera/缩放/标记/高亮全 false）
- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现**
- [ ] **Step 4: 全量测试通过零告警**
- [ ] **Step 5: Commit** `feat: P7b 仅摄像头录制（CameraOnlyRecorder）`

### Task 15: 导出核心（P8 核心）

**Files:**
- Create: `ScreenRecorder/Sources/Core/ExportCore.swift`
- Test: `ScreenRecorderTests/ExportCoreTests.swift`

**Interfaces:**
- Produces:
  - `struct GIFExportOptions: Equatable { var frameRate: Int = 10; var maxWidth: Int? = 720; var loops: Bool = true }`（frameRate ∈ {5,10,15} 钳制→10；maxWidth ∈ {480,720,nil}）
  - `struct CompressionPreset: Equatable { var codec: VideoCodec; var maxHeight: Int? }`（预设：源码率 HEVC 高效重编码；maxHeight ∈ {nil(源), 1080, 720}）
  - `enum ExportCore { static func gifData(fromFrames frames: [(image: CGImage, pts: CMTime)], options: GIFExportOptions) -> Data`（纯函数：均匀抽帧至目标帧率、缩放至 maxWidth、CGImageDestination GIF、loop 属性）; `static func exportGIF(from url: URL, options: GIFExportOptions, progress: @escaping (Double) -> Void) async throws -> URL`; `static func compress(from url: URL, preset: CompressionPreset, progress: @escaping (Double) -> Void) async throws -> URL }`——输出落源文件同目录，命名 `<原名>_gif.gif` / `<原名>_压缩.mp4`（同名冲突追加序号，沿用 nextFileURL 冲突惯例）
  - 进度回调 0…1，主线程外调用（UI 侧自行 hop）

- [ ] **Step 1: 失败测试**：`testGifDataFromFixtureFrames`（程序生成 10 帧纯色 CGImage → Data 非空且 GIF header 魔数正确、帧数正确）；`testFrameRateClampAndSampling`（30fps 源时长 1s、目标 10fps → 恰 10 帧）；`testGifNamingCollisionAppendsIndex`；compress 的 preset 枚举钉测（无重资源真机测试——AVAssetExportSession 路径归真机验收，代码级只钉参数构造）
- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现**（AVAssetImageGenerator 抽帧策略：均匀采样，规格 §7 留实现者微调）
- [ ] **Step 4: 全量测试通过零告警**
- [ ] **Step 5: Commit** `feat: P8 导出核心（GIF 编码/压缩预设/命名冲突）`

### Task 16: 导出 UI（P8 交付）

**Files:**
- Modify: `ScreenRecorder/Sources/UI/RecordingListView.swift`（contextMenu 增「导出 GIF…」「压缩…」——模态参数小窗 + 进度条；完成后通知/成功提示）
- Modify: `ScreenRecorder/Sources/Core/RecordingListViewModel.swift`（导出动作编排：调 ExportCore、进度转发主线程、错误以通知呈现）
- Test: `ScreenRecorderTests/RecordingListViewModelTests.swift`（追加）

**Interfaces:**
- Consumes: Task 15 全部；一期 RecordingListView contextMenu/模态模式（T18 惯例）
- Produces: 无新缝（编排层）

- [ ] **Step 1: 失败测试**：`testExportProgressHopsToMain`；`testExportFailureSurfacesNotification`（假 ExportCore 抛错）；`testExportSuggestedDestinationName`
- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现**
- [ ] **Step 4: 全量测试通过零告警**
- [ ] **Step 5: Commit** `feat: P8 导出 UI（GIF/压缩入口与进度）`

### Task 17: 离线缩放渲染引擎（P9 核心）

**Files:**
- Create: `ScreenRecorder/Sources/Core/ZoomSegment.swift`
- Create: `ScreenRecorder/Sources/Core/OfflineZoomRenderer.swift`
- Test: `ScreenRecorderTests/OfflineZoomRendererTests.swift`

**Interfaces:**
- Consumes: Task 1 `ZoomTransforms.contentTransform`（唯一变换真源——离线与实时共用）；一期 AssetWriterSession（离线写盘同纪律）
- Produces:
  - `struct ZoomSegment: Codable, Equatable { var start: TimeInterval; var end: TimeInterval; var level: Double; var center: CGPoint }`（center 归一化底帧坐标；约束 `start < end`、level ∈ {1.35,1.6,1.9}、`segments` 按时间排序且互不重叠——校验函数 `static func validate(_ segments: [ZoomSegment]) -> [ZoomSegment]`（排序+钳制+去重叠，重叠保留先者））
  - `enum OfflineZoomRenderer { static func render(sourceURL: URL, segments: [ZoomSegment], options: ExportVideoOptions, progress: @escaping (Double) -> Void) async throws -> URL }`
  - `struct ExportVideoOptions: Equatable { var fps: Int?; var maxHeight: Int?; var codec: VideoCodec }`（nil=沿用源）
  - 渲染循环：AVAssetReader 逐帧 → 该时间点所在 segment 的 `ZoomTransforms.contentTransform`（segment 内部进度=入点缓入 0.25s、出点缓出 0.4s，沿用 Task 1 时长常量）→ 无 segment 帧原样 → AVAssetWriter 写 MP4；音轨直通复制（reader/writer 音轨 passthrough——**音画时间线不动**）

- [ ] **Step 1: 失败测试**：`testValidateSortsClampsAndDropsOverlaps`；`testSegmentEasingWindowMatchesLiveConstants`（0.25/0.4 常量单一真源断言）；`testRenderSmallFixtureVideo`（程序生成 2s 30fps 纯色+运动标记源 → 带 1 个 segment 渲染 → 输出时长一致、中心区域像素在 hold 段被放大可区分；音轨 passthrough 用生成源带静音轨断言时间线不变）
- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现**
- [ ] **Step 4: 全量测试通过零告警**
- [ ] **Step 5: Commit** `feat: P9 离线缩放渲染引擎（ZoomSegment/OfflineZoomRenderer）`

### Task 18: 编辑器 UI（P9 交付）

**Files:**
- Create: `ScreenRecorder/Sources/UI/ZoomEditorWindow.swift`（时间线窗：AVPlayer 预览 + 播放头 + 分段列表（增/选/调档位/拖入出点/中心点九宫格）+ 导出参数（fps/分辨率/编码）+ 预估大小 + 进度）
- Modify: `ScreenRecorder/Sources/UI/RecordingListView.swift`（contextMenu 增「编辑…」）
- Modify: `ScreenRecorder/Sources/Core/RecordingListViewModel.swift`（编辑器编排；分段草稿持久化：`<成片>.zoomdraft.json`（Codable），成片删除时随删）
- Test: `ScreenRecorderTests/ZoomEditorLogicTests.swift`（分段校验/草稿往返/预估大小公式）

**Interfaces:**
- Consumes: Task 17 全部；一期 RecordingListView 模态/window 惯例
- Produces: 草稿文件格式 `ZoomSegment` JSON 数组（版本字段暂无——格式变更属三期）；预估大小 = 源码率 × 时长 × 编码系数（近似值，UI 标注「预估」）

- [ ] **Step 1: 失败测试**：`testDraftRoundTrip`；`testDraftDeletedWithMovie`；`testEstimateFormula`（源 size/时长 → 目标系数）；`testSegmentEditGoesThroughValidate`
- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现**（时间线交互细节规格 §7 留实现者；SwiftUI 在此工具链的限制沿用一期教训——Table/toolbar 已知不可用，用 contextMenu/safeAreaInset 惯例）
- [ ] **Step 4: 全量测试通过零告警**
- [ ] **Step 5: Commit** `feat: P9 缩放分段编辑器（时间线/草稿/导出）`

---

## 批次真机验收（controller 每批次后生成清单节，用户执行）

每批次验收重点（从规格 §6 展开，controller 生成详细步骤）：
- **P1**：效果叠加 60fps 长录 10 分钟平稳（活动监视器内存读数）；缩放四角点击不出画；音效入轨
- **P2**：标记烧入成片；缩放中画笔随内容；拖拽不触发点击系效果；⇧⌘M 全局可用
- **P3**：App 模式多窗口/部分关闭/全关三态；窗口区域子矩形跟随窗口移动
- **P4**：输入监控引导→授权→生效；未授权降级；密码框静默；拼音组合期显示原始字母（已知限制）
- **P5**：三种背景观感（人像边缘）；off 档零回归
- **P6**：自启重启生效；定时四路径（正常/忙/锁屏/睡眠错过）
- **P7**：m4a 可播入列；摄像头成片 H.264 可播
- **P8**：GIF 帧率/宽度参数生效；压缩输出可播更小
- **P9**：分段渲染时长一致、音画对齐；草稿持久化
