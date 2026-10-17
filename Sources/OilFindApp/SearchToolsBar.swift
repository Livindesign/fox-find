import AppKit

extension L10n {
    static func local(_ zh: String, _ en: String) -> String { chinese ? zh : en }
}

// Quiet controls retain generous hit targets without permanent button blocks.
final class ToolbarButton: ChromeButton {
    enum Selection { case underline, tint }
    var selection: Selection = .tint
    var symbolName: String? { didSet { icon.image = symbolName.map { Theme.symbol($0, size: 14, weight: .medium) }; needsLayout = true } }
    var showsChevron = false { didSet { needsLayout = true } }
    var iconOnly = false { didSet { needsLayout = true; needsDisplay = true } }
    private let icon = NSImageView(), chevron = NSImageView()
    private(set) var textRect = NSRect.zero
    init(symbol: String? = nil, selection: Selection = .tint) {
        self.selection = selection
        super.init("", style: .plain, size: 12.5, weight: .medium)
        addSubview(icon); addSubview(chevron)
        symbolName = symbol; icon.image = symbol.map { Theme.symbol($0, size: 14, weight: .medium) }
        chevron.image = Theme.symbol("chevron.down", size: 8, weight: .semibold)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        icon.isHidden = symbolName == nil; chevron.isHidden = !showsChevron || iconOnly
        if iconOnly {
            icon.frame = NSRect(x: (bounds.width - 18) / 2, y: (bounds.height - 18) / 2, width: 18, height: 18)
            textRect = .zero
        } else {
            let prefix: CGFloat = symbolName == nil ? 0 : 22, suffix: CGFloat = showsChevron ? 14 : 0
            let available = max(0, bounds.width - 16 - prefix - suffix)
            let textWidth = min(available, Theme.textWidth(title, font: font!))
            let x = (bounds.width - textWidth - prefix - suffix) / 2
            icon.frame = NSRect(x: x, y: (bounds.height - 16) / 2, width: 16, height: 16)
            let height = (title as NSString).size(withAttributes: [.font: font!]).height
            textRect = NSRect(x: x + prefix, y: (bounds.height - height) / 2, width: textWidth, height: height + 1)
            chevron.frame = NSRect(x: textRect.maxX + 5, y: (bounds.height - 8) / 2, width: 8, height: 8)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        let selectedInk = Theme.accentText(self)
        let ink: NSColor = active ? selectedInk : (hovered ? .labelColor : .secondaryLabelColor)
        if active && selection == .tint || hovered || cell?.isHighlighted == true {
            (active ? selectedInk.withAlphaComponent(0.14) : NSColor.labelColor.withAlphaComponent(0.055)).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 7, yRadius: 7).fill()
        }
        if active && selection == .underline {
            selectedInk.setFill()
            NSBezierPath(roundedRect: NSRect(x: 12, y: bounds.height - 3, width: bounds.width - 24, height: 2), xRadius: 1, yRadius: 1).fill()
        }
        let color = ink.withAlphaComponent(isEnabled ? 1 : 0.4)
        icon.contentTintColor = color; chevron.contentTintColor = color
        if !iconOnly {
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingMiddle
            (title as NSString).draw(in: textRect, withAttributes: [.font: font!, .foregroundColor: color, .paragraphStyle: paragraph])
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
}

final class SearchToolsBar: FlippedView {
    let match = ToolbarButton(symbol: "text.magnifyingglass")
    var onMatch: (() -> Void)?
    let scope = ToolbarButton(symbol: "folder"), refine = ToolbarButton(symbol: "slider.horizontal.3")
    let more = ToolbarButton(symbol: "ellipsis")
    let list = ToolbarButton(symbol: "list.bullet"), grid = ToolbarButton(symbol: "square.grid.2x2")
    private let separator = SeparatorView()
    private let viewModePlate = TintPlate(radius: 8) { _ in NSColor.labelColor.withAlphaComponent(0.035) }
    var onMode: ((SearchMode) -> Void)?
    var onScope: (() -> Void)?, onRefine: (() -> Void)?, onMore: (() -> Void)?
    var mode: SearchMode = .combined { didSet { localize() } }
    var folder: String? { didSet { localize() } }
    var contextFolder: String? { didSet { if oldValue != contextFolder { localize() } } }
    var refinement = AssetRefinement() { didSet { localize() } }
    var gridMode = false { didSet { refreshColors() } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(match); addSubview(separator); addSubview(viewModePlate)
        match.showsChevron = true; match.onPress = { [weak self] in self?.onMatch?() }
        [scope, refine, list, grid, more].forEach(addSubview)
        scope.showsChevron = true; refine.showsChevron = true
        list.iconOnly = true; grid.iconOnly = true; more.iconOnly = true
        scope.onPress = { [weak self] in self?.onScope?() }; refine.onPress = { [weak self] in self?.onRefine?() }
        more.onPress = { [weak self] in self?.onMore?() }
        localize()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func refreshColors() {
        match.active = mode != .combined
        scope.active = contextFolder != nil || folder != nil; refine.active = refinement.active
        list.active = !gridMode; grid.active = gridMode
        list.state = gridMode ? .off : .on; grid.state = gridMode ? .on : .off
        ([match, scope, refine, list, grid, more]).forEach { $0.refreshColors(); $0.needsLayout = true }
        viewModePlate.needsDisplay = true
    }
    func localize() {
        let key = mode == .combined ? "combined" : mode == .names ? "names" : "contents"
        match.title = L10n.text("tools.method", L10n.text("tools." + key))
        match.toolTip = L10n.text("tools." + key + "Help")
        scope.title = (contextFolder ?? folder).map { URL(fileURLWithPath: $0).lastPathComponent } ?? L10n.text("project.all")
        scope.toolTip = contextFolder ?? folder ?? L10n.text("tools.locationHelp")
        let count = (refinement.media == .all ? 0 : 1) + (refinement.tag.isEmpty ? 0 : 1) + (refinement.minWidth == nil ? 0 : 1) + (refinement.minHeight == nil ? 0 : 1) + (refinement.captured == nil ? 0 : 1)
        refine.title = count == 0 ? L10n.text("tools.filters") : L10n.text("tools.filterCount", String(count))
        var conditions: [String] = []
        if refinement.media != .all { conditions.append(refinement.media.title) }
        if !refinement.tag.isEmpty { conditions.append(L10n.text("asset.tags") + ": " + refinement.tag) }
        if let width = refinement.minWidth { conditions.append(L10n.text("workspace.widthOver", String(width - 1))) }
        if let height = refinement.minHeight { conditions.append(L10n.text("workspace.heightOver", String(height - 1))) }
        if refinement.captured != nil { conditions.append(refinement.captureDescription) }
        refine.toolTip = conditions.isEmpty ? L10n.text("tools.filterHelp") : conditions.joined(separator: " · ")
        list.title = L10n.text("asset.list"); grid.title = L10n.text("asset.grid"); more.title = L10n.text("tools.more")
        for button in [list, grid] { button.toolTip = button.title }
        more.toolTip = L10n.text("tools.moreHelp")
        for button in [match, scope, refine, list, grid, more] { button.setAccessibilityLabel(button.title) }
        refreshColors()
    }
    override func layout() {
        super.layout()
        let matchWidth = min(220, Theme.textWidth(match.title, font: match.font!) + 54)
        match.frame = NSRect(x: 18, y: 4, width: matchWidth, height: 36)
        separator.frame = NSRect(x: match.frame.maxX + 10, y: 14, width: Theme.pixel(self), height: 16)
        let locationX = match.frame.maxX + 24
        more.frame = NSRect(x: bounds.width - 54, y: 4, width: 36, height: 36)
        grid.frame = NSRect(x: more.frame.minX - 12 - 36, y: 4, width: 36, height: 36)
        list.frame = grid.frame.offsetBy(dx: -36, dy: 0)
        viewModePlate.frame = list.frame.union(grid.frame).insetBy(dx: 0, dy: 2)
        scope.frame = NSRect(x: locationX, y: 4, width: min(176, max(80, list.frame.minX - locationX - 152)), height: 36)
        refine.frame = NSRect(x: scope.frame.maxX + 12, y: 4, width: 124, height: 36)
    }
}
