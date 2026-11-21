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
/// 非激活面板：不抢焦点，任意应用前台都能点；按住条体/瓦片可拖动整条（越过 3pt
/// 阈值才算拖动，松手不再触发瓦片点击）。
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
        // 外观随系统（2026-11-21 用户要求）：此前钉死 darkAqua 防止浅色模式白底吞掉
        // 白色标题/图标；标题/图标/悬停底/分隔线已全部改用语义色（OmiStyle 同源），
        // 毛玻璃 material（hudWindow）本身也随外观解析，故不再需要钉色。
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        // 拖动由条体/瓦片自管（button 式阈值判定，见 LaunchBarDragTracker）——
        // isMovableByWindowBackground 会被瓦片的 mouseDown 吞掉，且无法区分点击/拖动。
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        sharingType = .none // 采集排除（浮条/选择器同纪律）——启动条永不入成片
        hasShadow = true
    }
}

// MARK: - 拖动判定（条体/瓦片共用，纯值类型供无头钉测）

/// 启动条拖动：按下记鼠标与窗口原点，越过 3pt 阈值后按位移返回窗口新原点——阈值内
/// 视为点击（瓦片开录），越过阈值后 mouseUp 不再触发点击（与 NSButton 的点击/拖动
/// 语义对齐）。坐标系一律屏幕坐标（`NSEvent.mouseLocation` / `window.frame.origin`）。
struct LaunchBarDragTracker {
    static let threshold: CGFloat = 3
    private(set) var startMouse: CGPoint?
    private(set) var startOrigin: CGPoint?
    private(set) var moved = false

    /// 按下：记录起点（窗口原点缺失 → 本轮只判点击，不移动）。
    mutating func begin(mouse: CGPoint, windowOrigin: CGPoint?) {
        startMouse = mouse
        startOrigin = windowOrigin
        moved = false
    }

    /// 拖到 `mouse` 时窗口应处的原点；未越过阈值/无窗口原点 → nil。
    mutating func origin(forMouse mouse: CGPoint) -> CGPoint? {
        guard let startMouse, let startOrigin else { return nil }
        let dx = mouse.x - startMouse.x
        let dy = mouse.y - startMouse.y
        if !moved, hypot(dx, dy) >= Self.threshold { moved = true }
        guard moved else { return nil }
        return CGPoint(x: startOrigin.x + dx, y: startOrigin.y + dy)
    }

    /// 结束本轮，返回是否拖动过（true = 不应当作点击）；状态复位供下次按下。
    mutating func end() -> Bool {
        defer {
            startMouse = nil
            startOrigin = nil
            moved = false
        }
        return moved
    }
}

/// 毛玻璃底：不参与命中测试——空白处事件落到 LaunchBarView（整条可拖动），
/// 瓦片/关闭钮仍各自命中。
private final class LaunchBarBackgroundView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - LaunchBarView（条体：毛玻璃底 + 7 瓦片 + 分隔 + 关闭钮）

/// 条体视图：hudWindow 毛玻璃（随系统外观：深色=深色半透明、浅色=浅色半透明）+ 等宽
/// 瓦片行（悬停高亮圆角底）+ 细分隔线 + 右上角 ×。全 AppKit 原生（mouseDown 直回调，
/// 无 SwiftUI 手势依赖）。文字/图标/描边一律语义色，随系统深浅色自适应。条体空白处
/// 按住可拖动整条（瓦片各自同样支持，见 LaunchBarTile）。
final class LaunchBarView: NSView {
    private let modeTapped: (LaunchBarMode) -> Void
    private let onClose: () -> Void
    private var tiles: [LaunchBarTile] = []
    /// 瓦片间分隔线（层色是 CGColor，切外观时需重解析——`viewDidChangeEffectiveAppearance`）。
    private var dividers: [NSView] = []
    /// 条体空白处的拖动状态。
    private var dragTracker = LaunchBarDragTracker()

