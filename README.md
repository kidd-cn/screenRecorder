# ScreenRecorder

macOS 录屏应用：为录制教程与会议而生。基于 ScreenCaptureKit，参考 OmniRecorder 的交互设计从零实现。

A macOS screen recording app for tutorials and meetings. Built from scratch on ScreenCaptureKit, with interaction design modeled on OmniRecorder.

---

## 中文

### 功能特性

- **三种录制模式**：全屏（多显示器可选）/ 窗口 / 区域拖框
- **音频混音**：系统声音与麦克风独立开关；麦克风音量滑杆与录制中实时静音
- **摄像头画中画**：圆角小窗可拖动，预览镜像、成片非镜像（FaceTime 习惯）；设备拔插自动降级与恢复
- **鼠标点击高亮**：黄色圆环淡出，可开关
- **暂停 / 恢复**：成片时长自动剔除暂停段
- **浮动控制条**：可拖动、不抢焦点、红点呼吸；丢弃需两击确认
- **全局快捷键**：`⇧⌘R` 开始/停止（记忆上次模式）、`⇧⌘P` 暂停/恢复、`⇧⌘W` 录制指定窗口——可在偏好设置改键，无需辅助功能权限
- **倒计时**：0 / 3 / 5 / 10 秒可选，屏幕覆盖层逐秒递减，可取消
- **编码**：H.264 / HEVC（硬件编码），帧率 30/60
- **中断保护**：录制中被录窗口关闭或显示器拔出 → 自动保存；锁屏继续录制；磁盘剩余空间不足 → 自动收尾成片
- **退出保护**：录制中退出应用 → 弹窗选择 保存并退出 / 丢弃并退出 / 取消
- **录制列表**：播放、Finder 显示、重命名、删除
- **菜单栏**：图标随状态换装（待命/倒计时/录制中/暂停/收尾），菜单直达所有功能

### 系统要求

- macOS 13.0+
- [Xcode](https://apps.apple.com/app/xcode/id497799835)（含命令行工具）
- [xcodegen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）

### 构建与运行

```bash
xcodegen generate          # 生成 ScreenRecorder.xcodeproj（工程文件不入库）
open ScreenRecorder.xcodeproj   # 方式一：Xcode 里 ⌘R
# 方式二：命令行
xcodebuild -project ScreenRecorder.xcodeproj -scheme ScreenRecorder \
  -configuration Debug -derivedDataPath .build build
open .build/Build/Products/Debug/ScreenRecorder.app
```

> 命令行构建用 Xcode.app 全量 SDK 时需前缀 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`（若 `xcode-select` 已指向 Xcode 则可省）。

首次使用会依次请求 **屏幕录制 / 麦克风 / 摄像头** 权限（按需，用到才弹）；全局快捷键基于 Carbon `RegisterEventHotKey`，不需要辅助功能授权。

### 使用说明

- 应用无常驻 Dock 图标（`LSUIElement`），一切从**菜单栏图标**进入
- 成片默认落在 `~/Movies/ScreenRecorder/录屏_*.mp4`，输出目录可在偏好设置修改
- 「录制指定窗口」：先在 偏好设置 → 录制源 → 窗口捕获 中选择目标窗口，之后按 `⇧⌘W` 直接开录；目标窗口关闭会提示重选
- 双声道会议场景：系统声音 + 麦克风全开即可，成片为立体声 AAC

### 运行测试

```bash
xcodebuild -project ScreenRecorder.xcodeproj -scheme ScreenRecorder \
  -configuration Debug -derivedDataPath .build test
```

### 技术栈

Swift 5 · ScreenCaptureKit（屏幕与系统声音采集）· AVFoundation（混音/H.264/HEVC 写盘）· AVCaptureDevice（画中画）· SwiftUI + AppKit（菜单栏、浮条、偏好设置）· [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)（全局快捷键）· 单 `@MainActor` 装配容器 + 捕获状态机。

---

## English

### Features

- **Three capture modes**: fullscreen (per-display) / window / region rubber-band
- **Audio mixing**: independent system-audio and microphone toggles; live mic volume slider and in-recording mute
- **Camera PiP**: draggable rounded picture-in-picture; mirrored preview, non-mirrored output (FaceTime-style); auto-degrade and recovery on device unplug/replug
- **Click highlighting**: fading yellow ring, toggleable
- **Pause / resume**: pause durations are excluded from the output timeline
- **Floating control bar**: draggable, non-activating, breathing red dot; discard requires a two-click confirm
- **Global hotkeys**: `⇧⌘R` start/stop (remembers last mode), `⇧⌘P` pause/resume, `⇧⌘W` record a chosen window — rebindable in preferences, no Accessibility permission needed
- **Countdown**: 0 / 3 / 5 / 10 s with an on-screen overlay, cancellable
- **Encoding**: H.264 / HEVC (hardware), 30 or 60 fps
- **Interruption protection**: captured window closed or display unplugged → auto-save; recording survives lock; low disk space → auto-finalize the take
- **Quit protection**: quitting mid-recording offers Save & Quit / Discard & Quit / Cancel
- **Recording list**: play, reveal in Finder, rename, delete
- **Menu bar**: state-aware icon (idle/countdown/recording/paused/finishing) with full menu access

### Requirements

- macOS 13.0+
- [Xcode](https://apps.apple.com/app/xcode/id497799835) with command-line tools
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

### Build & Run

```bash
xcodegen generate          # generates ScreenRecorder.xcodeproj (not checked in)
open ScreenRecorder.xcodeproj   # option 1: ⌘R in Xcode
# option 2: command line
xcodebuild -project ScreenRecorder.xcodeproj -scheme ScreenRecorder \
  -configuration Debug -derivedDataPath .build build
open .build/Build/Products/Debug/ScreenRecorder.app
```

> If `xcode-select` points at the CLT rather than Xcode.app, prefix xcodebuild with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

First use prompts for **Screen Recording / Microphone / Camera** permissions as needed. Global hotkeys use Carbon `RegisterEventHotKey` — no Accessibility permission required.

### Usage Notes

- The app is menu-bar-only (`LSUIElement`); there is no Dock icon
- Recordings land in `~/Movies/ScreenRecorder/录屏_*.mp4` by default; the output directory is configurable
- Window capture: pick a target window once under Preferences → Sources → Window Capture, then `⇧⌘W` starts recording it directly; a stale target prompts re-selection
- For stereo meeting captures, enable both system audio and microphone — output is stereo AAC

### Tests

```bash
xcodebuild -project ScreenRecorder.xcodeproj -scheme ScreenRecorder \
  -configuration Debug -derivedDataPath .build test
```

### Stack

Swift 5 · ScreenCaptureKit (screen + system audio capture) · AVFoundation (mixing, H.264/HEVC writing) · AVCaptureDevice (PiP) · SwiftUI + AppKit (menu bar, floating bar, preferences) · [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) (global hotkeys) · single `@MainActor` assembly container + capture state machine.
