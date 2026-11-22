# 三期速赢批次（Q1–Q6）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 补齐 Omi 对照盘点①组六件——截图、光标开关、重新录制、移出列表、长录时长提醒、编辑后动作。

**Architecture:** 六件互不依赖，全部挂在既有缝上：`RecordingConfiguration` 开录快照链（Q2/Q5）、`RecordingFileStore.contents()` 单点过滤（Q4）、`DiscardConfirmation` 两击确认 + `bypassCountdown` 起录缝（Q3）、`ExportNotifying` 导出完成回调（Q6）。纯逻辑一律抽 headless 可测缝。

**Tech Stack:** Swift 5 · ScreenCaptureKit · ImageIO/CoreGraphics（截图）· UserDefaults · SwiftUI+AppKit

**Spec:** `docs/superpowers/specs/2026-11-08-quickwins-batch-design.md`（批准版，微决策以它为准）

## Global Constraints

- 最低系统 **macOS 13**；非沙盒、LSUIElement；**零新 TCC**（截图复用屏幕录制既有授权）
- 测试全绿**零告警**；基线 **436 测试**；新逻辑一律 headless 钉测（纯函数 + 时钟/依赖注入），测试绝不触真 CGSession/真 SCStream
- xcodegen 管工程：**新增文件后必须 `xcodegen generate`** 再构建
- UI 文案**简体中文**；通知尽力而为、被拒静默（`try?`，绝不弹错误窗）
- 开录快照语义：Q2/Q5 偏好录制中改动不影响本场，下一场生效
- 构建/测试命令（一律带前缀）：
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build|test -project ScreenRecorder.xcodeproj -scheme ScreenRecorder -derivedDataPath .build -destination 'platform=macOS'`
- 单测过滤：`-only-testing:ScreenRecorderTests/<类名>/<方法名>`
- 提交风格：conventional commits 中文（`feat(Q2): …`），一任务一提交；**直接在 master 工作**（本仓库惯例）
- README.md 与 README.en.md 功能清单**每任务同步**（本批交付纪律）

## Review Focus

1. **Q6 误删原始文件**（本批最大风险）：导出失败 / 输出文件不存在 / 输出 0 字节三种场景，删除**绝不执行** → Task 6 `PostExportActions.plan` 组合钉测 + `deleteOriginalAndDraft` 校验链钉测
2. **Q4 陈旧集合**：文件被外部删除后集合项自愈剔除、不阻塞列表；重命名后文件重新出现（可再移出）→ Task 2 contents 钉测
3. **Q3 误重开**：武装窗口（5s）外单击永不触发；超时未回 idle 不重开不循环 → Task 4 `RestartOrchestrator` 预算钉测（两击窗口语义复用已钉测的 DiscardConfirmation）
4. **Q1 HiDPI 裁剪**：Retina 2x 换算 + CG 全局坐标（左下原点）→ 位图坐标（左上原点）的 Y 翻转，跨显示器原点偏移 → Task 3 crop 钉测（非方图 + 非零原点数字）
5. **Q5 恰一条**：暂停冻结不产生提醒、恢复后跨档恰一条、`0 = 从不` 零提醒、重开新场集合复位 → Task 5 `dueHour` + 控制器钉测

---

### Task 1: Q2 录制鼠标光标开关（开录快照）

**Files:**
- Modify: `ScreenRecorder/Sources/Core/SettingsStore.swift`（新增属性，模式照抄 ：73 `clickHighlightEnabled`：`@Published` + `didSet` 落 defaults + `static let …Key` + init 读缺省）
- Modify: `ScreenRecorder/Sources/Core/Models.swift`（`RecordingConfiguration` 追加字段）
- Modify: `ScreenRecorder/Sources/App/ScreenRecorderApp.swift`（`makeConfiguration` ~:367 追加快照映射）
- Modify: `ScreenRecorder/Sources/Capture/SCStreamRecorder.swift:218`（`streamConfig.showsCursor = true` → `= config.captureMouseCursor`——唯一接线点，五种 SCStream 画面模式自动全覆盖；audioOnly/cameraOnly 分支不设此键）
- Modify: `ScreenRecorder/Sources/UI/PreferencesView.swift`（`RecordingSourcesTab` 加 Toggle，照抄既有开关布局）
- Test: `ScreenRecorderTests/SettingsStoreTests.swift`

**Interfaces:**
- Produces: `SettingsStore.captureMouseCursor: Bool`（默认 **true**，UserDefaults 键 `"captureMouseCursor"`）；`RecordingConfiguration.captureMouseCursor: Bool = true`（缺省 true = 保持现状）

- [ ] **Step 1: 写失败测试**（夹具构造照抄本文件既有用例）

```swift
// SettingsStoreTests.swift
func testCaptureMouseCursorDefaultsTrueAndPersists() {
    // fresh defaults → captureMouseCursor == true
    // 翻转为 false → 重新用同一 suite 构造 SettingsStore → 仍为 false（持久化）
    // defaults 写回 true → 再构造 → true（往返）
}
```

- [ ] **Step 2: 跑测证失败**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project ScreenRecorder.xcodeproj -scheme ScreenRecorder -derivedDataPath .build -destination 'platform=macOS' -only-testing:ScreenRecorderTests/SettingsStoreTests/testCaptureMouseCursorDefaultsTrueAndPersists`
Expected: FAIL（`captureMouseCursor` 不存在）

