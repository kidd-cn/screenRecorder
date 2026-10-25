import AVFoundation
import CoreGraphics
import Foundation

/// 三大 TCC 权限的当前状态。
/// `screen` 为布尔（CoreGraphics 预检只给是/否）；麦克风/摄像头用 AVFoundation 的完整状态。
struct PermissionStatus {
    var screen: Bool
    var microphone: AVAuthorizationStatus
    var camera: AVAuthorizationStatus

    /// 三项均已授权（麦克风/摄像头要求 `.authorized`）。
    var allGranted: Bool {
        screen && microphone == .authorized && camera == .authorized
    }
}

/// 权限检测与请求：`currentStatus()` 只读预检；`requestMissing(from:)` 对缺失项发起系统请求。
/// 屏幕录制授权无异步 API——请求后只能轮询预检等待用户操作（见 `pollScreenPermission()`）。
enum PermissionChecker {
    /// 读取当前权限状态：screen 用 `CGPreflightScreenCaptureAccess()`；
    /// mic/camera 用 `AVCaptureDevice.authorizationStatus(for:)`。
    static func currentStatus() -> PermissionStatus {
        PermissionStatus(
            screen: CGPreflightScreenCaptureAccess(),
            microphone: AVCaptureDevice.authorizationStatus(for: .audio),
            camera: AVCaptureDevice.authorizationStatus(for: .video)
        )
    }

    /// 对 `status` 中缺失的权限逐项发起系统请求：mic/camera 走
    /// `AVCaptureDevice.requestAccess`（系统对话框串行弹出）；screen 走
    /// `CGRequestScreenCaptureAccess()` 触发弹窗后轮询等待用户授权（此前拒绝过
    /// 则该调用静默返回 false，需引导用户去系统设置手动允许）。
    /// 返回值恒为请求流程结束后的 `currentStatus()`，与入参快照无关地反映当前事实。
    static func requestMissing(from status: PermissionStatus) async -> PermissionStatus {
        if status.microphone == .notDetermined {
            await AVCaptureDevice.requestAccess(for: .audio)
        }
        if status.camera == .notDetermined {
            await AVCaptureDevice.requestAccess(for: .video)
        }
        if !status.screen {
            CGRequestScreenCaptureAccess()
            await pollScreenPermission()
        }
        return currentStatus()
    }

    /// 屏幕录制授权轮询：每 1s 预检一次，上限 60 次（约 1 分钟），
    /// 期间用户在系统设置授权即提前返回；超限或所在任务被取消（`Task.sleep`
    /// 抛出取消错误）即放弃。纯函数式：无 detached task、无全局状态，
    /// 取消语义完全由调用方的 Task 决定。
    private static func pollScreenPermission() async {
        for _ in 0 ..< 60 {
            if CGPreflightScreenCaptureAccess() { return }
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return // 任务被取消，停止轮询
            }
        }
    }
}
