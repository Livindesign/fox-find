import AppKit

struct SearchAction {
    var id: String, title: String, detail: String = "", symbol: String = "arrow.turn.down.right"
    enum Group { case view, use, more, destructive, search }
    var group: Group = .view
    var enabled = true
    var shortcut = ""
    var keyEquivalent = ""
    var modifiers: NSEvent.ModifierFlags = .command
    var checked = false
    var run: () -> Void
}

/// Menu and palette retain the same action snapshot, including its target identity.
final class SearchMenuAction: NSObject {
    let value: SearchAction
    init(_ value: SearchAction) { self.value = value }
    @objc func invoke(_ sender: Any?) { if value.enabled { value.run() } }
}

extension SearchAction {
    func menuItem() -> NSMenuItem {
        let target = SearchMenuAction(self)
        let item = NSMenuItem(title: title, action: #selector(SearchMenuAction.invoke(_:)), keyEquivalent: keyEquivalent)
        item.target = target; item.representedObject = target; item.identifier = .init(id)
        item.isEnabled = enabled; item.keyEquivalentModifierMask = modifiers
        item.state = checked ? .on : .off; item.toolTip = detail.isEmpty ? nil : detail
        item.image = Theme.symbol(symbol, size: 14, weight: .regular)
        return item
    }
}

final class SearchActionCell: NSTableCellView {
    private let icon = NSImageView()
    let nameLabel = Theme.label(13, .medium, .labelColor)
    let detailLabel = Theme.label(11, .regular, .secondaryLabelColor)
    let shortcutLabel = Theme.label(11, .regular, .secondaryLabelColor)
    override init(frame: NSRect) {
        super.init(frame: frame)
        shortcutLabel.alignment = .right; detailLabel.lineBreakMode = .byTruncatingMiddle
        [icon, nameLabel, detailLabel, shortcutLabel].forEach(addSubview); textField = nameLabel
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ action: SearchAction, startsGroup: Bool) {
        nameLabel.stringValue = action.title; nameLabel.textColor = action.enabled ? .labelColor : .disabledControlTextColor
        detailLabel.stringValue = action.detail; shortcutLabel.stringValue = action.shortcut
        icon.image = Theme.symbol(action.symbol, size: 15, weight: .regular); icon.contentTintColor = action.enabled ? .secondaryLabelColor : .disabledControlTextColor
        setAccessibilityLabel(action.title + " " + action.detail + " " + action.shortcut); needsLayout = true
    }
    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 12, y: (bounds.height - 16) / 2, width: 16, height: 16)
        let textWidth = max(0, bounds.width - 104)
        nameLabel.frame = NSRect(x: 38, y: detailLabel.stringValue.isEmpty ? (bounds.height - 18) / 2 : 20, width: textWidth, height: 18)
        detailLabel.frame = NSRect(x: 38, y: 4, width: textWidth, height: 15)
        shortcutLabel.frame = NSRect(x: max(38, bounds.width - 62), y: (bounds.height - 18) / 2, width: 52, height: 18)
    }
}

private final class SearchActionRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        Theme.accent.withAlphaComponent(Theme.dark(self) ? 0.16 : 0.18).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 2), xRadius: 8, yRadius: 8).fill()
    }
}

/// Mouse and keyboard share one highlighted row, just like a native menu.
/// Only the old/new row is invalidated; pointer movement never reloads data.
final class SearchActionTable: NSTableView {
    var canHighlight: ((Int) -> Bool)?
    private var tracking: NSTrackingArea?
    private var boundsObserver: NSObjectProtocol?
    private var pointerInside = false
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
        super.updateTrackingAreas()
    }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        boundsObserver = nil
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                guard let self, self.pointerInside, let window = self.window else { return }
                self.highlight(at: self.convert(window.mouseLocationOutsideOfEventStream, from: nil))
            }
        }
    }
    func highlight(at point: NSPoint) {
        let index = row(at: point)
        guard visibleRect.contains(point), index >= 0, index != selectedRow, canHighlight?(index) == true else { return }
        selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) {
        pointerInside = true; highlight(at: convert(event.locationInWindow, from: nil))
    }
    override func mouseExited(with event: NSEvent) { pointerInside = false }
    func resumeKeyboardNavigation() { pointerInside = false }
    deinit { if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) } }
}

