import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 自定义虚拟背景库（2026-11-15 Omi 虚拟背景页复刻）：Application Support 下
/// `Hummingbird/Backgrounds/`（沙盒内容器随 app 迁移）内托管用户导入的图片文件。
/// `CameraBackgroundMode.custom(文件名)` 只存文件名——目录真源在本 store，
/// 换机/迁移整目录搬走即可。Core 纪律：不引 AppKit（校验用 ImageIO）。
struct CustomBackgroundStore {
    /// 背景库目录（真源；构造注入——无头测试指临时目录）。
    let directory: URL

    /// 支持的导入格式（OpenPanel 允许类型与落库校验共用）。
    static let allowedTypes: [String] = [
        UTType.png.identifier, UTType.jpeg.identifier, UTType.heic.identifier,
        UTType.bmp.identifier, UTType.gif.identifier, UTType.tiff.identifier,
    ]

    /// 默认目录（Application Support/Hummingbird/Backgrounds；不存在懒建在 add 时）。
    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Hummingbird/Backgrounds", isDirectory: true)
    }

    init(directory: URL = CustomBackgroundStore.defaultDirectory()) {
        self.directory = directory
    }

    // MARK: 查询

    /// 库内全部背景文件名（按文件名排序，稳定网格序）。目录不存在 = 空。
    func listNames() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    /// 文件完整 URL。
    func url(forName name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    /// 名字是否在库（remove/selected 校验用）。
    func contains(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url(forName: name).path)
    }

    /// 图片解码（CGImage；处理器的帧路径与 UI 缩略图共用此口径）。
    /// 解码失败/非图片返回 nil（消费侧直通/占位）。
    static func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: 增删

    /// 导入图片：拷贝为库内新名（UUID + 原扩展名；无扩展名默认 .png），返回新文件名。
    /// 非 ImageIO 可解码文件拒绝导入（返回 nil，不留半文件）；同名冲突理论不可达
    ///（UUID），覆盖防御保留。
    @discardableResult
    func addImage(from sourceURL: URL) throws -> String? {
        guard CustomBackgroundStore.loadImage(at: sourceURL) != nil else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = sourceURL.pathExtension.isEmpty
            ? "png"
            : sourceURL.pathExtension.lowercased()
        let name = "\(UUID().uuidString).\(ext)"
        let destination = url(forName: name)
        // 拷贝前清同位残档（防御性；UUID 冲突理论不可达）
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return name
    }

    /// 删除背景文件（不存在静默幂等）。返回是否实际删除。
    @discardableResult
    func removeImage(named name: String) -> Bool {
        guard contains(name) else { return false }
        do {
            try FileManager.default.removeItem(at: url(forName: name))
            return true
        } catch {
            NSLog("CustomBackgroundStore: 删除背景失败 \(name): \(error.localizedDescription)")
            return false
        }
    }
}
