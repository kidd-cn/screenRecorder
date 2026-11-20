import AppKit
import CoreGraphics
import ScreenCaptureKit
import SwiftUI

// MARK: - 候选模型（简报 Produces 逐字）

/// 窗口选择器的一行候选：过滤后的可录制可见窗口。
struct WindowCandidate: Identifiable {
    var id: CGWindowID
    var title: String
    var appName: String
    var thumbnail: NSImage?
}

/// App 范围的一行候选（P3a 简报 Produces 逐字）：按 bundle 分组后的可录制 App。
/// 图标不进模型（视图层经 NSWorkspace 按 bundle id 取）；窗口数 = 与选择器同一可见
/// 口径（普通层、非零面积）下的窗口数。
struct AppCandidate: Equatable {
    var bundleID: String
    var appName: String
    var windowCount: Int
}

/// `SCShareableContent` 枚举产物的中性快照：无头可构造，过滤/排序/组装全部在此值类型上
/// 做纯函数（SCShareableContent/SCWindow 需屏幕录制授权，无头不可测——注入缝见
/// `WindowPicker.availableWindows` 的参数）。
struct ShareableWindow: Equatable {
    var windowID: CGWindowID
    var title: String?
    var appName: String?
    var appBundleID: String?
    var frame: CGRect
    /// 窗口层号（kCGWindowLayer）。SCK 的 `SCWindow` 不暴露层号，由
    /// `CGWindowListCopyWindowInfo` 快照补齐（缺配按 0 = 普通层保守放行）。
    var layer: Int
}

/// 一条缩略图请求：窗口 id + 封顶后的展示点尺寸（即 `NSImage(cgImage:size:)` 的 size 口径）。
struct ThumbnailRequest: Equatable {
    var windowID: CGWindowID
    var pointSize: CGSize
}

// MARK: - 错误语义

/// `WindowPicker.availableWindows()` 的失败通道：权限类单独 case（重编译后 ad-hoc 签名
/// 变化使 TCC 授权失效是已知场景，必须能与枚举失败区分开），枚举失败包裹底层描述。
enum WindowPickerError: LocalizedError, Equatable {
    case screenRecordingPermissionDenied
    case contentUnavailable(underlying: String)

    var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionDenied:
            return NSLocalizedString("无法枚举窗口：屏幕录制权限未授予或已失效（重新编译后签名变化会使授权失效，需在系统设置重新勾选并重启应用）", comment: "Picker permission error")
        case .contentUnavailable(let underlying):
            return String(format: NSLocalizedString("无法枚举窗口：%@", comment: "Picker enumeration error"), underlying)
        }
    }
}

// MARK: - WindowPicker（简报 Produces：静态 API，按需调用，不进装配容器）

/// 「从可见窗口列表里选一个来录」的数据侧：枚举 → 过滤 → 缩略图 → 候选数组。
/// 与 RegionSelector 同款纪律：纯静态入口、逐次调用、无状态；自身窗口（浮条/倒计时/
/// 设置窗）经 bundle id 过滤不出现；接线（菜单项/录制入口）归后续任务。
enum WindowPicker {
    /// 本 App 自身窗口过滤锚点（project.yml 钉死的 PRODUCT_BUNDLE_IDENTIFIER）。
    private static let selfBundleID = "com.screenrecorder.app"
    /// 缩略图点尺寸上限（简报钉死 128pt；`.bestResolution` 下 Retina 有 2x 像素余量）。
    static let thumbnailMaxPoint: CGFloat = 128

    /// 可录制的可见窗口候选（简报 Produces）。主 actor 入口：NSImage 与候选数组在主线程
    /// 组装（缩略图裁定）；重活都不占主线程——枚举走 SCK 自己的异步（非隔离缝自动跳离），
    /// 抓帧在 `ScreenFrameCapture`（见 `generateThumbnails`）。
    ///
    /// 失败可诊断：权限未授予/失效抛 `.screenRecordingPermissionDenied`（不弹系统设置
    /// 跳转——那是接线任务的事）；`SCShareableContent` 枚举失败包裹为
    /// `.contentUnavailable(underlying:)`，错误链不断。
    ///
    /// - Parameters:
    ///   - preflight: 注入缝——屏幕录制权限预检（生产 `CGPreflightScreenCaptureAccess`）。
    ///   - loadWindows: 注入缝——可共享内容枚举（生产 `SCShareableContent`，无头不可测）。
    ///   - loadThumbnails: 注入缝——缩略图批量生成（生产 `ScreenFrameCapture` 逐窗口单帧）。
    @MainActor
    static func availableWindows(
        preflight: () -> Bool = preflightScreenRecordingPermission,
        loadWindows: () async throws -> [ShareableWindow] = loadShareableWindowsFromSystem,
        loadThumbnails: @MainActor ([ThumbnailRequest]) async -> [CGWindowID: NSImage] = generateThumbnails,
        thumbnailCap: CGFloat = WindowPicker.thumbnailMaxPoint
    ) async throws -> [WindowCandidate] {
        let selectable = try await loadFilteredWindows(preflight: preflight, loadWindows: loadWindows)
        let requests = selectable.map { source in
            ThumbnailRequest(
                windowID: source.windowID,
                pointSize: thumbnailPointSize(fitting: source.frame.size, maxPoint: thumbnailCap))
        }
        let thumbnails = await loadThumbnails(requests)
        return selectable.map { source in
            WindowCandidate(
                id: source.windowID,
                title: source.title ?? "",
                appName: source.appName ?? "",
                thumbnail: thumbnails[source.windowID])
        }
    }

    /// 现场枚举（T20，⇧⌘W 解析缝）：过滤排序后的中性快照——解析裁定的匹配键（appBundleID /
    /// appName）与面积平决（frame）都在此类型上，`WindowTargetResolver.resolve` 消费。不产
    /// 缩略图（无 UI）；权限短路与错误包裹语义与 `availableWindows` 完全一致（共享
    /// `loadFilteredWindows`）。
    @MainActor
    static func enumeratedWindows(
        preflight: () -> Bool = preflightScreenRecordingPermission,
        loadWindows: () async throws -> [ShareableWindow] = loadShareableWindowsFromSystem
    ) async throws -> [ShareableWindow] {
        try await loadFilteredWindows(preflight: preflight, loadWindows: loadWindows)
    }

