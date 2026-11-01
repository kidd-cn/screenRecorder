**简体中文** ｜ [English](README.en.md)

# ScreenRecorder

macOS 录屏应用：为录制教程与会议而生。基于 ScreenCaptureKit，参考 OmniRecorder 的交互设计从零实现。

## 功能特性

- **七种录制模式**：全屏（多显示器可选）/ 窗口 / 区域拖框 / 整 App（按应用聚合其全部窗口，画布定格）/ 窗口区域（窗口内拖框裁剪）/ 仅声音（m4a 纯音轨）/ 仅摄像头（前置画面+麦克风可混）
- **音频混音**：系统声音与麦克风独立开关；麦克风音量滑杆与录制中实时静音
- **摄像头画中画**：圆角小窗可拖动，预览镜像、成片非镜像（FaceTime 习惯）；设备拔插自动降级与恢复
- **摄像头虚拟背景**：人像分割背景——模糊 / 暖渐变 / 冷渐变 / 纯色灰蓝，程序生成零素材；过载自动只保最新帧，分割不可用时回原画面
- **鼠标点击高亮**：黄色圆环淡出，可开关
- **点击自动缩放**：点击处放大引导视线，档位 1.35x / 1.6x / 1.9x，连点自动重定中心，可开关
- **点击音效**：短促滴答烧入成片音轨，可开关（系统声与麦全关时自动建效果专用音轨）
- **边录边标记**：录制/暂停中随时在画面上手绘标注——黑/红两色、粗/细两档、撤销/清空，标注烧入成片并在自动缩放时随内容锚定；`⇧⌘M` 呼出/收起标注工具条（可在偏好设置改键）
- **键盘按键可视化**：录制时按键以键帽样式烧入画面底部居中（两色、三档字号、停留时长可调）；需输入监控授权，未授权自动降级仅响应本应用按键；检测到安全输入（密码框）自动暂停显示
- **暂停 / 恢复**：成片时长自动剔除暂停段
- **浮动控制条**：可拖动、不抢焦点、红点呼吸；丢弃需两击确认
- **全局快捷键**：`⇧⌘R` 开始/停止（记忆上次模式）、`⇧⌘P` 暂停/恢复、`⇧⌘W` 录制指定窗口——可在偏好设置改键，无需辅助功能权限
- **倒计时**：0 / 3 / 5 / 10 秒可选，屏幕覆盖层逐秒递减，可取消
- **定时录制**：指定时刻或 N 分钟后自动以上次模式起录，可设时长上限到点自动停；睡眠错过补通知（带「开始录制」按钮），忙/锁屏自动跳过并通知
- **开机自启**：一键登录项（SMAppService），注册失败自动回翻开关并通知
- **编码**：H.264 / HEVC（硬件编码），帧率 30/60
- **中断保护**：录制中被录窗口关闭或显示器拔出 → 自动保存；锁屏继续录制；磁盘剩余空间不足 → 自动收尾成片
- **退出保护**：录制中退出应用 → 弹窗选择 保存并退出 / 丢弃并退出 / 取消
- **录制列表**：播放、Finder 显示、重命名、删除
- **导出**：右键「导出 GIF…」（帧率/宽度/循环可选）与「压缩…」（H.264/HEVC，720/1080），参数小窗+进度条；GIF 落源文件旁，压缩件自动入列
- **菜单栏**：图标随状态换装（待命/倒计时/录制中/暂停/收尾），菜单直达所有功能

## 系统要求

- macOS 13.0+
- [Xcode](https://apps.apple.com/app/xcode/id497799835)（含命令行工具）
- [xcodegen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）

## 构建与运行

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

## 使用说明

- 应用无常驻 Dock 图标（`LSUIElement`），一切从**菜单栏图标**进入
- 成片默认落在 `~/Movies/ScreenRecorder/录屏_*.mp4`，输出目录可在偏好设置修改
- 「录制指定窗口」：先在 偏好设置 → 录制源 → 窗口捕获 中选择目标窗口，之后按 `⇧⌘W` 直接开录；目标窗口关闭会提示重选
- 双声道会议场景：系统声音 + 麦克风全开即可，成片为立体声 AAC

## 运行测试

```bash
xcodebuild -project ScreenRecorder.xcodeproj -scheme ScreenRecorder \
  -configuration Debug -derivedDataPath .build test
```

## 技术栈

Swift 5 · ScreenCaptureKit（屏幕与系统声音采集）· AVFoundation（混音/H.264/HEVC 写盘）· AVCaptureDevice（画中画）· SwiftUI + AppKit（菜单栏、浮条、偏好设置）· [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)（全局快捷键）· 单 `@MainActor` 装配容器 + 捕获状态机。

## 许可证

[MIT](LICENSE)
