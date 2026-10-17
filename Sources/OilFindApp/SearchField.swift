import AppKit
import QuartzCore

final class SearchEditor: NSTextView {
    var handleKey: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), handleKey?(event) == true { return }
        super.keyDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !hasMarkedText(), handleKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

// Center the text cell and its field editor in the same line box. The stock
// borderless cell aligns to its top inset, which shifts Chinese text upward.
final class CenteredSearchCell: NSTextFieldCell {
    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let text = super.setUpFieldEditorAttributes(textObj)
        // AppKit reapplies field-editor traits when editing begins, so set the
        // query-specific behavior here rather than only during view creation.
        if #available(macOS 15.0, *), let editor = text as? NSTextView { editor.writingToolsBehavior = .none }
        return text
    }
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var result = super.drawingRect(forBounds: rect)
        let height = ceil(NSLayoutManager().defaultLineHeight(for: font ?? .systemFont(ofSize: 21)))
        result.origin.y = rect.midY - height / 2
        result.size.height = height
        return result
    }
    override func select(withFrame rect: NSRect, in view: NSView, editor: NSText, delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: drawingRect(forBounds: rect), in: view, editor: editor, delegate: delegate, start: start, length: length)
    }
    override func edit(withFrame rect: NSRect, in view: NSView, editor: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: view, editor: editor, delegate: delegate, event: event)
    }
}