- [ ] **Step 3: 实现**——SettingsStore 属性（默认 true）→ `RecordingConfiguration` 字段 → `makeConfiguration` 加 `captureMouseCursor: settings.captureMouseCursor` → SCStreamRecorder:218 改读 config → RecordingSourcesTab 加 `Toggle("录制鼠标光标", …)`

- [ ] **Step 4: 全量测试过**（同命令去掉 -only-testing；436 基线 + 新增）
- [ ] **Step 5: README 两份功能清单各加一行**（「鼠标光标开关」语义：默认显示、开录快照）
- [ ] **Step 6: 提交**

```bash
git add -A && git commit -m "feat(Q2): 录制鼠标光标显示开关（开录快照，五种画面模式生效）"
```

---

### Task 2: Q4 移出列表（记账不删文件）

**Files:**
- Modify: `ScreenRecorder/Sources/Core/RecordingFileStore.swift`（`RemovedListStore` + `contents()` 过滤与自愈）
- Modify: `ScreenRecorder/Sources/Core/RecordingListViewModel.swift`（`removeFromList` + init 注入）
- Modify: `ScreenRecorder/Sources/UI/RecordingListView.swift`（contextMenu 加「移出列表」，照抄既有「删除」项布局）
- Modify: `ScreenRecorder/Sources/App/ScreenRecorderApp.swift`（生产 `RemovedListStore` 接 UserDefaults，传入 fileStore 与 VM）
- Test: `ScreenRecorderTests/RecordingFileStoreTests.swift`、`ScreenRecorderTests/RecordingListViewModelTests.swift`

**Interfaces:**
- Produces:
```swift
struct RemovedListStore {
    static let key = "removedFromListPaths"   // UserDefaults 存 [String]
    init(read: @escaping () -> Set<String>, write: @escaping (Set<String>) -> Void)
    func remove(_ path: String)               // 读-改-写
}
RecordingFileStore.init(baseDirectory: URL, removedList: RemovedListStore)   // 带默认值（空集、write no-op），既有调用方零改动
RecordingListViewModel.init(…, removedList: RemovedListStore = …空集缺省…)  // 带默认值，既有用例零改动
RecordingListViewModel.removeFromList(_ item: RecordingFileMetadata) async  // 记账 + await refresh()
```
- `contents()` 语义钉定：**目录扫描 ∩ {mp4, m4a} − 已移出集合**；自愈：集合中已不存在的路径剔除并**写回**（仅集合有变化时写）