    init(modeTapped: @escaping (LaunchBarMode) -> Void, onClose: @escaping () -> Void) {
        self.modeTapped = modeTapped
        self.onClose = onClose
        let total = LaunchBarLayout.barWidth(tileCount: LaunchBarMode.allCases.count)
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: total, height: LaunchBarLayout.barHeight)))
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        // 毛玻璃底（hudWindow 随系统外观明暗；圆角由容器层裁切；命中测试放行给条体）。
        let effect = LaunchBarBackgroundView(frame: bounds)
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
                divider.autoresizingMask = [.height]
                addSubview(divider)
                dividers.append(divider)
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

        refreshDividerColors()
    }

    required init?(coder: NSCoder) { fatalError("LaunchBarView 仅代码装配") }

    /// 系统深浅色切换（含运行中切换）：CGColor 不随外观自动重解析，重设一次。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshDividerColors()
    }

    /// 分隔线取语义色（深色=白 12%、浅色=黑 12%）。
    private func refreshDividerColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = NSColor.labelColor.withAlphaComponent(0.12).cgColor
            for divider in dividers {
                divider.layer?.backgroundColor = color
            }
        }
    }

    @objc private func closeClicked() {
        onClose()
    }

    // 条体空白处：按住拖动整条（点击空白仍无动作，不透传下层）。

    override func mouseDown(with event: NSEvent) {
        dragTracker.begin(mouse: NSEvent.mouseLocation, windowOrigin: window?.frame.origin)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window,
              let origin = dragTracker.origin(forMouse: NSEvent.mouseLocation) else { return }
        window.setFrameOrigin(origin)
    }

    override func mouseUp(with event: NSEvent) {
        _ = dragTracker.end()
    }
}

// MARK: - LaunchBarTile（瓦片：标题 + 图标 + 悬停高亮）

/// 单瓦片：标题（13pt 中字重，语义色）+ 下方图标（SF 符号 / `.app` 自绘圆角方块）；
/// TrackingArea 悬停高亮（Omi 选中态圆角底 label 0.10）。按住拖动 = 移动整条，未越
/// 3pt 阈值松手 = 点击开录。
final class LaunchBarTile: NSView {
    var onTap: ((LaunchBarMode) -> Void)?
    private let mode: LaunchBarMode
    private var dragTracker = LaunchBarDragTracker()
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
        dragTracker.begin(mouse: NSEvent.mouseLocation, windowOrigin: window?.frame.origin)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window,
              let origin = dragTracker.origin(forMouse: NSEvent.mouseLocation) else { return }
        window.setFrameOrigin(origin)
    }

    override func mouseUp(with event: NSEvent) {
        // 拖动后松手不触发开录（与按钮点击/拖动语义一致）。
        if !dragTracker.end() {
            onTap?(mode)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // 悬停高亮（Omi 选中态：圆角 8 灰底内衬；深色=白 10%、浅色=黑 10%）。
        if hovered {
            NSColor.labelColor.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 4), xRadius: 8, yRadius: 8).fill()
        }
        // 标题（上）。
        let title = NSLocalizedString(mode.titleKey, comment: "Launch bar mode")
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor,
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
                NSColor.labelColor.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            let drawRect = NSRect(
                x: iconRect.midX - tinted.size.width / 2,
                y: iconRect.midY - tinted.size.height / 2,
                width: tinted.size.width, height: tinted.size.height)
            tinted.draw(in: drawRect)
        } else if mode == .app {
            // 自绘「APP」圆角方块（Omi 同款：描边圆角 + 文字，语义色随系统明暗）。
            let box = NSRect(x: iconRect.midX - 16, y: iconRect.minY, width: 32, height: 26)
            let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
            NSColor.labelColor.withAlphaComponent(0.9).setStroke()
            path.lineWidth = 1.5
            path.stroke()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ]
            let text = "APP" as NSString
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: box.midX - textSize.width / 2, y: box.midY - textSize.height / 2),
                      withAttributes: attributes)
        }
    }
}