    /// 可录制的 App 候选（P3a 简报 Produces，UI 入口）：按 bundle 分组的 App 行。错误
    /// 语义与 `availableWindows` 一致（权限 case / 包裹 case，选择器的失败 UI 原样复用）。
    @MainActor
    static func availableApps() async throws -> [AppCandidate] {
        try await enumeratedApps()
    }

    /// 现场枚举（P3a，注入缝沿用 `enumeratedWindows` 的缝形状）：过滤分组后的 App 候选。
    /// 权限短路与错误包裹语义与 `enumeratedWindows` 完全一致（共享 `loadFilteredWindows`）；
    /// 分组/排序走 `appCandidates`。
    @MainActor
    static func enumeratedApps(
        preflight: () -> Bool = preflightScreenRecordingPermission,
        loadWindows: () async throws -> [ShareableWindow] = loadShareableWindowsFromSystem
    ) async throws -> [AppCandidate] {
        let windows = try await loadFilteredWindows(preflight: preflight, loadWindows: loadWindows)
        return appCandidates(from: windows, excludingBundleID: selfBundleID)
    }

    /// 共享枚举路径（T20 从 availableWindows 抽取，语义逐行保持）：权限预检短路与——
    /// 权限未授予绝不触发内容枚举；枚举失败包裹 `.contentUnavailable(underlying:)`；
    /// 过滤排序走 `selectableWindows`。
    @MainActor
    private static func loadFilteredWindows(
        preflight: () -> Bool,
        loadWindows: () async throws -> [ShareableWindow]
    ) async throws -> [ShareableWindow] {
        guard preflight() else { throw WindowPickerError.screenRecordingPermissionDenied }
        let windows: [ShareableWindow]
        do {
            windows = try await loadWindows()
        } catch {
            throw WindowPickerError.contentUnavailable(underlying: String(describing: error))
        }
        return selectableWindows(from: windows, excludingBundleID: selfBundleID)
    }

    // MARK: 纯函数（无头测试钉死）

    /// 过滤 + 排序，规则与理由：
    /// - **自身 App 剔除**（bundle id 相同）：浮条/倒计时/设置窗一律不出现——简报钉死；
    /// - **layer != 0 剔除**：菜单栏项/状态项/Dock/桌面壁纸等系统内部面板绝大多数无标题
    ///   且不可正常录制，全部集中在非零层；简报「列表覆盖所有可见窗口」指用户可录的
    ///   普通窗口（layer 0）。无标题的普通层窗口**保留**（覆盖度裁定，不按标题过滤）；
    /// - **零面积剔除**：宽或高 < 1pt 的窗口无法作为录制目标；
    /// - **排序确定性**：App 名（大小写不敏感）→ 窗口名（大小写不敏感）→ windowID，
    ///   同参同序，UI 稳定、测试可断言。
    static func selectableWindows(from windows: [ShareableWindow], excludingBundleID bundleID: String) -> [ShareableWindow] {
        windows
            .filter { source in
                guard source.appBundleID != bundleID else { return false }
                guard source.layer == 0 else { return false }
                return source.frame.width >= 1 && source.frame.height >= 1
            }
            .sorted { lhs, rhs in
                let byApp = (lhs.appName ?? "").caseInsensitiveCompare(rhs.appName ?? "")
                if byApp != .orderedSame { return byApp == .orderedAscending }
                let byTitle = (lhs.title ?? "").caseInsensitiveCompare(rhs.title ?? "")
                if byTitle != .orderedSame { return byTitle == .orderedAscending }
                return lhs.windowID < rhs.windowID
            }
    }

    /// App 分组（P3a 纯函数，无头钉测）：可见窗口口径与选择器同源（`selectableWindows`——
    /// 自身剔除/layer 0/非零面积/确定性排序），再按 bundle id 分组计数。无 bundle id 的
    /// 窗口无法作为 App 目标，不进候选；候选按 App 名（大小写不敏感）→ bundle id 排序
    ///（确定性，同参同序）。
    static func appCandidates(from windows: [ShareableWindow], excludingBundleID bundleID: String) -> [AppCandidate] {
        var order: [String] = []
        var names: [String: String] = [:]
        var counts: [String: Int] = [:]
        for source in selectableWindows(from: windows, excludingBundleID: bundleID) {
            guard let id = source.appBundleID else { continue }
            if counts[id] == nil {
                order.append(id)
                names[id] = source.appName ?? ""
                counts[id] = 0
            }
            counts[id, default: 0] += 1
        }
        return order
            .map { AppCandidate(bundleID: $0, appName: names[$0] ?? "", windowCount: counts[$0] ?? 0) }
            .sorted { lhs, rhs in
                let byName = lhs.appName.caseInsensitiveCompare(rhs.appName)
                if byName != .orderedSame { return byName == .orderedAscending }
                return lhs.bundleID < rhs.bundleID
            }
    }

    /// App 模式 filter 构造的入参收集（P3a 纯函数，无头钉测；`SCContentFilter` 需 SCK
    /// 授权对象无头不可构造，裁定钉构造入参）：与选择器同一可见窗口口径（`selectableWindows`）
    /// 再按 bundle id 收集该 App 的全部窗口——start 时现场枚举的结果经本函数喂
    /// `SCContentFilter(display:including:)`（API 偏差台账见 SCStreamRecorder），
    /// 保证「用户看到的窗口数 = filter 窗口数」。
    static func appWindows(ofBundleID bundleID: String, from windows: [ShareableWindow]) -> [ShareableWindow] {
        selectableWindows(from: windows, excludingBundleID: selfBundleID).filter { $0.appBundleID == bundleID }
    }

