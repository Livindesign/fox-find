import AppKit

/// A native menu row with a real, accessible switch instead of a state checkmark.
final class MenuSwitchRow: NSView {
    let toggle = NSSwitch()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let activate: () -> Void
    init(title: String, image: NSImage?, activate: @escaping () -> Void) {
        self.activate = activate
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 32))
        autoresizingMask = [.width]
        icon.image = image; icon.imageScaling = .scaleProportionallyUpOrDown
        label.font = .menuFont(ofSize: 0)
        toggle.controlSize = .small; toggle.target = self; toggle.action = #selector(pressed)
        toggle.setAccessibilityIdentifier("menu.launchAtLogin")
        [icon, label, toggle].forEach(addSubview)
        update(title: title, enabled: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(title: String, enabled: Bool) {
        label.stringValue = title; toggle.setAccessibilityLabel(title)
        toggle.state = enabled ? .on : .off
        needsLayout = true
    }
    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 16, y: (bounds.height - 16) / 2, width: 16, height: 16)
        toggle.sizeToFit()
        toggle.frame.origin = NSPoint(x: bounds.width - toggle.frame.width - 16, y: (bounds.height - toggle.frame.height) / 2)
        label.frame = NSRect(x: 36, y: (bounds.height - 18) / 2, width: max(0, toggle.frame.minX - 48), height: 18)
    }
    @objc private func pressed() { activate() }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { pressed() }
    }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if [36, 49, 76].contains(event.keyCode) { pressed() }
        else { super.keyDown(with: event) }
    }
}
