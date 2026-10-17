import AppKit
import Quartz

final class QuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    struct Revision: Equatable { let size: UInt64; let modified: Date }
    var selectedURL: (() -> URL?)?
    var selectedRevision: (() -> Revision?)?
    var onKey: ((NSEvent) -> Bool)?
    private(set) var displayedURL: URL?
    private(set) var reloadCount = 0
    private var pending: DispatchWorkItem?
    private var displayedRevision: Revision?
    var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }
    func toggle() {
        if isVisible { close() }
        else if let url = selectedURL?() {
            pending?.cancel(); displayedURL = url; displayedRevision = selectedRevision?()
            let panel = QLPreviewPanel.shared()!
            panel.makeKeyAndOrderFront(nil)
            panel.reloadData(); reloadCount += 1
        }
    }
    deinit { pending?.cancel() }
    func close() {
        pending?.cancel(); pending = nil
        if QLPreviewPanel.sharedPreviewPanelExists() { QLPreviewPanel.shared().orderOut(nil) }
        displayedURL = nil; displayedRevision = nil
    }
    func begin(_ panel: QLPreviewPanel) {
        displayedURL = selectedURL?(); displayedRevision = selectedRevision?()
        panel.dataSource = self; panel.delegate = self
    }
    func end(_ panel: QLPreviewPanel) {
        pending?.cancel(); pending = nil; panel.dataSource = nil; panel.delegate = nil
    }
    func refresh() {
        guard isVisible else { return }
        pending?.cancel(); pending = nil
        guard let url = selectedURL?() else { close(); return }
        let revision = selectedRevision?()
        guard url != displayedURL || revision != displayedRevision else { return }
        // Index refreshes often reselect the same row. Do not restart the preview
        // provider for that file, and coalesce rapid arrow-key navigation.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isVisible, self.selectedURL?() == url, self.selectedRevision?() == revision else { return }
            self.pending = nil; self.displayedURL = url; self.displayedRevision = revision
            QLPreviewPanel.shared().reloadData(); self.reloadCount += 1
        }
        pending = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { displayedURL == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { displayedURL as NSURL? }
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        if event.keyCode == 49 { return onKey?(event) ?? false }
        if event.keyCode == 53 || (event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers?.lowercased() == "y") {
            close(); return true
        }
        if [125, 126, 116, 121, 115, 119].contains(event.keyCode) {
            return onKey?(event) ?? false
        }
        return false
    }
}
