import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import Hummingbird

/// 自定义虚拟背景库钉测（2026-11-15 Omi 虚拟背景页复刻）：临时目录注入——导入拷贝/
/// 列表排序/删除幂等/非图片拒绝/路径穿越防御（处理器侧）五条语义。
final class CustomBackgroundStoreTests: XCTestCase {
    private var directory: URL!
    private var store: CustomBackgroundStore!
    /// 导入源目录（与背景库**分离**——夹具源文件不得混入库列表）。
    private var sources: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hb-bgstore-\(UUID().uuidString)", isDirectory: true)
        sources = FileManager.default.temporaryDirectory
            .appendingPathComponent("hb-bgsrc-\(UUID().uuidString)", isDirectory: true)
        store = CustomBackgroundStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: sources)
    }

    /// 写一张纯红 PNG（ImageIO 直出，无 AppKit）到源目录。
    private func writePNG(red: UInt8 = 255, name: String = "src.png") throws -> URL {
        let url = sources.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let width = 4
        let height = 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw XCTSkip("CGContext 不可用")
        }
        context.setFillColor(CGColor(red: Double(red) / 255, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    /// 空库列表为空；导入后列表含新名（UUID 名，原文件名不入库）；再导一张按名排序。
    func testAddListSorted() throws {
        XCTAssertTrue(store.listNames().isEmpty, "空库列表为空")
        let first = try XCTUnwrap(store.addImage(from: writePNG(name: "a.png")))
        let second = try XCTUnwrap(store.addImage(from: writePNG(name: "b.png")))
        XCTAssertEqual(Set(store.listNames()), [first, second])
        XCTAssertEqual(store.listNames(), store.listNames().sorted(), "列表按文件名排序")
        XCTAssertTrue(store.contains(first))
        XCTAssertTrue(store.contains(second))
    }

    /// 删除真实删档（contains 翻转）；重复删除幂等返回 false；不存在名删除 false。
    func testRemoveIdempotent() throws {
        let name = try XCTUnwrap(store.addImage(from: writePNG()))
        XCTAssertTrue(store.removeImage(named: name))
        XCTAssertFalse(store.contains(name))
        XCTAssertFalse(store.removeImage(named: name), "重复删除幂等")
        XCTAssertFalse(store.removeImage(named: "nonexistent.png"), "不存在名删除 false")
        XCTAssertTrue(store.listNames().isEmpty)
    }

    /// 非 ImageIO 可解码文件拒绝导入（返回 nil 且不留半文件）。
    func testRejectsNonImage() throws {
        let junk = sources.appendingPathComponent("junk.dat")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: junk)
        let added = try store.addImage(from: junk)
        XCTAssertNil(added, "非图片拒绝导入")
        XCTAssertTrue(store.listNames().isEmpty, "不留半文件")
    }

    /// 无扩展名源导入默认 .png 扩展（可解码即通过）。
    func testAddsDefaultExtensionForExtensionlessSource() throws {
        let png = try writePNG(name: "noext")
        let renamed = sources.appendingPathComponent("noext")
        try FileManager.default.moveItem(at: png, to: renamed)
        let name = try XCTUnwrap(store.addImage(from: renamed))
        XCTAssertTrue(name.hasSuffix(".png"), "无扩展名源默认 .png：\(name)")
    }
}
