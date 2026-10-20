import AppKit

struct ActiveSearchCondition: Equatable {
    var id: String
    var title: String
    var help: String? = nil
}

/// A compact context strip appears only when there is something to remove or navigate.
final class SearchContextBar: FlippedView, NSMenuDelegate {
    let back = ToolbarButton(symbol: "chevron.left"), forward = ToolbarButton(symbol: "chevron.right")
    let up = ToolbarButton(symbol: "arrow.up"), edit = ToolbarButton(), depth = ToolbarButton()
    let label = Theme.label(11.5, .regular, .secondaryLabelColor)
    let reference = NSImageView()
    let exitSimilarity = ToolbarButton(symbol: "xmark")
    private let scroll = NSScrollView(), chips = FlippedView()
    let overflow = ToolbarButton()
    var onMenuTracking: ((Bool) -> Void)?
    private var overflowStart = 0
    private let icons = IconProvider()
    private var referencePath: String?
    private(set) var conditions: [ActiveSearchCondition] = []
    private(set) var chipButtons: [ToolbarButton] = []
    var onRemove: ((String) -> Void)?
    var browsing = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        [back, forward, up].forEach { $0.iconOnly = true }
        scroll.drawsBackground = false; scroll.hasHorizontalScroller = false; scroll.hasVerticalScroller = false
        scroll.documentView = chips
        reference.imageScaling = .scaleProportionallyUpOrDown; reference.isHidden = true; exitSimilarity.isHidden = true
        [back, forward, up, label, edit, depth, scroll, reference, exitSimilarity, overflow].forEach(addSubview)
        overflow.showsChevron = true; overflow.isHidden = true
        overflow.onPress = { [weak self] in
            guard let self else { return }
            let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
            for condition in self.conditions.dropFirst(self.overflowStart) {
                menu.addItem(SearchAction(id: condition.id, title: L10n.text("tools.removeCondition", condition.title), symbol: "xmark") { [weak self] in self?.onRemove?(condition.id) }.menuItem())
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 30), in: self.overflow)
        }
        label.lineBreakMode = .byTruncatingMiddle; isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(text: String?, browsing: Bool, canBack: Bool, canForward: Bool, recursive: Bool,
                conditions: [ActiveSearchCondition] = [], similarity: String? = nil) {
        self.browsing = browsing
        let similar = similarity != nil
        isHidden = text == nil && !canBack && !canForward && conditions.isEmpty && !similar
        label.stringValue = similarity.map { L10n.text("semantic.referenceLabel", URL(fileURLWithPath: $0).lastPathComponent) } ?? text ?? ""
        label.toolTip = similarity ?? text; label.isHidden = !similar && !browsing
        back.isEnabled = canBack; forward.isEnabled = canForward
        back.title = L10n.text("workspace.back"); forward.title = L10n.text("workspace.forward"); up.title = L10n.text("workspace.up")
        [back, forward, up].forEach { $0.toolTip = $0.title; $0.setAccessibilityLabel($0.title) }
        back.isHidden = similar || (!browsing && !canBack && !canForward); forward.isHidden = back.isHidden; up.isHidden = !browsing || similar
        edit.title = L10n.text("tools.clearConditions"); edit.isHidden = conditions.isEmpty || similar || browsing
        depth.title = L10n.text(recursive ? "workspace.recursive" : "workspace.direct"); depth.isHidden = !browsing || similar
        scroll.isHidden = similar || browsing || conditions.isEmpty
        if self.conditions != conditions {
            self.conditions = conditions; chipButtons.forEach { $0.removeFromSuperview() }
            chipButtons = conditions.map { condition in
                let button = ToolbarButton(); button.title = condition.title + "  ×"; button.active = true
                button.toolTip = L10n.text("tools.removeCondition", condition.title) + (condition.help.map { "\n" + $0 } ?? "")
                button.setAccessibilityLabel(button.toolTip!)
                button.onPress = { [weak self] in self?.onRemove?(condition.id) }; chips.addSubview(button); return button
            }
        }
        exitSimilarity.title = L10n.text("semantic.exit"); exitSimilarity.isHidden = !similar
        exitSimilarity.setAccessibilityLabel(exitSimilarity.title); reference.isHidden = !similar
        if referencePath != similarity {
            referencePath = similarity; reference.image = Theme.symbol("photo", size: 22, weight: .regular)
            if let path = similarity {
                icons.thumbnail(path: path, modified: Date(timeIntervalSince1970: 0)) { [weak self] image in
                    guard self?.referencePath == path else { return }; self?.reference.image = image
                }
            }
        }
        needsLayout = true
    }
    func menuWillOpen(_ menu: NSMenu) { MenuIcons.decorate(menu); onMenuTracking?(true) }
    func menuDidClose(_ menu: NSMenu) { onMenuTracking?(false) }
    override func layout() {
        super.layout()
        var x: CGFloat = 18
        for button in [back, forward, up] where !button.isHidden { button.frame = NSRect(x: x, y: 1, width: 30, height: 30); x += 30 }
        let button = !exitSimilarity.isHidden ? exitSimilarity : browsing ? depth : edit
        let width = min(210, Theme.textWidth(button.title, font: button.font!) + (button.symbolName == nil ? 22 : 44))
        button.frame = NSRect(x: bounds.width - 18 - width, y: 1, width: width, height: 30)
        if !reference.isHidden { reference.frame = NSRect(x: x, y: 3, width: 26, height: 26); x += 34 }
        let available = max(0, (button.isHidden ? bounds.width - 18 : button.frame.minX - 12) - x)
        label.frame = NSRect(x: x + 4, y: 8, width: max(0, available - 4), height: 17)
        scroll.frame = NSRect(x: x, y: 0, width: available, height: 32)
        var chipX: CGFloat = 0
        let widths = chipButtons.map { min(220, Theme.textWidth($0.title, font: $0.font!) + 20) }
        let needsOverflow = widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * 6 > available
        let limit = max(0, available - (needsOverflow ? 64 : 0))
        overflowStart = chipButtons.count
        for (index, chip) in chipButtons.enumerated() {
            let chipWidth = widths[index]
            chip.isHidden = chipX + chipWidth > limit
            if chip.isHidden { overflowStart = min(overflowStart, index); continue }
            chip.frame = NSRect(x: chipX, y: 1, width: chipWidth, height: 30); chipX += chipWidth + 6
        }
        // Once one condition overflows, every subsequent condition goes into the same menu.
        for index in overflowStart..<chipButtons.count { chipButtons[index].isHidden = true }
        overflow.isHidden = scroll.isHidden || !needsOverflow
        overflow.title = "+\(chipButtons.count - overflowStart)"; overflow.toolTip = L10n.text("tools.filters")
        overflow.setAccessibilityLabel(L10n.text("tools.filterCount", String(chipButtons.count - overflowStart)))
        overflow.frame = NSRect(x: x + limit + 4, y: 1, width: 60, height: 30)
        chips.frame = NSRect(x: 0, y: 0, width: available, height: 32)
    }
}

struct SearchNavigationState {
    var search: SavedSearch
    var browsing: Bool
    var recursive: Bool
    var selection: Int
    var scroll: NSPoint
    var refinement: AssetRefinement
}
