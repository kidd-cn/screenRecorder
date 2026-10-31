import CoreImage
import CoreVideo
import Foundation
import Vision

// MARK: - PersonSegmenting（简报 Produces 逐字）

/// 人像分割缝（P5）：给定摄像头帧返回人像亮度 mask（CIImage，白=人像前景）。生产实现挂
/// `VNGeneratePersonSegmentationRequest`（`VisionPersonSegmenter`）；无头测试注入假实现
/// ——Vision 真请求不得进测试进程。返回 nil = mask 不可得（请求失败/无人像），消费侧
///（`CameraBackgroundProcessor`）按原帧直通不丢帧——分割是增强，不是帧的门卫。
protocol PersonSegmenting {
    func segmentationMask(for pixelBuffer: CVPixelBuffer) async -> CIImage?
}

// MARK: - VisionPersonSegmenter（生产实现）

/// Vision 人像分割生产实现：`VNGeneratePersonSegmentationRequest` 在专用串行队列同步执行
///（`VNImageRequestHandler.perform` 是阻塞调用——不得占主线程，也不丢给协作线程池空转；
/// 专用串行队列同时给逐帧分割天然 FIFO 背压：上一帧未完，下一帧排队不并发堆积）。
///
/// 质量档（规格 §7 留实现者，此处定夺并记录）：`.balanced`——`.accurate` 在 640×480
/// 源上的发丝级边缘增益对 ~160pt 的 PiP 展示尺寸不可辨而耗时显著更高；`.fast` 边缘破损
/// 明显。balanced 在 VGA 尺寸毫秒级（真机清单保留 30/60fps 实测项），逐帧预算内。
final class VisionPersonSegmenter: PersonSegmenting {
    /// 进程级单例（模型加载一次，多场录制复用；无逐场冷启动成本）。
    static let shared = VisionPersonSegmenter()

    private let queue = DispatchQueue(
        label: "screenRecorder.CameraBackground.vision", qos: .userInitiated)

    func segmentationMask(for pixelBuffer: CVPixelBuffer) async -> CIImage? {
        await withCheckedContinuation { continuation in
            let job = VisionMaskJob(pixelBuffer: pixelBuffer, continuation: continuation)
            queue.async { job.perform() }
        }
    }
}

/// 逐帧分割任务（`@unchecked Sendable` 包装，消除 `queue.async` 的 @Sendable 闭包对
/// 非 Sendable `CVPixelBuffer` 的捕获告警）：CVPixelBuffer 为 CF 类型（内部引用计数），
/// 经此独占移交专用串行队列——队列串行语义下无并发访问，Sendable 约束据此成立
///（PiPFrameStore 的 @unchecked Sendable + 锁/队列纪律同风格）。
private struct VisionMaskJob: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let continuation: CheckedContinuation<CIImage?, Never>

    /// 专用串行队列上执行：`VNGeneratePersonSegmentationRequest` 同步 perform（阻塞调用，
    /// 队列串行即逐帧 FIFO 背压）。请求失败/无观测 → nil（消费侧原帧直通不丢帧）。
    func perform() {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do {
            try handler.perform([request])
            guard let maskBuffer = request.results?.first?.pixelBuffer else {
                continuation.resume(returning: nil)
                return
            }
            continuation.resume(returning: CIImage(cvPixelBuffer: maskBuffer))
        } catch {
            continuation.resume(returning: nil) // 请求失败：mask 不可得 → 原帧直通
        }
    }
}

// MARK: - CameraBackgroundProcessor（简报 Produces 逐字）

/// 摄像头 PiP 背景处理器（P5）：输入一帧摄像头画面，输出背景替换后的一帧。
/// - `.off`：零开销直通（原缓冲原样返回，不调分割不渲染——帧路径旁路）；
/// - `.blur`：人像前景叠「自身高斯模糊」底（虚化背景观感）；
/// - `.builtin`：人像前景叠程序生成渐变/纯色（CIImage 生成，零素材文件）。
/// mask 不可得（segmenter 返回 nil）或渲染链任一失败 → 原帧直通不丢帧（PiPCompositor
/// 「宁直通不丢帧」同纪律）。
///
/// 缓冲纪律（与一期 `PiPCompositor` 同款）：输出缓冲取自 `CVPixelBufferPool`（32BGRA @
/// 输入帧实测尺寸，尺寸变化时重建，池不可用兜底直建）；32BGRA 与 videoDataOutput 的
/// 输出格式一致——下游 `PiPCompositor` 的 `CIImage(cvPixelBuffer:)` 与摆放数学无格式/
/// 尺寸失配。`CIContext` 单实例复用（`useSoftwareRenderer: false` 走 GPU，PiPCompositor
/// 同款）。
///
/// 线程模型：`process` 为 async——分割 await 专用 Vision 队列，渲染在协作线程；连续帧的
/// 分割/渲染可并发，池字段以 NSLock 串行化（CIContext 本身线程安全，Apple 文档口径）。
/// 帧次序由消费侧（`CameraPiPController`）的序号守卫保证——本类无帧间状态（内置背景
/// 单槽缓存除外，键含尺寸，跨帧值等价直取）。
final class CameraBackgroundProcessor {
    /// 背景模式（开录快照语义；构造后不变——录制中换模式自下一场录制生效）。
    let mode: CameraBackgroundMode