// Both accessories use identical hit targets and symbol layout. No native
// NSButton bezel/content inset participates in the icon's vertical position.
final class SearchIconButton: NSButton {
    private let icon = NSImageView()
    private var tracking: NSTrackingArea?
    private var hovered = false
    var onPress: (() -> Void)?
    init(symbol: String, size: CGFloat) {
        super.init(frame: .zero)
        title = ""; isBordered = false; setButtonType(.momentaryChange)
        target = self; action = #selector(pressed)
        icon.image = Theme.symbol(symbol, size: size, weight: .regular)
        icon.imageScaling = .scaleProportionallyUpOrDown; icon.imageAlignment = .alignCenter
        icon.contentTintColor = .secondaryLabelColor
        addSubview(icon)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    @objc private func pressed() { onPress?() }
    override func layout() {
        super.layout()
        icon.frame = NSRect(x: (bounds.width - 20) / 2, y: (bounds.height - 20) / 2, width: 20, height: 20)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func draw(_ dirtyRect: NSRect) {
        if hovered || cell?.isHighlighted == true {
            NSColor.labelColor.withAlphaComponent(cell?.isHighlighted == true ? 0.12 : 0.06).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        }
        if window?.firstResponder === self {
            Theme.accentText(self).setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
            ring.lineWidth = 2; ring.stroke()
        }
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; icon.contentTintColor = .labelColor; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; icon.contentTintColor = .secondaryLabelColor; needsDisplay = true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
}

private final class PassiveProgressIndicator: NSProgressIndicator {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class SearchField: FlippedView, NSTextFieldDelegate {
    let input = NSTextField()
    let editor = SearchEditor()
    private let glass = NSImageView()
    let clear = SearchIconButton(symbol: "xmark.circle.fill", size: 18)
    private let progress = PassiveProgressIndicator()
    let settings = SearchIconButton(symbol: "gearshape", size: 18)
    private var selectionObserver: NSObjectProtocol?
    private var clearVisible = false, progressVisible = false
    var onSettings: (() -> Void)?
    var onSelectionChange: (() -> Void)?
    var onChange: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    var indexing = false { didSet { updateAccessory() } }
    var text: String {
        get { input.stringValue }
        set { input.stringValue = newValue; updateAccessory() }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        glass.image = Theme.symbol("magnifyingglass", size: 19, weight: .medium)
        glass.contentTintColor = .secondaryLabelColor
        input.cell = CenteredSearchCell(textCell: "")
        input.isEditable = true; input.isSelectable = true
        input.font = .systemFont(ofSize: 25, weight: .regular); input.textColor = .labelColor
        input.isBordered = false; input.drawsBackground = false; input.focusRingType = .none
        input.cell?.isScrollable = true; input.cell?.usesSingleLineMode = true
        input.lineBreakMode = .byClipping
        input.placeholderAttributedString = NSAttributedString(string: L10n.text("placeholder"), attributes: [.font: input.font!, .foregroundColor: NSColor.placeholderTextColor])
        input.delegate = self
        editor.isFieldEditor = true
        // Queries are literal input. Do not start the system rewriting UI while
        // focusing a search field or changing the result presentation.
        if #available(macOS 15.0, *) { editor.writingToolsBehavior = .none }
        editor.textContainerInset = .zero; editor.textContainer?.lineFragmentPadding = 0
        selectionObserver = NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: editor, queue: .main) { [weak self] _ in self?.onSelectionChange?() }
        editor.handleKey = { [weak self] event in self?.onKey?(event) ?? false }
        clear.onPress = { [weak self] in self?.clearText() }
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        [clear, progress].forEach { $0.wantsLayer = true; $0.alphaValue = 0 }
        settings.onPress = { [weak self] in self?.onSettings?() }
        [glass, input, clear, progress, settings].forEach(addSubview)
        localize(); updateAccessory()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func localize() {
        input.placeholderAttributedString = NSAttributedString(string: L10n.text("placeholder"), attributes: [.font: input.font!, .foregroundColor: NSColor.placeholderTextColor])
        clear.toolTip = L10n.local("清除搜索", "Clear Search"); clear.setAccessibilityLabel(clear.toolTip)
        input.setAccessibilityLabel(L10n.local("搜索文件与内容", "Search files and content"))
        settings.toolTip = L10n.text("panel.settings")
        settings.setAccessibilityLabel(L10n.text("panel.settings"))
    }
    override func layout() {
        super.layout()
        glass.frame = NSRect(x: 24, y: (bounds.height - 22) / 2, width: 22, height: 22)
        input.frame = NSRect(x: 58, y: (bounds.height - 44) / 2, width: max(0, bounds.width - 164), height: 44)
        clear.frame = NSRect(x: bounds.width - 96, y: (bounds.height - 36) / 2, width: 36, height: 36)
        progress.frame = NSRect(x: clear.frame.midX - 8, y: bounds.midY - 8, width: 16, height: 16)
        settings.frame = NSRect(x: bounds.width - 52, y: (bounds.height - 36) / 2, width: 36, height: 36)
    }
    func focus(selectAll: Bool = false) {
        guard let window else { return }
        if input.currentEditor() == nil || input.currentEditor() !== window.firstResponder { window.makeFirstResponder(input) }
        if selectAll { input.selectText(nil) }
    }
    deinit { if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) } }
    func controlTextDidEndEditing(_ obj: Notification) { onSelectionChange?() }
    func controlTextDidChange(_ obj: Notification) { updateAccessory(); onChange?() }
    @objc private func clearText() { text = ""; focus(); onChange?() }
    private func accessory(_ view: NSView, visible: Bool) {
        let animate = window?.isVisible == true
        view.isHidden = false
        Theme.Motion.opacity(view, to: visible ? 1 : 0, using: animate ? Theme.Motion.basic(Theme.Motion.crossfade) : nil)

    }
    private func updateAccessory() {
        let showClear = !indexing && !text.isEmpty
        if clearVisible != showClear { clearVisible = showClear; accessory(clear, visible: showClear) }
        clear.isEnabled = showClear
        if progressVisible != indexing {
            progressVisible = indexing
            if indexing { progress.startAnimation(nil) }
            accessory(progress, visible: indexing)
            if !indexing {
                DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.crossfade) { [weak self] in
                    if self?.indexing == false { self?.progress.stopAnimation(nil) }
                }
            }
        }
    }
}
