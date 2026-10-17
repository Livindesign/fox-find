import AppKit
import PDFKit
import Darwin

private final class PreviewSurface: NSView {
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); bounds.fill() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

struct ContentMatchIndex {
    let preview: ExtractedTextPreview
    func matches(_ needle: String) -> [NSRange] {
        let text = preview.text as NSString
        guard !needle.isEmpty else { return [] }
        var found = [NSRange](), range = NSRange(location: 0, length: text.length)
        while range.length > 0 && found.count < 1000 {
            let match = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: range)
            guard match.location != NSNotFound, match.length > 0 else { break }
            found.append(match); range = NSRange(location: NSMaxRange(match), length: text.length - NSMaxRange(match))
        }
        return found
    }
    func page(at offset: Int) -> Int? {
        preview.segments.first { offset >= $0.offset && offset < $0.offset + $0.length }?.page
    }
    func line(at offset: Int) -> Int {
        let prefix = (preview.text as NSString).substring(to: min(max(0, offset), (preview.text as NSString).length))
        return prefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }
    func context(around range: NSRange) -> NSRange {
        let text = preview.text as NSString, start = max(0, range.location - 250)
        return text.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: min(text.length - start, range.length + 500)))
    }
    static func currentStamp(_ url: URL) -> String? {
        var s = stat()
        guard lstat(url.path, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_flags & UInt32(SF_DATALESS) == 0,
              s.st_size <= 64 * 1024 * 1024 else { return nil }
        return "\(s.st_dev):\(s.st_ino):\(s.st_size):\(s.st_mtimespec.tv_sec):\(s.st_mtimespec.tv_nsec)"
    }
}

