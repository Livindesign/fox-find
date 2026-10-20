import AppKit

/// A search operation has one foreground destination. A previously opened tool
/// must not become the implicit return window when a preview is dismissed.
final class AuxiliaryWindows {
    private(set) weak var active: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private var revision = 0
    var onReturn: (() -> Void)?

    func present(_ window: NSWindow, from owner: NSWindow?) {
        suspend()
        active = window
        let token = revision
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            guard let self, self.revision == token else { return }
            self.clearObserver(); self.active = nil
            // AppKit picks its next key window after willClose. Restore our owner
            // afterwards, unless another operation has superseded this one.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.revision == token else { return }
                self.onReturn?()
            }
        }
        if let panel = window as? NSPanel { panel.hidesOnDeactivate = false }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        owner?.orderOut(nil)
    }

    /// Returning to search or opening another destination hides stale tools, but
    /// keeps their edits and selection. It never invokes a close/return callback.
    func suspend() {
        revision += 1; clearObserver()
        active?.orderOut(nil); active = nil
    }
    private func clearObserver() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
    }
    deinit { clearObserver() }
}
