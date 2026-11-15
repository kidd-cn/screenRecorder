import AppKit

// MARK: - LaunchBarMode（2026-11-15 Omi 49.png 启动条复刻）

/// 启动条录制模式（顺序与 Omi 启动条逐格对齐——testLaunchBarModesMatchOmiOrder 钉测）：
/// 全屏录制 / 自定义区域录制 / 窗口区域录制 / 窗口内容录制 / App 内容录制 / 摄像头录制 /
/// 声音录制。`symbolName` 为 SF Symbols 名（macOS 13 可用档）；`.app` 用自绘「APP」
/// 圆角方块（Omi 同款），不走符号。
enum LaunchBarMode: CaseIterable, Equatable {
    case fullscreen
    case region
    case windowRegion
    case window
    case app
    case camera
    case audio

    /// 标题（本地化键，zh = 原文与 Omi 逐字对齐）。
    var titleKey: String {
        switch self {
        case .fullscreen: return "全屏录制"
        case .region: return "自定义区域录制"
        case .windowRegion: return "窗口区域录制"
        case .window: return "窗口内容录制"
        case .app: return "App内容录制"
        case .camera: return "摄像头录制"
        case .audio: return "声音录制"
        }
    }

    /// SF Symbols 名（`.app` 无——自绘）。全屏取四角外扩（本系统 `rectangle.expand`
    /// 不可用，probe 钉测）；摄像头取相机+矩形（`webcamera` 不可用）。
    var symbolName: String? {
        switch self {
        case .fullscreen: return "square.arrowtriangle.4.outward"
        case .region: return "crop"
        case .windowRegion: return "viewfinder"
        case .window: return "macwindow"
        case .app: return nil
        case .camera: return "camera.on.rectangle"
        case .audio: return "speaker.wave.2"
        }
    }
}

/// 启动条布局几何（internal 供无头钉测）：等宽瓦片 + 1pt 分隔 + 左右内边距。
enum LaunchBarLayout {
    /// 单瓦片宽度（Omi 启动条 ~130pt 逐格目测取值）。
    static let tileWidth: CGFloat = 130
    /// 条高（标题 + 图标上下结构）。
    static let barHeight: CGFloat = 78
    /// 条左右内边距。
    static let sidePadding: CGFloat = 6

    /// 条总宽（n 瓦片 + 内边距；分隔线画在瓦片边界不占宽）。
    static func barWidth(tileCount: Int) -> CGFloat {
        CGFloat(tileCount) * tileWidth + sidePadding * 2
    }

    /// 第 i 块瓦片的 x（条内坐标）。
    static func tileX(index: Int) -> CGFloat {
        sidePadding + CGFloat(index) * tileWidth
    }
}

// MARK: - LaunchBarWindowController（装配红线：窗口归装配容器）

/// 启动条（Omi 49.png）：顶部居中悬浮横条，7 个录制模式瓦片（标题+图标，悬停高亮）
/// + 右上角关闭钮。AppKit 原生交互（手建窗 SwiftUI 手势层死——ZoomEditor 定论），
/// 点击瓦片即回调装配层开录（回调后收条；窗口/声画选择器自会盖上来）。
/// 非激活面板：不抢焦点，任意应用前台都能点。
@MainActor
final class LaunchBarWindowController {
    private let panel = LaunchBarPanel()
    /// 瓦片点击回调（装配层注入；开录入口与菜单栏磁贴同源）。
    private let onMode: (LaunchBarMode) -> Void
    private var barView: LaunchBarView?

    init(onMode: @escaping (LaunchBarMode) -> Void) {
        self.onMode = onMode
    }

    /// 显示启动条（幂等重入 = 前置；已显示不重复定位）。主屏顶部居中（Omi 位）。
    func show() {
        if barView == nil {
            installBar()
        }
        positionTopCenter()
        panel.orderFrontRegardless()
        // macOS 26 启动期合成晚到（2026-11-15 实测：show 时 occlusion 不含 .visible，
        // ~1s 后合成到位）：1s 后复查，仍未上屏（窗口服务拥塞等）重发一次前置。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.panel.isVisible,
                  self.panel.occlusionState.intersection(.visible).isEmpty else { return }
            self.panel.orderFrontRegardless()
        }
    }

    /// 收条（× / 瓦片点击后）。
    func close() {
        panel.orderOut(nil)
    }

    var isVisible: Bool { panel.isVisible }

    /// 主屏顶部居中（可视区顶边距 6pt；多屏取含菜单栏主屏）。
    private func positionTopCenter() {
        guard let screen = NSScreen.main else { return }
        let width = LaunchBarLayout.barWidth(tileCount: LaunchBarMode.allCases.count)
        let screenFrame = screen.visibleFrame
        let origin = NSPoint(
            x: screenFrame.midX - width / 2,
            y: screenFrame.maxY - LaunchBarLayout.barHeight - 6)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: LaunchBarLayout.barHeight)), display: true)
    }

    private func installBar() {
        let bar = LaunchBarView(modeTapped: { [weak self] mode in
            guard let self else { return }
            self.close()
            self.onMode(mode)
        }, onClose: { [weak self] in self?.close() })
        panel.contentView = bar
        barView = bar
    }
}

/// 启动条面板（非激活无边框浮层，FloatingControlBar 同款纪律）：不抢焦点、任意空间
/// 可见、采集排除（永不入成片）。
final class LaunchBarPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: NSSize(
                width: LaunchBarLayout.barWidth(tileCount: LaunchBarMode.allCases.count),
                height: LaunchBarLayout.barHeight)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        // 恒深色 HUD（Omi 49.png 观感；hudWindow 跟随系统外观——浅色模式白底会吞掉
        // 白色标题/图标，2026-11-16 用户反馈，钉死 darkAqua）。
        appearance = NSAppearance(named: .darkAqua)
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        sharingType = .none // 采集排除（浮条/选择器同纪律）——启动条永不入成片
        hasShadow = true
    }
}

