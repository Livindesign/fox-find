import AppKit

/// Window-scoped interception runs before Quick Look's remote content view.
/// Space remains text input in an editable find field; it closes read-only previews.
final class PreviewKeys {
    private weak var window: NSWindow?
    private let close: () -> Void
    private var monitor: Any?
    init(window: NSWindow, close: @escaping () -> Void) {
        self.window = window; self.close = close
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    @discardableResult func handle(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let window, window.isVisible,
              event.window === window else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 53 || (flags == .command && event.charactersIgnoringModifiers?.lowercased() == "y") {
            close(); return true
        }
        guard event.keyCode == 49, flags.isEmpty else { return false }
        if let editor = window.firstResponder as? NSTextView, editor.isEditable || editor.hasMarkedText() { return false }
        close(); return true
    }
}