    /// 展示点尺寸：最长边封顶 `maxPoint`（默认 128pt），等比缩、不放大、零尺寸 → `.zero`。
    static func thumbnailPointSize(fitting pointSize: CGSize, maxPoint: CGFloat = WindowPicker.thumbnailMaxPoint) -> CGSize {
        let longest = max(pointSize.width, pointSize.height)
        guard pointSize.width > 0, pointSize.height > 0, longest > 0 else { return .zero }
        guard longest > maxPoint else { return pointSize }
        let scale = maxPoint / longest
        return CGSize(
            width: (pointSize.width * scale).rounded(.toNearestOrAwayFromZero),
            height: (pointSize.height * scale).rounded(.toNearestOrAwayFromZero))
    }

    // MARK: 系统注入缝的生产实现（无头不可测部分，收敛在最小面积）

    /// 权限预检：只查询不弹窗、不跳设置（弹授权/引导归权限引导与接线任务）。
    private static func preflightScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 可共享内容枚举 → 中性快照。枚举参数简报钉死：
    /// `excludingDesktopWindows(false, onScreenWindowsOnly: true)`（桌面窗口由 layer 过滤兜住）。
    /// `SCWindow` 不暴露层号，用 `CGWindowListCopyWindowInfo` on-screen 快照补
    /// （两份快照间的枚举间隙窗口按 0 = 普通层保守放行，后续 frame 过滤仍有机会剔除）。
    private static func loadShareableWindowsFromSystem() async throws -> [ShareableWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return shareableSnapshots(from: content.windows)
    }

    /// `SCWindow` → 中性快照（P3a 从 `loadShareableWindowsFromSystem` 抽取：SCStreamRecorder
    /// 的 App 模式现场解析复用同一映射与层号口径，保证选择器与 start 时解析看到同一份世界）。
    /// internal：跨文件装配缝。
    static func shareableSnapshots(from windows: [SCWindow]) -> [ShareableWindow] {
        let layers = onScreenWindowLayers()
        return windows.map { window in
            ShareableWindow(
                windowID: window.windowID,
                title: window.title,
                appName: window.owningApplication?.applicationName,
                appBundleID: window.owningApplication?.bundleIdentifier,
                frame: window.frame,
                layer: layers[window.windowID] ?? 0)
        }
    }

    /// on-screen 窗口的 `windowID → kCGWindowLayer` 映射（`CGWindowListCopyWindowInfo`
    /// 未弃用，与 `CGWindowListCreateImage` 的弃用范围无关）。
    private static func onScreenWindowLayers() -> [CGWindowID: Int] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        var layers: [CGWindowID: Int] = [:]
        for info in list {
            guard let number = info[kCGWindowNumber as String] as? Int,
                  let layer = info[kCGWindowLayer as String] as? Int else { continue }
            layers[CGWindowID(number)] = layer
        }
        return layers
    }

    /// 缩略图批量生成（2026-11-14 废弃 API 迁移）：ScreenCaptureKit 逐窗口单帧抓取，
    /// 替代已弃用的 `CGWindowListCreateImage`。像素 2x 对齐旧 `.bestResolution` 清晰度，
    /// `NSImage(cgImage:size:)` 以点尺寸声明 DPI（2x 屏即 2x 清晰度）；窗口已关闭/
    /// 抓取失败缺席映射，候选侧保持 nil 由视图出占位图。
    @MainActor
    private static func generateThumbnails(_ requests: [ThumbnailRequest]) async -> [CGWindowID: NSImage] {
        guard !requests.isEmpty,
              let content = try? await SCShareableContent.excludingDesktopWindows(
                  false, onScreenWindowsOnly: true)
        else { return [:] }
        var windowsByID: [CGWindowID: SCWindow] = [:]
        for window in content.windows {
            windowsByID[window.windowID] = window
        }
        var thumbnails: [CGWindowID: NSImage] = [:]
        for request in requests {
            guard let window = windowsByID[request.windowID],
                  request.pointSize.width > 0, request.pointSize.height > 0 else { continue }
            let config = SCStreamConfiguration()
            config.width = Int(request.pointSize.width) * 2
            config.height = Int(request.pointSize.height) * 2
            config.showsCursor = false
            config.capturesAudio = false
            let filter = SCContentFilter(desktopIndependentWindow: window)
            guard let cgImage = try? await ScreenFrameCapture.capture(
                filter: filter, configuration: config) else { continue }
            thumbnails[request.windowID] = NSImage(cgImage: cgImage, size: request.pointSize)
        }
        return thumbnails
    }
}

/// 窗口选择器 UI（T14 简报 Produces + P3a 范围切换）：窗口范围加载
/// `WindowPicker.availableWindows()`、App 范围加载 `WindowPicker.availableApps()`，
/// 双击行回调 `onSelect(CGWindowID)` / `onAppSelect(bundleID)`。不含窗口容器/录制入口
/// 接线（装配层职责），不加调试 UI。权限/枚举失败原样透出错误文案 + 重试（不跳系统
/// 设置——接线任务职责）。
struct WindowPickerView: View {
    /// 选择范围（P3a）：单个窗口 / 一个应用的全部窗口。
    enum Scope: String, CaseIterable, Identifiable {
        case windows
        case apps

        var id: String { rawValue }
        var title: String {
            self == .windows
                ? NSLocalizedString("窗口", comment: "Picker scope window")
                : NSLocalizedString("App", comment: "Picker scope app")
        }
    }

    var onSelect: (CGWindowID) -> Void
    /// App 行选定回调（P3a）：透传所选 bundleID（装配层决定开录/持久化）。
    var onAppSelect: (String) -> Void
    /// 「下一步」确认回调（2026-11-16 Omi 55.png 多选补齐）：透传当前选中窗口 id 集
    ///（≥1；单选 = 单窗语义，多选 = 多窗口录制/union 区域，装配层按流程分流）。
    var onConfirm: ([CGWindowID]) -> Void
    /// App 范围「下一步」确认回调（2026-11-20 Omi 38.png 多选补齐）：选中 bundle 集
    ///（单选 = 既有 `.app` 语义，多选 = `.apps` 多应用合成）。
    var onConfirmApps: ([String]) -> Void

