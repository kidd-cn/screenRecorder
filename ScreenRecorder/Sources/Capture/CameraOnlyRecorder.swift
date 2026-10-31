// @preconcurrency：AVCaptureDevice 在 SDK 里尚未标注 Sendable，跨 sessionQueue 的
// @Sendable 装配闭包捕获它触发误报（设备对象线程安全；装配在 start/stop 生命周期内串行）。
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// 仅摄像头录制会话（P7b）：前置摄像头 `AVCaptureSession` videoDataOutput →
/// `AssetWriterSession` H.264/HEVC MP4。生命周期与 `SCStreamRecorder` 同形
///（start/pause/resume/stop + `finishedFileURL`/`lastError`，另有 brief 签名缝
/// `finish() async -> URL?`），经 `CaptureRecorderControlling` 互换缝与 SCStreamRecorder
/// 在协调器内互换装配（`makeConfiguration` 对 cameraOnly 强制关闭全部屏幕合成效果族，
/// 故本类无任何合成注入缝——成片即摄像头画面 + 可选混音音轨）。
///
/// 视频路径：video 队列首帧装配 writer（尺寸校验 + addVideoInput 携首帧格式描述做
/// sourceFormatHint；有混音器则 addAudioInput + startWriting）→ 逐帧 append；暂停门控 +
/// 平移 + 单调护栏走 `PauseMediaClock`，与 SCStreamRecorder 同款语义。音频路径
///（captureMicrophone 开启）：mic 经 `AVAudioEngine` inputNode tap 入 `SystemAudioMixer`
///（同一混音机器；cameraOnly 无系统声源——系统声唯一采集通道是 SCStream），混音包经
/// 视频锚点兜底门控（首帧原始 PTS gate + 文件基锚点比较，同 SCStreamRecorder 视频模式
/// 双保险）后 appendAudio。
///
/// 摄像头装配：授权/设备惯例沿用 `CameraPiPController`（`.builtInWideAngleCamera` 前置
/// + 在位校验 + notDetermined 代请求）；预设优先 720p、设备不支持退 VGA 档
///（`capturePlan` 成对决策 preset 与 writer 画布尺寸——两档交付尺寸恒定，是「writer
/// pixelSize 与实际交付一致」的机制前提，adaptor append 对维度硬约束）；帧率 = 设置 fps
/// 的设备就近支持档（`clampedFPS` 读设备格式钳制，lockForConfiguration 钉 min/max 帧间隔）。
/// 数据输出不镜像（成片为「他人视角」正规方向，CameraPiPController 同惯例）。
///
/// 排他纪律：writer 会话在采集装配成功后、startRunning 前挂载（`AssetWriterSession`
/// 预检 + O_EXCL claim），startRunning 后至首帧装配前的输出 URL 竞争窗口被封死；
/// 启动失败回滚 `discardIfNoContent` 摘除占位。
///
/// 失败通道：装配/启动失败由 start() 直接抛（协调器走 begin 失败路径）；录制中 append
/// 失败经 `onStreamFailure`（主队列保证；成员名沿用互换缝——语义为「会话失败通道」）
/// 上报，上层负责 stop() 安全收尾。`stop()` 后读 `finishedFileURL`（nil = 无成片）与
/// `lastError`（首个失败原因）。
///
/// 线程模型：会话装配与 startRunning/stopRunning 收敛在自有 `sessionQueue`
///（AVCaptureSession 的启停 API 阻塞式）；样本回调在自有 video 队列；`@unchecked
/// Sendable`——writerSession/mixer/mediaClock 全部经 stateLock 串行化，writerArmed 仅
/// video 队列触碰（生产单写者；无头测试在单测试线程直接驱动同一收敛点，等价串行）。
///
/// 单次生命周期实例：一个 recorder 只承载一次录制，不支持 stop 后复用。
final class CameraOnlyRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum CameraOnlyRecorderError: LocalizedError {
        /// notDetermined：已代发起系统授权请求，本次录制未开始（不阻塞等待授权）。
        case cameraPermissionNotDetermined
        /// denied/restricted：系统设置里权限被拒。
        case cameraPermissionDenied
        case cameraNotFound
        /// 会话装配期失败（canAddInput/canAddOutput 拒绝、设备连接失败等），携带原因。
        case sessionConfigurationFailed(String)
        /// startRunning 后会话仍未运行（设备被独占/拔出等）。
        case sessionDidNotStart
        /// 首帧交付尺寸与挂载画布不符（防御：adaptor append 维度硬约束的前置显式失败）。
        case frameDimensionMismatch(expected: CGSize, actual: CGSize)