- [ ] **Step 1: 写失败测试**

```swift
// RecordingFileStoreTests.swift——内存版 RemovedListStore 夹具
func testContentsExcludesRemovedPaths()                       // 移出路径不出现
func testContentsSelfHealsStaleRemovedPaths()                 // 集合里的路径文件已删 → write 收到剔除后的集合
func testContentsRenamedFileReappears()                       // 改名后新路径不在集合 → 条目重现
// RecordingListViewModelTests.swift
func testRemoveFromListPersistsAndRefreshes()                 // removeFromList → store.write 收到该 path → 列表刷新不含
```

- [ ] **Step 2: 跑测证失败**（四个新测试 FAIL：类型不存在）
- [ ] **Step 3: 实现**——`RemovedListStore` → store 注入 + contents 过滤/自愈 → VM 注入 + `removeFromList` → contextMenu 项 → 装配层 UserDefaults 接线（read: `Set(UserDefaults.standard.stringArray(forKey: RemovedListStore.key) ?? [])`，write: `set(Array($0), forKey:)`）
- [ ] **Step 4: 全量测试过**
- [ ] **Step 5: README 两份同步**（录制列表行操作加「移出列表（文件保留原地）」）
- [ ] **Step 6: 提交** `git commit -m "feat(Q4): 文件列表移出条目（文件原地保留，持久化记账+集合自愈）"`

---

### Task 3: Q1 截图（区域拖框 / 整屏）

**Files:**
- Modify: `ScreenRecorder/Sources/Core/RecordingFileStore.swift`（`fileName(for:extension:prefix:)` 与 `nextFileURL(now:extension:prefix:)` 追加 `prefix: String = "录屏"` 参数——既有调用方零改动）
- Create: `ScreenRecorder/Sources/Core/ScreenshotCore.swift`（纯函数：裁剪 + PNG 编码）
- Modify: `ScreenRecorder/Sources/App/ScreenRecorderApp.swift`（`takeScreenshot(displayID:regionInGlobalPoints:)` 编排：RegionSelector → CGDisplayCreateImage → crop → 写盘 → 通知；显示器锚定照抄区域录制入口的既有屏解析）
- Modify: `ScreenRecorder/Sources/Capture/CaptureController.swift:29`（`RecordingNotifying` 加 `notifyScreenshotSaved(fileURL:)`）
- Modify: `ScreenRecorder/Sources/App/RecordingNotifier.swift`（实现：标题「截图已保存」，正文「已保存：<文件名>」）
- Modify: `ScreenRecorder/Sources/UI/MenuBar.swift`（「截图」子菜单：区域截图… + 全屏截图→显示器列表，显示器列表数据源与命名照抄「开始录制→全屏」子菜单；idle 态才可用，非 idle **置灰**同「开始录制」既有 disabled 模式）
- Test: `ScreenRecorderTests/RecordingFileStoreTests.swift`、Create `ScreenRecorderTests/ScreenshotCoreTests.swift`；`SpyNotifier`（`CaptureControllerTests.swift:91`）补 stub

**Interfaces:**
- Produces:
```swift
enum ScreenshotCore {
    /// 位图裁剪：全局 points rect → 像素 rect。scale = image 宽 / displayPointSize 宽；
    /// 局部 points = region − displayOrigin；像素 y 翻转：pixelY = imageHeight − (localY + regionH)·scale。
    /// rect 退化/越界 → nil。
    static func crop(_ image: CGImage, displayOrigin: CGPoint, displayPointSize: CGSize,
                     regionInGlobalPoints: CGRect) -> CGImage?
    static func pngData(_ image: CGImage) -> Data?      // ImageIO，PNG UTType
}
// 装配层（AppAssembly）
func takeScreenshot(displayID: CGDirectDisplayID, regionInGlobalPoints: CGRect?) async
// RecordingNotifying 新方法
func notifyScreenshotSaved(fileURL: URL)
```
- 命名钉定：`截图_yyyy-MM-dd_HH-mm-ss.png`，冲突 " (2)"（走 `nextFileURL(prefix: "截图", extension: "png")`）；**不入文件列表**；失败 NSLog 静默

