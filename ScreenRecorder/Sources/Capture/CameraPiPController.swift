import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

// MARK: - CameraPiPController（简报 Produces：前置摄像头采集控制器）

/// 摄像头画中画采集控制器（T15，简报 Produces 逐字）：前置广角 + `.vga640x480` +
/// videoDataOutput 专用串行队列；最新一帧以 NSLock 保护暴露（`latestPixelBuffer`，合成在
/// SCStream video 队列逐帧读取），预览层供浮窗（`CameraPiPWindow`）安装。
///
/// 失败通道（`start() throws`）：授权拒绝 / 无摄像头 / 会话装配失败一律抛可诊断错误，
/// 由装配层（`CameraPiPWindowController.beginRecording`）降级为纯屏幕录制并留日志
/// ——录制本体不阻断（T8 混音降级同精神）。`notDetermined`（首次）时代为发起授权请求后
/// 抛错降级：不阻塞录制等待授权，授权完成后重录生效。
///
/// 线程模型：`start()`/`stop()` 在控制器自建的 lifecycle 专用串行队列执行（调用方视角
/// start 同步、stop 异步提交；调用方仍须在非主线程——`AVCaptureSession.startRunning`
/// 阻塞，装配层已切后台队列）；样本回调在自有 video 队列，`latestPixelBuffer` 任意队列
/// 可读。`@unchecked Sendable`：latestFrame 由 frameLock 保护、session/previewLayer 只在
/// lifecycle 串行队列读写——跨线程读面收敛在锁保护的 `latestPixelBuffer` 上（合成器唯一依赖）。
final class CameraPiPController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum CameraPiPError: LocalizedError {
        case cameraPermissionNotDetermined
        case cameraPermissionDenied
        case cameraNotFound
        case sessionConfigurationFailed(String)
        case sessionDidNotStart

        var errorDescription: String? {
            switch self {
            case .cameraPermissionNotDetermined:
                return "摄像头尚未授权：已代为发起系统授权请求，本次录制为纯屏幕；重新开始录制即可带上摄像头画面"
            case .cameraPermissionDenied:
                return "摄像头权限被拒绝：请在系统设置 > 隐私与安全性 > 摄像头中允许本应用，本次录制为纯屏幕"
            case .cameraNotFound:
                return "未找到可用的前置摄像头，本次录制为纯屏幕"
            case .sessionConfigurationFailed(let reason):
                return "摄像头会话装配失败：\(reason)，本次录制为纯屏幕"
            case .sessionDidNotStart:
                return "摄像头会话启动失败（设备被其他应用占用或已断开），本次录制为纯屏幕"
            }
        }
    }

    /// 测试缝：授权状态查询。生产 = `AVCaptureDevice.authorizationStatus(for:)`。
    var authorizationStatus: (AVMediaType) -> AVAuthorizationStatus = {
        AVCaptureDevice.authorizationStatus(for: $0)
    }
    /// 测试缝：授权请求发起（生产弹系统授权框；completion 仅为接口形，start 不等待结果）。
    var requestCameraAccess: (AVMediaType, @escaping (Bool) -> Void) -> Void = {
        AVCaptureDevice.requestAccess(for: $0, completionHandler: $1)
    }
    /// 测试缝：前置广角设备解析（无头测试注入 nil 走 cameraNotFound）。
    var frontCameraProvider: () -> AVCaptureDevice? = {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
    }

    private let session = AVCaptureSession()
    /// start/stop 的串行化载体（修复轮 Important #1）：跨场录制的上一场 stop 与下一场 start
    /// 即使由不同线程并发提交（收尾的 global 并发队列 async 与开场的 sync 本可并发），也在此
    /// FIFO 排队——「旧 stopRunning 落在新 startRunning 之后」的乱序不可能发生（那会使摄像头
    /// 在新一场录制中途被静默关停、成片 PiP 冻结在最后一帧且无错误）。串行序即 happens-before。
    private let lifecycleQueue = DispatchQueue(
        label: "screenRecorder.CameraPiP.lifecycle", qos: .userInitiated)
    /// 样本回调专用串行队列（简报钉死；与屏幕采集的 video 队列互不干扰）。
    private let videoQueue = DispatchQueue(label: "screenRecorder.CameraPiP.video", qos: .userInitiated)
    /// `latestFrame` 的锁（帧写在自有 video 队列，读在 SCStream video 队列——跨队列锁保护）。
    private let frameLock = NSLock()
    private var latestFrame: CVPixelBuffer?

    /// 最新摄像头帧（锁保护，任意队列可读；未启动/已停止/尚未出帧时 nil）。
    var latestPixelBuffer: CVPixelBuffer? {
        frameLock.withStateLock { latestFrame }
    }

    /// 预览层（`start()` 成功后非 nil；浮窗安装，浮窗负责 frame 与圆角裁切）。
    private(set) var previewLayer: AVCaptureVideoPreviewLayer?

    /// 装配并启动摄像头会话。调用方视角同步返回；内部在 lifecycle 串行队列执行——等待期间
    /// 此前提交的 stop 必已完装（跨场 happens-before，见 lifecycleQueue 注释）。阻塞式
    /// （startRunning ~百毫秒级），调用方须在后台队列。
    func start() throws {
        try lifecycleQueue.sync { try startOnLifecycleQueue() }
    }

    /// 停止会话并清空最新帧（幂等）。提交到 lifecycle 串行队列异步执行：不占调用线程
    /// （stopRunning 阻塞式），且与后续 start 的 FIFO 序即跨场 happens-before。
    func stop() {
        lifecycleQueue.async { self.stopOnLifecycleQueue() }
    }

    // MARK: lifecycle 串行队列上的启停实现（session/previewLayer 只在此队列读写）

    private func startOnLifecycleQueue() throws {
        switch authorizationStatus(.video) {
        case .authorized:
            break
        case .notDetermined:
            requestCameraAccess(.video) { _ in } // 已代为发起；本次降级，重录生效
            throw CameraPiPError.cameraPermissionNotDetermined
        case .denied, .restricted:
            throw CameraPiPError.cameraPermissionDenied
        @unknown default:
            throw CameraPiPError.cameraPermissionDenied
        }
        let plan = Self.assemblyPlan(inputs: session.inputs.count, outputs: session.outputs.count)
        if plan.input || plan.output {
            session.beginConfiguration()
            do {
                session.sessionPreset = .vga640x480 // 简报钉死
                if plan.input {
                    guard let device = frontCameraProvider() else {
                        throw CameraPiPError.cameraNotFound
                    }
                    let input: AVCaptureDeviceInput
                    do {
                        input = try AVCaptureDeviceInput(device: device)
                    } catch {
                        throw CameraPiPError.sessionConfigurationFailed("无法连接摄像头设备：\(error)")
                    }
                    guard session.canAddInput(input) else {
                        throw CameraPiPError.sessionConfigurationFailed("会话拒绝摄像头输入")
                    }
                    session.addInput(input)
                }
                if plan.output {
                    let output = AVCaptureVideoDataOutput()
                    output.videoSettings = [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    ]
                    output.alwaysDiscardsLateVideoFrames = true // 实时语义：宁丢帧不积压（合成侧零背压）
                    output.setSampleBufferDelegate(self, queue: videoQueue)
                    guard session.canAddOutput(output) else {
                        throw CameraPiPError.sessionConfigurationFailed("会话拒绝帧输出")
                    }
                    session.addOutput(output)
                }
            } catch {
                session.commitConfiguration()
                throw error
            }
            session.commitConfiguration()
        }

        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer?.videoGravity = .resizeAspectFill
        // 预览连接由系统按前置摄像头自动镜像（自拍习惯）；数据输出不镜像——成片里是
        // 「他人视角」的正规方向（与 FaceTime 观看习惯一致）。镜像设置维持系统默认。
        session.startRunning()
        guard session.isRunning else {
            throw CameraPiPError.sessionDidNotStart
        }
    }

    /// 装配决策（internal 供无头测试钉住半装配修复，修复轮 Minor #1）：按会话现状缺哪部分
    /// 补哪部分。修复背景：旧实现仅看 `inputs.isEmpty`——`canAddOutput` 失败留下的
    /// 「有输入/无输出」残留会让下一场跳过整块装配，输出永久缺失（PiP 静默消失）。
    static func assemblyPlan(inputs: Int, outputs: Int) -> (input: Bool, output: Bool) {
        (input: inputs == 0, output: outputs == 0)
    }

    private func stopOnLifecycleQueue() {
        if session.isRunning {
            session.stopRunning()
        }
        frameLock.withStateLock { latestFrame = nil }
        previewLayer = nil // 浮窗已由装配层收起；下次录制重新安装
    }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate

    /// video 队列串行执行。
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        recordFrameIfNeeded(sampleBuffer)
    }

    /// 帧入口收敛点（internal 供无头测试直接驱动「锁保护 latestPixelBuffer 语义」）：
    /// 仅做「最新帧覆盖」——retain 像素缓冲（独立于 CMSampleBuffer 生命周期），旧帧随
    /// 覆盖释放；不解码不拷贝，逐帧成本为一次锁 + 一次 retain。
    func recordFrameIfNeeded(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameLock.withStateLock { latestFrame = pixelBuffer }
    }
}