        var errorDescription: String? {
            switch self {
            case .cameraPermissionNotDetermined:
                return "摄像头尚未授权：已发起系统授权请求，本次录制未能开始；授权后重新开始录制即可"
            case .cameraPermissionDenied:
                return "摄像头权限被拒绝：请在系统设置 > 隐私与安全性 > 摄像头中允许本应用后重新开始录制"
            case .cameraNotFound:
                return "未找到可用的前置摄像头，无法开始仅摄像头录制"
            case .sessionConfigurationFailed(let reason):
                return "摄像头会话装配失败：\(reason)"
            case .sessionDidNotStart:
                return "摄像头会话启动失败（设备可能被其他应用占用或已断开）"
            case .frameDimensionMismatch(let expected, let actual):
                return "摄像头交付尺寸与预期不符（预期 \(Int(expected.width))×\(Int(expected.height))，"
                    + "实际 \(Int(actual.width))×\(Int(actual.height))），本次录制未能开始"
            }
        }
    }

    /// 会话失败通道（主队列保证；互换缝沿用 SCStreamRecorder 成员名）。
    var onStreamFailure: ((Error) -> Void)?

    /// `stop()` 完成后的成片 URL；nil 表示本次无产出（启动失败 / 采集失败 / 零样本）。
    private(set) var finishedFileURL: URL?

    /// 首个失败的原因（诊断用）。
    private(set) var lastError: Error?

    // MARK: 测试缝（CameraPiPController 同款授权/设备缝 + 受控暂停时钟）

    /// 授权状态查询（生产 = `AVCaptureDevice.authorizationStatus(for:)`；无头钉测注入）。
    var authorizationStatus: (AVMediaType) -> AVAuthorizationStatus = {
        AVCaptureDevice.authorizationStatus(for: $0)
    }
    /// 授权请求发起（notDetermined 时生产弹系统授权框，start 不等待结果）。
    var requestCameraAccess: (AVMediaType, @escaping (Bool) -> Void) -> Void = { mediaType, completionHandler in
        AVCaptureDevice.requestAccess(for: mediaType, completionHandler: completionHandler)
    }
    /// 前置广角设备解析（枚举惯例沿用 CameraPiPController；无头钉测注入 nil 验失败路径）。
    var cameraDeviceProvider: () -> AVCaptureDevice? = {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
    }
    /// 前置摄像头在位校验（CameraPiPController「拔出后装配显式失败」同惯例）。
    var isCameraDeviceConnected: () -> Bool = {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)?.isConnected == true
    }
    /// 暂停时点时钟（生产 = `CMClock.hostTimeClock.time`，与帧 PTS 同 mach 时基；本类抽缝
    /// 供无头钉测注入受控时点——SCStreamRecorder 内联 host 值，无缝）。
    var pauseClock: () -> CMTime = { CMClock.hostTimeClock.time }

    private let config: RecordingConfiguration
    private let session = AVCaptureSession()
    /// start/stop 的会话装配与启停专用串行队列（startRunning/stopRunning 阻塞式，不占调用线程）。
    private let sessionQueue = DispatchQueue(label: "screenRecorder.CameraOnlyRecorder.session", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "screenRecorder.CameraOnlyRecorder.video", qos: .userInteractive)
    private let stateLock = NSLock()
    private var writerSession: AssetWriterSession?
    /// 混音器（含 engine；captureMicrophone 且启动成功时非 nil）。
    private var mixer: SystemAudioMixer?
    /// 挂载 writer 时的画布尺寸（首帧尺寸校验基准；挂载前/收尾后 .zero）。
    private var expectedPixelSize: CGSize = .zero
    /// startRunning 成功后置位（stop 收尾用：会话确实跑过才需要 stopRunning）。
    private var captureStarted = false
    /// 仅 video 队列触碰：writer 输入是否已装配完毕（首帧装配，SCStreamRecorder 同款旗标）。
    private var writerArmed = false
    /// 暂停媒体时钟（门控 + 平移 + 每轨单调护栏），所有访问经 stateLock。
    private var mediaClock = PauseMediaClock()
    /// 暂停丢弃计数的收尾快照（SCStreamRecorder 同款：stop/失败回滚复位时钟前并入，
    /// 只读属性读「活动 + 快照」，stop 后诊断读数仍是终值）。
    var finalPausedDroppedVideoFrameCount = 0
    var finalPausedDroppedAudioPacketCount = 0

    init(config: RecordingConfiguration) {
        self.config = config
        super.init()
    }

    /// 诊断只读（无头钉测缝）：writer 当前状态（等 .writing 的测试同
    /// AssetWriterSessionTests.waitForNonUnknownStatus 精神；生产零消费）。
    var writerStatusForTesting: AVAssetWriter.Status? {
        stateLock.withStateLock { writerSession?.writerStatus }
    }

    // MARK: - 纯逻辑钉测缝

    /// 采集计划：会话预设与 writer 画布尺寸成对定格（单一真源，装配与钉测共用）。
    struct CapturePlan: Equatable {
        let preset: AVCaptureSession.Preset
        let pixelSize: CGSize
    }

    /// 预设决策（纯逻辑，无头钉测缝）：HD 档可用 → 720p（仅摄像头成片是主画面，VGA 偏低）；
    /// 不可用 → VGA 档（CameraPiPController 既有惯例档）。两档交付尺寸恒定（hd1280x720 →
    /// 1280×720；vga640x480 → 640×480），writer pixelSize 按同值挂载——adaptor append 对
    /// 维度硬约束，尺寸与交付档一致的机制前提。
    static func capturePlan(supportsHD: Bool) -> CapturePlan {
        supportsHD
            ? CapturePlan(preset: .hd1280x720, pixelSize: CGSize(width: 1280, height: 720))
            : CapturePlan(preset: .vga640x480, pixelSize: CGSize(width: 640, height: 480))
    }

    /// 设置 fps 的设备就近支持档（纯逻辑，无头钉测缝）：高于设备格式全档上限取上限、低于
    /// 全档下限取下限、档间原样；野值（≤0）先收敛到 1 再落钳制区间。
    static func clampedFPS(_ requested: Int, deviceMin: Double, deviceMax: Double) -> Double {
        min(max(Double(Swift.max(requested, 1)), deviceMin), deviceMax)
    }

    /// 首帧尺寸校验（防御，纯逻辑可钉）：交付格式与 writer 画布必须一致——adaptor append
    /// 对维度硬约束，错配会在逐帧 append 上低可诊断地失败；首帧显式比对给出可行动错误。
    static func validateFrameDimensions(_ format: CMFormatDescription?, expected: CGSize) throws {
        guard let format else {
            throw CameraOnlyRecorderError.sessionConfigurationFailed("首帧缺少格式描述")
        }
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        guard Int(dims.width) == Int(expected.width), Int(dims.height) == Int(expected.height) else {
            throw CameraOnlyRecorderError.frameDimensionMismatch(
                expected: expected,
                actual: CGSize(width: Int(dims.width), height: Int(dims.height)))
        }
    }

    // MARK: - 生命周期

    /// 启动录制：授权/设备预检 → 混音器启动（麦克风，失败降级纯视频轨）→ 会话装配
    ///（设备输入 + 预设谈判 + 帧率钳制 + 帧输出）→ writer 挂载（claim 排他占位）→
    /// startRunning。任一步失败即抛（协调器走 begin 失败路径，占位清理由回滚完成）。
    func start() async throws {
        try checkCameraAuthorization()
        guard isCameraDeviceConnected() else {
            throw CameraOnlyRecorderError.cameraNotFound
        }
        guard let device = cameraDeviceProvider() else {
            throw CameraOnlyRecorderError.cameraNotFound
        }
        // 混音器先于 startRunning 启动（SCStreamRecorder 同序——engine 先热，两路音频从
        // 第一刻起不缺位；仅开麦克风即建混音器）。启动失败（无输出设备等极端环境）降级为
        // 纯视频轨，不阻断录制。cameraOnly 无系统声源（SCStream 专属通道）。
        var activeMixer: SystemAudioMixer?
        if SCStreamRecorder.includesAudioTrack(captureSystemAudio: config.captureSystemAudio,
                                               captureMicrophone: config.captureMicrophone,
                                               clickSoundEnabled: config.clickSoundEnabled) {
            let engine = AVAudioEngine()
            let mixer = SystemAudioMixer()
            if config.captureMicrophone {
                registerMicrophone(on: mixer, engine: engine)
            }
            do {
                try mixer.start(engine: engine) { [weak self] sampleBuffer in
                    self?.handleMixedAudio(sampleBuffer)
                }
                activeMixer = mixer
            } catch {
                NSLog("CameraOnlyRecorder: 混音器启动失败，本次录制仅视频轨：\(error)")
            }
        }
        do {
            // 会话装配（sessionQueue 串行）产出捕获计划（preset 与 writer 画布成对定格），
            // writer 挂载（claim）后才 startRunning——首帧装配前的输出 URL 竞争窗口被封死。
            let plan = try await assembleCaptureSession(device: device)
            try mountWriterSession(pixelSize: plan.pixelSize)
            try await startRunning()
            stateLock.withStateLock {
                mixer = activeMixer
                captureStarted = true
            }
        } catch {
            // 回滚（SCStreamRecorder start 失败同款模式）：撤销已发布引用 + 复位暂停时钟
            //（封住发布→撤销竞态窗口内进入的暂停）+ 停混音 + discard 摘除排他占位。
            let mounted: AssetWriterSession? = stateLock.withStateLock {
                finalPausedDroppedVideoFrameCount += mediaClock.pausedDroppedVideoFrameCount
                finalPausedDroppedAudioPacketCount += mediaClock.pausedDroppedAudioPacketCount
                let owned = writerSession
                writerSession = nil
                expectedPixelSize = .zero
                mediaClock = PauseMediaClock()
                return owned
            }
            activeMixer?.stop()
            mounted?.discardIfNoContent()
            throw error
        }
    }

    /// 摄像头授权预检（CameraPiPController 同款分流）：denied/restricted 抛权限错；
    /// notDetermined 代为发起授权请求后抛错——不阻塞录制等待授权（授权完成后重录生效）。
    private func checkCameraAuthorization() throws {
        switch authorizationStatus(.video) {
        case .authorized:
            return
        case .notDetermined:
            requestCameraAccess(.video) { _ in }
            throw CameraOnlyRecorderError.cameraPermissionNotDetermined
        case .denied, .restricted:
            throw CameraOnlyRecorderError.cameraPermissionDenied
        @unknown default:
            throw CameraOnlyRecorderError.cameraPermissionDenied
        }
    }

    /// 会话装配（sessionQueue 串行）：设备输入 + 预设谈判（`capturePlan`，成对产出 writer
    /// 画布尺寸）+ 帧率钳制 + 帧输出（不镜像——「他人视角」）。返回捕获计划。
    private func assembleCaptureSession(device: AVCaptureDevice) async throws -> CapturePlan {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CapturePlan, Error>) in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CameraOnlyRecorderError.sessionConfigurationFailed("会话已被释放"))
                    return
                }
                do {
                    let plan: CapturePlan = try self.assembleOnSessionQueue(device: device)
                    continuation.resume(returning: plan)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func assembleOnSessionQueue(device: AVCaptureDevice) throws -> CapturePlan {
        session.beginConfiguration()
        do {
            let input: AVCaptureDeviceInput
            do {
                input = try AVCaptureDeviceInput(device: device)
            } catch {
                throw CameraOnlyRecorderError.sessionConfigurationFailed("无法连接摄像头设备：\(error)")
            }
            guard session.canAddInput(input) else {
                throw CameraOnlyRecorderError.sessionConfigurationFailed("会话拒绝摄像头输入")
            }
            session.addInput(input)
            // 预设谈判在设备输入在位后进行（canSetSessionPreset 反映实际设备能力）；
            // preset 与 writer 画布成对定格（capturePlan 单一真源）。
            let plan = Self.capturePlan(supportsHD: session.canSetSessionPreset(.hd1280x720))
            session.sessionPreset = plan.preset
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, // 与 adaptor 声明一致
            ]
            output.alwaysDiscardsLateVideoFrames = true // 实时语义：宁丢帧不积压（CameraPiPController 同款）
            output.setSampleBufferDelegate(self, queue: videoQueue)
            guard session.canAddOutput(output) else {
                throw CameraOnlyRecorderError.sessionConfigurationFailed("会话拒绝帧输出")
            }
            session.addOutput(output)
            if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false // 数据输出不镜像：成片为「他人视角」
            }
            applyFrameRateLimit(on: device)
            session.commitConfiguration()
            return plan
        } catch {
            session.commitConfiguration()
            throw error
        }
    }

    /// 帧率钳制（设置 fps 的设备就近支持档）：读设备 activeFormat 支持区间收敛后，把
    /// min/max 帧间隔同时钉到该档（稳态节拍）。读写失败仅留日志——帧率档是尽力装配，
    /// 不阻断录制（设备按自身默认节拍交付）。
    private func applyFrameRateLimit(on device: AVCaptureDevice) {
        let ranges = device.activeFormat.videoSupportedFrameRateRanges
        let minFPS = ranges.reduce(Double.greatestFiniteMagnitude) { Swift.min($0, Double($1.minFrameRate)) }
        let maxFPS = ranges.reduce(0.0) { Swift.max($0, Double($1.maxFrameRate)) }
        guard minFPS > 0, maxFPS > 0, maxFPS >= minFPS else { return }
        let clamped = Self.clampedFPS(config.fps, deviceMin: minFPS, deviceMax: maxFPS)
        let duration = CMTime(value: 1, timescale: CMTimeScale(clamped))
        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
        } catch {
            NSLog("CameraOnlyRecorder: 帧率钳制失败（请求 \(config.fps) fps，就近档 \(clamped)）：\(error)")
        }
    }

    /// writer 会话挂载（internal = 无头钉测缝，CameraPiPTests 假源惯例）：建
    /// `AssetWriterSession`（预检 + O_EXCL claim 排他占位）并记录画布尺寸（首帧校验基准）。
    /// 生产路径由 start() 在会话装配成功后调用；无头测试据此在不触碰摄像头的情况下钉
    /// writer 装配、claim 纪律与暂停时间轴（假帧源直接驱动 `handleVideoSample`）。
    func mountWriterSession(pixelSize: CGSize) throws {
        let writer = try AssetWriterSession(config: config, pixelSize: pixelSize)
        stateLock.withStateLock {
            writerSession = writer
            expectedPixelSize = pixelSize
        }
    }

    private func startRunning() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CameraOnlyRecorderError.sessionConfigurationFailed("会话已被释放"))
                    return
                }
                self.session.startRunning()
                if self.session.isRunning {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: CameraOnlyRecorderError.sessionDidNotStart)
                }
            }
        }
    }

    private func stopRunning() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                if self.session.isRunning {
                    self.session.stopRunning()
                }
                continuation.resume()
            }
        }
    }

    /// 是否暂停中（任意线程可读；T11 浮条按钮态）。
    var isPaused: Bool {
        stateLock.withStateLock { mediaClock.isPaused }
    }

    /// 暂停录制（T11 浮条消费）：此后帧与音频包在各自队列上下文丢弃，会话保持运行（恢复
    /// 零重启开销）。录制未开始（writer 未挂载）或已 stop() 后为 no-op（不抛错）；幂等。
    func pause() {
        stateLock.withStateLock {
            guard writerSession != nil, !mediaClock.isPaused else { return }
            mediaClock.pause(at: pauseClock())
        }
    }

    /// 恢复录制：此后 append 的 PTS 统一平移去除暂停段，成片时长不含暂停间隙。
    /// 未暂停时 no-op（幂等）。
    func resume() {
        stateLock.withStateLock {
            guard mediaClock.isPaused else { return }
            mediaClock.resume(at: pauseClock())
        }
    }

    /// 暂停期间丢弃的视频帧数（诊断只读；语义与 SCStreamRecorder 同款：读数 = 活动 +
    /// 收尾快照，与 writer 编码未就绪丢弃互斥可区分，回跳丢弃与非数值 PTS 不计入）。
    var pausedDroppedVideoFrameCount: Int {
        stateLock.withStateLock {
            mediaClock.pausedDroppedVideoFrameCount + finalPausedDroppedVideoFrameCount
        }
    }

    /// 暂停期间丢弃的音频包数（诊断口径同上）。
    var pausedDroppedAudioPacketCount: Int {
        stateLock.withStateLock {
            mediaClock.pausedDroppedAudioPacketCount + finalPausedDroppedAudioPacketCount
        }
    }

    /// 停采集并收尾成片。幂等（重复调用 no-op）；完成后 `finishedFileURL` 反映结果，
    /// 失败原因记入 `lastError`（不触发 `onStreamFailure`——主动收尾时调用方就在现场）。
    /// 顺序与 SCStreamRecorder 同构：先停源（stopRunning，此后无新帧）→ 停混音（围栏
    /// 排空 delivery 队列）→ video 队列栅栏排空在途帧回调 → 收尾 writer。
    func stop() async {
        let started: Bool = stateLock.withStateLock { captureStarted }
        if started {
            await stopRunning()
        }
        let mixer: SystemAudioMixer? = stateLock.withStateLock {
            let owned = self.mixer
            self.mixer = nil
            return owned
        }
        mixer?.stop()
        videoQueue.sync {} // 栅栏：在途帧回调全部完成（未开采集时亦无害）
        let writer: AssetWriterSession? = stateLock.withStateLock {
            let owned = writerSession
            writerSession = nil
            expectedPixelSize = .zero
            captureStarted = false
            // 暂停态随会话一并终结 + 计数并入快照（SCStreamRecorder 同款：`+=` 对复位后
            // 的新时钟恒加 0，重复 stop 不覆盖快照）。
            finalPausedDroppedVideoFrameCount += mediaClock.pausedDroppedVideoFrameCount
            finalPausedDroppedAudioPacketCount += mediaClock.pausedDroppedAudioPacketCount
            mediaClock = PauseMediaClock()
            return owned
        }
        guard let writer else { return } // start() 从未成功：无会话可收尾
        do {
            let url = try await writer.finish()
            stateLock.withStateLock { finishedFileURL = url }
        } catch {
            stateLock.withStateLock { if lastError == nil { lastError = error } }
        }
    }

    /// brief 签名缝（`finish() async -> URL?`）：stop + 读成片的合成便捷面。协调器互换
    /// 装配走 stop()/finishedFileURL（与 SCStreamRecorder 同形），本缝供直接持有的调用方。
    func finish() async -> URL? {
        await stop()
        return stateLock.withStateLock { finishedFileURL }
    }

    // MARK: - 混音 live 链（互换缝：转发语义与 SCStreamRecorder 一致）

    /// 登记麦克风输入（SCStreamRecorder 同款）：engine inputNode tap。无音频输入设备的
    /// 极端环境访问 inputNode 会抛 ObjC 异常（Swift 侧接不住），先以 AVCaptureDevice 预检
    /// 降级为不含麦克风的混音；TCC 未授权时 inputNode 输出静音（无声人声轨，成片仍有效）。
    private func registerMicrophone(on mixer: SystemAudioMixer, engine: AVAudioEngine) {
        guard AVCaptureDevice.default(for: .audio) != nil else {
            NSLog("CameraOnlyRecorder: 无音频输入设备，本次录制不含麦克风")
            return
        }
        mixer.setMicrophoneInput(engine.inputNode.inputFormat(forBus: 0), volume: Float(config.micVolume))
        // 终审 F2：开录时的静音快照（config.micMuted）——状态驱动幂等。
        mixer.setMicMuted(config.micMuted)
    }

    /// 麦克风静音（浮条静音按钮语义）：转发混音器摘除/回装 inputNode tap；无混音器 no-op。
    func setMicMuted(_ muted: Bool) {
        let mixer: SystemAudioMixer? = stateLock.withStateLock { mixer }
        mixer?.setMicMuted(muted)
    }

    /// 麦克风增益实时更新：转发混音器施加 per-input 音量（运行中即时生效）；无混音器 no-op。
    func setMicVolume(_ volume: Float) {
        let mixer: SystemAudioMixer? = stateLock.withStateLock { mixer }
        mixer?.setMicVolume(volume)
    }

    /// 路由自愈触发（T18，MicrophoneRouteWatcher 主队列回调）：快照当前混音器执行
    /// `.AVAudioEngineConfigurationChange` 后的重建。无混音器 no-op。
    func rebuildAudioAfterConfigurationChange() {
        let mixer: SystemAudioMixer? = stateLock.withStateLock { mixer }
        mixer?.rebuildAfterConfigurationChange()
    }

    /// 点击音效调度（互换缝要求成员在位；cameraOnly 经 makeConfiguration 强制关，实际
    /// 不可达）：转发当前混音器，无混音器 no-op。
    func scheduleClickEffect() {
        let mixer: SystemAudioMixer? = stateLock.withStateLock { mixer }
        mixer?.scheduleClickEffect()
    }
}

