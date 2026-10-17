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
    var displayText: NSAttributedString {
        let result = NSMutableAttributedString()
        func append(_ value: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor, spacing: CGFloat = 14) {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4; paragraph.paragraphSpacing = spacing
            result.append(NSAttributedString(string: value + "\n", attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph]))
        }
        append(topic.title, size: 21, weight: .semibold)
        if !topic.project.isEmpty { append(topic.project, size: 12, color: .secondaryLabelColor, spacing: 24) }
        for message in messages {
            let role = message.role == "user" ? L10n.local("你", "You") : message.role == "assistant" ? topic.provider.name : L10n.local("消息", "Message")
            append(role, size: 12, weight: .semibold, color: .secondaryLabelColor, spacing: 6)
            append(message.text, size: 14, spacing: 24)
        }
        if truncated { append(L10n.local("对话较长，此处仅显示部分内容。完整记录请在原应用查看。", "This is part of a long conversation. View the full record in the original app."), size: 12, color: .secondaryLabelColor) }
        return result
    }
}

/// Plain text only: messages are untrusted content, never rendered as executable HTML.
final class AIConversationWindow: NSWindowController {
    init(content: AIConversationContent, query: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = content.topic.title + " · " + content.topic.provider.name
        window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 480, height: 320)
        window.titlebarAppearsTransparent = true
        let surface = NSVisualEffectView(); surface.material = .underWindowBackground; surface.blendingMode = .behindWindow; surface.state = .active
        window.contentView = surface; window.isOpaque = false; window.backgroundColor = .clear
        let note = NSTextField(wrappingLabelWithString: L10n.local("本地对话副本 · ", "Local conversation copy · ") + content.topic.provider.name + (content.truncated ? L10n.local(" · 内容已截断", " · Truncated") : ""))
        note.font = .systemFont(ofSize: 12); note.textColor = .secondaryLabelColor
        let scroll = ResultScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        let text = NSTextView(); text.isEditable = false; text.isSelectable = true; text.isRichText = true
        text.drawsBackground = false; text.textColor = .labelColor; text.font = .systemFont(ofSize: 14)
        text.textContainerInset = NSSize(width: 18, height: 18); text.isVerticallyResizable = true
        text.isHorizontallyResizable = false; text.autoresizingMask = .width; text.textContainer?.widthTracksTextView = true
        text.textStorage?.setAttributedString(content.displayText); scroll.documentView = text
        [note, scroll].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; surface.addSubview($0) }
        NSLayoutConstraint.activate([
            note.topAnchor.constraint(equalTo: surface.topAnchor, constant: 16), note.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 20), note.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 12), scroll.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 4), scroll.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -4), scroll.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -12)
        ])
        // Jump to the first literal keyword in the loaded text, with no global keyboard events.
        if let term = query.split(whereSeparator: { $0.isWhitespace }).first {
            let range = (text.string as NSString).range(of: String(term), options: [.caseInsensitive, .diacriticInsensitive])
            if range.location != NSNotFound { text.setSelectedRange(range); text.scrollRangeToVisible(range) }
        }
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
