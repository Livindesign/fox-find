import AppKit
import UniformTypeIdentifiers

private final class WorkflowPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) { close() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
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
    private static let operationQueue = DispatchQueue(label: "app.localfind.workflow", qos: .utility)
    var queue: DispatchQueue { Self.operationQueue }
    var cancellation = WorkflowCancellation()
    var onClose: (() -> Void)?
    init(title: String, width: CGFloat = 840, height: CGFloat = 660) {
        let panel = WorkflowPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.delegate = self; panel.isReleasedWhenClosed = false; panel.title = title
        panel.minSize = NSSize(width: width, height: height); panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true; panel.hasShadow = true; panel.isOpaque = false
        panel.backgroundColor = NSColor(name: nil) { Theme.glassTint(dark: $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua) }
        let surface = PanelSurface(snapshot: false); panel.contentView = surface
        body.frame = surface.bounds; body.autoresizingMask = [.width, .height]; surface.addSubview(body)
        heading.stringValue = title; status.lineBreakMode = .byTruncatingTail
        body.addSubview(heading); body.addSubview(status); panel.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func windowWillClose(_ notification: Notification) { cancellation.cancel(); onClose?() }
    func showStatus(_ value: String) { status.stringValue = value; status.toolTip = value }
    func present() { showWindow(nil); window?.makeKeyAndOrderFront(nil) }
    static func textArea(editable: Bool) -> (ResultScrollView, NSTextView) {
        let scroll = ResultScrollView(), text = NSTextView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        text.isEditable = editable; text.isSelectable = true; text.isRichText = false
        text.drawsBackground = false; text.textColor = .labelColor; text.font = .systemFont(ofSize: 12)
        text.textContainerInset = NSSize(width: 12, height: 10)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = .width; text.textContainer?.widthTracksTextView = true
        text.layoutManager?.allowsNonContiguousLayout = true
        scroll.documentView = text; return (scroll, text)
    }
    static func button(_ title: String, primary: Bool = false) -> ChromeButton {
        ChromeButton(title, style: primary ? .tonal : .plain, size: 12, weight: .medium)
    }
}

private final class WorkflowRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 2), xRadius: 10, yRadius: 10).fill()
    }
}