/// Actions stay inside the owning panel; keyboard handling is never global.
final class SearchActionPalette: FlippedView, NSTableViewDataSource, NSTableViewDelegate {
    let table = SearchActionTable()
    let scroll = ResultScrollView()
    private let surface = PanelSurface(snapshot: false)
    private let title = Theme.label(13, .medium, .labelColor)
    private let hint = Theme.label(11, .regular, .secondaryLabelColor)
    private(set) var actions: [SearchAction] = []
    var onClose: (() -> Void)?
    var onVisibilityChange: (() -> Void)?
    override var isHidden: Bool { didSet { if isHidden != oldValue { onVisibilityChange?() } } }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        clipsToBounds = false; layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowRadius = 18; layer?.shadowOffset = CGSize(width: 0, height: 6)
        surface.layer?.borderWidth = 0.5
        addSubview(surface); updateElevation()
        table.headerView = nil; table.rowHeight = 42; table.intercellSpacing = .zero; table.selectionHighlightStyle = .regular
        table.backgroundColor = .clear; table.style = .plain
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle; table.focusRingType = .none
        table.addTableColumn(NSTableColumn(identifier: .init("action"))); table.dataSource = self; table.delegate = self
        table.target = self; table.action = #selector(activateClickedRow)
        table.canHighlight = { [weak self] row in self?.actions.indices.contains(row) == true && self?.actions[row].enabled == true }
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        [title, scroll, hint].forEach(addSubview); isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show(_ actions: [SearchAction], title: String) {
        table.resumeKeyboardNavigation()
        self.actions = actions; self.title.stringValue = title; self.title.toolTip = title
        hint.stringValue = L10n.text("workspace.actionHint")
        isHidden = false; table.reloadData(); needsLayout = true
        if let row = actions.firstIndex(where: { $0.enabled }) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row) }
        else { table.deselectAll(nil) }
        window?.makeFirstResponder(self)
    }
    override var acceptsFirstResponder: Bool { true }
    func numberOfRows(in tableView: NSTableView) -> Int { actions.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard actions.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("action")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? SearchActionCell) ?? SearchActionCell(frame: .zero)
        cell.identifier = identifier
        cell.configure(actions[row], startsGroup: row > 0 && actions[row - 1].group != actions[row].group)
        return cell
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SearchActionRow() }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { actions.indices.contains(row) && actions[row].enabled }

    func handleKey(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 53 { onClose?(); return }
        if flags.isEmpty {
            switch event.keyCode {
            case 125: move(1)
            case 126: move(-1)
            case 36, 76: activate()
            default: break
            }
        } else if let action = actions.first(where: { !$0.keyEquivalent.isEmpty && $0.keyEquivalent.lowercased() == event.charactersIgnoringModifiers?.lowercased() && $0.modifiers.intersection([.command, .control, .option, .shift]) == flags }), action.enabled {
            onClose?(); action.run()
        }
    }
    override func keyDown(with event: NSEvent) { handleKey(event) }
    func move(_ delta: Int) {
        guard !actions.isEmpty, delta != 0 else { return }
        table.resumeKeyboardNavigation()
        var row = table.selectedRow + delta
        while actions.indices.contains(row), !actions[row].enabled { row += delta }
        guard actions.indices.contains(row) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row)
    }
    @objc private func activateClickedRow() { activate(row: table.clickedRow) }
    func activate() { activate(row: table.selectedRow) }
    func activate(row: Int) {
        guard actions.indices.contains(row) else { return }
        let action = actions[row]; guard action.enabled else { return }; onClose?(); action.run()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateElevation() }
    private func updateElevation() {
        let dark = Theme.dark(self)
        layer?.shadowOpacity = dark ? 0.42 : 0.20
        surface.layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.12)).cgColor
    }
    override func layout() {
        super.layout()
        surface.frame = bounds
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Theme.corner, cornerHeight: Theme.corner, transform: nil)
        title.frame = NSRect(x: 18, y: 14, width: bounds.width - 36, height: 18)
        scroll.frame = NSRect(x: 8, y: 44, width: bounds.width - 16, height: max(0, bounds.height - 82))
        table.tableColumns.first?.width = scroll.contentSize.width
        hint.frame = NSRect(x: 18, y: bounds.height - 28, width: bounds.width - 36, height: 16)
    }
}