// MARK: - 互换缝

/// `CaptureRecorderControlling` 生产实现：生命周期与 live 链成员全部在位，空扩展即合规。
extension CameraOnlyRecorder: CaptureRecorderControlling {}

// MARK: - 采样回调

extension CameraOnlyRecorder {
    /// `AVCaptureVideoDataOutput` 样本回调（video 队列串行执行）。
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        handleVideoSample(sampleBuffer)
    }

    /// video 队列串行执行（internal = 无头钉测缝——AVCaptureOutput/Connection 形参无法在
    /// 无头测试进程构造，假源直接驱动本收敛点，CameraPiPTests 惯例）。首帧装配 writer
    ///（尺寸校验 + addVideoInput + 有混音器则 addAudioInput + startWriting），之后逐帧
    /// append；首帧 append 确立锚点后，把首帧原始采集 PTS 交给混音器 gate（音频初筛）。
    /// 暂停门控 + 平移 + 视频轨单调护栏与 SCStreamRecorder 同款：暂停中的帧不入 writer、
    /// 不装配也不平移——首帧装配顺延到恢复后的首个内容帧。
    func handleVideoSample(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let writer: AssetWriterSession? = stateLock.withStateLock { writerSession }
        guard let writer else { return } // stop() 已收走会话：丢弃尾部帧
        let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        // 暂停门控 + 平移 + 视频轨单调护栏（clock 决策 nil = 丢弃，含暂停中的全部帧）
        guard let shiftedPTS = stateLock.withStateLock({ mediaClock.shiftedPTS(rawPTS, for: .video) }) else { return }
        do {
            let didArm = !writerArmed
            if didArm {
                let formatHint = CMSampleBufferGetFormatDescription(sampleBuffer)
                try Self.validateFrameDimensions(formatHint, expected: expectedPixelSize)
                try writer.addVideoInput(with: formatHint)
                let mixer: SystemAudioMixer? = stateLock.withStateLock { mixer }
                if let mixer {
                    try writer.addAudioInput(with: mixer.masterFormat)
                }
                writer.startWriting()
                writerArmed = true
            }
            try writer.appendVideo(pixelBuffer, at: shiftedPTS)
            if didArm {
                // gate 用首帧原始采集 PTS（host 时基）：混音侧初筛「锚点前的内容」；
                // 文件基（平移后）锚点兜底由 handleMixedAudio 负责（SCStreamRecorder 同款双保险）。
                let mixer: SystemAudioMixer? = stateLock.withStateLock { mixer }
                mixer?.setGatePTS(rawPTS)
            }
        } catch {
            recordFailure(error)
        }
    }

    /// delivery 串行队列回调：混音器输出（masterFormat）→ 平移 → 视频锚点兜底门控 →
    /// appendAudio。cameraOnly 必有视频锚定先导（与 audioOnly 相反）：锚点未立（视频帧
    /// 未到）前整包丢弃，文件基比较拒绝早于锚点的包（早于锚点的样本 macOS 27 会被 writer
    /// 静默钳到成片起点，不可靠拒绝）；时钟层音频单调护栏挡暂停边界在途回跳包（SCStreamRecorder
    /// 视频模式同款互补）。
    private func handleMixedAudio(_ sampleBuffer: CMSampleBuffer) {
        let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard let shiftedPTS = stateLock.withStateLock({ mediaClock.shiftedPTS(rawPTS, for: .audio) }) else { return }
        let writer: AssetWriterSession? = stateLock.withStateLock { writerSession }
        guard let writer else { return } // stop() 已收走会话：丢弃尾部样本
        let anchor = writer.isReadyForVideoMediaTime
        guard anchor.isValid, anchor.isNumeric else { return } // 视频未锚定：录制尚未开始，丢弃
        guard CMTimeCompare(shiftedPTS, anchor) >= 0 else { return } // 文件基：不得早于锚点
        // 平移落盘：换时浅拷贝（数据与时长保真，仅 PTS 置为平移值）；打包失败丢包。
        guard let retimed = AudioSampleBridge.sampleBuffer(copying: sampleBuffer, presentationTimeStamp: shiftedPTS) else { return }
        do {
            try writer.appendAudio(retimed)
        } catch {
            // stop() 先围栏排空混音 delivery 队列再收尾 writer，finish 期间不可能有 append——
            // 本分支纯防御：仅当 stop 已开始（会话已被收走）才吞错；录制中途真正的 writer
            // 故障仍必须 recordFailure → onStreamFailure。
            let stopHasBegun: Bool = stateLock.withStateLock { writerSession == nil }
            if !stopHasBegun {
                recordFailure(error)
            }
        }
    }

    /// 首次失败生效：记录原因 + 主队列上报 `onStreamFailure`（SCStreamRecorder 同款）；
    /// 上层负责 stop() 安全收尾。
    private func recordFailure(_ error: Error) {
        let shouldNotify: Bool = stateLock.withStateLock {
            guard lastError == nil else { return false }
            lastError = error
            return true
        }
        guard shouldNotify else { return }
        let callback = onStreamFailure
        if Thread.isMainThread {
            callback?(error)
        } else {
            DispatchQueue.main.async { callback?(error) }
        }
    }
}
