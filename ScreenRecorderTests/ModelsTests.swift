import CoreGraphics
import XCTest

@testable import ScreenRecorder

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