// MARK: - LaunchBarView（条体：毛玻璃底 + 7 瓦片 + 分隔 + 关闭钮）

/// 条体视图：hudWindow 毛玻璃（Omi 深色半透明观感）+ 等宽瓦片行（悬停高亮圆角底）+
/// 细分隔线 + 右上角 ×。全 AppKit 原生（mouseDown 直回调，无 SwiftUI 手势依赖）。
final class LaunchBarView: NSView {
    private let modeTapped: (LaunchBarMode) -> Void
    private let onClose: () -> Void
    private var tiles: [LaunchBarTile] = []

    init(modeTapped: @escaping (LaunchBarMode) -> Void, onClose: @escaping () -> Void) {
        self.modeTapped = modeTapped
        self.onClose = onClose
        let total = LaunchBarLayout.barWidth(tileCount: LaunchBarMode.allCases.count)
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: total, height: LaunchBarLayout.barHeight)))
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        // 毛玻璃底（hudWindow = Omi 深色半透明观感；圆角由容器层裁切）。
        let effect = NSVisualEffectView(frame: bounds)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        addSubview(effect)

        // 瓦片行 + 瓦片间细分隔线（Omi 同款 1pt 竖线）。
        let modes = LaunchBarMode.allCases
        for (index, mode) in modes.enumerated() {
            let tile = LaunchBarTile(
                mode: mode,
                frame: NSRect(
                    x: LaunchBarLayout.tileX(index: index),
                    y: 0,
                    width: LaunchBarLayout.tileWidth,
                    height: LaunchBarLayout.barHeight))
            tile.onTap = { [weak self] mode in self?.modeTapped(mode) }
            addSubview(tile)
            tiles.append(tile)
            if index > 0 {
                let divider = NSView(frame: NSRect(
                    x: LaunchBarLayout.tileX(index: index),
                    y: 12,
                    width: 1,
                    height: LaunchBarLayout.barHeight - 24))
                divider.wantsLayer = true
                divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
                divider.autoresizingMask = [.height]
                addSubview(divider)
            }
        }

        // 右上角关闭钮（Omi 同款灰色 ×，条外缘内收 10pt）。
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)!,
                             target: self, action: #selector(closeClicked))
        close.bezelStyle = .regularSquare
        close.isBordered = false
        close.imageScaling = .scaleProportionallyDown
        close.contentTintColor = .secondaryLabelColor
        let closeSize: CGFloat = 18
        close.frame = NSRect(
            x: total - closeSize - 10,
            y: LaunchBarLayout.barHeight - closeSize - 10,
            width: closeSize, height: closeSize)
        close.autoresizingMask = [.minXMargin, .minYMargin]
        addSubview(close)
    }

    required init?(coder: NSCoder) { fatalError("LaunchBarView 仅代码装配") }

    @objc private func closeClicked() {
        onClose()
    }

    override func mouseDown(with event: NSEvent) {} // 条体空白处吞点击（不透传下层）
}

// MARK: - LaunchBarTile（瓦片：标题 + 图标 + 悬停高亮）

/// 单瓦片：白标题（13pt 中字重）+ 下方图标（SF 符号 / `.app` 自绘圆角方块）；
/// TrackingArea 悬停高亮（Omi 选中态圆角底 white 0.10），mouseDown 即点击。
final class LaunchBarTile: NSView {
    var onTap: ((LaunchBarMode) -> Void)?
    private let mode: LaunchBarMode
    private var hovered = false {
        didSet { needsDisplay = true }
    }

    init(mode: LaunchBarMode, frame: NSRect) {
        self.mode = mode
        super.init(frame: frame)
        wantsLayer = true
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("LaunchBarTile 仅代码装配") }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func mouseDown(with event: NSEvent) {
        onTap?(mode)
    }

    override func draw(_ dirtyRect: NSRect) {
        // 悬停高亮（Omi 选中态：圆角 8 灰底内衬）。
        if hovered {
            NSColor.white.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 4), xRadius: 8, yRadius: 8).fill()
        }
        // 标题（上）。
        let title = NSLocalizedString(mode.titleKey, comment: "Launch bar mode")
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let titleSize = (title as NSString).size(withAttributes: titleAttributes)
        (title as NSString).draw(
            at: NSPoint(x: (bounds.width - titleSize.width) / 2, y: bounds.height - titleSize.height - 12),
            withAttributes: titleAttributes)
        // 图标（下）：SF 符号 or 自绘「APP」方块（Omi 同款）。
        let iconRect = NSRect(
            x: bounds.midX - 22, y: 14, width: 44, height: 30)
        if let symbolName = mode.symbolName,
           let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .regular)) {
            let tinted = NSImage(size: symbol.size, flipped: false) { rect in
                symbol.draw(in: rect)
                NSColor.white.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            let drawRect = NSRect(
                x: iconRect.midX - tinted.size.width / 2,
                y: iconRect.midY - tinted.size.height / 2,
                width: tinted.size.width, height: tinted.size.height)
            tinted.draw(in: drawRect)
        } else if mode == .app {
            // 自绘「APP」圆角方块（Omi 同款：白描边圆角 + 白字）。
            let box = NSRect(x: iconRect.midX - 16, y: iconRect.minY, width: 32, height: 26)
            let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
            NSColor.white.withAlphaComponent(0.9).setStroke()
            path.lineWidth = 1.5
            path.stroke()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let text = "APP" as NSString
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: box.midX - textSize.width / 2, y: box.midY - textSize.height / 2),
                      withAttributes: attributes)
        }
    }
}
