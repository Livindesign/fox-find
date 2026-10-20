import AppKit

enum WorkflowPreview {
    static func render(_ value: WorkCollection) -> NSAttributedString {
        let result = NSMutableAttributedString()
        func line(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor = Theme.Ink.body, gap: CGFloat = 7) {
            let p = NSMutableParagraphStyle(); p.lineSpacing = 4; p.paragraphSpacing = gap
            result.append(NSAttributedString(string: text + "\n", attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: color, .paragraphStyle: p]))
        }
        line(value.title.isEmpty ? L10n.local("文件清单与对话摘录", "File list and conversation excerpts") : value.title, size: 17, weight: .semibold, color: Theme.Ink.primary, gap: 15)
        if !value.instructions.isEmpty {
            line(L10n.local("下一步", "Next steps"), size: 10.5, weight: .medium, color: Theme.Ink.muted)
            line(value.instructions, gap: 16)
        }
        if !value.files.isEmpty {
            line(L10n.local("文件引用", "File references") + " · \(value.files.count)", size: 10.5, weight: .medium, color: Theme.Ink.muted)
            for file in value.files {
                line(file.name, weight: .medium, gap: 2)
                line(file.path, size: 10, color: Theme.Ink.muted, gap: 10)
            }
        }
        for excerpt in value.excerpts {
            line(L10n.local("对话摘录", "Conversation excerpt") + " · " + excerpt.provider, size: 10.5, weight: .medium, color: Theme.Ink.muted)
            line(excerpt.title, weight: .medium, gap: 4)
            line(excerpt.text)
            line(L10n.local("消息", "Message") + " \(excerpt.message) · \(excerpt.role) · UTF-16 +\(excerpt.offset)", size: 10, color: Theme.Ink.muted, gap: 16)
        }
        if value.count == 0 && value.instructions.isEmpty {
            line(L10n.local("加入内容后，这里会显示可复制的文件路径与对话摘录。", "Add items to preview the file paths and excerpts you can copy."), color: Theme.Ink.muted)
        }
        return result
    }
}