- [ ] **Step 1: 写失败测试**

```swift
// ScreenshotCoreTests.swift——合成位图（CGContext 画纯色），断言裁剪尺寸与 PNG 魔数
func testCropFullDisplayAtScale2()      // display 20×10 pts，image 40×20 px，region 全屏(0,0,20,10) → 裁出 40×20
func testCropWithDisplayOriginOffsetAndYFlip()  // displayOrigin(100,50)，region(110,55,10,5)，scale2 → 裁出 20×10
func testCropDegenerateRectReturnsNil() // 零宽/全越界 → nil
func testPngDataHasPngMagic()           // data 前两字节 [0x89, 0x50]
// RecordingFileStoreTests.swift
func testFileNameSupportsPrefix()       // fileName(for: d, extension: "png", prefix: "截图") == "截图_…"；缺省 prefix 行为不变（既有用例回归）
```

- [ ] **Step 2: 跑测证失败**
- [ ] **Step 3: 实现**——prefix 参数 → `ScreenshotCore` → 装配编排（取帧时机：`selectRegion` 返回后覆盖层已摘除；失败静默 NSLog）→ 协议方法 + 两处实现 → 菜单 → **`xcodegen generate`**（新文件）
- [ ] **Step 4: 全量测试过**
- [ ] **Step 5: README 两份同步**（新增「截图」功能行）
- [ ] **Step 6: 提交** `git commit -m "feat(Q1): 截图（区域拖框/整屏，PNG 落输出目录+通知，不入列表）"`

---

### Task 4: Q3 重新录制（两击确认 + 绕过倒计时）

**Files:**
- Create: `ScreenRecorder/Sources/Core/RestartOrchestrator.swift`（有界等待 idle 后重开的可测编排）
- Modify: `ScreenRecorder/Sources/UI/FloatingControlBar.swift`（重录按钮 + 独立 `DiscardConfirmation` 实例 + 武装胶囊「再次点击确认重录」——**复用 DiscardConfirmation 类不改名**，视图加按钮，可见态照抄丢弃按钮 recording/paused 逻辑）
- Modify: `ScreenRecorder/Sources/App/ScreenRecorderApp.swift`（`restartRecording()` 编排 + 浮条接线（照抄 `attachMarkingToggle` 先例 :659）+ 菜单项）
- Modify: `ScreenRecorder/Sources/UI/MenuBar.swift`（「重新录制」项，recording/paused 才可用）
- Test: Create `ScreenRecorderTests/RestartOrchestratorTests.swift`

**Interfaces:**
- Consumes: `CaptureController.cancelAndDiscard()`（:677，既有）、`startRecording(mode:bypassCountdown:)`（:327，既有）、`DiscardConfirmation.tap(at:) -> Bool`（:177，既有，5s 窗口已钉测）
- Produces:
```swift
enum RestartOrchestrator {
    /// 轮询 poll（含等待）；首次 true → 执行 start 返回 true；
    /// pollBudget 次全 false → 不执行 start 返回 false。
    static func run(poll: () async -> Bool, pollBudget: Int = 50,
                    start: () async -> Void) async -> Bool
}
// 装配层
func restartRecording()   // guard recording|paused → cancelAndDiscard() → RestartOrchestrator.run(poll: { [weak self] in self?.controller.state == .idle ?? false }, start: { self.startRecording(mode: lastCaptureMode, bypassCountdown: true) })
```
- 语义钉定：配置 = **新一轮设置快照**（走既有起录入口）；预算 50×0.1s = 5s；超时不重开、不通知、不循环