    private let segmenter: PersonSegmenting
    /// 单实例复用的渲染上下文（PiPCompositor 同款：GPU 渲染）。
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    /// 输出缓冲池与池尺寸（stateLock 保护——渲染可跨线程并发）。
    private var bufferPool: CVPixelBufferPool?
    private var poolSize: CGSize?
    private let stateLock = NSLock()
    /// 内置背景单槽缓存：键 =（样式, 宽, 高）——录制中恒定，逐帧零生成直取（平移/缩放
    /// 不缓存：渐变按帧尺寸生成即到位，无逐帧摆放成本）。
    private var builtinCache: (background: BuiltinBackground, width: Int, height: Int, image: CIImage)?

    /// 模糊半径（捕获像素，P5 观感定值）：640×480 源上 ~16px 高斯模糊在 PiP 展示尺寸
    ///（~160pt 窗）仍读得出「虚化」，边缘不过分涂抹。
    static let blurRadius: CGFloat = 16

    /// - Parameter mode: 背景模式（开录快照）。
    /// - Parameter segmenter: 分割缝（生产 = `VisionPersonSegmenter.shared`；测试注入假实现）。
    init(mode: CameraBackgroundMode, segmenter: PersonSegmenting) {
        self.mode = mode
        self.segmenter = segmenter
    }

    /// 逐帧处理：off 直通；mask 不可得/渲染失败直通原帧（不丢帧）。
    func process(_ frame: CVPixelBuffer) async -> CVPixelBuffer {
        if case .off = mode { return frame } // 零开销直通（不触碰分割缝）
        guard let mask = await segmenter.segmentationMask(for: frame) else {
            return frame // mask 不可得：原帧直通不丢帧
        }
        return compose(frame: frame, mask: mask) ?? frame
    }

    /// 当前输出缓冲池（internal 只读，供无头钉测「连帧命中同一池实例」——PiPCompositor
    /// 同款缝）。只在测试读；池字段本就 stateLock 保护。
    var activeOutputPool: CVPixelBufferPool? {
        stateLock.withStateLock { bufferPool }
    }

    // MARK: 合成（前景叠背景）

    /// 前景合成：`CIBlendWithMask`——inputImage=原帧（前景）、backgroundImage=背景、
    /// mask=人像亮度图（白=取前景）。任一滤镜构建/缓冲获取/渲染失败返回 nil（调用方
    /// 原帧直通）。
    private func compose(frame: CVPixelBuffer, mask: CIImage) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(frame)
        let height = CVPixelBufferGetHeight(frame)
        guard width > 0, height > 0 else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let input = CIImage(cvPixelBuffer: frame)
        guard input.extent.width > 0, input.extent.height > 0 else { return nil }

        let background: CIImage
        switch mode {
        case .off:
            return frame // 不可达（process 已旁路）；保守直通
        case .blur:
            guard let blur = CIFilter(name: "CIGaussianBlur") else { return nil }
            blur.setValue(input.clampedToExtent(), forKey: kCIInputImageKey) // 钳边防暗晕
            blur.setValue(Self.blurRadius, forKey: kCIInputRadiusKey)
            guard let blurred = blur.outputImage else { return nil }
            background = blurred.cropped(to: bounds)
        case .builtin(let builtin):
            guard let generated = builtinBackground(builtin, bounds: bounds) else { return nil }
            background = generated
        }

        // mask 对齐帧尺寸：Vision 观测缓冲可能小于输入帧——平移掉观测原点（像素缓冲
        // 观测恒 origin 0，平移为零；保守处理防御观测形态变化）后按帧尺寸拉伸。
        let maskExtent = mask.extent
        guard maskExtent.width > 0, maskExtent.height > 0,
              maskExtent.width.isFinite, maskExtent.height.isFinite else { return nil }
        let scaledMask = mask
            .transformed(by: CGAffineTransform(
                translationX: -maskExtent.minX, y: -maskExtent.minY))
            .transformed(by: CGAffineTransform(
                scaleX: bounds.width / maskExtent.width,
                y: bounds.height / maskExtent.height))

