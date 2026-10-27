import AppKit
import CoreGraphics
import Foundation

// MARK: - 持久化目标（简报 Produces 逐字）

/// 窗口捕获的持久化目标（T20）：稳定标识 = `ownerAppIdentifier`（选定时刻 owner 进程的
/// bundle id，取不到回退 ownerName）+ `windowTitle`（裁定 1）。CGWindowID 从不持久化
/// ——每次启动窗口 id 重新分配，只有（应用, 标题）跨启动稳定。Codable JSON 整只落库
/// `SettingsStore.windowCaptureTarget`（nil = 未配置）。
struct WindowCaptureTarget: Codable, Equatable {
    var ownerAppIdentifier: String
    var windowTitle: String
    var savedAt: Date
}

/// 选定时刻的单窗所有者快照（`windowOwnerSnapshot` 的产物，无头可构造）。
struct WindowOwnerSnapshot: Equatable {
    var ownerPID: Int32
    var title: String?
    var ownerName: String?
}

// MARK: - 目标解析（纯函数，全无头可测）

/// 解析顺序（裁定 2）：bundleID+标题全等 → bundleID+标题前缀 → ownerName 兜底；
/// 同段多命中取面积最大，仍平取候选序首个（枚举侧排序确定）；零命中 / 空目标 → nil。
/// 前缀段覆盖窗口改名（标题被加前后缀）；ownerName 段覆盖保存时 bundle id 不可得的
/// 候选——三段都不要求大小写折叠，稳定可断言；宁重选不录错窗（兜底段同样要求标题全等）。
enum WindowTargetResolver {
    /// 现场解析：候选（`WindowPicker.enumeratedWindows` 产物）对持久化目标求命中窗口。
    static func resolve(candidates: [ShareableWindow], target: WindowCaptureTarget?) -> ShareableWindow? {
        guard let target, !target.ownerAppIdentifier.isEmpty, !target.windowTitle.isEmpty else { return nil }
        // 段序即优先序：全等 ⊂ 前缀，先查全等；段内多命中取面积最大（平取序首）。
        let stages: [[ShareableWindow]] = [
            candidates.filter { $0.appBundleID == target.ownerAppIdentifier && $0.title == target.windowTitle },
            candidates.filter { $0.appBundleID == target.ownerAppIdentifier && $0.title?.hasPrefix(target.windowTitle) == true },
            candidates.filter { $0.appName == target.ownerAppIdentifier && $0.title == target.windowTitle },
        ]
        for stage in stages where !stage.isEmpty {
            return stage.reduce(stage[0]) { current, next in
                area(next) > area(current) ? next : current
            }
        }
        return nil
    }

    /// 选定 → 持久化目标组装（裁定 1）：bundle id 经 owner PID → `NSRunningApplication`
    /// 解析，取不到回退 ownerName；两者皆缺（选中间隙窗口关闭/进程退出）→ nil，不持久化。
    /// 无标题窗口以空串占位（立即开录仍可用 windowID；下次解析按空目标走 stale 分支）。
    static func makeTarget(
        windowID: CGWindowID,
        snapshot: WindowOwnerSnapshot?,
        savedAt: Date = Date(),
        bundleIdentifierForPID: (Int32) -> String? = { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
    ) -> WindowCaptureTarget? {
        guard let snapshot else { return nil }
        let identifier = bundleIdentifierForPID(snapshot.ownerPID) ?? snapshot.ownerName
        guard let identifier else { return nil }
        return WindowCaptureTarget(
            ownerAppIdentifier: identifier,
            windowTitle: snapshot.title ?? "",
            savedAt: savedAt)
    }

    /// 生产缝（非无头）：单窗快照 `CGWindowListCopyWindowInfo([.optionIncludingWindow], id)`
    /// 取 kCGWindowOwnerPID / kCGWindowName / kCGWindowOwnerName。窗口不存在（选中间隙
    /// 关闭）返回 nil。`kCGWindowName` 需屏幕录制 TCC——调用点（选择器选定）已在枚举路径
    /// 之后，授权已前置保证（裁定 4：不新增权限面）。
    static func windowOwnerSnapshot(windowID: CGWindowID) -> WindowOwnerSnapshot? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = list.first,
              let pid = info[kCGWindowOwnerPID as String] as? Int32 else { return nil }
        return WindowOwnerSnapshot(
            ownerPID: pid,
            title: info[kCGWindowName as String] as? String,
            ownerName: info[kCGWindowOwnerName as String] as? String)
    }

    private static func area(_ window: ShareableWindow) -> CGFloat {
        window.frame.width * window.frame.height
    }
}

// MARK: - ⇧⌘W handler 三分支决策（裁定 5，纯函数；装配层只做执行）

/// 快捷键行为规格（简报 1-3）的决策面：装配层 `AppAssembly` 枚举后调 `resolve`，按决策执行
/// （开始录制 / 打开选择器 / 提示后打开选择器）。选择器取消不录制、不清除既有目标——
/// 由装配层「只在选定时刻写 `windowCaptureTarget`」保证，决策面不含状态写。
enum WindowStartDecision: Equatable {
    /// 命中 → 直接开始录制该窗口（经装配层 `startRecording`，.window 随之成为上次使用模式）。
    case start(windowID: CGWindowID)
    /// 无存储目标 → 打开选择器；选定即持久化并立即开始窗口录制。
    case openPicker
    /// 有目标但现场解析不命中（窗口已关/改名/空目标）→ 通知「上次选择的窗口不可用」后打开
    /// 选择器；不清除既有目标。
    case staleNotifyThenPicker

    static func resolve(target: WindowCaptureTarget?, candidates: [ShareableWindow]) -> WindowStartDecision {
        guard let target else { return .openPicker }
        guard let hit = WindowTargetResolver.resolve(candidates: candidates, target: target) else {
            return .staleNotifyThenPicker
        }
        return .start(windowID: hit.windowID)
    }
}
