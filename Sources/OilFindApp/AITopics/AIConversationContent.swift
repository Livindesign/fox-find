import AppKit

struct AIConversationContent {
    struct Message { let role: String; let text: String }
    let topic: AITopic
    let messages: [Message]
    let truncated: Bool
    var markdown: String {
        var parts = ["# " + topic.title, topic.provider.name + " · " + topic.id]
        if !topic.project.isEmpty { parts.append(topic.project) }
        for message in messages {
            let role = message.role == "user" ? L10n.local("用户", "User") : message.role == "assistant" ? L10n.local("助手", "Assistant") : L10n.local("消息", "Message")
            parts.append("## " + role + "\n\n" + message.text)
        }
        if truncated { parts.append(L10n.local("（对话较长，此处仅展示前一部分。请打开原会话查看完整内容。）", "(This long conversation is truncated. Open the original to read it in full.)")) }
        return parts.joined(separator: "\n\n")
    }
    /// Native attributed text, with message bodies treated as literal source material.
    var displayText: NSAttributedString { displayParts.text }
    private var displayParts: (text: NSAttributedString, bodies: [NSRange]) {
        let result = NSMutableAttributedString()
        var bodies = [NSRange]()
        func append(_ value: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor, spacing: CGFloat = 14) {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4; paragraph.paragraphSpacing = spacing
            result.append(NSAttributedString(string: value + "\n", attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph]))
        }
        append(topic.title, size: 21, weight: .semibold)
        if !topic.project.isEmpty { append(topic.project, size: 12, color: .secondaryLabelColor, spacing: 24) }
        if messages.isEmpty { append(L10n.local("这段对话尚无可预览的文字，可在原应用中查看。", "There is no previewable text yet. View this conversation in its original app."), size: 14, color: .secondaryLabelColor) }
        for message in messages {
            let role = message.role == "user" ? L10n.local("你", "You") : message.role == "assistant" ? topic.provider.name : L10n.local("消息", "Message")
            append(role, size: 12, weight: .semibold, color: .secondaryLabelColor, spacing: 6)
            bodies.append(NSRange(location: result.length, length: (message.text as NSString).length))
            append(message.text, size: 14, spacing: 24)
        }
        if truncated { append(L10n.local("对话较长，此处仅显示部分内容。完整记录请在原应用查看。", "This is part of a long conversation. View the full record in the original app."), size: 12, color: .secondaryLabelColor) }
        return (result, bodies)
    }
    func selectedExcerpts(_ selection: NSRange, now: Date = Date()) -> [WorkExcerpt] {
        let parts = displayParts
        guard selection.location != NSNotFound, selection.location <= parts.text.length,
              selection.length > 0, selection.length <= parts.text.length - selection.location else { return [] }
        return parts.bodies.enumerated().compactMap { index, body in
            let intersection = NSIntersectionRange(selection, body)
            guard intersection.length > 0 else { return nil }
            let offset = intersection.location - body.location
            return WorkExcerpt(provider: topic.provider.rawValue, conversationID: topic.id, title: topic.title, project: topic.project,
                               message: index + 1, role: messages[index].role, offset: offset,
                               text: (messages[index].text as NSString).substring(with: NSRange(location: offset, length: intersection.length)), collected: now)
        }
    }
}

