import CoreGraphics
import XCTest

@testable import Hummingbird

/// CaptureMode 序列化钉测（P3a）：`lastCaptureMode` 以 JSON 整只落 UserDefaults
///（T17，⇧⌘R 上次使用模式）——新增 `.app(bundleID:)` 后 Codable 往返必须无损。
final class ModelsTests: XCTestCase {
    func testCaptureModeAppCodableRoundTrip() throws {
        let mode = CaptureMode.app(bundleID: "com.example.app")
        let data = try JSONEncoder().encode(mode)
        let decoded = try JSONDecoder().decode(CaptureMode.self, from: data)
        XCTAssertEqual(decoded, mode, "app 模式 Codable 往返无损（Equatable 逐值相等）")
    }

    /// P3b：windowRegion 携带双关联值（CGWindowID + 窗口相对 rect），`lastCaptureMode`
    /// JSON 落库往返必须无损（⇧⌘R 上次使用模式语义）。
    func testCaptureModeWindowRegionCodableRoundTrip() throws {
        let mode = CaptureMode.windowRegion(window: 42, rect: CGRect(x: 10, y: 20, width: 300, height: 200))
        let data = try JSONEncoder().encode(mode)
        let decoded = try JSONDecoder().decode(CaptureMode.self, from: data)
        XCTAssertEqual(decoded, mode, "windowRegion 模式 Codable 往返无损（Equatable 逐值相等）")
    }
}

/// 录制清晰度（2026-11-15）：按最大高度等比收敛、只缩不放、无效尺寸原样。
final class CaptureQualityTests: XCTestCase {
    func testSourceKeepsSize() {
        let size = CGSize(width: 3456, height: 2234)
        XCTAssertEqual(CaptureQuality.source.scaledPixelSize(size), size)
    }

    func testCapsTallerThanTargetPreservingAspect() {
        let size = CGSize(width: 3456, height: 2234)
        let capped = CaptureQuality.p1080.scaledPixelSize(size)
        XCTAssertEqual(capped.height, 1080)
        XCTAssertEqual(capped.width, 1671) // 3456 × 1080/2234 ≈ 1670.9 → round 1671
    }

    func testDoesNotUpscaleSmallerSource() {
        let size = CGSize(width: 1280, height: 720)
        XCTAssertEqual(CaptureQuality.p1080.scaledPixelSize(size), size)
        XCTAssertEqual(CaptureQuality.p720.scaledPixelSize(size), size)
    }

    func testZeroOrNonFiniteSizePassesThrough() {
        XCTAssertEqual(CaptureQuality.p720.scaledPixelSize(.zero), .zero)
        let nonFinite = CaptureQuality.p720.scaledPixelSize(
            CGSize(width: CGFloat.nan, height: 2000))
        XCTAssertTrue(nonFinite.width.isNaN, "非有限尺寸原样返回（NaN 不等于自身）")
        XCTAssertEqual(nonFinite.height, 2000)
    }

    func testExistingCallersDefaultToSource() {
        XCTAssertEqual(CaptureQuality(rawValue: "p720")?.maxHeight, 720)
        // 持久化解码缺键/野值 → settings 侧回退 .source（此处钉枚举原始值契约）。
        XCTAssertEqual(CaptureQuality(rawValue: "bogus"), nil)
    }
}