    @State private var scope: Scope
    @State private var candidates: [WindowCandidate] = []
    @State private var apps: [AppCandidate] = []
    @State private var failureText: String?
    @State private var isLoading = true
    /// 网格当前选中（Omi 多选：⌘-点击切换；单选语义 = 集合恰一元素）。
    @State private var selectedIDs: Set<CGWindowID> = []
    @State private var selectedAppIDs: Set<String> = []

    /// `initialScope` 决定打开时落在哪个范围（菜单「App…」= .apps，既有入口 = .windows）；
    /// 各回调缺省空闭包：未接线的调用点（若未来出现）编译期无需感知新参数。
    init(
        onSelect: @escaping (CGWindowID) -> Void,
        onAppSelect: @escaping (String) -> Void = { _ in },
        onConfirm: @escaping ([CGWindowID]) -> Void = { _ in },
        onConfirmApps: @escaping ([String]) -> Void = { _ in },
        initialScope: Scope = .windows
    ) {
        self.onSelect = onSelect
        self.onAppSelect = onAppSelect
        self.onConfirm = onConfirm
        self.onConfirmApps = onConfirmApps
        _scope = State(initialValue: initialScope)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("范围", selection: $scope) {
                ForEach(Scope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .help("选择要录制的内容范围：单个窗口，或一个应用的全部窗口")
            .accessibilityLabel("录制范围")
            content
        }
        .frame(minWidth: 420, minHeight: 320)
        .task(id: scope) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView {
                Text(scope == .apps
                     ? NSLocalizedString("正在枚举 App…", comment: "Enumerating apps")
                     : NSLocalizedString("正在枚举窗口…", comment: "Enumerating windows"))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let failureText {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title)
                    .foregroundStyle(OmiStyle.subtleText)
                Text(failureText)
                    .font(.caption)
                    .foregroundStyle(OmiStyle.subtleText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button("重试") {
                    Task { await load() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if scope == .apps {
            if apps.isEmpty {
                Text("没有可录制的 App")
                    .foregroundStyle(OmiStyle.subtleText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // App 范围 = Omi 38.png 图标网格页（2026-11-20 像素级复刻）：5 列大图标
                // + 应用名；选中绿框；底部 下一步 + ⌘ 多选提示。双击 = 既有即选即走。
                VStack(spacing: 0) {
                    AppGridView(
                        candidates: apps,
                        selectedBundleIDs: $selectedAppIDs,
                        onActivate: { bundleID in onAppSelect(bundleID) })
                    nextStepBar(disabled: selectedAppIDs.isEmpty) {
                        onConfirmApps(selectedAppIDs.sorted())
                    }
                }
            }
        } else if candidates.isEmpty {
            Text("没有可录制的窗口")
                .foregroundStyle(OmiStyle.subtleText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // 窗口范围 = Omi 55.png 网格页（2026-11-16 像素级复刻）：大缩略图瓦片 +
            // 「App - 标题」标签 + 选中绿框；底部 下一步 + ⌘ 多选提示。双击瓦片 = 既有
            // 即选即走语义（onSelect 直达）；下一步 = 选中集确认（单选/多选分流在装配层）。
            VStack(spacing: 0) {
                WindowGridView(
                    candidates: candidates,
                    selectedIDs: $selectedIDs,
                    onActivate: { id in onSelect(id) })
                nextStepBar(disabled: selectedIDs.isEmpty) {
                    onConfirm(selectedIDs.sorted())
                }
            }
        }
    }

    /// 底部「下一步」+ ⌘ 多选提示（Omi 同款；两范围共用）。
    private func nextStepBar(disabled: Bool, action: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Button(action: action) {
                Text("下一步")
                    .frame(width: 110, height: 26)
            }
            .buttonStyle(NextStepButtonStyle())
            .disabled(disabled)
            Text("按住⌘键后可进行多选 / 反选")
                .font(.footnote)
                .foregroundStyle(OmiStyle.subtleText)
        }
        .padding(.vertical, 10)
    }

    private func load() async {
        isLoading = true
        failureText = nil
        selectedIDs = [] // 候选重枚举（复用窗口重开/换范围）：旧选择全灭（陈旧 id 无意义）
        selectedAppIDs = []
        do {
            switch scope {
            case .windows:
                candidates = try await WindowPicker.availableWindows(
                    thumbnailCap: WindowGridGeometry.thumbnailPointCap)
            case .apps:
                apps = try await WindowPicker.availableApps()
            }
        } catch {
            candidates = []
            apps = []
            failureText = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - 原生行表格（交互层修复，2026-11-14）
//
// 原行视图用 `.onTapGesture(count: 2)` 双击选择——本库手建 NSWindow + NSHostingView
// 窗口内 SwiftUI 手势层整层不响应（列表窗同根因实证实修，见 RecordingListView 头注），
// 用户真机「选择窗口和选择 App 没法选择」。故行列表改用原生 NSTableView：单击选中、
// 双击（doubleAction）触发选择回调，全走 AppKit 事件通道。

/// 选择器行数据（窗口行 / App 行共用一张表，按 scope 二选一装配）。
enum PickerRow {
    case window(WindowCandidate)
    case app(AppCandidate)
}

/// 选择器行表格（原生 NSTableView 桥接）：行内容与旧 SwiftUI 行逐项对齐——
/// 窗口行 = App 名/窗口名 + 右侧 72×48 缩略图；App 行 = 32pt 图标 + 名称/窗口数。
struct WindowPickerTable: NSViewRepresentable {
    let rows: [PickerRow]
    /// 双击行回调（等价旧 `onTapGesture(count: 2)`）。
    let onActivate: (PickerRow) -> Void

    /// 行高：窗口行带缩略图 56，App 行 44（按行内容定，见 `rowOffsets`）。
    private static let windowRowHeight: CGFloat = 56
    private static let appRowHeight: CGFloat = 44

    private var isAppScope: Bool {
        if case .app = rows.first { return true }
        return false
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(rows: rows, onActivate: onActivate)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let table = NSTableView()
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.rowHeight = isAppScope ? Self.appRowHeight : Self.windowRowHeight
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("picker"))
        column.width = 600
        table.addTableColumn(column)
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClick(_:))
        context.coordinator.table = table
        scrollView.documentView = table
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.rows = rows
        coordinator.onActivate = onActivate
        coordinator.table?.rowHeight = isAppScope ? Self.appRowHeight : Self.windowRowHeight
        coordinator.table?.reloadData()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var rows: [PickerRow]
        var onActivate: (PickerRow) -> Void
        weak var table: NSTableView?

        init(rows: [PickerRow], onActivate: @escaping (PickerRow) -> Void) {
            self.rows = rows
            self.onActivate = onActivate
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row) else { return nil }
            switch rows[row] {
            case .window(let candidate):
                let cell = tableView.makeView(
                    withIdentifier: NSUserInterfaceItemIdentifier("window-row"), owner: nil)
                    as? WindowPickerWindowCell ?? WindowPickerWindowCell()
                cell.identifier = NSUserInterfaceItemIdentifier("window-row")
                cell.titleLabel.stringValue = candidate.appName.isEmpty ? NSLocalizedString("未知应用", comment: "Unknown app") : candidate.appName
                cell.subtitleLabel.stringValue = candidate.title.isEmpty ? NSLocalizedString("（无标题）", comment: "Untitled window") : candidate.title
                cell.applyThumbnail(candidate.thumbnail)
                return cell
            case .app(let app):
                let cell = tableView.makeView(
                    withIdentifier: NSUserInterfaceItemIdentifier("app-row"), owner: nil)
                    as? WindowPickerAppCell ?? WindowPickerAppCell()
                cell.identifier = NSUserInterfaceItemIdentifier("app-row")
                cell.titleLabel.stringValue = app.appName.isEmpty ? NSLocalizedString("未知应用", comment: "Unknown app") : app.appName
                cell.subtitleLabel.stringValue = String(format: NSLocalizedString("%lld 个窗口", comment: "Window count"), app.windowCount)
                cell.applyIcon(forBundleID: app.bundleID)
                return cell
            }
        }

        @objc func doubleClick(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard rows.indices.contains(row) else { return }
            onActivate(rows[row])
        }
    }
}

/// 窗口行单元格：App 名（headline）/ 窗口名（次级）+ 右侧 72×48 缩略图（无图回退符号占位）。
@MainActor
final class WindowPickerWindowCell: NSTableCellView {
    let titleLabel = NSTextField(labelWithString: "")
    let subtitleLabel = NSTextField(labelWithString: "")
    private let thumbnailView = NSImageView()

    init() {
        super.init(frame: .zero)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = NSColor.labelColor.withAlphaComponent(0.78)
        for label in [titleLabel, subtitleLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 4
        thumbnailView.layer?.masksToBounds = true
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(thumbnailView)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.bottomAnchor.constraint(equalTo: centerYAnchor, constant: -1),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: thumbnailView.leadingAnchor, constant: -12),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: thumbnailView.leadingAnchor, constant: -12),
            thumbnailView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            thumbnailView.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnailView.widthAnchor.constraint(equalToConstant: 72),
            thumbnailView.heightAnchor.constraint(equalToConstant: 48)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 不支持（代码构建视图）")
    }

    func applyThumbnail(_ image: NSImage?) {
        if let image {
            thumbnailView.image = image
        } else {
            thumbnailView.image = NSImage(
                systemSymbolName: "macwindow", accessibilityDescription: nil)
            thumbnailView.contentTintColor = .secondaryLabelColor
        }
    }
}

/// App 行单元格：32pt 图标 + 名称/窗口数（图标经 NSWorkspace 现场取，失败回退占位符号）。
@MainActor
final class WindowPickerAppCell: NSTableCellView {
    let titleLabel = NSTextField(labelWithString: "")
    let subtitleLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    /// 图标缓存（同一 App 行复用时避免重复查 NSWorkspace）。
    private var iconBundleID: String?

    init() {
        super.init(frame: .zero)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = NSColor.labelColor.withAlphaComponent(0.78)
        for label in [titleLabel, subtitleLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            titleLabel.bottomAnchor.constraint(equalTo: centerYAnchor, constant: -1),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: centerYAnchor, constant: 1)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 不支持（代码构建视图）")
    }

    func applyIcon(forBundleID bundleID: String) {
        guard iconBundleID != bundleID else { return }
        iconBundleID = bundleID
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            iconView.image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            iconView.image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        }
    }
}

// MARK: - Omi 选择窗口网格页（2026-11-16 55.png 像素级复刻）
//
// 手建窗内 SwiftUI 手势层死的定论（列表窗/选择器同根因实证实修）——网格交互全走
// AppKit 原生 NSCollectionView：单击选中（⌘-点击切换 = Omi「多选 / 反选」）、双击
// 即选即走（mouseDown clickCount 计数，AppKit 事件通道）。选中态绿框自绘
//（NSCollectionView 默认系统蓝选框不是 Omi 观感）。

/// 网格几何（internal 供无头钉测）：4 列等宽瓦片，缩略图 + 标签上下结构。
enum WindowGridGeometry {
    static let columns = 4
    static let thumbnailHeight: CGFloat = 118
    static let labelHeight: CGFloat = 26
    static let spacing: CGFloat = 10
    static let sectionInset: CGFloat = 14
    /// 标称瓦片尺寸（视图宽度不可得时的回退；视图宽就绪后按等分重排）。
    static let fallbackTileWidth: CGFloat = 200
    /// 瓦片缩略图点尺寸上限（availableWindows 抓帧封顶——Retina 2x 像素余量同惯例）。
    static let thumbnailPointCap: CGFloat = 200

    static var itemHeight: CGFloat { thumbnailHeight + labelHeight }

    /// 视图宽 → 瓦片尺寸（等分列数扣间距；超窄/非法回退标称瓦片）。
    static func tileSize(forViewWidth width: CGFloat) -> CGSize {
        let computed = floor((width - spacing * CGFloat(columns - 1) - sectionInset * 2) / CGFloat(columns))
        guard computed.isFinite, computed > 60 else {
            return CGSize(width: fallbackTileWidth, height: itemHeight)
        }
        return CGSize(width: computed, height: itemHeight)
    }
}

/// 网格桥（AppKit 原生 NSCollectionView）：候选 → 瓦片（缩略图 aspect-fill + 「App - 标题」
/// 标签），选中绿框；⌘-点击原生切换（allowsMultipleSelection），双击回调 onActivate。
struct WindowGridView: NSViewRepresentable {
    let candidates: [WindowCandidate]
    @Binding var selectedIDs: Set<CGWindowID>
    /// 双击瓦片（即选即走，既有 onSelect 语义）。
    let onActivate: (CGWindowID) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let layout = NSCollectionViewFlowLayout()
        layout.minimumLineSpacing = WindowGridGeometry.spacing
        layout.minimumInteritemSpacing = WindowGridGeometry.spacing
        layout.sectionInset = NSEdgeInsets(
            top: WindowGridGeometry.sectionInset,
            left: WindowGridGeometry.sectionInset,
            bottom: WindowGridGeometry.sectionInset,
            right: WindowGridGeometry.sectionInset)
        layout.itemSize = WindowGridGeometry.tileSize(forViewWidth: scrollView.frame.width)

        let grid = NSCollectionView(frame: .zero)
        grid.collectionViewLayout = layout
        grid.dataSource = context.coordinator
        grid.delegate = context.coordinator
        grid.isSelectable = true
        grid.allowsMultipleSelection = true
        // 选中视觉完全由瓦片自绘（isSelected 翻转 → 绿框；本 SDK 无系统选框可关）。
        // ⌘-点击的原生多选切换语义不受影响（委托 didSelect/didDeselect 照常回调）。
        grid.backgroundColors = [.clear]
        grid.register(
            WindowGridItem.self,
            forItemWithIdentifier: NSUserInterfaceItemIdentifier("windowTile"))
        scrollView.documentView = grid
        context.coordinator.grid = grid
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.syncSelection(selectedIDs)
        guard let grid = coordinator.grid else { return }
        // 候选变化（重枚举）才重载；仅选择变化（Binding 回流）不重载不打断 ⌘ 连选。
        if coordinator.candidates.map(\.id) != candidates.map(\.id) {
            coordinator.candidates = candidates
            let layout = grid.collectionViewLayout as? NSCollectionViewFlowLayout
            layout?.itemSize = WindowGridGeometry.tileSize(forViewWidth: scrollView.frame.width)
            grid.reloadData()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        var parent: WindowGridView
        var candidates: [WindowCandidate] = []
        var grid: NSCollectionView?

        init(parent: WindowGridView) {
            self.parent = parent
        }

        // MARK: 数据源

        func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            candidates.count
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(
                withIdentifier: NSUserInterfaceItemIdentifier("windowTile"),
                for: indexPath)
            if let tile = item as? WindowGridItem,
               indexPath.item < candidates.count {
                tile.configure(with: candidates[indexPath.item])
            }
            return item
        }

        /// 双击转发（WindowGridItem.mouseDown clickCount≥2 → 按序号取候选回调）。
        fileprivate func forwardActivation(at index: Int) {
            guard index < candidates.count else { return }
            parent.onActivate(candidates[index].id)
        }

        /// 单击选择（自管语义，WindowGridItem.mouseDown 驱动）：无 ⌘ = 单选替换；
        /// ⌘ = 切换（Omi 多选/反选）。同步 item 视觉（isSelected）+ Binding 回流。
        fileprivate func handleTap(at index: Int, commandPressed: Bool) {
            guard index < candidates.count, let grid else { return }
            let id = candidates[index].id
            var ids = Set(grid.selectionIndexPaths.compactMap { candidateID(at: $0.item) })
            if commandPressed {
                if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
            } else {
                ids = [id]
            }
            applySelection(ids)
        }

        /// 选中集 → collection view（驱动 item.isSelected 视觉）+ Binding 回流。
        fileprivate func applySelection(_ ids: Set<CGWindowID>) {
            guard let grid else { return }
            let idToIndex = Dictionary(uniqueKeysWithValues: candidates.enumerated().map { ($1.id, $0) })
            grid.selectionIndexPaths = Set(ids.compactMap { idToIndex[$0] }.map { IndexPath(item: $0, section: 0) })
            if parent.selectedIDs != ids {
                parent.selectedIDs = ids
            }
        }

        // MARK: 选择（系统选择事件照常回流；自管路径为主，两者幂等一致）

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            forwardSelection()
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            forwardSelection()
        }

        /// 选择态 → SwiftUI Binding（以委托回调为准——⌘ 切换由 NSCollectionView 原生
        /// 处理，这里只搬运结果，不自己维护选中集）。
        fileprivate func forwardSelection() {
            guard let grid else { return }
            let ids = Set(grid.selectionIndexPaths.compactMap { candidateID(at: $0.item) })
            if parent.selectedIDs != ids {
                parent.selectedIDs = ids
            }
        }

        /// Binding → 视图（load 重置清空时回流；编程选择无其它入口）。
        func syncSelection(_ ids: Set<CGWindowID>) {
            guard let grid else { return }
            let current = Set(grid.selectionIndexPaths.compactMap { candidateID(at: $0.item) })
            guard current != ids else { return }
            applySelection(ids)
        }

        private func candidateID(at index: Int) -> CGWindowID? {
            index < candidates.count ? candidates[index].id : nil
        }
    }
}

/// 网格瓦片（NSCollectionViewItem）：缩略图 aspect-fill（Omi 同款裁切满格）+ 下方
/// 「App - 标题」白标签；选中态绿框 2pt（自绘 layer border——默认系统蓝选框非 Omi 观感）。
@MainActor
final class WindowGridItem: NSCollectionViewItem {
    private let thumbContainer = NSView()
    private let thumbView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: WindowGridGeometry.fallbackTileWidth, height: WindowGridGeometry.itemHeight))
        container.wantsLayer = true

