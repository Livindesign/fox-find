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
    let moreButton = ToolbarButton(symbol: "ellipsis")
    let previewButton = ToolbarButton(symbol: "sidebar.right")
    var onPreview: (() -> Void)?
    let sortButton = ChromeButton("", style: .plain, size: 13, weight: .medium)
    var onChange: (() -> Void)?
    var onKindChange: (() -> Void)?
    var interpretedKind: UInt8? { didSet { if oldValue != interpretedKind { refresh() } } }
    var onMenuTracking: ((Bool) -> Void)?
    var onSortChange: (() -> Void)?
    var options = SearchOptions() { didSet { refresh() } }
    var isEnabled = true {
        didSet { alphaValue = isEnabled ? 1 : 0.4; (buttons + [sortButton, moreButton, previewButton]).forEach { $0.isEnabled = isEnabled } }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(capsule)
        for (i, name) in Self.names.enumerated() {
            let button = ChromeButton(L10n.text("filter." + name), style: .filter, size: 13.5, weight: .medium)
            button.leadingSymbol = FunctionalIcons.image(["face-all", "face-folder", "face-applications", "face-document", "face-image", "face-video", "face-audio", "face-code", "face-archive"][i])
            button.onPress = { [weak self] in self?.select(i) }
            buttons.append(button); buttonWidths.append(Theme.textWidth(button.title, font: button.font!) + 22); addSubview(button)
        }
        sortButton.trailingSymbol = Theme.symbol("arrow.up.arrow.down", size: 10, weight: .medium)
        sortButton.onPress = { [weak self] in self?.showSortMenu() }
        addSubview(sortButton)
        moreButton.iconOnly = true; moreButton.title = L10n.local("更多类型", "More types")
        moreButton.setAccessibilityLabel(moreButton.title); moreButton.onPress = { [weak self] in self?.showTypesMenu() }
        previewButton.iconOnly = true; previewButton.title = L10n.local("显示或隐藏预览", "Show or hide preview")
        previewButton.toolTip = previewButton.title; previewButton.setAccessibilityLabel(previewButton.title)
        previewButton.onPress = { [weak self] in self?.onPreview?() }
        addSubview(moreButton); addSubview(previewButton); refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    static func sortName(_ key: SortKey) -> String {
        switch key { case .relevance: return "relevance"; case .name: return "name"; case .modified: return "modified"; case .size: return "size" }
    }
    func localize() {
        moreButton.title = L10n.local("更多类型", "More types"); moreButton.setAccessibilityLabel(moreButton.title)
        previewButton.title = L10n.local("显示或隐藏预览", "Show or hide preview")
        previewButton.toolTip = previewButton.title; previewButton.setAccessibilityLabel(previewButton.title)
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
        let sortWidth: CGFloat = sortButton.superview === self ? 120 : 0
        let available = bounds.width - 48 - sortWidth - 80
        var x: CGFloat = 22
        for (i, button) in buttons.enumerated() {
            let width = Theme.textWidth(button.title, font: button.font!) + 55
            button.isHidden = i >= 5 || x + width > available
            guard !button.isHidden else { continue }
            button.frame = NSRect(x: x, y: 6, width: width, height: 34); x += width + 3
        }
        moreButton.frame = NSRect(x: x + 2, y: 6, width: 34, height: 34)
        previewButton.frame = NSRect(x: bounds.width - 60 - sortWidth, y: 6, width: 34, height: 34)
        if sortButton.superview === self { sortButton.frame = NSRect(x: bounds.width - 138, y: 6, width: 116, height: 34) }
        laidOut = true; moveCapsule(animated: false)
    }
    private func moveCapsule(animated: Bool) {
        let selected = buttons[Int(options.kind ?? interpretedKind ?? 0)]
        moreButton.active = selected.isHidden
        Theme.Motion.frame(capsule, to: selected.isHidden ? moreButton.frame : selected.frame, using: animated && !Theme.Motion.reduced ? Theme.Motion.chip : nil)
    }
    func select(_ index: Int) {
        guard !isHidden, isEnabled else { return }
        options.kind = index == 0 ? nil : UInt8(index)
        onKindChange?(); onChange?()
    }
    func cycle(_ delta: Int) { select((Int(options.kind ?? interpretedKind ?? 0) + delta + 9) % 9) }
    func showSortMenu() {
        guard isEnabled else { return }
        let menu = NSMenu(); menu.delegate = self
        for (i, key) in [SortKey.relevance, .name, .modified, .size].enumerated() {
            let item = NSMenuItem(title: L10n.text("sort." + Self.sortName(key)), action: #selector(sortSelected(_:)), keyEquivalent: "")
            item.tag = i; item.target = self; item.state = options.sort == key ? .on : .off
            menu.addItem(item)
        }
        sortButton.hovered = true; defer { sortButton.hovered = false }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sortButton.bounds.height), in: sortButton)
    }
    private func showTypesMenu() {
        let menu = NSMenu(); menu.delegate = self
        for (index, name) in Self.names.enumerated() {
            let item = NSMenuItem(title: L10n.text("filter." + name), action: #selector(typeSelected(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; item.state = Int(options.kind ?? interpretedKind ?? 0) == index ? .on : .off
            item.image = buttons[index].leadingSymbol; menu.addItem(item)
        }
        moreButton.present(menu)
    }
    @objc private func typeSelected(_ item: NSMenuItem) { select(item.tag) }
    @objc private func sortSelected(_ item: NSMenuItem) {
        let key = [SortKey.relevance, .name, .modified, .size][item.tag]
        options.ascending = options.sort == key && key != .relevance ? !options.ascending : key == .name
        options.sort = key; onSortChange?(); onChange?()
    }
    func menuWillOpen(_ menu: NSMenu) { onMenuTracking?(true) }
    func menuDidClose(_ menu: NSMenu) { onMenuTracking?(false) }
}
