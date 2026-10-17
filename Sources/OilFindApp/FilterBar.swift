import AppKit
import OilFindCore

final class FilterBar: FlippedView, NSMenuDelegate {
    static let names = ["all", "folder", "app", "document", "image", "video", "audio", "code", "archive"]
    private var buttons: [ChromeButton] = []
    private var buttonWidths: [CGFloat] = []
    private let capsule = TintPlate(radius: 10) { view in
        Theme.accent.withAlphaComponent(Theme.dark(view) ? 0.16 : 0.18)
    }
    private var laidOut = false
    let sortButton = ChromeButton("", style: .plain, size: 13, weight: .medium)
    var onChange: (() -> Void)?
    var onKindChange: (() -> Void)?
    var interpretedKind: UInt8? { didSet { if oldValue != interpretedKind { refresh() } } }
    var onMenuTracking: ((Bool) -> Void)?
    var onSortChange: (() -> Void)?
    var options = SearchOptions() { didSet { refresh() } }
    var isEnabled = true {
        didSet { alphaValue = isEnabled ? 1 : 0.4; (buttons + [sortButton]).forEach { $0.isEnabled = isEnabled } }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(capsule)
        for (i, name) in Self.names.enumerated() {
            let button = ChromeButton(L10n.text("filter." + name), style: .filter, size: 13.5, weight: .medium)
            button.onPress = { [weak self] in self?.select(i) }
            buttons.append(button); buttonWidths.append(Theme.textWidth(button.title, font: button.font!) + 22); addSubview(button)
        }
        sortButton.trailingSymbol = Theme.symbol("arrow.up.arrow.down", size: 10, weight: .medium)
        sortButton.onPress = { [weak self] in self?.showSortMenu() }
        addSubview(sortButton); refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    static func sortName(_ key: SortKey) -> String {
        switch key { case .relevance: return "relevance"; case .name: return "name"; case .modified: return "modified"; case .size: return "size" }
    }
    func localize() {
        for (i, button) in buttons.enumerated() {
            button.title = L10n.text("filter." + Self.names[i])
            button.refreshColors()
            buttonWidths[i] = Theme.textWidth(button.title, font: button.font!) + 22
        }
        capsule.needsDisplay = true; refresh(); needsLayout = true
    }
    private func refresh() {
        for (i, button) in buttons.enumerated() { button.active = i == Int(options.kind ?? interpretedKind ?? 0) }
        let sortTitle = L10n.text("sort.label", L10n.text("sort." + Self.sortName(options.sort)))
        sortButton.toolTip = L10n.text("sort.help")
        sortButton.setAccessibilityLabel(sortTitle)
        sortButton.trailingSymbol = Theme.symbol(options.sort == .relevance ? "arrow.up.arrow.down" : options.ascending ? "arrow.up" : "arrow.down", size: 10, weight: .medium)
        let changedSort = sortButton.title != sortTitle
        sortButton.title = sortTitle; sortButton.needsDisplay = true
        if laidOut { moveCapsule(animated: window?.isVisible == true) }
        if changedSort || sortButton.frame.isEmpty { needsLayout = true }
    }
    override func layout() {
        super.layout()
        let width = Theme.textWidth(sortButton.title, font: sortButton.font!) + 20
        let textWidths = buttons.map { Theme.textWidth($0.title, font: $0.font!) }
        let available = bounds.width - 36 - width - 12
        let roomy = textWidths.reduce(0, +) + CGFloat(buttons.count) * 26 <= available
        let gap: CGFloat = roomy ? 4 : 0
        let padding = min(22, max(8, (available - textWidths.reduce(0, +)) / CGFloat(buttons.count) - gap))
        var x: CGFloat = 18
        for (i, button) in buttons.enumerated() {
            let itemWidth = max(32, textWidths[i] + padding)
            button.frame = NSRect(x: x, y: 7, width: itemWidth, height: 34); x += itemWidth + gap
        }
        sortButton.frame = NSRect(x: bounds.width - 18 - width, y: 7, width: width, height: 34)
        laidOut = true; moveCapsule(animated: false)
    }
    private func moveCapsule(animated: Bool) {
        Theme.Motion.frame(capsule, to: buttons[Int(options.kind ?? interpretedKind ?? 0)].frame, using: animated && !Theme.Motion.reduced ? Theme.Motion.chip : nil)
    }
    func select(_ index: Int) {
        guard !isHidden, isEnabled else { return }
        options.kind = index == 0 ? nil : UInt8(index)
        onKindChange?(); onChange?()
    }
    func cycle(_ delta: Int) { select((Int(options.kind ?? interpretedKind ?? 0) + delta + 9) % 9) }
    private func showSortMenu() {
        guard isEnabled else { return }
        let menu = NSMenu(); menu.delegate = self
        for (i, key) in [SortKey.relevance, .name, .modified, .size].enumerated() {
            let item = NSMenuItem(title: L10n.text("sort." + Self.sortName(key)), action: #selector(sortSelected(_:)), keyEquivalent: "")
            item.tag = i; item.target = self; item.state = options.sort == key ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: sortButton.frame.minX, y: sortButton.frame.maxY), in: self)
    }
    @objc private func sortSelected(_ item: NSMenuItem) {
        let key = [SortKey.relevance, .name, .modified, .size][item.tag]
        options.ascending = options.sort == key && key != .relevance ? !options.ascending : key == .name
        options.sort = key; onSortChange?(); onChange?()
    }
    func menuWillOpen(_ menu: NSMenu) { onMenuTracking?(true) }
    func menuDidClose(_ menu: NSMenu) { onMenuTracking?(false) }
}