        guard let blend = CIFilter(name: "CIBlendWithMask") else { return nil }
        blend.setValue(input, forKey: kCIInputImageKey)
        blend.setValue(background, forKey: kCIInputBackgroundImageKey)
        blend.setValue(scaledMask, forKey: kCIInputMaskImageKey)
        guard let composed = blend.outputImage else { return nil }
        guard let output = dequeueOutputBuffer(width: width, height: height) else { return nil }
        context.render(composed.cropped(to: bounds), to: output)
        return output
    }

    // MARK: 内置背景（程序生成，零素材文件）

    /// 内置背景按帧尺寸生成；单槽缓存（样式+尺寸命中即直取，录制中恒定）。
    /// 渐变生成失败（滤镜缺位，实践中不可达）回退纯色灰蓝——背景路永不因生成失败丢帧。
    private func builtinBackground(_ builtin: BuiltinBackground, bounds: CGRect) -> CIImage? {
        if let cache = builtinCache,
           cache.background == builtin,
           cache.width == Int(bounds.width), cache.height == Int(bounds.height) {
            return cache.image
        }
        let image: CIImage
        switch builtin {
        case .gradientWarm:
            image = Self.linearGradient(bounds: bounds,
                                        from: Self.gradientWarmTop, to: Self.gradientWarmBottom)
                ?? Self.solid(bounds: bounds, color: Self.slateColor)
        case .gradientCool:
            image = Self.linearGradient(bounds: bounds,
                                        from: Self.gradientCoolTop, to: Self.gradientCoolBottom)
                ?? Self.solid(bounds: bounds, color: Self.slateColor)
        case .solidSlate:
            image = Self.solid(bounds: bounds, color: Self.slateColor)
        }
        builtinCache = (builtin, Int(bounds.width), Int(bounds.height), image)
        return image
    }

    /// 对角线性渐变（CILinearGradient）：起止点 = 画布左上 → 右下（CI 坐标 y 向上；
    /// 渲染进缓冲后即屏上的左上→右下对角向）。颜色以 sRGB 取值（CI 工作空间往返后
    /// 端点色保真）。
    private static func linearGradient(bounds: CGRect, from: CIColor, to: CIColor) -> CIImage? {
        guard let gradient = CIFilter(name: "CILinearGradient") else { return nil }
        gradient.setValue(CIVector(x: bounds.minX, y: bounds.maxY), forKey: "inputPoint0")
        gradient.setValue(from, forKey: "inputColor0")
        gradient.setValue(CIVector(x: bounds.maxX, y: bounds.minY), forKey: "inputPoint1")
        gradient.setValue(to, forKey: "inputColor1")
        guard let image = gradient.outputImage else { return nil }
        return image.cropped(to: bounds)
    }

    /// 纯色底。
    private static func solid(bounds: CGRect, color: CIColor) -> CIImage {
        CIImage(color: color).cropped(to: bounds)
    }

    /// 渐变/纯色配色（P5 观感定值；sRGB 空间取色——CI 工作空间往返后端点色保真）。
    /// `CIColor(…colorSpace:)` 为可失败初始化（色彩空间转换失败时 nil），失败回退
    /// 默认空间取色（观感近似，不阻断）。
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private static func srgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CIColor {
        CIColor(red: red, green: green, blue: blue, alpha: 1, colorSpace: sRGB)
            ?? CIColor(red: red, green: green, blue: blue, alpha: 1)
    }
    /// 暖渐变：橙 (1.00, 0.62, 0.35) → 绯红 (0.94, 0.33, 0.38)。
    private static let gradientWarmTop = srgb(1.00, 0.62, 0.35)
    private static let gradientWarmBottom = srgb(0.94, 0.33, 0.38)
    /// 冷渐变：青 (0.22, 0.78, 0.86) → 蓝 (0.33, 0.51, 0.90)。
    private static let gradientCoolTop = srgb(0.22, 0.78, 0.86)
    private static let gradientCoolBottom = srgb(0.33, 0.51, 0.90)
    /// 纯色灰蓝（slate）：(0.42, 0.47, 0.58)。
    private static let slateColor = srgb(0.42, 0.47, 0.58)

    // MARK: 输出缓冲池（PiPCompositor 同款纪律）

    /// 从池取输出缓冲（按帧实测尺寸建池，尺寸变化时重建；池不可用/耗尽时直建兜底——
    /// 宁分配不丢帧）。stateLock 串行化（渲染可跨线程并发）。
    private func dequeueOutputBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let size = CGSize(width: width, height: height)
        if poolSize != size {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
            var pool: CVPixelBufferPool?
            if CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess,
               let pool {
                bufferPool = pool
                poolSize = size
            } else {
                bufferPool = nil
                poolSize = nil
            }
        }
        if let bufferPool {
            var pooled: CVPixelBuffer?
            if CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, bufferPool, &pooled) == kCVReturnSuccess,
               let pooled {
                return pooled
            }
        }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, nil, &buffer
        ) == kCVReturnSuccess else { return nil }
        return buffer
    }
}
