import AppKit
import SwiftUI

public struct SettingsGroup<Content: View>: View {
    private let header: AnyView, footer: AnyView
    private let content: Content
    public init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        header = AnyView(title.map { Text($0) }); footer = AnyView(EmptyView()); self.content = content()
    }
    public init<Header: View, Footer: View>(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header, @ViewBuilder footer: () -> Footer) {
        self.header = AnyView(header()); self.footer = AnyView(footer()); self.content = content()
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header.font(.system(size: 13, weight: .semibold)).padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 16) { content }
                .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
            footer.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 4)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.055), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SettingsGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> PanelSurface { PanelSurface(snapshot: false) }
    func updateNSView(_ nsView: PanelSurface, context: Context) {}
}

struct SettingsShell<Content: View>: View {
    @ObservedObject var model: SettingsModel
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(L10n.text("settings.title")).font(.system(size: 15, weight: .semibold)); Spacer() }
                .padding(.leading, 78).frame(height: 52)
            content.frame(maxHeight: .infinity)
        }.frame(width: 540, height: 600).background(SettingsGlass()).clipShape(RoundedRectangle(cornerRadius: 22)).ignoresSafeArea()
    }
}

struct SettingsToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 16) {
            configuration.label.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}

/// Adapts SwiftUI's native scroll container without replacing its keyboard or accessibility behavior.
struct SettingsScrollStyling: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsScrollBridge { SettingsScrollBridge() }
    func updateNSView(_ view: SettingsScrollBridge, context: Context) { view.attachWhenReady() }
}

final class SettingsScrollBridge: NSView {
    private weak var scroll: NSScrollView?
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var lastOrigin = NSPoint.zero
    private var lastMovement = Date.distantPast
    private var dragging = false
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attachWhenReady() }
    func attachWhenReady() { DispatchQueue.main.async { [weak self] in self?.attach() } }
    private func attach() {
        guard let viewport = enclosingScrollView, scroll !== viewport else { return }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        timer?.invalidate(); timer = nil
        scroll = viewport; lastOrigin = viewport.contentView.bounds.origin
        viewport.scrollerStyle = .overlay; viewport.autohidesScrollers = true
        let thumb = TransientResultScroller(); thumb.scrollerStyle = .overlay; thumb.alphaValue = 0
        thumb.onDrag = { [weak self] active in self?.dragging = active; self?.reveal() }
        viewport.verticalScroller = thumb
        viewport.contentView.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: viewport.contentView, queue: .main) { [weak self] _ in
            guard let self, let viewport = self.scroll else { return }
            let origin = viewport.contentView.bounds.origin
            if origin != self.lastOrigin { self.lastOrigin = origin; self.reveal() }
            viewport.verticalScroller?.needsDisplay = true
        }
    }
    private func reveal() {
        guard let thumb = scroll?.verticalScroller else { return }
        lastMovement = Date()
        if thumb.alphaValue != 1 { Theme.Motion.opacity(thumb, to: 1, using: Theme.Motion.basic(0.1)) }
        guard timer == nil else { return }
        let idle = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !self.dragging && Date().timeIntervalSince(self.lastMovement) > 0.75 {
                self.timer?.invalidate(); self.timer = nil
                if let thumb = self.scroll?.verticalScroller { Theme.Motion.opacity(thumb, to: 0, using: Theme.Motion.basic(0.2)) }
            }
        }
        timer = idle; RunLoop.main.add(idle, forMode: .common)
    }
    deinit { timer?.invalidate(); if let observer { NotificationCenter.default.removeObserver(observer) } }
}