- [ ] **Step 1: 写失败测试**

```swift
// RestartOrchestratorTests.swift
func testRunsStartOnceWhenIdleArrives()      // poll false×2 后 true → start 恰一次，返回 true
func testNeverStartsWhenBudgetExhausted()    // poll 恒 false（budget 内）→ start 零次，返回 false
func testStartsImmediatelyWhenIdleInitially()// poll 首次即 true → start 恰一次
```

- [ ] **Step 2: 跑测证失败**
- [ ] **Step 3: 实现**——`RestartOrchestrator` → 装配 `restartRecording()` → 浮条按钮（第二 `DiscardConfirmation` 实例 + 武装胶囊文案「再次点击确认重录」+ 装配层接线）→ 菜单项 → **`xcodegen generate`**
- [ ] **Step 4: 全量测试过**
- [ ] **Step 5: README 两份同步**（浮条/菜单功能行加「重新录制」）
- [ ] **Step 6: 提交** `git commit -m "feat(Q3): 重新录制（丢弃已录内容+立即重开同模式，两击确认，绕过倒计时）"`

---

### Task 5: Q5 长录时长提醒

**Files:**
- Modify: `ScreenRecorder/Sources/Core/Models.swift`（`RecordingConfiguration.recordingReminderIntervalHours: Int = 0`——0=从不；程序化构造安全缺省）
- Modify: `ScreenRecorder/Sources/Core/SettingsStore.swift`（`recordingReminderIntervalHours: Int` 默认 **1**，持久化）
- Modify: `ScreenRecorder/Sources/Capture/CaptureController.swift`（`static func dueHour(...)` 纯函数 + `notifiedHours` 集合（start 消费 config 时复位）+ `refreshElapsed`（:770）挂点）
- Modify: `ScreenRecorder/Sources/Capture/CaptureController.swift:29`（`RecordingNotifying` 加 `notifyRecordingDurationReached(hours: Int)`）
- Modify: `ScreenRecorder/Sources/App/RecordingNotifier.swift`（实现：标题「长录提醒」，正文「已录制 N 小时，请注意磁盘剩余容量。」）
- Modify: `ScreenRecorder/Sources/App/ScreenRecorderApp.swift`（`makeConfiguration` 快照映射）
- Modify: `ScreenRecorder/Sources/UI/PreferencesView.swift`（`GeneralTab` 加 Picker「录制提醒间隔」：1 小时（默认）/2 小时/3 小时/从不）
- Test: `ScreenRecorderTests/CaptureControllerTests.swift`（`SpyNotifier`:91 补记录）、`ScreenRecorderTests/SettingsStoreTests.swift`

**Interfaces:**
- Produces:
```swift
// CaptureController
/// 语义：intervalHours ≤ 0 → nil；n = Int(elapsed / (intervalHours·3600))；n ≥ 1 且未提醒过 → n
static func dueHour(elapsed: TimeInterval, intervalHours: Int, alreadyNotified: Set<Int>) -> Int?
// RecordingNotifying
func notifyRecordingDurationReached(hours: Int)
// RecordingConfiguration
var recordingReminderIntervalHours: Int = 0
// SettingsStore
var recordingReminderIntervalHours: Int   // 默认 1，键 "recordingReminderIntervalHours"
```

- [ ] **Step 1: 写失败测试**

```swift
// CaptureControllerTests.swift——纯函数钉测
func testDueHourNilForNeverInterval()            // intervalHours 0 / -1 → nil（任意 elapsed）
func testDueHourAtExactMultiples()               // 1h 档：3599→nil、3600→1、7200→2；已含 1 → 3600 nil
func testDueHourTwoHourInterval()                // 2h 档：3600→nil、7200→1
// 控制器钉测（夹具照抄本文件既有 elapsed/假时钟用例）
func testReminderNotifiesExactlyOncePerMultiple()// 跨 1h 恰一条；继续走再跨 2h 再恰一条
func testReminderFrozenDuringPause()             // 暂停期 elapsed 冻结不产生新提醒
func testReminderStateResetsOnNewSession()       // stop→start 后 notifiedHours 复位（同 elapsed 会重新提醒 1h 档的 1）
// SettingsStoreTests.swift
func testRecordingReminderIntervalDefaultsOneAndPersists()
```