final class ContentPreviewWindow: NSWindowController, NSSearchFieldDelegate, NSWindowDelegate {
    private let preview: ExtractedTextPreview
    private let index: ContentMatchIndex
    private let textView = NSTextView()
    private let find = NSSearchField()
    private let status = NSTextField(labelWithString: "")
    private let fold = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let openPage = ChromeButton("", style: .plain, size: 12, weight: .medium)
    private(set) var matches = [NSRange](), position = -1
    private var pdfWindow: NSWindowController?
    private var request = 0
    init(preview: ExtractedTextPreview, query: String) {
        self.preview = preview; index = ContentMatchIndex(preview: preview)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 620), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.delegate = self
        window.title = URL(fileURLWithPath: preview.path).lastPathComponent + " · " + L10n.text("workspace.textPreview")
        window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 600, height: 350)
        let container = PreviewSurface(); window.contentView = container
        let path = NSTextField(wrappingLabelWithString: preview.path)
        path.font = .systemFont(ofSize: 11); path.textColor = .secondaryLabelColor; path.isSelectable = true; path.maximumNumberOfLines = 2
        find.placeholderString = L10n.text("workspace.findText"); find.delegate = self; find.stringValue = query
        let previous = ChromeButton("↑", style: .plain, size: 15, weight: .medium)
        let next = ChromeButton("↓", style: .plain, size: 15, weight: .medium)
        previous.onPress = { [weak self] in self?.move(-1) }; next.onPress = { [weak self] in self?.move(1) }
        previous.setAccessibilityLabel(L10n.local("上一个匹配", "Previous Match")); next.setAccessibilityLabel(L10n.local("下一个匹配", "Next Match"))
        let toolbar = NSStackView(views: [find, previous, next, status]); toolbar.spacing = 8; toolbar.alignment = .centerY
        find.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        for button in [previous, next] { button.widthAnchor.constraint(equalToConstant: 32).isActive = true; button.heightAnchor.constraint(equalToConstant: 30).isActive = true }
        status.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); status.setContentHuggingPriority(.required, for: .horizontal)
        fold.title = L10n.text("workspace.foldMatches"); fold.target = self; fold.action = #selector(toggleFold)
        let copy = ChromeButton(L10n.text("workspace.copyAll"), style: .plain, size: 12, weight: .medium)
        copy.onPress = { [weak self] in self?.copyText() }; copy.widthAnchor.constraint(equalToConstant: 100).isActive = true
        openPage.title = L10n.text("workspace.openPage"); openPage.widthAnchor.constraint(equalToConstant: 150).isActive = true
        openPage.onPress = { [weak self] in self?.showPDFPage() }
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [fold, spacer, openPage, copy]); actions.alignment = .centerY; actions.spacing = 8
        let origin = !preview.isCached ? L10n.text("workspace.previewExtracted") : (preview.isOnline ? L10n.local("本机内容缓存", "Local content cache") : L10n.local("离线内容缓存 · 重新连接磁盘后可打开原文件", "Offline cache · Reconnect to open the original"))
        let note = NSTextField(wrappingLabelWithString: origin + (preview.note.isEmpty ? "" : " · " + preview.note))
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        textView.textColor = .textColor; textView.backgroundColor = .textBackgroundColor
        textView.isEditable = false; textView.isSelectable = true; textView.isRichText = false
        textView.font = .systemFont(ofSize: 14); textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]; textView.textContainer?.widthTracksTextView = true
        textView.string = preview.text; scroll.documentView = textView
        for item in [path, toolbar, actions, note, scroll] { item.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(item) }
        NSLayoutConstraint.activate([
            path.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18), path.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18), path.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            toolbar.leadingAnchor.constraint(equalTo: path.leadingAnchor), toolbar.trailingAnchor.constraint(equalTo: path.trailingAnchor), toolbar.topAnchor.constraint(equalTo: path.bottomAnchor, constant: 12),
            actions.leadingAnchor.constraint(equalTo: path.leadingAnchor), actions.trailingAnchor.constraint(equalTo: path.trailingAnchor), actions.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 6), actions.heightAnchor.constraint(equalToConstant: 30),
            note.leadingAnchor.constraint(equalTo: path.leadingAnchor), note.trailingAnchor.constraint(equalTo: path.trailingAnchor), note.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16), scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16), scroll.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 10), scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16)
        ])
        window.center(); updateMatches()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func close() { request += 1; pdfWindow?.close(); super.close() }
    func windowWillClose(_ notification: Notification) { request += 1; pdfWindow?.close() }
    func controlTextDidChange(_ obj: Notification) { updateMatches() }
    private func updateMatches() { matches = index.matches(find.stringValue); position = matches.isEmpty ? -1 : 0; renderMatch() }
    private func move(_ delta: Int) {
        if !matches.isEmpty { position = (position + delta + matches.count) % matches.count }
        renderMatch()
    }
    @objc private func toggleFold() { renderMatch() }
    private func renderMatch() {
        let match = matches.indices.contains(position) ? matches[position] : nil
        let slice = fold.state == .on ? match.map { index.context(around: $0) } : nil
        textView.string = slice.map { (preview.text as NSString).substring(with: $0) } ?? preview.text
        let offset = slice?.location ?? 0, length = (textView.string as NSString).length
        for range in matches {
            let translated = NSRange(location: range.location - offset, length: range.length)
            if translated.location >= 0 && NSMaxRange(translated) <= length { textView.textStorage?.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.3), range: translated) }
        }
        if let match {
            let range = NSRange(location: match.location - offset, length: match.length)
            textView.setSelectedRange(range); textView.scrollRangeToVisible(range)
            let location = index.page(at: match.location).map { L10n.text("workspace.page", String($0)) } ?? L10n.text("workspace.line", String(index.line(at: match.location)))
            status.stringValue = "\(position + 1)/\(matches.count)" + (matches.count == 1000 ? "+" : "") + " · " + location
        } else { status.stringValue = find.stringValue.isEmpty ? L10n.text("workspace.enterMatch") : L10n.local("无匹配", "No matches") }
        openPage.isHidden = preview.segments.isEmpty
        openPage.isEnabled = preview.isOnline && match.flatMap { index.page(at: $0.location) } != nil
    }
    private func copyText() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(preview.text, forType: .string) }
    private func showPDFPage() {
        guard preview.isOnline, matches.indices.contains(position), let page = index.page(at: matches[position].location) else { return }
        request += 1; let token = request, preview = self.preview, url = URL(fileURLWithPath: preview.path)
        status.stringValue = L10n.text("workspace.pdfLoading")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let stamp = ContentMatchIndex.currentStamp(url)
            let document = stamp != nil && stamp == preview.sourceStamp ? PDFDocument(url: url) : nil
            let current = stamp == ContentMatchIndex.currentStamp(url)
            DispatchQueue.main.async {
                guard let self, self.request == token else { return }
                guard current, let document, let target = document.page(at: page - 1) else { self.status.stringValue = L10n.text("workspace.stalePreview"); return }
                let view = PDFView(); view.document = document; view.autoScales = true; view.go(to: target)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                window.title = url.lastPathComponent + " · " + L10n.text("workspace.page", String(page)); window.contentView = view; window.isReleasedWhenClosed = false; window.center()
                self.pdfWindow?.close(); self.pdfWindow = NSWindowController(window: window); self.pdfWindow?.showWindow(nil)
                self.renderMatch()
            }
        }
    }
}
