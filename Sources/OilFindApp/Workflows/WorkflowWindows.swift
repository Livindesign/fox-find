import AppKit
import UniformTypeIdentifiers

enum WorkflowTextKeys {
    /// Native Open/Save panels dispatch editing through the app menu, including
    /// their out-of-process path fields. Accessory apps otherwise have no Edit menu.
    static func installEditingMenu() {
        let menu = NSApp.mainMenu ?? NSMenu()
        guard !menu.items.contains(where: { $0.identifier?.rawValue == "workflow.edit" || $0.submenu?.items.contains(where: { $0.action == #selector(NSText.paste(_:)) }) == true }) else { return }
        if menu.items.isEmpty {
            let appItem = NSMenuItem(), appMenu = NSMenu()
            let quit = NSMenuItem(title: L10n.local("退出 Fox Find", "Quit Fox Find"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            appMenu.addItem(quit); MenuIcons.decorate(appMenu); appItem.submenu = appMenu; menu.addItem(appItem)
        }
        let item = NSMenuItem(title: L10n.local("编辑", "Edit"), action: nil, keyEquivalent: "")
        item.identifier = .init("workflow.edit")
        let edit = NSMenu(title: item.title)
        for (title, selector, key, modifiers) in [
            (L10n.local("撤销", "Undo"), Selector(("undo:")), "z", NSEvent.ModifierFlags.command),
            (L10n.local("重做", "Redo"), Selector(("redo:")), "z", [.command, .shift]),
            (L10n.local("剪切", "Cut"), #selector(NSText.cut(_:)), "x", .command),
            (L10n.local("拷贝", "Copy"), #selector(NSText.copy(_:)), "c", .command),
            (L10n.local("粘贴", "Paste"), #selector(NSText.paste(_:)), "v", .command),
            (L10n.local("全选", "Select All"), #selector(NSText.selectAll(_:)), "a", .command)
        ] {
            let command = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            command.keyEquivalentModifierMask = modifiers; edit.addItem(command)
        }
        MenuIcons.decorate(edit)
        item.submenu = edit; menu.addItem(item); NSApp.mainMenu = menu
    }
    static func handle(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard window.attachedSheet == nil, let editor = window.firstResponder as? NSTextView, !editor.hasMarkedText() else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if key == "z", editor.isEditable, modifiers == .command || modifiers == [.command, .shift] {
            if modifiers.contains(.shift) { editor.undoManager?.redo() } else { editor.undoManager?.undo() }
            return true
        }
        guard modifiers == .command else { return false }
        switch key {
        case "a" where editor.isSelectable: editor.selectAll(nil)
        case "c" where editor.isSelectable: editor.copy(nil)
        case "x" where editor.isEditable: editor.cut(nil)
        case "v" where editor.isEditable: editor.paste(nil)
        default: return false
        }
        return true
    }
}

private final class WorkflowPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) { close() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.window === self, isVisible, attachedSheet == nil else { return false }
        if WorkflowTextKeys.handle(event, in: self) { return true }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" { close(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

final class WorkflowLayout: FlippedView {
    var arrange: ((NSRect) -> Void)?
    override func layout() { super.layout(); arrange?(bounds) }
}

class WorkflowWindow: NSWindowController, NSWindowDelegate {
    let body = WorkflowLayout()
    let heading = Theme.label(13, .semibold, .labelColor)
    let status = Theme.label(11, .regular, .secondaryLabelColor)
    let pageTitle = Theme.label(23, .semibold, .labelColor)
    let subtitle = Theme.label(12, .regular, .secondaryLabelColor)
    let divider = TintPlate(radius: 0) { _ in Theme.Surface.divider }
    private static let operationQueue = DispatchQueue(label: "app.localfind.workflow", qos: .utility)
    var queue: DispatchQueue { Self.operationQueue }
    var cancellation = WorkflowCancellation()
    var onClose: (() -> Void)?
    init(title: String, width: CGFloat = 940, height: CGFloat = 720) {
        WorkflowTextKeys.installEditingMenu()
        let panel = WorkflowPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.delegate = self; panel.isReleasedWhenClosed = false; panel.title = title
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.minSize = NSSize(width: width, height: height); panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true; panel.hasShadow = true; panel.isOpaque = false
        panel.backgroundColor = NSColor(name: nil) { Theme.glassTint(dark: $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua) }
        let surface = PanelSurface(snapshot: false); panel.contentView = surface
        body.frame = surface.bounds; body.autoresizingMask = [.width, .height]; surface.addSubview(body)
        heading.stringValue = "Fox Find"; pageTitle.stringValue = title; status.lineBreakMode = .byTruncatingTail
        for view in [heading, pageTitle, subtitle, divider, status] { body.addSubview(view) }; panel.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func windowWillClose(_ notification: Notification) { cancellation.cancel(); onClose?() }
    func showStatus(_ value: String) { status.stringValue = value; status.toolTip = value }
    func present() { NSApp.activate(ignoringOtherApps: true); showWindow(nil); window?.makeKeyAndOrderFront(nil) }
    func arrangeChrome(_ r: NSRect) {
        heading.frame = NSRect(x: 84, y: 8, width: 200, height: 24)
        pageTitle.frame = NSRect(x: 26, y: 52, width: r.width - 52, height: 30)
        subtitle.frame = NSRect(x: 27, y: 87, width: r.width - 54, height: 18)
        divider.frame = NSRect(x: 24, y: r.height - 84, width: r.width - 48, height: 0.5)
        status.frame = NSRect(x: 26, y: r.height - 27, width: r.width - 52, height: 16)
    }
    static func textArea(editable: Bool) -> (ResultScrollView, NSTextView) {
        let scroll = ResultScrollView(), text = NSTextView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        text.isEditable = editable; text.isSelectable = true; text.isRichText = false
        text.allowsUndo = editable
        text.drawsBackground = false; text.textColor = .labelColor; text.font = .systemFont(ofSize: 12)
        text.selectedTextAttributes = [.backgroundColor: Theme.Control.textSelection, .foregroundColor: NSColor.white]
        text.insertionPointColor = NSColor(white: 0.9, alpha: 1)
        text.textContainerInset = NSSize(width: 12, height: 10)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = .width; text.textContainer?.widthTracksTextView = true
        text.layoutManager?.allowsNonContiguousLayout = true
        scroll.documentView = text; return (scroll, text)
    }
    static func button(_ title: String, symbol: String? = nil, primary: Bool = false, quiet: Bool = false) -> GlassButton {
        GlassButton(title, symbol: symbol, emphasis: primary ? .primary : quiet ? .quiet : .secondary)
    }
}

final class WorkflowList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let scroll = ResultScrollView(), table = NSTableView()
    var rows: [(String, String)] = [] { didSet { table.reloadData() } }
    var symbols: [String] = []
    var onSelect: ((Int) -> Void)?
    override init() {
        super.init()
        let column = NSTableColumn(identifier: .init("item")); column.resizingMask = .autoresizingMask; table.addTableColumn(column)
        table.headerView = nil; table.backgroundColor = .clear; table.rowHeight = 62
        table.intercellSpacing = .zero; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.delegate = self; table.dataSource = self; table.allowsEmptySelection = true
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.documentView = table
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { GlassListRow() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("workflow.row")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? NSTableCellView()
        if cell.textField == nil {
            cell.identifier = id
            let image = NSImageView(); image.imageScaling = .scaleProportionallyUpOrDown
            image.contentTintColor = Theme.Ink.icon; cell.imageView = image; cell.addSubview(image)
            let text = Theme.label(12, .medium, .labelColor); text.tag = 1; text.lineBreakMode = .byTruncatingMiddle
            let detail = Theme.label(10.5, .regular, .secondaryLabelColor); detail.tag = 2; detail.lineBreakMode = .byTruncatingMiddle
            cell.textField = text; cell.addSubview(text); cell.addSubview(detail)
            text.translatesAutoresizingMaskIntoConstraints = false; detail.translatesAutoresizingMaskIntoConstraints = false; image.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 16), image.centerYAnchor.constraint(equalTo: cell.centerYAnchor), image.widthAnchor.constraint(equalToConstant: 20), image.heightAnchor.constraint(equalToConstant: 22),
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 49), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -14),
                text.topAnchor.constraint(equalTo: cell.topAnchor, constant: 12), text.heightAnchor.constraint(equalToConstant: 18),
                detail.leadingAnchor.constraint(equalTo: text.leadingAnchor), detail.trailingAnchor.constraint(equalTo: text.trailingAnchor),
                detail.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 2), detail.heightAnchor.constraint(equalToConstant: 16)
            ])
        }
        cell.textField?.stringValue = rows[row].0; (cell.viewWithTag(2) as? NSTextField)?.stringValue = rows[row].1
        cell.imageView?.image = Theme.symbol(symbols.indices.contains(row) ? symbols[row] : "photo", size: 20, weight: .regular)
        cell.toolTip = rows[row].0 + "\n" + rows[row].1
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { onSelect?(table.selectedRow) }
}

final class WorkCollectionWindow: WorkflowWindow, NSTextFieldDelegate, NSTextViewDelegate {
    let store: WorkCollectionStore
    let list = WorkflowList()
    let titleField = NSTextField()
    let notesScroll: ResultScrollView, notes: NSTextView
    let previewScroll: ResultScrollView, preview: NSTextView
    let collectionCard = GlassSection(), notesCard = GlassSection(), previewCard = GlassSection()
    private let collectionTitle = Theme.label(13, .semibold, .labelColor)
    private let countLabel = Theme.label(10.5, .medium, .secondaryLabelColor)
    private let taskLabel = Theme.label(10.5, .medium, .secondaryLabelColor)
    private let previewTitle = Theme.label(13, .semibold, .labelColor)
    private let previewHint = Theme.label(10.5, .regular, .secondaryLabelColor)
    private let emptyLabel = Theme.label(12, .regular, .secondaryLabelColor)
    private let titlePlate = GlassSection(), notesPlate = GlassSection()
    private let notesLabel = Theme.label(11, .medium, .secondaryLabelColor)
    private let removeButton = WorkflowWindow.button(L10n.local("移除选中", "Remove"), symbol: "minus", quiet: true)
    private let clearButton = WorkflowWindow.button(L10n.local("清空", "Clear"), quiet: true)
    private let addButton = WorkflowWindow.button(L10n.local("添加", "Add"), symbol: "plus")
    private let copyFiles = WorkflowWindow.button(L10n.local("复制文件", "Copy files"), symbol: "doc.on.doc")
    private let exportFiles = WorkflowWindow.button(L10n.local("导出副本", "Export copies"), symbol: "square.and.arrow.up")
    private let copyPack = WorkflowWindow.button(L10n.local("复制清单与摘录", "Copy list & excerpts"), symbol: "doc.on.clipboard", primary: true)
    private let savePack = WorkflowWindow.button(L10n.local("保存 Markdown", "Save Markdown"), symbol: "arrow.down.to.line")
    var offlineSources: () -> Set<String> = { [] }
    var pasteboard = NSPasteboard.general
    private var busy = false
    private var reloading = false
    init(store: WorkCollectionStore) {
        self.store = store
        (notesScroll, notes) = Self.textArea(editable: true)
        (previewScroll, preview) = Self.textArea(editable: false)
        super.init(title: L10n.local("收集篮", "Collection"))
        subtitle.stringValue = L10n.local("跨多次搜索暂存文件和对话摘录，再统一复制、导出或整理给 AI。", "Keep files and excerpts across searches, then copy, export or prepare them for AI.")
        collectionTitle.stringValue = L10n.local("已收集内容", "Collected items")
        taskLabel.stringValue = L10n.local("清单名称 · 可选", "List name · Optional")
        previewTitle.stringValue = L10n.local("将要复制的内容", "What will be copied")
        previewHint.stringValue = "Markdown"
        emptyLabel.stringValue = L10n.local("先搜索文件 → 加入收集篮（⌘⇧C）\n再搜索其他内容，它们会一起保留在这里。", "Search → Add to collection (⇧⌘C)\nKeep searching. Your collected items stay here.")
        emptyLabel.cell?.wraps = true; emptyLabel.maximumNumberOfLines = 3
        titleField.placeholderString = L10n.local("任务名称（可选）", "Task name (optional)"); titleField.delegate = self
        titleField.isBezeled = false; titleField.drawsBackground = false; titleField.font = .systemFont(ofSize: 14, weight: .medium)
        titleField.focusRingType = .none
        notes.delegate = self
        notes.setAccessibilityLabel(L10n.local("我的要求与下一步", "My requirements and next steps"))
        notesLabel.stringValue = L10n.local("下一步 · 可选", "Next steps · Optional")
        notes.toolTip = L10n.local("填写你的要求与下一步。不会自动生成或发送给 AI。", "Write your requirements and next steps. Nothing is generated or sent to AI automatically.")
        for card in [collectionCard, notesCard, previewCard] { body.addSubview(card) }
        for view in [collectionTitle, countLabel, list.scroll, emptyLabel, removeButton, clearButton, addButton, copyFiles, exportFiles] as [NSView] { collectionCard.addSubview(view) }
        for view in [titlePlate, notesPlate, taskLabel, titleField, notesLabel, notesScroll] as [NSView] { notesCard.addSubview(view) }
        for view in [previewTitle, previewHint, previewScroll] { previewCard.addSubview(view) }
        for view in [copyPack, savePack] as [NSView] { body.addSubview(view) }
        addButton.onPress = { [weak self] in self?.addFiles() }
        removeButton.onPress = { [weak self] in guard let self else { return }; self.store.remove(at: self.list.table.selectedRow) }
        clearButton.onPress = { [weak self] in self?.confirmClear() }
        copyFiles.onPress = { [weak self] in self?.copyReferences() }
        exportFiles.onPress = { [weak self] in self?.chooseExportFolder() }
        copyPack.onPress = { [weak self] in
            guard let self else { return }; self.commitNotes()
            self.pasteboard.clearContents(); self.pasteboard.setString(self.store.value.markdown, forType: .string)
            self.showStatus(L10n.local("已复制清单与摘录", "List and excerpts copied"))
        }
        savePack.onPress = { [weak self] in self?.saveMarkdown() }
        savePack.keyEquivalent = "s"; savePack.keyEquivalentModifierMask = .command
        savePack.toolTip = L10n.local("保存为 Markdown 文件 · ⌘S", "Save as Markdown · ⌘S")
        copyPack.keyEquivalent = "\r"; copyPack.keyEquivalentModifierMask = .command
        copyPack.toolTip = L10n.local("⌘↩ · 复制文件路径和对话摘录。需要 AI 读取文件正文时，请另行附加原文件。", "⌘↩ · Copy paths and excerpts. Attach the originals separately if AI needs their contents.")
        list.onSelect = { [weak self] row in self?.removeButton.isEnabled = row >= 0 && self?.busy == false }
        body.arrange = { [weak self] rect in self?.arrange(rect) }
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func reload() {
        guard !reloading else { return }
        reloading = true; defer { reloading = false }
        let selected = list.table.selectedRow
        titleField.stringValue = store.value.title; notes.string = store.value.instructions
        list.symbols = store.value.files.map { OriginalCandidates.extensions.contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased()) ? "photo" : "doc.text" } + store.value.excerpts.map { _ in "text.bubble" }
        list.rows = store.value.files.map { ($0.name, $0.path) } + store.value.excerpts.map { ($0.title, "\($0.provider) · " + L10n.local("消息", "Message") + " \($0.message)") }
        if list.rows.indices.contains(selected) { list.table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false) }
        preview.textStorage?.setAttributedString(WorkflowPreview.render(store.value))
        countLabel.stringValue = L10n.local("\(store.value.files.count) 个文件 · \(store.value.excerpts.count) 段摘录", "\(store.value.files.count) files · \(store.value.excerpts.count) excerpts")
        emptyLabel.isHidden = store.value.count > 0
        showStatus(L10n.local("复制文件路径与摘录，不含文件正文。", "Copies paths and excerpts, not file contents."))
        updateButtons()
    }
    private func arrange(_ r: NSRect) {
        arrangeChrome(r)
        let left: CGFloat = 296, h = r.height - 224, right = r.width - left - 64
        collectionCard.frame = NSRect(x: 24, y: 124, width: left, height: h)
        collectionTitle.frame = NSRect(x: 18, y: 17, width: 150, height: 20)
        countLabel.frame = NSRect(x: 18, y: 42, width: 180, height: 18)
        addButton.frame = NSRect(x: left - 98, y: 18, width: 80, height: 30)
        list.scroll.frame = NSRect(x: 8, y: 74, width: left - 16, height: h - 178)
        emptyLabel.frame = NSRect(x: 18, y: 112, width: left - 36, height: 72)
        removeButton.frame = NSRect(x: 12, y: h - 96, width: 118, height: 28)
        clearButton.frame = NSRect(x: left - 76, y: h - 96, width: 60, height: 28)
        copyFiles.frame = NSRect(x: 16, y: h - 54, width: (left - 40) / 2, height: Theme.Control.height)
        exportFiles.frame = NSRect(x: left / 2 + 4, y: h - 54, width: (left - 40) / 2, height: Theme.Control.height)
        notesCard.frame = NSRect(x: left + 40, y: 124, width: right, height: 206)
        taskLabel.frame = NSRect(x: 18, y: 15, width: right - 36, height: 17)
        titlePlate.frame = NSRect(x: 16, y: 38, width: right - 32, height: 35)
        titleField.frame = NSRect(x: 28, y: 46, width: right - 56, height: 21)
        notesLabel.frame = NSRect(x: 18, y: 87, width: right - 36, height: 18)
        notesPlate.frame = NSRect(x: 16, y: 112, width: right - 32, height: 78)
        notesScroll.frame = notesPlate.frame
        previewCard.frame = NSRect(x: left + 40, y: 346, width: right, height: h - 222)
        previewTitle.frame = NSRect(x: 18, y: 16, width: 180, height: 20)
        previewHint.frame = NSRect(x: right - 96, y: 18, width: 78, height: 17); previewHint.alignment = .right
        previewScroll.frame = NSRect(x: 6, y: 48, width: right - 12, height: previewCard.bounds.height - 56)
        status.frame = NSRect(x: 26, y: r.height - 59, width: r.width - 446, height: 18)
        savePack.frame = NSRect(x: r.width - 400, y: r.height - 69, width: 164, height: Theme.Control.footerHeight)
        copyPack.frame = NSRect(x: r.width - 224, y: r.height - 69, width: 200, height: Theme.Control.footerHeight)
    }
    func controlTextDidChange(_ obj: Notification) { commitNotes() }
    func textDidChange(_ notification: Notification) { commitNotes() }
    private func commitNotes() {
        guard !reloading else { return }
        // Avoid replacing an active editor or moving its cursor on every keystroke.
        reloading = true
        store.edit(title: titleField.stringValue, instructions: notes.string)
        reloading = false
        if store.value.instructions != notes.string || store.value.title != titleField.stringValue {
            showStatus(L10n.local("名称最多 160 字、要求最多 8000 字；超出部分未保存。", "Title limit: 160 characters; notes: 8,000. Excess text is not saved."))
        }
        preview.textStorage?.setAttributedString(WorkflowPreview.render(store.value))
        updateButtons()
    }
    private func updateButtons() {
        [copyFiles, exportFiles].forEach { $0.isEnabled = !busy && !store.value.files.isEmpty }
        [copyPack, savePack].forEach { $0.isEnabled = !busy && (store.value.count > 0 || !store.value.instructions.isEmpty) }
        addButton.isEnabled = !busy; clearButton.isEnabled = !busy && (store.value.count > 0 || !store.value.title.isEmpty || !store.value.instructions.isEmpty)
        removeButton.isEnabled = !busy && list.table.selectedRow >= 0
    }
    private func addFiles() {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            var all = true
            for url in panel.urls { if !self.store.add(WorkFile(path: url.path)) { all = false } }
            if !all { self.showStatus(L10n.local("收集篮已满，部分文件未加入。最多 100 项。", "Collection is full. Some files were not added. Limit: 100 items.")) }
        }
    }
    private func confirmClear() {
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = L10n.local("清空收集篮？", "Clear the collection?")
        alert.informativeText = L10n.local("只移除这里保存的引用、摘录和要求，原文件与原对话不变。", "Removes saved references, excerpts, and notes. Original files and conversations stay unchanged.")
        alert.addButton(withTitle: L10n.local("清空", "Clear")); alert.addButton(withTitle: L10n.local("取消", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in if response == .alertFirstButtonReturn { self?.store.clear() } }
    }
    private func perform<T>(_ work: @escaping (WorkflowCancellation) throws -> T, completion: @escaping (T) -> Void) {
        guard !busy else { return }
        cancellation.cancel(); let token = WorkflowCancellation(); cancellation = token
        busy = true; updateButtons(); showStatus(L10n.local("正在检查本地文件… 关闭窗口可取消。", "Checking local files… Close this window to cancel."))
        queue.async { [weak self] in
            let result = Result { try work(token) }
            DispatchQueue.main.async {
                guard let self, self.cancellation === token else { return }
                self.busy = false; self.updateButtons()
                if token.cancelled { return }
                switch result { case .success(let value): completion(value); case .failure(let error): self.showStatus(error.localizedDescription) }
            }
        }
    }
    private func copyReferences() {
        let files = store.value.files, offline = offlineSources()
        perform({ token in try WorkflowFiles.urls(files, offline: offline, cancelled: { token.cancelled }) }) { [weak self] urls in
            guard let self else { return }
            self.pasteboard.clearContents(); self.pasteboard.writeObjects(urls as [NSURL])
            self.showStatus(L10n.local("已复制 \(urls.count) 个文件，可在访达中粘贴。", "Copied \(urls.count) file references. Paste in Finder."))
        }
    }
    private func chooseExportFolder() {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.message = L10n.local("将在所选位置新建文件夹。仅复制普通本地文件，每个不超过 100 MB、合计不超过 500 MB。", "Creates a new folder here. Local regular files only: up to 100 MB each and 500 MB total.")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let files = self.store.value.files, offline = self.offlineSources()
            self.perform({ token in try WorkflowFiles.export(files, to: url, offline: offline, cancelled: { token.cancelled }) }) { [weak self] destination in
                self?.showStatus(L10n.local("副本已导出到：", "Copies exported to: ") + destination.path)
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            }
        }
    }
    private func saveMarkdown() {
        guard let window else { return }; commitNotes()
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Fox Find Context.md"; panel.allowedContentTypes = [.plainText]
        let text = store.value.markdown
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.perform({ token in
                if token.cancelled { throw WorkflowFailure.cancelled }
                try text.write(to: url, atomically: true, encoding: .utf8); return url
            }) { [weak self] url in self?.showStatus(L10n.local("已保存：", "Saved: ") + url.path) }
        }
    }
}

final class OriginalCandidatesWindow: WorkflowWindow {
    let reference: WorkFile
    private let list = WorkflowList()
    private let referenceImage = NSImageView(), candidateImage = NSImageView()
    private let referenceLabel = Theme.label(11, .medium, .secondaryLabelColor)
    private let candidateLabel = Theme.label(11, .medium, .secondaryLabelColor)
    private let referenceMeta = Theme.label(11, .regular, .secondaryLabelColor)
    private let candidateMeta = Theme.label(11, .regular, .secondaryLabelColor)
    private let candidatesTitle = Theme.label(13, .semibold, .labelColor)
    private let candidatesCount = Theme.label(11, .medium, .secondaryLabelColor)
    private let evidence = Theme.label(13, .medium, .labelColor)
    private let filename = Theme.label(12, .medium, .labelColor)
    private let candidatesCard = GlassSection(), referenceCard = GlassSection(), candidateCard = GlassSection(), detailsCard = GlassSection()
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let chooseFolder = WorkflowWindow.button(L10n.local("选择文件夹…", "Choose a folder…"), symbol: "folder")
    private let collect = WorkflowWindow.button(L10n.local("加入收集篮", "Add to collection"), symbol: "plus", primary: true)
    private let reveal = WorkflowWindow.button(L10n.local("在访达中显示", "Show in Finder"), symbol: "arrow.up.forward.square")
    private(set) var report: OriginalCandidates.Report?
    var onCollect: ((WorkFile) -> Bool)?
    private let offline: Set<String>
    private let scopeLimited: Bool
    init(reference: WorkFile, candidates: [WorkFile], offline: Set<String>, scopeLimited: Bool = false) {
        self.reference = reference; self.offline = offline; self.scopeLimited = scopeLimited
        super.init(title: L10n.local("原文件对照", "Compare originals"))
        subtitle.stringValue = L10n.local("比较画面与文件信息，确认要保留的版本。", "Compare images and file details. Choose the version you want to keep.")
        candidatesTitle.stringValue = L10n.local("候选文件", "Candidates")
        for image in [referenceImage, candidateImage] { image.imageScaling = .scaleProportionallyUpOrDown; image.imageAlignment = .alignCenter }
        notice.font = .systemFont(ofSize: 12); notice.textColor = .secondaryLabelColor
        notice.stringValue = L10n.local("相似仅作参考，原文件需要你确认。", "Similarity is a clue. Confirm the original yourself.")
        notice.toolTip = L10n.local("当前结果前 256 项内最多比较 64 张图片；选择文件夹时仅检查当前层。尺寸或日期不能证明来源。", "Compare up to 64 images from the first 256 results, or a folder's direct children. Dimensions and dates do not prove origin.")
        referenceLabel.stringValue = L10n.local("当前图片", "Reference image")
        candidateLabel.stringValue = L10n.local("选中候选", "Selected candidate")
        detail.font = .systemFont(ofSize: 12); detail.textColor = .secondaryLabelColor
        for card in [candidatesCard, referenceCard, candidateCard, detailsCard] { body.addSubview(card) }
        for view in [candidatesTitle, candidatesCount, list.scroll, chooseFolder] as [NSView] { candidatesCard.addSubview(view) }
        for view in [referenceImage, referenceLabel, referenceMeta] as [NSView] { referenceCard.addSubview(view) }
        for view in [candidateImage, candidateLabel, candidateMeta] as [NSView] { candidateCard.addSubview(view) }
        for view in [evidence, filename, detail] { detailsCard.addSubview(view) }
        for view in [notice, collect, reveal] as [NSView] { body.addSubview(view) }
        list.onSelect = { [weak self] row in self?.select(row) }
        chooseFolder.onPress = { [weak self] in self?.selectFolder() }
        collect.onPress = { [weak self] in
            guard let self, let selected = self.selected else { return }
            self.showStatus(self.onCollect?(selected.file) == true ? L10n.local("已加入收集篮。", "Added to collection.") : L10n.local("收集篮已满，请先移除部分内容。", "Collection is full. Remove some items first."))
        }
        reveal.onPress = { [weak self] in
            guard let file = self?.selected?.file else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
        }
        body.arrange = { [weak self] rect in self?.arrange(rect) }
        compare(candidates: candidates, folder: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var selected: OriginalCandidates.Candidate? {
        guard let report, report.matches.indices.contains(list.table.selectedRow) else { return nil }
        return report.matches[list.table.selectedRow]
    }
    private func arrange(_ r: NSRect) {
        arrangeChrome(r)
        let left: CGFloat = 268, h = r.height - 224, right = r.width - left - 64, width = (right - 16) / 2
        candidatesCard.frame = NSRect(x: 24, y: 124, width: left, height: h)
        candidatesTitle.frame = NSRect(x: 18, y: 18, width: 180, height: 20)
        candidatesCount.frame = NSRect(x: left - 54, y: 20, width: 36, height: 18); candidatesCount.alignment = .right
        list.scroll.frame = NSRect(x: 8, y: 56, width: left - 16, height: h - 124)
        chooseFolder.frame = NSRect(x: 16, y: h - 52, width: left - 32, height: Theme.Control.height)
        referenceCard.frame = NSRect(x: left + 40, y: 124, width: width, height: h - 152)
        candidateCard.frame = NSRect(x: left + 56 + width, y: 124, width: width, height: h - 152)
        for (image, label, meta) in [(referenceImage, referenceLabel, referenceMeta), (candidateImage, candidateLabel, candidateMeta)] {
            label.frame = NSRect(x: 18, y: 16, width: width - 36, height: 18)
            image.frame = NSRect(x: 18, y: 48, width: width - 36, height: h - 244)
            meta.frame = NSRect(x: 18, y: h - 184, width: width - 36, height: 18)
        }
        detailsCard.frame = NSRect(x: left + 40, y: 124 + h - 136, width: right, height: 136)
        evidence.frame = NSRect(x: 18, y: 17, width: right - 36, height: 20)
        filename.frame = NSRect(x: 18, y: 48, width: right - 36, height: 18)
        detail.frame = NSRect(x: 18, y: 74, width: right - 36, height: 44)
        notice.frame = NSRect(x: 26, y: r.height - 64, width: r.width - 414, height: 28)
        reveal.frame = NSRect(x: r.width - 368, y: r.height - 69, width: 164, height: Theme.Control.footerHeight)
        collect.frame = NSRect(x: r.width - 192, y: r.height - 69, width: 168, height: Theme.Control.footerHeight)
    }
    private func select(_ row: Int) {
        collect.isEnabled = selected != nil; reveal.isEnabled = selected != nil
        guard let item = selected else { candidateImage.image = nil; detail.stringValue = ""; evidence.stringValue = ""; filename.stringValue = ""; candidateMeta.stringValue = ""; return }
        candidateImage.image = NSImage(cgImage: item.thumbnail, size: .zero)
        let referenceSize = report.map { "\($0.reference.width) × \($0.reference.height)" } ?? ""
        referenceMeta.stringValue = referenceSize
        candidateMeta.stringValue = "\(item.width) × \(item.height) · " + ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)
        evidence.stringValue = item.explanation; filename.stringValue = item.file.name
        detail.stringValue = item.file.path; detail.toolTip = item.file.path
    }
    private func selectFolder() {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.message = L10n.local("只比较该文件夹当前层，最多 64 张图片；不会递归扫描或下载云端文件。", "Compare up to 64 images directly in this folder. No recursive scanning or cloud downloads.")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            self?.compare(candidates: [], folder: folder)
        }
    }
    private func compare(candidates: [WorkFile], folder: URL?) {
        cancellation.cancel(); let token = WorkflowCancellation(); cancellation = token
        report = nil; list.rows = []; select(-1); referenceImage.image = nil; candidatesCount.stringValue = "…"; referenceMeta.stringValue = ""
        showStatus(L10n.local("正在比较，关闭窗口可取消…", "Comparing… Close this window to cancel."))
        let reference = reference, offline = offline
        queue.async { [weak self] in
            let result = Result { () throws -> (OriginalCandidates.Report, Bool) in
                let scope = folder.map { OriginalCandidates.folderCandidates($0, cancelled: { token.cancelled }) }
                let report = try OriginalCandidates.compare(reference: reference, candidates: scope?.files ?? candidates, offline: offline, cancelled: { token.cancelled })
                return (report, scope?.limited ?? false)
            }
            DispatchQueue.main.async {
                guard let self, self.cancellation === token, !token.cancelled else { return }
                switch result {
                case .failure(let error): self.showStatus(error.localizedDescription)
                case .success(let (report, folderLimited)):
                    self.report = report; self.referenceImage.image = NSImage(cgImage: report.reference.thumbnail, size: .zero)
                    self.candidatesCount.stringValue = "\(report.matches.count)"
                    self.list.rows = report.matches.map { ($0.file.name, $0.explanation) }
                    if !report.matches.isEmpty { self.list.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); self.select(0) }
                    else { self.detail.stringValue = L10n.local("本次范围没有可靠候选。可选择存放原图的文件夹继续比较。", "No reliable candidates in this scope. Choose the folder that may contain your originals.") }
                    let scope = folder?.lastPathComponent ?? L10n.local("当前搜索结果", "Current search results")
                    self.showStatus(scope + " · " + L10n.local("已比较 \(report.checked) 张，跳过 \(report.skipped) 张，\(report.matches.count) 个候选", "\(report.checked) compared, \(report.skipped) skipped, \(report.matches.count) candidates") +
                        ((report.limited || folderLimited || (folder == nil && self.scopeLimited)) ? L10n.local(" · 仅比较部分文件，请缩小范围", " · Partial comparison; narrow the scope") : ""))
                }
            }
        }
    }
}