        thumbContainer.wantsLayer = true
        thumbContainer.translatesAutoresizingMaskIntoConstraints = false
        thumbContainer.layer?.backgroundColor = NSColor.black.cgColor
        thumbContainer.layer?.cornerRadius = 4
        thumbContainer.layer?.masksToBounds = true
        thumbView.imageScaling = .scaleProportionallyUpOrDown
        thumbView.translatesAutoresizingMaskIntoConstraints = false
        thumbContainer.addSubview(thumbView)
        NSLayoutConstraint.activate([
            thumbView.topAnchor.constraint(equalTo: thumbContainer.topAnchor),
            thumbView.bottomAnchor.constraint(equalTo: thumbContainer.bottomAnchor),
            thumbView.leadingAnchor.constraint(equalTo: thumbContainer.leadingAnchor),
            thumbView.trailingAnchor.constraint(equalTo: thumbContainer.trailingAnchor),
        ])

        label.font = .systemFont(ofSize: 13)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(thumbContainer)
        container.addSubview(label)
        NSLayoutConstraint.activate([
            thumbContainer.topAnchor.constraint(equalTo: container.topAnchor),
            thumbContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            thumbContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            thumbContainer.heightAnchor.constraint(equalToConstant: WindowGridGeometry.thumbnailHeight),
            label.topAnchor.constraint(equalTo: thumbContainer.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            label.heightAnchor.constraint(equalToConstant: WindowGridGeometry.labelHeight - 4),
        ])
        view = container
    }

