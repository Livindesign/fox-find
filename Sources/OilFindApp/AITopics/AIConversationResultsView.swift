import AppKit

private final class ConversationRow: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override var isEmphasized: Bool { get { true } set {} }
    override func drawSelection(in dirtyRect: NSRect) {
        Theme.accent.withAlphaComponent(Theme.dark(self) ? 0.16 : 0.12).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 10, yRadius: 10).fill()
    }
}

private final class ConversationTable: NSTableView {
    var makeMenu: (() -> NSMenu?)?
    var pointerSelected: (() -> Void)?
    override var acceptsFirstResponder: Bool { false }
    override func mouseDown(with event: NSEvent) { super.mouseDown(with: event); pointerSelected?() }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); pointerSelected?()
        return makeMenu?()
    }
}

private final class ConversationCell: NSTableCellView {
    let icon = NSImageView(), title = Theme.label(14, .medium, .labelColor)
    let excerpt = Theme.label(12, .regular, .secondaryLabelColor)
    let source = Theme.label(11, .regular, .tertiaryLabelColor)
    let more = ToolbarButton(symbol: "ellipsis")
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        [icon, title, excerpt, source, more].forEach(addSubview); textField = title
        [title, excerpt, source].forEach { $0.lineBreakMode = .byTruncatingTail }
        more.iconOnly = true; more.title = L10n.local("对话操作", "Conversation actions")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 16, y: 21, width: 36, height: 36)
        let width = max(0, bounds.width - 120)
        title.frame = NSRect(x: 68, y: 9, width: width, height: 22)
        excerpt.frame = NSRect(x: 68, y: 32, width: width, height: 19)
        source.frame = NSRect(x: 68, y: 54, width: width, height: 17)
        more.frame = NSRect(x: bounds.width - 42, y: 24, width: 30, height: 30)
    }
}

/// A virtual list for non-file results. No disk reads or transcript decompression in cell layout.
final class AIConversationResultsView: FlippedView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = ConversationTable(), scroll = ResultScrollView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let settings = ChromeButton("", style: .plain, size: 13, weight: .medium)
    private let icons = AITopicIcons()
    private let dateFormatter = DateFormatter()
    private(set) var topics: [AITopic] = []
    var onOpen: (() -> Void)?, onActions: (() -> Void)?, onSelect: (() -> Void)?, onSettings: (() -> Void)?
    var makeMenu: (() -> NSMenu?)?
    var selected: AITopic? { topics.indices.contains(table.selectedRow) ? topics[table.selectedRow] : nil }
    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true; scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        table.headerView = nil; table.backgroundColor = .clear; table.rowHeight = 80
        table.intercellSpacing = NSSize(width: 0, height: 4); table.usesAutomaticRowHeights = false
        table.style = .plain; table.focusRingType = .none; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.addTableColumn(NSTableColumn(identifier: .init("conversation")))
        table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(openRow)
        table.makeMenu = { [weak self] in self?.makeMenu?() }; table.pointerSelected = { [weak self] in self?.onSelect?() }
        scroll.documentView = table
        message.alignment = .center; message.font = .systemFont(ofSize: 14); message.textColor = .secondaryLabelColor
        settings.title = L10n.local("设置对话来源…", "Set up conversation sources…")
        settings.onPress = { [weak self] in self?.onSettings?() }
        [scroll, message, settings].forEach(addSubview)
        dateFormatter.dateStyle = .medium; dateFormatter.timeStyle = .none
        dateFormatter.locale = Locale(identifier: L10n.chinese ? "zh_CN" : "en_US")
        setMessage(L10n.local("输入关键词，找回聊过的内容", "Search for something you discussed"), setup: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func openRow() { onOpen?() }
    func setMessage(_ text: String, setup: Bool) {
        show([], preserveSelection: false); message.stringValue = text; message.isHidden = false; settings.isHidden = !setup
    }
    func show(_ topics: [AITopic], preserveSelection: Bool) {
        let key = preserveSelection ? selected?.key : nil
        let origin = scroll.contentView.bounds.origin
        if self.topics != topics { self.topics = topics; table.reloadData() }
        if !topics.isEmpty { select(key.flatMap { value in topics.firstIndex { $0.key == value } } ?? 0, scroll: !preserveSelection) }
        if preserveSelection { scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView) }
        scroll.isHidden = topics.isEmpty; message.isHidden = !topics.isEmpty; settings.isHidden = true
        message.stringValue = L10n.local("没有找到这段对话，试试其他关键词", "No matching conversations. Try other keywords.")
    }
    func select(_ index: Int, scroll reveal: Bool = true) {
        guard !topics.isEmpty else { return }
        let value = max(0, min(index, topics.count - 1))
        table.selectRowIndexes(IndexSet(integer: value), byExtendingSelection: false)
        if reveal { table.scrollRowToVisible(value) }
    }
    func move(_ delta: Int) { select(table.selectedRow + delta) }
    override func layout() {
        super.layout(); scroll.frame = bounds.insetBy(dx: 14, dy: 4)
        message.frame = NSRect(x: 36, y: max(20, bounds.height * 0.38), width: max(0, bounds.width - 72), height: 52)
        settings.frame = NSRect(x: (bounds.width - 280) / 2, y: message.frame.maxY + 16, width: 280, height: 36)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { topics.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(withIdentifier: .init("conversationRow"), owner: self) as? ConversationRow ?? ConversationRow(frame: .zero)
        view.identifier = .init("conversationRow"); return view
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard topics.indices.contains(row) else { return nil }
        let cell = tableView.makeView(withIdentifier: .init("topic"), owner: self) as? ConversationCell ?? ConversationCell(frame: .zero)
        cell.identifier = .init("topic")
        let topic = topics[row]
        cell.icon.image = icons.image(topic.provider); cell.title.stringValue = topic.title.isEmpty ? L10n.text("topicsUntitled") : topic.title
        cell.excerpt.stringValue = topic.excerpt.replacingOccurrences(of: "\n", with: " ")
        cell.source.stringValue = topic.provider.name + " · " + dateFormatter.string(from: Date(timeIntervalSince1970: topic.modified)) + (topic.project.isEmpty ? "" : " · " + URL(fileURLWithPath: topic.project).lastPathComponent)
        cell.more.onPress = { [weak self] in self?.select(row, scroll: false); self?.onSelect?(); self?.onActions?() }
        return cell
    }
}
