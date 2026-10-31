import Foundation
import UserNotifications

/// `RecordingNotifying` 生产实现（简报 Step 6：通知用 UNUserNotificationCenter，
/// Info.plist 无需额外键）。LSUIElement App 通知照常投递；授权尽力申请（用户拒绝后静默——
/// 通知是尽力而为的副通道，成片落盘才是主契约）。测试进程不可用（无 App bundle 上下文），
/// 故控制器经协议注入、测试用 spy 替换。
@MainActor
final class UNRecordingNotifier: RecordingNotifying {
    func notifySaved(fileURL: URL) {
        post(title: "录制完成", body: "已保存：\(fileURL.lastPathComponent)")
    }

    func notifyFailure(message: String) {
        post(title: "录制出现问题", body: message)
    }

    func notifyDiskSpaceWarning() {
        post(title: "磁盘空间不足", body: "剩余空间偏低，录制可能即将中断并自动保存。")
    }

    /// P6a：开机自启注册/注销失败通知（开关已回翻，真实态优先于 UI 态）——同
    /// notifySaved 纪律的尽力而为副通道，授权被拒/投递失败静默跳过。
    func notifyLaunchAtLoginFailure(message: String) {
        post(title: "开机自启设置失败", body: message)
    }

    /// P6b：定时录制跳过通知（忙/锁屏路径，标题正文透传，无动作按钮）——同
    /// notifySaved 纪律的尽力而为副通道。错过补通知带「开始录制」UNNotificationAction
    ///（category + delegate 派发），归装配层接线（见 AppAssembly / ScheduledMissedNotifyDelegate）。
    func notifyScheduledRecordingSkipped(title: String, body: String?) {
        post(title: title, body: body ?? "")
    }

    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            try? await center.add(request)
        }
    }
}

// MARK: - 导出通知（P8/T16：文件列表模型导出编排经 ExportNotifying 缝接入）

extension UNRecordingNotifier: ExportNotifying {
    /// 导出完成（`notifySaved` 对称文案：「录制完成/已保存」→「导出完成/已保存」）——
    /// 尽力而为副通道，同 post 纪律。
    func notifyExportCompleted(fileURL: URL) {
        post(title: "导出完成", body: "已保存：\(fileURL.lastPathComponent)")
    }

    /// 导出失败（`notifyFailure` 对称：标题 Severity 类别「导出出现问题」，正文透传
    /// ExportError 文案族完整行——T15 errorDescription 原样「导出失败：GIF 编码失败，
    /// 请重试」，不为消重做脆弱的前缀拆分）。
    func notifyExportFailed(message: String) {
        post(title: "导出出现问题", body: message)
    }
}