    func configure(with candidate: WindowCandidate) {
        thumbView.image = candidate.thumbnail
        label.stringValue = candidate.title.isEmpty
            ? candidate.appName
            : "\(candidate.appName) - \(candidate.title)"
        refreshSelectionVisual()
    }

    override var isSelected: Bool {
        didSet { refreshSelectionVisual() }
    }

    /// 选中绿框（Omi 55.png 同款 2pt 绿描边；未选中透明）。绿框包住缩略图区（标签不框）。
    private func refreshSelectionVisual() {
        thumbContainer.layer?.borderWidth = isSelected ? 2 : 0
        thumbContainer.layer?.borderColor = NSColor.systemGreen.cgColor
    }

    /// 双击即选即走 + 单击选择（**完全自管**——系统 NSCollectionView 的内部单击选择在
    /// 本宿主环境不可依赖（2026-11-20 用户实测「下一步」永远禁用），手建窗交互纪律与
    /// 列表窗 doubleAction 同源：AppKit 事件通道 + 自己维护状态）。⌘ = 切换（Omi 多选
    /// /反选）；无 ⌘ = 单选替换。
    override func mouseDown(with event: NSEvent) {
        guard let indexPath = collectionView?.indexPath(for: self),
              let coordinator = collectionView?.delegate as? WindowGridView.Coordinator else {
            return super.mouseDown(with: event)
        }
        if event.clickCount >= 2 {
            coordinator.forwardActivation(at: indexPath.item)
            return
        }
        coordinator.handleTap(at: indexPath.item, commandPressed: event.modifierFlags.contains(.command))
    }
}

