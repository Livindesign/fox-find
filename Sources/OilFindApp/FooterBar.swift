import AppKit
import QuartzCore
import OilFindCore

private final class KeyHint: FlippedView {
    var key: String { didSet { needsLayout = true; needsDisplay = true } }
    private let label = Theme.label(11.5, .regular, .tertiaryLabelColor)
    private let keyFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)
    private var capWidth: CGFloat { max(28, Theme.textWidth(key, font: keyFont) + 14) }
    var desiredWidth: CGFloat { capWidth + 8 + Theme.textWidth(label.stringValue, font: label.font!) + 4 }
    func localize(_ text: String) { label.stringValue = text; needsLayout = true }
    init(_ key: String, _ text: String) {
        self.key = key; super.init(frame: .zero); label.stringValue = text; addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); label.frame = NSRect(x: capWidth + 8, y: (bounds.height - 16) / 2, width: desiredWidth - capWidth - 8, height: 16) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.09).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: (bounds.height - 25) / 2, width: capWidth, height: 25), xRadius: 5, yRadius: 5).fill()
        let size = (key as NSString).size(withAttributes: [.font: keyFont])
        (key as NSString).draw(at: NSPoint(x: (capWidth - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: [.font: keyFont, .foregroundColor: NSColor.secondaryLabelColor])
    }
}

final class FooterBar: FlippedView {
    enum Context { case files, application, calculation, link }
    var context: Context = .files { didSet { if context != oldValue { localize() } } }
    private let toast = Theme.label(11.5, .regular, .labelColor)
    private var toastTimer: Timer?
    private var toastContent: (ToastKind, String)?
    private let status = Theme.label(11.5, .regular, .tertiaryLabelColor)
    private let hints = [KeyHint("↩", L10n.text("hint.open")), KeyHint("⌘Y", L10n.text("hint.preview"))]
    let actions = ToolbarButton()
    var onActions: (() -> Void)?
    private let syntax = KeyHint("⌘/", L10n.text("hint.help"))
    var spacePreview = false { didSet { updatePreviewKey() } }
    var previewKey: String { spacePreview ? L10n.text("hint.space") : "⌘Y" }
    private func updatePreviewKey() { hints[1].key = previewKey; needsLayout = true }
    var warning = false { didSet { status.textColor = warning ? .systemOrange : .tertiaryLabelColor; needsLayout = true } }
    var statusHelp = "" { didSet { guard oldValue != statusHelp else { return }; status.toolTip = text + (statusHelp.isEmpty ? "" : "\n" + statusHelp); status.setAccessibilityHelp(status.toolTip) } }
    var text: String { get { status.stringValue } set { guard status.stringValue != newValue else { return }; status.stringValue = newValue; status.toolTip = newValue + (statusHelp.isEmpty ? "" : "\n" + statusHelp) } }
    // Hints explain the keyboard controls even when there is no selected result.
    // Action availability remains controlled by the search controller.
    var actionable = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        status.wantsLayer = true; toast.wantsLayer = true; toast.alphaValue = 0
        status.lineBreakMode = .byTruncatingMiddle
        toast.lineBreakMode = .byTruncatingMiddle
        addSubview(status); addSubview(toast); hints.forEach(addSubview); addSubview(syntax); addSubview(actions)
        actions.shortcutHint = "⌘K"; actions.title = L10n.text("hint.actions"); actions.toolTip = L10n.text("workspace.actions")
        actions.setAccessibilityLabel(L10n.text("workspace.actions"))
        actions.onPress = { [weak self] in self?.onActions?() }
        actionable = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func showToast(_ kind: ToastKind, value: String, snapshot: Bool = false) {
        toastContent = (kind, value)
        toastTimer?.invalidate()
        toast.stringValue = Presentation.toastText(kind, value: value, chinese: L10n.chinese)
        let wasVisible = (toast.layer?.presentation()?.opacity ?? Float(toast.alphaValue)) > 0
        Theme.Motion.opacity(status, to: 0, using: snapshot ? nil : Theme.Motion.basic(Theme.Motion.toastIn))
        Theme.Motion.opacity(toast, to: 1, using: snapshot ? nil : Theme.Motion.basic(Theme.Motion.toastIn))
        if let layer = toast.layer {
            Theme.Motion.animate(layer, "transform.translation.y", to: 0, using: snapshot ? nil : Theme.Motion.basic(Theme.Motion.toastIn, .easeOut), from: wasVisible ? nil : Theme.Motion.toastOffset)
        }
        if !snapshot {
            toastTimer = Timer.scheduledTimer(withTimeInterval: Theme.Motion.toastIn + Theme.Motion.toastStay, repeats: false) { [weak self] _ in
                guard let self else { return }
                Theme.Motion.opacity(self.toast, to: 0, using: Theme.Motion.basic(Theme.Motion.toastOut))
                Theme.Motion.opacity(self.status, to: 1, using: Theme.Motion.basic(Theme.Motion.toastOut))
            }
        }
    }
    func localize() {
        updatePreviewKey()
        for (hint, key) in zip(hints, ["open", "preview"]) { hint.localize(L10n.text("hint." + key)) }
        if context == .calculation { hints[0].localize(L10n.text("quick.copy")) }
        if context == .application { hints[0].localize(L10n.text("quick.launch")) }
        syntax.localize(L10n.text("hint.help"))
        actions.shortcutHint = "⌘K"; actions.title = L10n.text("hint.actions"); actions.setAccessibilityLabel(L10n.text("workspace.actions"))
        if let (kind, value) = toastContent { toast.stringValue = Presentation.toastText(kind, value: value, chinese: L10n.chinese) }
        needsLayout = true
    }
    deinit { toastTimer?.invalidate() }
    override func layout() {
        super.layout()
        let visibleHints = (context == .calculation || context == .link || context == .application ? [hints[0]] : hints) + [syntax]
        for hint in hints { hint.isHidden = !visibleHints.contains(where: { $0 === hint }) }
        let actionWidth = Theme.textWidth(actions.title, font: actions.font!) + actions.shortcutWidth + 24
        let center = bounds.height > 40 ? bounds.height - 32 - 12.5 : bounds.midY
        actions.frame = NSRect(x: bounds.width - 24 - actionWidth, y: center - 15, width: actionWidth, height: 30)
        var x = actions.frame.minX - 20 - visibleHints.reduce(0) { $0 + $1.desiredWidth } - CGFloat(visibleHints.count - 1) * 20
        status.frame = NSRect(x: 24, y: center - 8, width: max(0, x - 38), height: 16)
        toast.frame = status.frame
        for hint in visibleHints { hint.frame = NSRect(x: x, y: center - 12.5, width: hint.desiredWidth, height: 25); x += hint.desiredWidth + 20 }
    }
}