- [ ] **Step 2: 跑测证失败**
- [ ] **Step 3: 实现**——纯函数 → config 字段 → 控制器集合与挂点 → 协议 + 实现 → 快照 → 偏好 Picker → SettingsStore
- [ ] **Step 4: 全量测试过**
- [ ] **Step 5: README 两份同步**（新增「长录提醒」功能行）
- [ ] **Step 6: 提交** `git commit -m "feat(Q5): 长录时长提醒（净录时长跨间隔整数倍恰一条通知，1/2/3h/从不）"`

---

### Task 6: Q6 编辑后动作（reveal / 删除原始文件）

**Files:**
- Create: `ScreenRecorder/Sources/Core/PostExportActions.swift`（纯函数动作计划）
- Modify: `ScreenRecorder/Sources/Core/SettingsStore.swift`（两开关）
- Modify: `ScreenRecorder/Sources/Core/RecordingListViewModel.swift`（:61 `ExportNotifying.notifyExportCompleted(fileURL:)` → `notifyExportCompleted(fileURL: URL, originalDeleted: Bool)`；`renderZoom` 成功路径（~:335）接动作；init 注入三缝）
- Modify: `ScreenRecorder/Sources/App/RecordingNotifier.swift`（正文分支）
- Modify: `ScreenRecorder/Sources/App/ScreenRecorderApp.swift`（生产缝：prefs 读 SettingsStore、reveal = `NSWorkspace.shared.activateFileViewerSelecting`、delete = FileManager 校验（存在 + fileSize > 0）→ 删原始 + 删草稿（`<成片>.zoomdraft.json`，既有 helper :262，尽力而为））
- Modify: `ScreenRecorder/Sources/UI/PreferencesView.swift`（`GeneralTab` 加「编辑导出完成后」组两 Toggle：「打开文件所在目录」「删除原始文件」，均默认关）
- Test: Create `ScreenRecorderTests/PostExportActionsTests.swift`；`RecordingListViewModelTests.swift`（SpyExportNotifier :264 签名）、`ZoomEditorLogicTests.swift`（SpyExportNotifier :525 签名）、`SettingsStoreTests.swift`

**Interfaces:**
- Produces:
```swift
enum PostExportAction: Equatable {
    case revealInFinder(URL)
    case deleteOriginal(original: URL, draft: URL?)
}
enum PostExportActions {
    /// 顺序钉定：reveal 在前。delete 仅当 deleteEnabled && outputExists && outputBytes > 0；
    /// draft 随 delete 搭载（draftURL nil 则不带）。
    static func plan(revealEnabled: Bool, deleteEnabled: Bool, outputURL: URL,
                     outputExists: Bool, outputBytes: Int64,
                     originalURL: URL, draftURL: URL?) -> [PostExportAction]
}
// ExportNotifying 签名变更（编译器找出全部调用方：UNRecordingNotifier、两个 SpyExportNotifier）
func notifyExportCompleted(fileURL: URL, originalDeleted: Bool)
// RecordingListViewModel init 新参（均带缺省，既有用例零改动）
postExportPrefs: () -> (reveal: Bool, deleteOriginal: Bool) = { (false, false) }
revealInFinder: (URL) -> Void = { _ in }
deleteOriginalAndDraft: (URL, URL?) -> Bool = { _, _ in false }   // 校验→删→返回是否删成
```
- 文案钉定：`originalDeleted == true` → 正文「已保存：<文件名>（原始文件已删除）」；否则「已保存：<文件名>」