/// 「下一步」按钮样式（Omi 55.png 同款灰底圆角 + 白字；按下微降透明度）。
struct NextStepButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.75 : 1))
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.18)))
    }
}

// MARK: - Omi 选择 App 图标网格页（2026-11-20 38.png 像素级复刻）
//
// 与窗口网格同纪律：手建窗 SwiftUI 手势层死 → AppKit 原生 NSCollectionView + 自管
// 选择（单击替换/⌘ 切换；双击即选即走）。视觉 = 5 列大应用图标 + 下方名称 + 选中绿框。

/// App 网格几何（internal 供无头钉测）。
enum AppGridGeometry {
    static let columns = 5
    /// 图标视觉边长（Omi 38.png 目测 ~76pt；图标本体按系统图标绘制）。
    static let iconSide: CGFloat = 76
    static let labelHeight: CGFloat = 24
    static let spacing: CGFloat = 26
    static let sectionInset: CGFloat = 28
    static let fallbackTileWidth: CGFloat = 130

    static var itemHeight: CGFloat { iconSide + labelHeight + 8 }

    /// 视图宽 → 瓦片尺寸（等分列数扣间距；超窄/非法回退标称瓦片）。
    static func tileSize(forViewWidth width: CGFloat) -> CGSize {
        let computed = floor(
            (width - spacing * CGFloat(columns - 1) - sectionInset * 2) / CGFloat(columns))
        guard computed.isFinite, computed > 60 else {
            return CGSize(width: fallbackTileWidth, height: itemHeight)
        }
        return CGSize(width: computed, height: itemHeight)
    }
}

/// App 图标网格桥（NSCollectionView）：AppCandidate → 大图标 + 名称瓦片，选中绿框。
struct AppGridView: NSViewRepresentable {
    let candidates: [AppCandidate]
    @Binding var selectedBundleIDs: Set<String>
    /// 双击瓦片（即选即走，既有 onAppSelect 语义）。
    let onActivate: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let layout = NSCollectionViewFlowLayout()
        layout.minimumLineSpacing = AppGridGeometry.spacing
        layout.minimumInteritemSpacing = AppGridGeometry.spacing
        layout.sectionInset = NSEdgeInsets(
            top: AppGridGeometry.sectionInset,
            left: AppGridGeometry.sectionInset,
            bottom: AppGridGeometry.sectionInset,
            right: AppGridGeometry.sectionInset)
        layout.itemSize = AppGridGeometry.tileSize(forViewWidth: scrollView.frame.width)