final class WorkflowList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let scroll = ResultScrollView(), table = NSTableView()
    var rows: [(String, String)] = [] { didSet { table.reloadData() } }
    var onSelect: ((Int) -> Void)?
    override init() {
        super.init()
        let column = NSTableColumn(identifier: .init("item")); column.resizingMask = .autoresizingMask; table.addTableColumn(column)
        table.headerView = nil; table.backgroundColor = .clear; table.rowHeight = 52
        table.intercellSpacing = .zero; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.delegate = self; table.dataSource = self; table.allowsEmptySelection = true
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.documentView = table
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { WorkflowRow() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("workflow.row")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? NSTableCellView()
        if cell.textField == nil {
            cell.identifier = id
            let text = Theme.label(12, .medium, .labelColor); text.tag = 1; text.lineBreakMode = .byTruncatingMiddle
            let detail = Theme.label(10.5, .regular, .secondaryLabelColor); detail.tag = 2; detail.lineBreakMode = .byTruncatingMiddle
            cell.textField = text; cell.addSubview(text); cell.addSubview(detail)
            text.translatesAutoresizingMaskIntoConstraints = false; detail.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
                text.topAnchor.constraint(equalTo: cell.topAnchor, constant: 8), text.heightAnchor.constraint(equalToConstant: 18),
                detail.leadingAnchor.constraint(equalTo: text.leadingAnchor), detail.trailingAnchor.constraint(equalTo: text.trailingAnchor),
                detail.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 2), detail.heightAnchor.constraint(equalToConstant: 16)
            ])
        }
        cell.textField?.stringValue = rows[row].0; (cell.viewWithTag(2) as? NSTextField)?.stringValue = rows[row].1
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
    private let notice = Theme.label(11, .regular, .secondaryLabelColor)
    private let notesLabel = Theme.label(11, .medium, .secondaryLabelColor)
    private let removeButton = WorkflowWindow.button(L10n.local("移除选中", "Remove selected"))
    private let clearButton = WorkflowWindow.button(L10n.local("清空", "Clear"))
    private let addButton = WorkflowWindow.button(L10n.local("添加文件…", "Add files…"))
    private let copyFiles = WorkflowWindow.button(L10n.local("复制文件", "Copy files"))
    private let exportFiles = WorkflowWindow.button(L10n.local("导出副本…", "Export copies…"))
    private let copyPack = WorkflowWindow.button(L10n.local("复制继续资料", "Copy context pack"), primary: true)
    private let savePack = WorkflowWindow.button(L10n.local("保存 Markdown…", "Save Markdown…"))
    var offlineSources: () -> Set<String> = { [] }
    var pasteboard = NSPasteboard.general
    private var busy = false
    private var reloading = false
    init(store: WorkCollectionStore) {
        self.store = store
        (notesScroll, notes) = Self.textArea(editable: true)
        (previewScroll, preview) = Self.textArea(editable: false)
        super.init(title: L10n.local("收集篮 · 继续资料", "Collection · Context pack"))
        titleField.placeholderString = L10n.local("任务名称（可选）", "Task name (optional)"); titleField.delegate = self
        titleField.isBezeled = false; titleField.drawsBackground = false; titleField.font = .systemFont(ofSize: 18, weight: .semibold)
        notes.delegate = self
        notes.setAccessibilityLabel(L10n.local("我的要求与下一步", "My requirements and next steps"))
        notesLabel.stringValue = L10n.local("我的要求与下一步（可选）", "My requirements and next steps (optional)")
        notes.toolTip = L10n.local("填写你的要求与下一步。不会自动生成或发送给 AI。", "Write your requirements and next steps. Nothing is generated or sent to AI automatically.")
        notice.stringValue = L10n.local("仅保存在本机，清空即移除。右侧为导出预览；文件内容不附带。", "Saved locally until cleared. Export preview on the right; file contents are not attached.")
        notice.lineBreakMode = .byTruncatingTail
        for view in [titleField, notesLabel, notesScroll, notice, list.scroll, previewScroll, removeButton, clearButton, addButton, copyFiles, exportFiles, copyPack, savePack] as [NSView] { body.addSubview(view) }
        addButton.onPress = { [weak self] in self?.addFiles() }
        removeButton.onPress = { [weak self] in guard let self else { return }; self.store.remove(at: self.list.table.selectedRow) }
        clearButton.onPress = { [weak self] in self?.confirmClear() }
        copyFiles.onPress = { [weak self] in self?.copyReferences() }
        exportFiles.onPress = { [weak self] in self?.chooseExportFolder() }
        copyPack.onPress = { [weak self] in
            guard let self else { return }; self.commitNotes()
            self.pasteboard.clearContents(); self.pasteboard.setString(self.store.value.markdown, forType: .string)
            self.showStatus(L10n.local("已复制继续资料，可粘贴到你选择的对话中。", "Context pack copied. Paste it into the conversation you choose."))
        }
        savePack.onPress = { [weak self] in self?.saveMarkdown() }
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
        list.rows = store.value.files.map { ($0.name, $0.path) } + store.value.excerpts.map { ($0.title, "\($0.provider) · " + L10n.local("消息", "Message") + " \($0.message)") }
        if list.rows.indices.contains(selected) { list.table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false) }
        preview.string = store.value.markdown
        showStatus(L10n.local("已收集 \(store.value.files.count) 个文件、\(store.value.excerpts.count) 段文字 · 最多 100 项", "\(store.value.files.count) files, \(store.value.excerpts.count) excerpts · Up to 100 items"))
        updateButtons()
    }
    private func arrange(_ r: NSRect) {
        heading.frame = NSRect(x: 84, y: 8, width: r.width - 260, height: 24)
        addButton.frame = NSRect(x: r.width - 152, y: 6, width: 128, height: 28)
        titleField.frame = NSRect(x: 28, y: 52, width: r.width - 56, height: 28)
        notesLabel.frame = NSRect(x: 28, y: 88, width: r.width - 56, height: 18)
        notesScroll.frame = NSRect(x: 16, y: 106, width: r.width - 32, height: 60)
        notice.frame = NSRect(x: 28, y: 172, width: r.width - 56, height: 18)
        let left: CGFloat = 280
        list.scroll.frame = NSRect(x: 20, y: 204, width: left, height: r.height - 320)
        previewScroll.frame = NSRect(x: left + 36, y: 204, width: r.width - left - 56, height: r.height - 320)
        removeButton.frame = NSRect(x: 24, y: r.height - 110, width: 140, height: 28)
        clearButton.frame = NSRect(x: 176, y: r.height - 110, width: 100, height: 28)
        let buttons = [copyFiles, exportFiles, savePack, copyPack], width = (r.width - 60) / 4
        for (i, button) in buttons.enumerated() { button.frame = NSRect(x: 24 + CGFloat(i) * (width + 4), y: r.height - 70, width: width, height: 34) }
        status.frame = NSRect(x: 28, y: r.height - 29, width: r.width - 56, height: 18)
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
        preview.string = store.value.markdown
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
        let alert = NSAlert(); alert.messageText = L10n.local("清空收集篮和继续资料？", "Clear the collection and context pack?")
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
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let chooseFolder = WorkflowWindow.button(L10n.local("选择文件夹比较…", "Compare a folder…"))
    private let collect = WorkflowWindow.button(L10n.local("加入收集篮", "Add to collection"), primary: true)
    private let reveal = WorkflowWindow.button(L10n.local("在访达中显示", "Show in Finder"))
    private(set) var report: OriginalCandidates.Report?
    var onCollect: ((WorkFile) -> Bool)?
    private let offline: Set<String>
    private let scopeLimited: Bool
    init(reference: WorkFile, candidates: [WorkFile], offline: Set<String>, scopeLimited: Bool = false) {
        self.reference = reference; self.offline = offline; self.scopeLimited = scopeLimited
        super.init(title: L10n.local("原文件候选 · 对照确认", "Original candidates · Compare to confirm"), height: 640)
        for image in [referenceImage, candidateImage] { image.imageScaling = .scaleProportionallyUpOrDown; image.imageAlignment = .alignCenter }
        notice.font = .systemFont(ofSize: 12); notice.textColor = .secondaryLabelColor
        notice.stringValue = L10n.local("先从结果前 256 项中比较最多 64 张图片，也可选择一个文件夹（仅当前层）。候选不代表原文件；尺寸或日期不能证明来源。", "Compare up to 64 images from the first 256 results, or one folder (direct children only). Candidates are not proven originals; dimensions and dates are not proof.")
        referenceLabel.stringValue = L10n.local("参考图片", "Reference image")
        candidateLabel.stringValue = L10n.local("选中候选", "Selected candidate")
        detail.font = .systemFont(ofSize: 12); detail.textColor = .secondaryLabelColor
        for view in [notice, list.scroll, referenceImage, candidateImage, referenceLabel, candidateLabel, detail, chooseFolder, collect, reveal] as [NSView] { body.addSubview(view) }
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
        heading.frame = NSRect(x: 84, y: 8, width: r.width - 108, height: 24)
        notice.frame = NSRect(x: 28, y: 52, width: r.width - 56, height: 50)
        list.scroll.frame = NSRect(x: 20, y: 118, width: 300, height: r.height - 218)
        let width = (r.width - 364) / 2
        referenceImage.frame = NSRect(x: 340, y: 144, width: width, height: 200)
        candidateImage.frame = NSRect(x: 356 + width, y: 144, width: width, height: 200)
        referenceLabel.frame = NSRect(x: 340, y: 118, width: width, height: 20)
        candidateLabel.frame = NSRect(x: 356 + width, y: 118, width: width, height: 20)
        detail.frame = NSRect(x: 340, y: 360, width: r.width - 368, height: r.height - 466)
        chooseFolder.frame = NSRect(x: 24, y: r.height - 78, width: 224, height: 34)
        reveal.frame = NSRect(x: r.width - 348, y: r.height - 78, width: 156, height: 34)
        collect.frame = NSRect(x: r.width - 180, y: r.height - 78, width: 156, height: 34)
        status.frame = NSRect(x: 28, y: r.height - 32, width: r.width - 56, height: 18)
    }
    private func select(_ row: Int) {
        collect.isEnabled = selected != nil; reveal.isEnabled = selected != nil
        guard let item = selected else { candidateImage.image = nil; detail.stringValue = ""; return }
        candidateImage.image = NSImage(cgImage: item.thumbnail, size: .zero)
        let referenceSize = report.map { "\($0.reference.width) × \($0.reference.height)" } ?? ""
        detail.stringValue = item.explanation + "\n\n" + L10n.local("参考：", "Reference: ") + referenceSize + "\n" +
            L10n.local("候选：", "Candidate: ") + "\(item.width) × \(item.height) · " + ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file) + "\n\n" + item.file.path
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
        report = nil; list.rows = []; select(-1); referenceImage.image = nil
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