/// Plain text only: messages are untrusted content, never rendered as executable HTML.
final class AIConversationWindow: NSWindowController {
    var onOpen: (() -> Void)?, onCopy: (() -> Void)?, onResume: (() -> Void)?
    var onCollect: (([WorkExcerpt]) -> Bool)?
    private let status = Theme.label(11, .regular, .secondaryLabelColor)
    let textView = NSTextView()
    let scrollView = ResultScrollView()
    let openButton = ChromeButton("", style: .tonal, size: 12, weight: .medium)
    let copyButton = ChromeButton(L10n.local("复制内容", "Copy content"), style: .plain, size: 12, weight: .medium)
    let collectButton = ChromeButton(L10n.local("收集选中文字", "Collect selection"), style: .tonal, size: 12, weight: .medium)
    private var initialMatch: NSRange?
    private var previewKeys: PreviewKeys?
    init(content: AIConversationContent, query: String, snapshot: Bool = false) {
        let window = ConversationPreviewPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init(window: window)
        previewKeys = PreviewKeys(window: window) { [weak self] in self?.close() }
        window.title = content.topic.title + " · " + content.topic.provider.name
        window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 560, height: 360)
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true; window.hasShadow = true
        let surface = PanelSurface(snapshot: snapshot)
        window.contentView = surface; window.isOpaque = false
        // The full-size glass covers the title bar too. An opaque neutral fallback
        // avoids a clear/black strip while the visual-effect layer is being attached.
        window.backgroundColor = NSColor(name: nil) { appearance in
            Theme.glassTint(dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        }
        let heading = Theme.label(12, .medium, .secondaryLabelColor)
        heading.stringValue = content.topic.provider.name + " · " + L10n.local("对话预览", "Conversation preview")
        status.stringValue = content.truncated ? L10n.local("本地副本 · 仅显示部分内容", "Local copy · Partial content") : L10n.local("本地对话副本", "Local conversation copy")
        status.lineBreakMode = .byTruncatingTail
        let originalAvailable = AITopicActions.desktopURL(content.topic) != nil
        openButton.title = originalAvailable ? L10n.local("打开原会话", "Open original") : L10n.local("复制继续命令", "Copy resume command")
        openButton.isEnabled = originalAvailable || !content.topic.resumeCommand.isEmpty
        openButton.onPress = { [weak self] in
            if originalAvailable { self?.onOpen?() } else { self?.onResume?() }
        }
        copyButton.onPress = { [weak self] in self?.onCopy?() }
        collectButton.onPress = { [weak self] in
            guard let self else { return }
            let excerpts = content.selectedExcerpts(self.textView.selectedRange())
            guard !excerpts.isEmpty else { self.showStatus(L10n.local("先选中要保留的对话文字。", "Select the conversation text you want to keep.")); return }
            self.showStatus(self.onCollect?(excerpts) == true ? L10n.local("已加入收集篮，可与文件一起整理为继续资料。", "Added to the collection. Combine with files in a context pack.") : L10n.local("未加入：来源已关闭，或超过 100 项 / 128 KB 摘录上限。", "Not added: source disabled or 100-item / 128 KB excerpt limit reached."))
        }
        let scroll = scrollView, text = textView
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        text.isEditable = false; text.isSelectable = true; text.isRichText = true
        text.drawsBackground = false; text.textColor = .labelColor; text.font = .systemFont(ofSize: 14)
        text.textContainerInset = NSSize(width: 22, height: 16); text.isVerticallyResizable = true
        text.isHorizontallyResizable = false; text.autoresizingMask = .width; text.textContainer?.widthTracksTextView = true
        text.layoutManager?.allowsNonContiguousLayout = true
        text.textStorage?.setAttributedString(content.displayText); scroll.documentView = text
        [heading, scroll, status, copyButton, openButton, collectButton].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; surface.addSubview($0) }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: surface.topAnchor, constant: 8), heading.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 84), heading.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -24), heading.heightAnchor.constraint(equalToConstant: 22),
            scroll.topAnchor.constraint(equalTo: surface.topAnchor, constant: 48), scroll.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 4), scroll.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -4), scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -10),
            openButton.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -24), openButton.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -18), openButton.heightAnchor.constraint(equalToConstant: 34), openButton.widthAnchor.constraint(equalToConstant: originalAvailable ? 132 : 164),
            copyButton.trailingAnchor.constraint(equalTo: openButton.leadingAnchor, constant: -8), copyButton.centerYAnchor.constraint(equalTo: openButton.centerYAnchor), copyButton.widthAnchor.constraint(equalToConstant: 104), copyButton.heightAnchor.constraint(equalTo: openButton.heightAnchor),
            collectButton.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 24), collectButton.centerYAnchor.constraint(equalTo: openButton.centerYAnchor), collectButton.widthAnchor.constraint(equalToConstant: 152), collectButton.heightAnchor.constraint(equalTo: openButton.heightAnchor),
            status.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 26), status.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -26), status.bottomAnchor.constraint(equalTo: openButton.topAnchor, constant: -8), status.heightAnchor.constraint(equalToConstant: 18)
        ])
        if let term = query.split(whereSeparator: { $0.isWhitespace }).first {
            let range = (text.string as NSString).range(of: String(term), options: [.caseInsensitive, .diacriticInsensitive])
            if range.location != NSNotFound { initialMatch = range }
        }
        window.initialFirstResponder = textView
        window.center()
    }
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.contentView?.layoutSubtreeIfNeeded()
        // Scroll only after the text container has its actual viewport width.
        if let range = initialMatch {
            textView.setSelectedRange(range); textView.scrollRangeToVisible(range); initialMatch = nil
        }
    }
    func showStatus(_ message: String) { status.stringValue = message; status.toolTip = message }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class ConversationPreviewPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) { close() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" { close(); return true }
        return super.performKeyEquivalent(with: event)
    }
}
