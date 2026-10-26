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
            return "无法枚举窗口：屏幕录制权限未授予或已失效（重新编译后签名变化会使授权失效，需在系统设置重新勾选并重启应用）"
        case .contentUnavailable(let underlying):
            return "无法枚举窗口：\(underlying)"
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
    /// 光栅化在后台队列（见 `generateThumbnails`）。
    ///
    /// 失败可诊断：权限未授予/失效抛 `.screenRecordingPermissionDenied`（不弹系统设置
    /// 跳转——那是接线任务的事）；`SCShareableContent` 枚举失败包裹为
    /// `.contentUnavailable(underlying:)`，错误链不断。
    ///
    /// - Parameters:
    ///   - preflight: 注入缝——屏幕录制权限预检（生产 `CGPreflightScreenCaptureAccess`）。
    ///   - loadWindows: 注入缝——可共享内容枚举（生产 `SCShareableContent`，无头不可测）。
    ///   - loadThumbnails: 注入缝——缩略图批量生成（生产 `CGWindowListCreateImage` 批处理）。
    @MainActor
    static func availableWindows(
        preflight: () -> Bool = preflightScreenRecordingPermission,
        loadWindows: () async throws -> [ShareableWindow] = loadShareableWindowsFromSystem,
        loadThumbnails: @MainActor ([ThumbnailRequest]) async -> [CGWindowID: NSImage] = generateThumbnails
    ) async throws -> [WindowCandidate] {
        guard preflight() else { throw WindowPickerError.screenRecordingPermissionDenied }
        let windows: [ShareableWindow]
        do {
            windows = try await loadWindows()
        } catch {
            throw WindowPickerError.contentUnavailable(underlying: String(describing: error))
        }
        let selectable = selectableWindows(from: windows, excludingBundleID: selfBundleID)
        let requests = selectable.map { source in
            ThumbnailRequest(windowID: source.windowID, pointSize: thumbnailPointSize(fitting: source.frame.size))
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
        let layers = onScreenWindowLayers()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.windows.map { window in
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

    /// 缩略图批量生成：光栅化在后台队列（`CGWindowListCreateImage` 同步调用，macOS 13 的
    /// 正确 API，14+ 才弃用、deployment target 13 下零告警）；`.bestResolution` 取 Retina
    /// 物理像素，`NSImage(cgImage:size:)` 以封顶点尺寸声明 DPI（2x 屏即 2x 清晰度）。
    /// 主 actor 入口：续体恢复即跳回主线程，NSImage 组装在主线程完成、字典不跨域
    /// （NSImage 的 Sendable 一致性 macOS 14 才有，跨域组装会触发可用性告警）。
    /// 失败窗口（无内容/已消失）缺席映射，候选侧保持 nil 由视图出占位图。
    @MainActor
    private static func generateThumbnails(_ requests: [ThumbnailRequest]) async -> [CGWindowID: NSImage] {
        let rasterized: [(windowID: CGWindowID, cgImage: CGImage?)] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let images = requests.map { request in
                    (windowID: request.windowID,
                     cgImage: CGWindowListCreateImage(.null, .optionIncludingWindow, request.windowID, [.bestResolution]))
                }
                continuation.resume(returning: images)
            }
        }
        var thumbnails: [CGWindowID: NSImage] = [:]
        for request in requests {
            guard let cgImage = rasterized.first(where: { $0.windowID == request.windowID })?.cgImage else { continue }
            thumbnails[request.windowID] = NSImage(cgImage: cgImage, size: request.pointSize)
        }
        return thumbnails
    }
}

// MARK: - 窗口选择界面（两列：App 名/窗口名 + 缩略图；双击选择）

/// 窗口选择器 UI（简报 Produces）：加载 `WindowPicker.availableWindows()`，双击行回调
/// `onSelect(CGWindowID)`。不含窗口容器/录制入口接线（后续任务），不加调试 UI。
/// 权限/枚举失败原样透出错误文案 + 重试（不跳系统设置——接线任务职责）。
struct WindowPickerView: View {
    var onSelect: (CGWindowID) -> Void

    @State private var candidates: [WindowCandidate] = []
    @State private var failureText: String?
    @State private var isLoading = true

    var body: some View {
        content
            .frame(minWidth: 420, minHeight: 320)
            .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView {
                Text("正在枚举窗口…")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let failureText {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text(failureText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button("重试") {
                    Task { await load() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if candidates.isEmpty {
            Text("没有可录制的窗口")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(candidates) { candidate in
                row(candidate)
            }
        }
    }

    /// 行布局（简报「两列」）：左列 App 名 + 窗口名，右列缩略图（72×48 展示框，
    /// 128pt 生成余量供 Retina 2x 用）；双击整行选择。
    private func row(_ candidate: WindowCandidate) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.appName.isEmpty ? "未知应用" : candidate.appName)
                    .font(.headline)
                    .lineLimit(1)
                Text(candidate.title.isEmpty ? "（无标题）" : candidate.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            thumbnailView(candidate.thumbnail)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onSelect(candidate.id)
        }
    }

    @ViewBuilder
    private func thumbnailView(_ image: NSImage?) -> some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator, lineWidth: 1))
        } else {
            Image(systemName: "macwindow")
                .foregroundStyle(.secondary)
                .frame(width: 72, height: 48)
        }
    }

    private func load() async {
        isLoading = true
        failureText = nil
        do {
            candidates = try await WindowPicker.availableWindows()
        } catch {
            candidates = []
            failureText = error.localizedDescription
        }
        isLoading = false
    }
}