- [ ] **Step 1: 写失败测试**

```swift
// PostExportActionsTests.swift
func testPlanEmptyWhenBothDisabled()
func testPlanRevealOnlyWhenOnlyRevealEnabled()
func testPlanSkipsDeleteWhenOutputZeroBytes()       // deleteEnabled + exists + 0 字节 → 无 delete
func testPlanSkipsDeleteWhenOutputMissing()         // deleteEnabled + !exists → 无 delete
func testPlanDeletesWithDraftRidingAlong()          // 全条件过 → [reveal, delete(original:draft:)]，reveal 在前
func testPlanDeleteWithoutDraftWhenDraftNil()
// RecordingListViewModelTests.swift
func testRenderZoomNotifiesOriginalDeletedTrue()    // 注入 prefs(true) + delete 返回 true → spy 记录 originalDeleted=true
func testRenderZoomNotifiesOriginalDeletedFalseWhenDeleteFails() // delete 返回 false → false
// SettingsStoreTests.swift
func testEditorPostExportSwitchesDefaultOffAndPersist()
```

- [ ] **Step 2: 跑测证失败**
- [ ] **Step 3: 实现**——`PostExportActions` → 协议签名变更（编译器驱动改 UNRecordingNotifier/两 spy/renderZoom 调用点）→ VM 注入缝 + renderZoom 接线（先 refresh → plan → 按序执行 → notify）→ 生产缝 → 偏好组 → **`xcodegen generate`**
- [ ] **Step 4: 全量测试过**
- [ ] **Step 5: README 两份同步**（缩放分段编辑器功能行补「导出后自动打开目录/删除原始文件（默认关）」）
- [ ] **Step 6: 提交** `git commit -m "feat(Q6): 编辑导出后动作（打开所在目录/删除原始文件，三重校验防误删）"`

---

### Task 7: 批次收尾（全量回归 + 真机验收清单）

**Files:**
- Modify: 无代码（如 README 漏项在此补齐）

- [ ] **Step 1: `xcodegen generate` + 全量测试**（基线 436 + 本批新增全部绿、零告警）
- [ ] **Step 2: 构建 Debug 产物并重启 app**（`.build/Build/Products/Debug/ScreenRecorder.app`）
- [ ] **Step 3: 输出真机验收清单给用户**（勾选式）：
  - Q2：开关关→五种画面模式成片均无光标；开→有；录制中改开关不影响本场
  - Q1：区域截图 HiDPI 尺寸正确、遮罩不入画；Esc 取消无文件；PNG 落输出目录 + 通知、不入列表
  - Q3：录 10s→重录→旧内容未落盘、无倒计时直录、计时归零；单击仅武装、5s 后自动解除；定时场（设时长上限）中重录观察剩余上限语义
  - Q4：移出→列表消失、Finder 文件在；重开列表不回来；外部删文件后再开列表正常
  - Q5：设 1h 档录 65min（或临时改小验证）→ 恰一条通知；暂停期不提醒
  - Q6：开「删除原始文件」导出 → 成片入列 + 原始删除 + 草稿删除 + 通知注明；人为造失败（导出中断）→ 原始**未删**
- [ ] **Step 4: 验收通过后如用户要求则推送**

---

## Self-Review 记录

- 规格覆盖：Q1→T3、Q2→T1、Q3→T4、Q4→T2、Q5→T5、Q6→T6、README 纪律→各任务 Step 5、验收→T7；spec §3 每条钉定均有落点。✓
- 类型一致：`RemovedListStore`/`PostExportAction`/`dueHour`/`RestartOrchestrator.run(poll:pollBudget:start:)` 各任务间签名一致；`notifyExportCompleted(fileURL:originalDeleted:)` 变更以编译器找出全部调用方。✓
- Review Focus 五项全部有 owning task 钉测。✓
- 比例：计划只钉接缝/数值/文案，不含实现体。✓
