import AppKit

/// One native glass surface per window; interior groups use inexpensive neutral
/// plates, never another live blur or the system's colored selection material.
final class GlassSection: FlippedView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.Surface.sectionRadius; layer?.cornerCurve = .continuous
        layer?.backgroundColor = Theme.Surface.section.cgColor
        layer?.borderColor = Theme.Surface.border.cgColor
        layer?.borderWidth = Theme.Surface.stroke
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class GlassButton: NSButton {
    enum Emphasis { case primary, secondary, quiet }
    let emphasis: Emphasis
    var onPress: (() -> Void)?
    private let label = FilterTitleView(), icon = NSImageView()
    private let symbol: String?
    private var tracking: NSTrackingArea?
    private var hovered = false
    init(_ title: String, symbol: String? = nil, emphasis: Emphasis = .secondary) {
        self.symbol = symbol; self.emphasis = emphasis
        super.init(frame: .zero)
        self.title = title; isBordered = false; setButtonType(.momentaryChange)
        target = self; action = #selector(pressed); font = Theme.Control.font
        wantsLayer = true; layer?.cornerRadius = Theme.Surface.controlRadius; layer?.cornerCurve = .continuous
        layer?.borderWidth = Theme.Surface.stroke
        label.font = font; label.stringValue = title; addSubview(label)
        if let symbol { icon.image = Theme.symbol(symbol, size: 14, weight: .medium); addSubview(icon) }
        icon.imageScaling = .scaleProportionallyUpOrDown
        setAccessibilityLabel(title); refresh(animated: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override var isEnabled: Bool { didSet { refresh(animated: false) } }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    @objc private func pressed() { onPress?() }
    override func keyDown(with event: NSEvent) {
        if isEnabled && [36, 49, 76].contains(event.keyCode) { onPress?() } else { super.keyDown(with: event) }
    }
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); refresh(animated: false); return result }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); refresh(animated: false); return result }
    override func highlight(_ flag: Bool) { super.highlight(flag); refresh(animated: true) }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; refresh(animated: true) }
    override func mouseExited(with event: NSEvent) { hovered = false; refresh(animated: true) }
    private func refresh(animated: Bool) {
        guard let layer else { return }
        let down = cell?.isHighlighted == true, primary = emphasis == .primary
        let fill = primary ? (down ? Theme.Control.primaryPressed : hovered ? Theme.Control.primaryHover : Theme.Control.primary) :
            (down ? Theme.Control.pressed : hovered ? Theme.Control.hover : emphasis == .quiet ? .clear : Theme.Control.secondary)
        let ink = (primary ? Theme.Control.primaryInk : emphasis == .quiet ? Theme.Ink.secondary : Theme.Ink.primary).withAlphaComponent(isEnabled ? 1 : 0.32)
        label.textColor = ink; icon.contentTintColor = ink
        layer.borderColor = (window?.firstResponder === self ? Theme.Control.focus : emphasis == .quiet ? .clear : Theme.Control.border).cgColor
        Theme.Motion.animate(layer, "backgroundColor", to: fill.withAlphaComponent(isEnabled ? fill.alphaComponent : fill.alphaComponent * 0.5).cgColor,
            using: animated ? Theme.Motion.basic(Theme.Motion.reduced ? 0 : Theme.Motion.hover) : nil)
    }
    override func layout() {
        super.layout()
        label.stringValue = title
        let gap: CGFloat = symbol == nil ? 0 : 22
        let width = min(Theme.textWidth(title, font: font!), max(0, bounds.width - 2 * Theme.Control.horizontalInset - gap))
        let x = (bounds.width - width - gap) / 2
        icon.frame = NSRect(x: x, y: (bounds.height - 14) / 2, width: 14, height: 14)
        label.frame = NSRect(x: x + gap, y: 0, width: width, height: bounds.height)
    }
    override func draw(_ dirtyRect: NSRect) {}
}

final class GlassListRow: NSTableRowView {
    private var hovered = false
    private var tracking: NSTrackingArea?
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func drawBackground(in dirtyRect: NSRect) {
        if hovered && !isSelected {
            Theme.Control.rowHover.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 3), xRadius: Theme.Surface.controlRadius, yRadius: Theme.Surface.controlRadius).fill()
        }
    }
    override func drawSelection(in dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 3), xRadius: Theme.Surface.controlRadius, yRadius: Theme.Surface.controlRadius)
        Theme.Control.rowSelected.setFill(); shape.fill()
        Theme.Control.border.setStroke(); shape.lineWidth = Theme.Surface.stroke; shape.stroke()
    }
}
