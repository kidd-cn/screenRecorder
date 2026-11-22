# 4c-2 关键帧 + 转场 设计规格（剪映对齐·终章）

> 状态：设计定稿待施工。前一进度：批次 1-3 + 4a 片段流 + 4b 多轨音轨 + 4c-1 变调不变声
> 已全部落地（master 34de3c4，590 测试全绿）。本规格为 8 项能力复刻的最后两件。

## 1. 关键帧引擎（音量维度先行）

### 数据模型（EditDocument v4）
- `keyframes: [EditKeyframe]` 追加进 EditDocument（Codable 向后兼容：decodeIfPresent ?? []）。
- `EditKeyframe: Codable, Equatable { outputTime: TimeInterval; volume: Double }`——
  **成品时间轴**坐标（波纹删除时随接合平移：`removingOutputRange` 内对区间右侧关键帧
  平移 −删除长度；`movingSeam` 同理。迁移：v3 草稿无此字段 → 空数组）。
- 语义：替换 4c-1 的自动首尾淡入淡出——存在关键帧时按关键帧插值，无关键帧时保留
  自动淡入淡出（0.5s）。插值：相邻两帧线性；首帧前=首帧值、末帧后=末帧值。
- 纯函数（无头钉测）：`volume(atOutputTime:)`、`removingOutputRange` 的关键帧平移、
  `validate`（时间有序去重 1e-6、volume 钳 0…1）。

### 渲染
- 变调路径（clips 含速度≠1）：`renderPitchPreservedAudio` 的逐帧增益改为
  `keyframes.volume(atOutputTime: t) ?? autoFade(t)`——签名加 `keyframes` 参数。
- 透传路径（全原速）：`appendAudio` 包中点增益同理替换。

### UI（时间线音频车道）
- 关键帧菱形：音频车道中央画 ◇（旋转 45° 方块 8pt，accent 绿）；点击选中（显示时间码
  + 音量）、拖动横向=移时间/纵向=调音量（拖拽中实时预览）、⌥+点击=删除、双击车道空白=
  在该处添加关键帧（音量取当前 sourceVolume）。
- 撤销/重做天然覆盖（keyframes 在 EditDocument 快照内）。

### 钉测清单
validate/插值三态（帧间线性/首前/末后）/波纹删除平移/Codable v3→v4 兼容；
模型级：添加-拖动-删除关键帧全链（真实 mp4 夹具）。

## 2. 片段间转场（黑场 + 交叉溶解）

### 数据模型
- `EditTransition: Codable, Equatable { kind: Kind, duration: TimeInterval }`，
  `Kind = black | crossfade`（v1 只做这两种；duration 钳 0.2…2s，默认 0.5）。
- 挂接点：`transitions: [Int: EditTransition]`（键 = **接缝下标**，即 clip[i] 与
  clip[i+1] 之间的缝；Codable 用 `[String: EditTransition]` 数组对转）。转场占用
  **两侧 clip 各一半时长**（剪映同款：转场期间两 clip 重叠/压黑）。
- `outputDuration` 不变（转场不改变总时长——占用两侧 clip 尾/头部）。波纹删除跨越带
  转场的接缝 → 该转场删除；`movingSeam` 拖带转场接缝 → 转场跟随新边界。

### 渲染（视频）
- 双解码器窗口合成：转场窗口 [boundary − d/2, boundary + d/2)（成品时间）内，
  帧来自两侧 clip 各取对应源帧：black = 前段渐黑 + 后段从黑渐入（每帧乘增益系数，
  CI multiply 或直接像素乘——用 CIExposureAdjust/CIColorMatrix 按 alpha 混黑）；
  crossfade = 前后两帧 CI 混合（`CIImage.applyingFilter("CIDissolveTransitionEngine",
  parameters: [.inputTime: progress])` 或手写 blend alpha）。
- 工程量最大件：现有渲染是单 reader 顺序流；转场窗口内需要**第二解码位置**的帧。
  实现裁定：主 reader 顺序流不变；遇到转场窗口时，用独立 `AVAssetImageGenerator`
  （容差 0）取另一侧对应源帧（转场帧数有限——0.5s×2×30fps=30 帧/转场，性能可接受）。

### 渲染（音频）
- black：窗口内原声按同曲线压到 0 再起（沿用增益链）。
- crossfade：两侧音频交叉——实现裁定 v1 简化为窗口内原声不处理（视觉转场、声音硬切），
  完整 J-cut/L-cut 归后续。

### UI
- 接缝右键菜单（现有返回 nil 处）：「添加黑场转场 0.5s」「添加溶解转场 0.5s」「删除
  转场」；带转场的接缝画橙色菱形标记；点击选中可改时长（复用片段面板形态）。

### 钉测清单
转场占用映射（outputDuration 不变）/删除接缝连带删转场/双解码器取帧的像素探针
（溶解中点 = 两源帧均值）/black 中点恒黑。

## 3. 施工批次
- Task A：关键帧引擎 + 渲染接线 + 钉测（先行，独立可交付）。
- Task B：转场数据模型 + black 渲染 + 接缝菜单 + 钉测。
- Task C：crossfade 双帧合成 + 像素探针钉测。
- Task D：README + 真机验收清单（转场听感/帧精确性/性能）。

## 4. 非目标（记录在案）
- 音量以外的关键帧维度（位置/缩放/旋转）留待 PiP 后期轨需求出现再立项。
- J-cut/L-cut 音频先行转场、更多转场种类（推移/闪白）不在本批。
