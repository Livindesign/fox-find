import AppKit

enum QuickResult: Equatable {
    case application(LauncherApplication), calculation(Calculation), shortcut(SearchShortcut, URL)
    var targetKey: String {
        switch self {
        case .application(let app): return "app:" + app.path
        case .shortcut(let shortcut, _): return "shortcut:" + shortcut.id
        case .calculation: return ""
        }
    }
    var title: String {
        switch self {
        case .application(let app): return app.name
        case .shortcut(let shortcut, _): return shortcut.name
        case .calculation(let calculation): return calculation.errorKey.map { L10n.text($0) } ?? calculation.output
        }
    }
    var detail: String {
        switch self {
        case .application(let app): return (app.path as NSString).abbreviatingWithTildeInPath
        case .shortcut(let shortcut, let url): return L10n.text(shortcut.origin == "bookmark" ? "workspace.bookmark" : "workspace.shortcut") + " · " + (url.isFileURL ? (url.path as NSString).abbreviatingWithTildeInPath : url.absoluteString)
        case .calculation(let calculation): return calculation.expression
        }
    }
}

private final class QuickResultButton: NSButton {
    var chosen = false { didSet { needsDisplay = true } }
    let icon = NSImageView(), name = Theme.label(15, .medium, .labelColor)
    let detail = Theme.label(11.5, .regular, .secondaryLabelColor)
    let actionHint = Theme.label(11.5, .regular, .secondaryLabelColor)
    var onPress: (() -> Void)?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame); isBordered = false; title = ""; focusRingType = .none
        target = self; action = #selector(pressed)
        [icon, name, detail, actionHint].forEach(addSubview)
        name.lineBreakMode = .byTruncatingTail; detail.lineBreakMode = .byTruncatingMiddle
        actionHint.alignment = .right
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func pressed() { onPress?() }
    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 14, y: (bounds.height - 34) / 2, width: 34, height: 34)
        let actionWidth = ceil(actionHint.cell?.cellSize.width ?? 0) + 4
        actionHint.frame = NSRect(x: bounds.width - actionWidth - 16, y: (bounds.height - 18) / 2, width: actionWidth, height: 18)
        name.frame = NSRect(x: 62, y: 9, width: max(0, actionHint.frame.minX - 78), height: 24)
        if (name.font?.pointSize ?? 0) > 20 { name.frame.origin.y = 2; name.frame.size.height = 32 }
        detail.frame = NSRect(x: 62, y: 34, width: max(0, bounds.width - 80), height: 17)
    }
    override func draw(_ dirtyRect: NSRect) {
        if chosen {
            Theme.accent.withAlphaComponent(Theme.dark(self) ? 0.16 : 0.12).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10).fill()
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
}

/// At most three immediate results; no list reloads or synchronous icon reads.
final class QuickResultsView: FlippedView {
    private let heading = Theme.label(11, .medium, .secondaryLabelColor)
    private let line = SeparatorView()
    private var rows: [QuickResultButton] = []
    private let icons = IconProvider()
    private(set) var items: [QuickResult] = []
    var selectedIndex: Int? { didSet { for (i, row) in rows.enumerated() { row.chosen = selectedIndex == i } } }
    var onSelect: ((Int) -> Void)?
    var onActivate: (() -> Void)?
    var desiredHeight: CGFloat { items.isEmpty ? 0 : 34 + CGFloat(items.count) * 60 + 8 }
    override init(frame: NSRect) { super.init(frame: frame); addSubview(heading); addSubview(line); isHidden = true }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show(_ items: [QuickResult], selection: Int?) {
        if self.items != items {
            self.items = items; rows.forEach { $0.removeFromSuperview() }; rows = []
            for (i, item) in items.enumerated() {
                let row = QuickResultButton(frame: .zero)
                row.name.stringValue = item.title; row.detail.stringValue = item.detail
                row.toolTip = item.detail; row.setAccessibilityLabel(item.title + ", " + item.detail)
                switch item {
                case .application(let app):
                    row.actionHint.stringValue = "↩  " + L10n.text("quick.launch")
                    row.icon.image = icons.icon(name: app.name, path: app.path, flags: 1, kind: 2) { [weak row] image in row?.icon.image = image }
                case .shortcut(_, let url):
                    row.actionHint.stringValue = "↩  " + L10n.text("workspace.openLink")
                    row.icon.image = Theme.symbol(url.isFileURL ? "folder" : "link", size: 24, weight: .regular)
                case .calculation(let calculation):
                    row.name.font = .systemFont(ofSize: calculation.value == nil ? 16 : 24, weight: .medium)
                    row.icon.image = Theme.symbol("equal", size: 24, weight: .medium)
                    row.actionHint.stringValue = calculation.value == nil ? "" : "↩  " + L10n.text("quick.copy")
                    row.name.textColor = calculation.value == nil ? .systemOrange : .labelColor
                }
                row.onPress = { [weak self] in self?.onSelect?(i); self?.onActivate?() }
                rows.append(row); addSubview(row)
            }
        }
        if case .calculation(let value) = items.first { heading.stringValue = L10n.text(value.unit.isEmpty ? "quick.calculator" : "quick.conversion") }
        else { heading.stringValue = L10n.text(items.contains { if case .shortcut = $0 { return true }; return false } ? "workspace.quickHeading" : "quick.apps") }
        selectedIndex = selection; isHidden = items.isEmpty; needsLayout = true
    }
    func localize() { let saved = items; items = []; show(saved, selection: selectedIndex) }
    override func layout() {
        super.layout()
        heading.frame = NSRect(x: 26, y: 9, width: max(0, bounds.width - 52), height: 16)
        for (i, row) in rows.enumerated() { row.frame = NSRect(x: 14, y: 32 + CGFloat(i) * 60, width: bounds.width - 28, height: 58) }
        line.frame = NSRect(x: 26, y: bounds.height - 1, width: max(0, bounds.width - 52), height: Theme.pixel(self))
    }
}
