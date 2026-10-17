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

/// Actions stay inside the owning panel; keyboard handling is never global.
final class SearchActionPalette: FlippedView, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let find = NSSearchField()
    let table = NSTableView()
    let scroll = ResultScrollView()
    private let surface = PanelSurface(snapshot: false)
    private let fieldPlate = TintPlate(radius: 8) { _ in NSColor.labelColor.withAlphaComponent(0.045) }
    private let title = Theme.label(13, .medium, .labelColor)
    private let hint = Theme.label(11, .regular, .secondaryLabelColor)
    private(set) var actions: [SearchAction] = []
    private(set) var filtered: [SearchAction] = []
    private var searchTerms: [String] = []
    var onClose: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.cornerRadius = 18; layer?.masksToBounds = true
        addSubview(surface); addSubview(fieldPlate)
        find.delegate = self; find.sendsSearchStringImmediately = true
        find.isBordered = false; find.drawsBackground = false; find.focusRingType = .none; find.font = .systemFont(ofSize: 12)
        table.headerView = nil; table.rowHeight = 42; table.intercellSpacing = .zero; table.selectionHighlightStyle = .regular
        table.backgroundColor = .clear
        table.addTableColumn(NSTableColumn(identifier: .init("action"))); table.dataSource = self; table.delegate = self
        table.target = self; table.action = #selector(activate)
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        [title, find, scroll, hint].forEach(addSubview); isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show(_ actions: [SearchAction], title: String) {
        self.actions = actions; self.title.stringValue = title; self.title.toolTip = title
        searchTerms = actions.map { LauncherApplication.normalize($0.title + " " + $0.detail) }
        find.placeholderString = L10n.text("workspace.findAction")
        hint.stringValue = L10n.text("workspace.actionHint")
        find.stringValue = ""; isHidden = false; reload(); needsLayout = true
        window?.makeFirstResponder(find)
    }
    func controlTextDidChange(_ obj: Notification) { reload() }
    private func reload() {
        let q = LauncherApplication.normalize(find.stringValue)
        filtered = q.isEmpty ? actions : actions.enumerated().compactMap { searchTerms[$0.offset].contains(q) ? $0.element : nil }
        table.reloadData(); if !filtered.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        hint.stringValue = filtered.isEmpty ? L10n.text("workspace.noAction") : L10n.text("workspace.actionHint")
    }
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("action")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? SearchActionCell) ?? SearchActionCell(frame: .zero)
        cell.identifier = identifier
        cell.configure(filtered[row], startsGroup: row > 0 && filtered[row - 1].group != filtered[row].group)
        return cell
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SearchActionRow() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): activate(); return true
        case #selector(NSResponder.cancelOperation(_:)): onClose?(); return true
        default: return false
        }
    }
    func move(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        let row = max(0, min(filtered.count - 1, table.selectedRow + delta))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row)
    }
    @objc func activate() {
        guard filtered.indices.contains(table.selectedRow) else { return }
        let action = filtered[table.selectedRow]; guard action.enabled else { return }; onClose?(); action.run()
    }
    override func layout() {
        super.layout()
        surface.frame = bounds
        title.frame = NSRect(x: 18, y: 14, width: bounds.width - 36, height: 18)
        fieldPlate.frame = NSRect(x: 14, y: 42, width: bounds.width - 28, height: 30)
        find.frame = fieldPlate.frame.insetBy(dx: 7, dy: 3)
        scroll.frame = NSRect(x: 8, y: 80, width: bounds.width - 16, height: max(0, bounds.height - 118))
        table.tableColumns.first?.width = scroll.contentSize.width
        hint.frame = NSRect(x: 18, y: bounds.height - 28, width: bounds.width - 36, height: 16)
    }
}