        let grid = NSCollectionView(frame: .zero)
        grid.collectionViewLayout = layout
        grid.dataSource = context.coordinator
        grid.delegate = context.coordinator
        grid.isSelectable = true
        grid.allowsMultipleSelection = true
        grid.backgroundColors = [.clear]
        grid.register(
            AppGridItem.self,
            forItemWithIdentifier: NSUserInterfaceItemIdentifier("appTile"))
        scrollView.documentView = grid
        context.coordinator.grid = grid
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.syncSelection(selectedBundleIDs)
        guard let grid = coordinator.grid else { return }
        if coordinator.candidates.map(\.bundleID) != candidates.map(\.bundleID) {
            coordinator.candidates = candidates
            let layout = grid.collectionViewLayout as? NSCollectionViewFlowLayout
            layout?.itemSize = AppGridGeometry.tileSize(forViewWidth: scrollView.frame.width)
            grid.reloadData()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        var parent: AppGridView
        var candidates: [AppCandidate] = []
        var grid: NSCollectionView?

        init(parent: AppGridView) {
            self.parent = parent
        }

        func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            candidates.count
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(
                withIdentifier: NSUserInterfaceItemIdentifier("appTile"),
                for: indexPath)
            if let tile = item as? AppGridItem,
               indexPath.item < candidates.count {
                tile.configure(with: candidates[indexPath.item])
            }
            return item
        }

        /// 双击转发（即选即走）。
        fileprivate func forwardActivation(at index: Int) {
            guard index < candidates.count else { return }
            parent.onActivate(candidates[index].bundleID)
        }

        /// 单击选择（自管；系统 NSCollectionView 内部单击选择在本宿主不可依赖）。
        fileprivate func handleTap(at index: Int, commandPressed: Bool) {
            guard index < candidates.count, let grid else { return }
            let bundleID = candidates[index].bundleID
            var ids = Set(grid.selectionIndexPaths.compactMap { self.bundleID(at: $0.item) })
            if commandPressed {
                if ids.contains(bundleID) { ids.remove(bundleID) } else { ids.insert(bundleID) }
            } else {
                ids = [bundleID]
            }
            applySelection(ids)
        }

        fileprivate func applySelection(_ ids: Set<String>) {
            guard let grid else { return }
            let indexByBundle = Dictionary(
                uniqueKeysWithValues: candidates.enumerated().map { ($1.bundleID, $0) })
            grid.selectionIndexPaths = Set(
                ids.compactMap { indexByBundle[$0] }.map { IndexPath(item: $0, section: 0) })
            if parent.selectedBundleIDs != ids {
                parent.selectedBundleIDs = ids
            }
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            let ids = Set(collectionView.selectionIndexPaths.compactMap { bundleID(at: $0.item) })
            if parent.selectedBundleIDs != ids {
                parent.selectedBundleIDs = ids
            }
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            let ids = Set(collectionView.selectionIndexPaths.compactMap { bundleID(at: $0.item) })
            if parent.selectedBundleIDs != ids {
                parent.selectedBundleIDs = ids
            }
        }

        func syncSelection(_ ids: Set<String>) {
            guard let grid else { return }
            let current = Set(grid.selectionIndexPaths.compactMap { bundleID(at: $0.item) })
            guard current != ids else { return }
            applySelection(ids)
        }

        private func bundleID(at index: Int) -> String? {
            index < candidates.count ? candidates[index].bundleID : nil
        }
    }
}

/// App 图标瓦片（NSCollectionViewItem）：大图标（NSWorkspace 取应用图标）+ 名称；
/// 选中绿框（包图标区，同窗口网格观感）。
@MainActor
final class AppGridItem: NSCollectionViewItem {
    private let iconContainer = NSView()
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override func loadView() {
        let container = NSView(frame: NSRect(
            x: 0, y: 0, width: AppGridGeometry.fallbackTileWidth, height: AppGridGeometry.itemHeight))
        container.wantsLayer = true

        iconContainer.wantsLayer = true
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.layer?.cornerRadius = 12
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.addSubview(iconView)

        label.font = .systemFont(ofSize: 13)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(iconContainer)
        container.addSubview(label)
        let iconSide = AppGridGeometry.iconSide
        NSLayoutConstraint.activate([
            iconContainer.topAnchor.constraint(equalTo: container.topAnchor),
            iconContainer.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            iconContainer.widthAnchor.constraint(equalToConstant: iconSide),
            iconContainer.heightAnchor.constraint(equalToConstant: iconSide),
            iconView.topAnchor.constraint(equalTo: iconContainer.topAnchor, constant: 4),
            iconView.bottomAnchor.constraint(equalTo: iconContainer.bottomAnchor, constant: -4),
            iconView.leadingAnchor.constraint(equalTo: iconContainer.leadingAnchor, constant: 4),
            iconView.trailingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: -4),
            label.topAnchor.constraint(equalTo: iconContainer.bottomAnchor, constant: 6),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            label.heightAnchor.constraint(equalToConstant: AppGridGeometry.labelHeight - 8),
        ])
        view = container
    }

    func configure(with candidate: AppCandidate) {
        iconView.image = AppIconProvider.icon(forBundleID: candidate.bundleID)
        label.stringValue = candidate.appName
        refreshSelectionVisual()
    }

    override var isSelected: Bool {
        didSet { refreshSelectionVisual() }
    }

    private func refreshSelectionVisual() {
        iconContainer.layer?.borderWidth = isSelected ? 2 : 0
        iconContainer.layer?.borderColor = NSColor.systemGreen.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        guard let indexPath = collectionView?.indexPath(for: self),
              let coordinator = collectionView?.delegate as? AppGridView.Coordinator else {
            return super.mouseDown(with: event)
        }
        if event.clickCount >= 2 {
            coordinator.forwardActivation(at: indexPath.item)
            return
        }
        coordinator.handleTap(at: indexPath.item, commandPressed: event.modifierFlags.contains(.command))
    }
}

/// 应用图标缓存（NSWorkspace 按 bundle id 解析一次；图标集合主线程消费）。
@MainActor
enum AppIconProvider {
    private static var cache: [String: NSImage] = [:]

    static func icon(forBundleID bundleID: String) -> NSImage {
        if let cached = cache[bundleID] { return cached }
        let icon: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = NSWorkspace.shared.icon(for: .applicationBundle)
        }
        cache[bundleID] = icon
        return icon
    }
}
