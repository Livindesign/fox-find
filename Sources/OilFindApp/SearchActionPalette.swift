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
    private let divider = SeparatorView()
    override init(frame: NSRect) {
        super.init(frame: frame)
        shortcutLabel.alignment = .right; detailLabel.lineBreakMode = .byTruncatingMiddle
        [icon, nameLabel, detailLabel, shortcutLabel, divider].forEach(addSubview); textField = nameLabel
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ action: SearchAction, startsGroup: Bool) {
        nameLabel.stringValue = action.title; nameLabel.textColor = action.enabled ? .labelColor : .disabledControlTextColor
        detailLabel.stringValue = action.detail; shortcutLabel.stringValue = action.shortcut
        icon.image = Theme.symbol(action.symbol, size: 15, weight: .regular); icon.contentTintColor = action.enabled ? .secondaryLabelColor : .disabledControlTextColor
        divider.isHidden = !startsGroup; setAccessibilityLabel(action.title + " " + action.detail + " " + action.shortcut); needsLayout = true
    }
    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 10, y: 15, width: 18, height: 18)
        nameLabel.frame = NSRect(x: 40, y: detailLabel.stringValue.isEmpty ? 14 : 24, width: max(0, bounds.width - 126), height: 18)
        detailLabel.frame = NSRect(x: 40, y: 6, width: max(0, bounds.width - 126), height: 16)
        shortcutLabel.frame = NSRect(x: max(40, bounds.width - 76), y: 15, width: 62, height: 18)
        divider.frame = NSRect(x: 40, y: bounds.height - 1, width: max(0, bounds.width - 54), height: Theme.pixel(self))
    }
}

/// Actions stay inside the owning panel; keyboard handling is never global.
final class SearchActionPalette: FlippedView, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let find = NSSearchField()
    let table = NSTableView()
    private let scroll = NSScrollView()
    private let title = Theme.label(13, .medium, .labelColor)
    private let hint = Theme.label(11, .regular, .secondaryLabelColor)
    private(set) var actions: [SearchAction] = []
    private(set) var filtered: [SearchAction] = []
    var onClose: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.cornerRadius = 12; layer?.borderWidth = 1
        find.delegate = self; find.sendsSearchStringImmediately = true
        table.headerView = nil; table.rowHeight = 48; table.intercellSpacing = .zero; table.selectionHighlightStyle = .regular
        table.addTableColumn(NSTableColumn(identifier: .init("action"))); table.dataSource = self; table.delegate = self
        table.target = self; table.action = #selector(activate)
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        [title, find, scroll, hint].forEach(addSubview); isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
    func show(_ actions: [SearchAction], title: String) {
        self.actions = actions; self.title.stringValue = title; self.title.toolTip = title
        find.placeholderString = L10n.text("workspace.findAction")
        hint.stringValue = L10n.text("workspace.actionHint")
        find.stringValue = ""; isHidden = false; reload(); needsLayout = true
        window?.makeFirstResponder(find)
    }
    func controlTextDidChange(_ obj: Notification) { reload() }
    private func reload() {
        let q = LauncherApplication.normalize(find.stringValue)
        filtered = actions.filter { q.isEmpty || LauncherApplication.normalize($0.title + " " + $0.detail).contains(q) }
        table.reloadData(); if !filtered.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        hint.stringValue = filtered.isEmpty ? L10n.text("workspace.noAction") : L10n.text("workspace.actionHint")
    }
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row) else { return nil }
        let cell = SearchActionCell(frame: .zero)
        cell.configure(filtered[row], startsGroup: row > 0 && filtered[row - 1].group != filtered[row].group)
        return cell
    }

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
        title.frame = NSRect(x: 18, y: 12, width: bounds.width - 36, height: 20)
        find.frame = NSRect(x: 16, y: 42, width: bounds.width - 32, height: 28)
        scroll.frame = NSRect(x: 8, y: 82, width: bounds.width - 16, height: max(0, bounds.height - 114))
        table.tableColumns.first?.width = scroll.contentSize.width
        hint.frame = NSRect(x: 18, y: bounds.height - 26, width: bounds.width - 36, height: 16)
    }
}
