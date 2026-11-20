import XCTest

@testable import Hummingbird

/// 启动条钉测（2026-11-15 Omi 49.png 复刻）：七模式顺序与 Omi 启动条逐格对齐、
/// 图标配置完备、布局几何可加性（总宽 = Σ瓦片 + 内边距）。
final class LaunchBarTests: XCTestCase {
    /// Omi 49.png 从左到右：全屏 / 自定义区域 / 窗口区域 / 窗口内容 / App 内容 /
    /// 摄像头 / 声音——顺序即产品规格（点击语义与菜单栏磁贴同源）。
    func testLaunchBarModesMatchOmiOrder() {
        XCTAssertEqual(LaunchBarMode.allCases, [
            .fullscreen, .region, .windowRegion, .window, .app, .camera, .audio,
        ])
    }

    /// 除 `.app`（自绘圆角方块）外全部有 SF 符号名；全部有非空标题键。
    func testModeIconAndTitleConfiguration() {
        for mode in LaunchBarMode.allCases {
            XCTAssertFalse(mode.titleKey.isEmpty)
            if mode == .app {
                XCTAssertNil(mode.symbolName, ".app 走自绘「APP」方块")
            } else {
                XCTAssertNotNil(mode.symbolName, "\(mode.titleKey) 须配 SF 符号")
            }
        }
    }

    /// 布局几何可加性：总宽 = n×瓦片宽 + 两侧内边距；第 i 块 x = 内边距 + i×瓦片宽
    ///（分隔线画在瓦片边界不占宽——逐格像素复制的前提）。
    func testLayoutArithmetic() {
        let count = LaunchBarMode.allCases.count
        XCTAssertEqual(
            LaunchBarLayout.barWidth(tileCount: count),
            CGFloat(count) * LaunchBarLayout.tileWidth + LaunchBarLayout.sidePadding * 2)
        XCTAssertEqual(LaunchBarLayout.tileX(index: 0), LaunchBarLayout.sidePadding)
        XCTAssertEqual(
            LaunchBarLayout.tileX(index: 3) - LaunchBarLayout.tileX(index: 2),
            LaunchBarLayout.tileWidth, "等宽逐格排布")
    }
}

// MARK: - Omi 选择窗口网格页（2026-11-16 55.png 复刻）钉测

/// 网格几何：4 列等分（视图宽扣除列间距与两侧 inset）、瓦片高 = 缩略图 + 标签、
/// 超窄回退标称瓦片。
final class WindowGridGeometryTests: XCTestCase {
    func testTileSizeDividesViewWidthIntoFourColumns() {
        // 900 宽 - 2×14 inset - 3×10 间距 = 842 → 每列 210.5 → floor 210
        XCTAssertEqual(
            WindowGridGeometry.tileSize(forViewWidth: 900),
            CGSize(width: 210, height: WindowGridGeometry.itemHeight))
    }

    func testTileSizeFallsBackOnTooNarrowView() {
        let fallback = CGSize(width: WindowGridGeometry.fallbackTileWidth,
                              height: WindowGridGeometry.itemHeight)
        XCTAssertEqual(WindowGridGeometry.tileSize(forViewWidth: 0), fallback)
        XCTAssertEqual(WindowGridGeometry.tileSize(forViewWidth: 100), fallback,
                       "每列不足 60pt 回退标称瓦片")
    }

    /// 新捕获模式（多窗口/多窗口区域）Codable 往返保值 + 屏幕画布表态在。
    func testWindowsModesCodableAndCanvasFlag() throws {
        let multi = CaptureMode.windows([1, 2, 3])
        let multiRegion = CaptureMode.windowsRegion(windows: [4, 5], rect: CGRect(x: 10, y: 20, width: 30, height: 40))
        for mode in [multi, multiRegion] {
            let decoded = try JSONDecoder().decode(
                CaptureMode.self, from: JSONEncoder().encode(mode))
            XCTAssertEqual(decoded, mode, "Codable 往返必须保值")
            XCTAssertTrue(mode.hasVideoCanvas, "多窗口族 = 屏幕视频画布在")
        }
    }
}