// MARK: - PiPFrameStore（拖动锚点桥：主线程写 / video 队列读）

/// PiP 浮窗位置与捕获几何的锁保护快照：主线程写（录制装配 + 拖动 frame 变化），SCStream
/// video 队列读（逐帧合成）。浮窗 frame 在写入时即完成 Cocoa→CG 换算（主线程才能安全读
/// NSScreen），video 队列侧只做纯数学（`PiPCaptureGeometry.pipFrame(fromCGRect:)`）。
/// `@unchecked Sendable`：全部状态经 NSLock 串行化（写入方主线程、读取方 video 队列）。
final class PiPFrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var geometry: PiPCaptureGeometry?
    /// 浮窗在 CG 全局系（points）的 frame 快照；nil = 浮窗未显示 / 已收起。
    private var windowRectInCG: CGRect?

    /// 录制装配/收尾时设置（主线程）。nil = 本场录制无 PiP（纯屏幕）。
    func setGeometry(_ geometry: PiPCaptureGeometry?) {
        lock.withStateLock { self.geometry = geometry }
    }

    /// 发布浮窗最新位置（主线程：拖动 frame 变化 / 装配定位）。nil = 收起。
    func setScreenRect(_ cocoaRect: CGRect?, screenFrame: CGRect, cgDisplayOrigin: CGPoint) {
        lock.withStateLock {
            guard let cocoaRect, !cocoaRect.isEmpty else {
                windowRectInCG = nil
                return
            }
            windowRectInCG = RegionSelectorMath.cgRect(
                fromCocoaRect: cocoaRect,
                screenFrame: screenFrame,
                cgDisplayOrigin: cgDisplayOrigin)
        }
    }

    /// 逐帧合成取数（video 队列）：几何与浮窗位置齐备时给出捕获像素空间 rect，否则 nil
    /// （合成侧按无 PiP 直通）。
    func currentPiPFrame() -> PiPFrame? {
        lock.withStateLock {
            guard let geometry, let windowRectInCG else { return nil }
            return geometry.pipFrame(fromCGRect: windowRectInCG)
        }
    }
}
