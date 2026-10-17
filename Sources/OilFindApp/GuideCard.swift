import AppKit
import SwiftUI
import OilFindCore

private struct GuideGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView(); view.material = .popover; view.blendingMode = .behindWindow; view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// A finite demonstration, not a permanent attention-grabbing loop.
private struct GuideKeycaps: View {
    let page: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = 0
    private var keys: [String] { page == 1 ? ["⌘", "⇧", "L"] : ["⌘", "K"] }
    var body: some View {
        HStack(spacing: 9) {
            ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                let pressed = phase == 2 || (phase == 1 && index < keys.count - 1)
                Text(key).font(.system(size: 29, weight: .light)).frame(width: 56, height: 56)
                    .background(LinearGradient(colors: [Color.primary.opacity(0.08), Color.primary.opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12))
                    .background(Color(nsColor: Theme.accent).opacity(pressed ? 0.23 : 0), in: RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(pressed ? 0.02 : 0.16), radius: pressed ? 1 : 5, y: pressed ? 0 : 4)
                    .scaleEffect(pressed && !reduceMotion ? 0.94 : 1)
                    .offset(y: pressed && !reduceMotion ? 3 : 0)
            }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(keys.joined())
        .task(id: "\(page)-\(reduceMotion)") {
            phase = 0
            guard !reduceMotion else { return }
            do {
                try await Task.sleep(nanoseconds: 380_000_000)
                withAnimation(.easeOut(duration: 0.16)) { phase = 1 }
                try await Task.sleep(nanoseconds: 170_000_000)
                withAnimation(.easeOut(duration: 0.12)) { phase = 2 }
                try await Task.sleep(nanoseconds: 320_000_000)
                withAnimation(.interpolatingSpring(stiffness: 240, damping: 22)) { phase = 0 }
            } catch { phase = 0 }
        }
    }
}

private struct GuideArtwork: View {
    let image: NSImage
    let identity: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = false
    var body: some View {
        Image(nsImage: image).resizable().scaledToFit().frame(width: 260, height: 174)
            .scaleEffect(1.15).frame(width: 260, height: 200)
            .offset(x: settled || reduceMotion ? 0 : -6, y: settled || reduceMotion ? 0 : 10)
            .opacity(settled ? 1 : 0.5)
            .task(id: identity) {
                settled = false
                do { try await Task.sleep(nanoseconds: 120_000_000) } catch { return }
                withAnimation(.easeOut(duration: reduceMotion ? 0.1 : 0.65)) { settled = true }
            }.accessibilityHidden(true)
    }
}

struct GuideCard: View {
    @ObservedObject var model: GuideModel
    @ObservedObject private var appearance = AppearancePreferences.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var compact = false
    var primary: (() -> Void)?
    var secondary: (() -> Void)?
    private var background: NSColor { Theme.glassTint(dark: scheme == .dark) }
    private var motion: Animation { .easeOut(duration: reduceMotion ? 0.10 : 0.22) }
    private var art: String { model.cardNumber == 1 ? "01-search" : model.cardNumber == 2 ? "02-actions" : "03-content" }
    private func glyph(_ name: String, size: CGFloat) -> some View {
        Image(nsImage: Theme.symbol(name, size: size, weight: .regular)).resizable().scaledToFit().frame(width: size, height: size)
    }
    private func arrow(_ direction: Int) -> some View {
        Button { withAnimation(motion) { model.navigate(direction) } } label: {
            glyph("chevron.down", size: 15).rotationEffect(.degrees(direction < 0 ? 90 : -90))
                .frame(width: 34, height: 34).background(Color.primary.opacity(0.065), in: Circle()).contentShape(Circle())
        }.buttonStyle(.plain)
            .disabled(direction < 0 ? model.cardNumber == 1 : model.cardNumber == 3)
            .accessibilityLabel(L10n.local(direction < 0 ? "上一条说明" : "下一条说明", direction < 0 ? "Previous tip" : "Next tip"))
            .accessibilityIdentifier(direction < 0 ? "guide.previous" : "guide.next")
    }
    private var closeButton: some View {
        Button { model.dismiss() } label: { glyph("xmark", size: 13).frame(width: 30, height: 30).contentShape(Rectangle()) }
            .buttonStyle(.plain).help(L10n.local("关闭引导（Esc）", "Dismiss guide (Esc)"))
            .accessibilityLabel(L10n.local("关闭使用引导", "Dismiss getting started guide"))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !compact { HStack(spacing: 8) {
                if let logo = FunctionalIcons.art("fox-original") { Image(nsImage: logo).resizable().frame(width: 27, height: 27).clipShape(RoundedRectangle(cornerRadius: 7)) }
                Text("Fox Find").font(.system(size: 12, weight: .medium))
                Spacer()
                closeButton
            } }
            HStack(spacing: 20) {
                arrow(-1)
                Text("\(model.cardNumber) / 3").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).frame(width: 40)
                arrow(1)
            }.frame(maxWidth: .infinity).overlay(alignment: .trailing) { if compact { closeButton } }.padding(.top, compact ? 0 : 18)
            VStack(alignment: .leading, spacing: 0) {
                if !compact {
                    HStack(spacing: 9) {
                        if model.cardNumber == 3 { glyph("folder", size: 30).frame(width: 56, height: 56).background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12)) }
                        else {
                            GuideKeycaps(page: model.cardNumber)
                        }
                    }.frame(maxWidth: .infinity).padding(.top, 16)
                }
                Text(model.title).font(.system(size: compact ? 17 : 20, weight: .semibold)).tracking(-0.35)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, compact ? 6 : 22)
                Text(model.message).font(.system(size: 12)).lineSpacing(compact ? 2 : 3).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                if !compact, let image = FunctionalIcons.art(art) {
                    // Give the artwork all remaining space between copy and actions.
                    // Its transparent padding stays inside the card; only the subject grows.
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        GuideArtwork(image: image, identity: art)
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                } else {
                    Spacer(minLength: compact ? 4 : 8)
                }
                if let status = model.statusText {
                    Text(status).font(.system(size: 11)).monospacedDigit().lineLimit(2)
                        .foregroundStyle(Color(nsColor: appearance.readableAccent(on: background))).padding(.bottom, 8)
                }
                if let title = model.primaryTitle {
                    Button(title) { (primary ?? model.onPrimary)?() }
                        .buttonStyle(GuideButtonStyle(accent: appearance.accent, height: compact ? 32 : 36))
                        .disabled(!model.primaryEnabled).opacity(model.primaryEnabled ? 1 : 0.45).accessibilityIdentifier("guide.primary")
                }
                Button(model.step == .contentSetup && model.content.folders > 0 ? L10n.local("先搜文件名", "Search filenames") : L10n.local("稍后，我先自己试试", "I’ll explore on my own")) {
                    if let secondary { secondary() } else { model.dismiss() }
                }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).frame(minHeight: compact ? 24 : 30).padding(.top, compact ? 3 : 5).accessibilityIdentifier("guide.skip")
            }.id(model.cardStep)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: reduceMotion ? 0 : CGFloat(model.navigationDirection) * 12)), removal: .opacity))
                .animation(motion, value: model.cardStep)
        }
        .padding(compact ? 14 : 23).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { ZStack { GuideGlass(); Color(nsColor: background).opacity(reduceTransparency ? 1 : 0.68) } }
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.local("使用引导，第 \(model.cardNumber) 步，共 3 步", "Getting started, step \(model.cardNumber) of 3"))
        .accessibilityIdentifier("guide.card")
    }
}

private struct GuideButtonStyle: ButtonStyle {
    let accent: NSColor
    var height: CGFloat = 36
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity).frame(minHeight: height)
            .foregroundStyle(Color(nsColor: AppearancePreferences.foreground(on: accent)))
            .background(Color(nsColor: accent).opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

private final class GuidePanel: NSPanel {
    var onDismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDismiss?() } else { super.keyDown(with: event) }
    }
}

/// A child panel when there is desktop space; a compact window-local card otherwise.
/// Opening either presentation never changes the search field's first responder.
final class GuideOverlay: FlippedView {
    private let hosting: NSHostingView<GuideCard>
    private let model: GuideModel
    private let allowsDetached: Bool
    private var detached: GuidePanel?
    private weak var anchor: NSView?
    private var lower = false
    private(set) var anchorRect = NSRect.zero
    var cardFrame: NSRect { hosting.frame }
    var isDetachedKey: Bool { detached?.isKeyWindow == true }
    init(model: GuideModel, allowsDetached: Bool = false) {
        self.model = model; self.allowsDetached = allowsDetached
        hosting = NSHostingView(rootView: GuideCard(model: model, compact: true))
        super.init(frame: .zero)
        hosting.sizingOptions = []; hosting.wantsLayer = true
        addSubview(hosting)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isHidden: Bool { didSet { guard oldValue != isHidden else { return }; if isHidden { detached?.orderOut(nil) } else { needsLayout = true } } }
    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil { detachPanel() }
        super.viewWillMove(toSuperview: newSuperview)
    }
    private func detachPanel() {
        detached?.parent?.removeChildWindow(detached!); detached?.orderOut(nil); detached = nil
    }
    func hideDetached() { detached?.orderOut(nil) }
    func point(to view: NSView, lower: Bool) {
        if anchor !== view || self.lower != lower { anchor = view; self.lower = lower; needsLayout = true }
    }
    override func layout() {
        super.layout()
        guard let anchor else { return }
        anchorRect = convert(anchor.bounds, from: anchor).insetBy(dx: -4, dy: -3)
        if allowsDetached, !isHidden, let parent = window, parent.isVisible,
           (parent as? SearchPanel)?.hiding != true, let screen = parent.screen {
            let width: CGFloat = 306, height = min(610, screen.visibleFrame.height - 48)
            let right = parent.frame.maxX + 18, left = parent.frame.minX - width - 18
            let x = right + width <= screen.visibleFrame.maxX - 12 ? right : left
            if x >= screen.visibleFrame.minX + 12 {
                if detached == nil {
                    let panel = GuidePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                    panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.isReleasedWhenClosed = false
                    panel.delegate = parent.delegate
                    panel.onDismiss = { [weak model] in model?.dismiss() }
                    hosting.removeFromSuperview(); hosting.rootView = GuideCard(model: model)
                    panel.contentView = hosting; parent.addChildWindow(panel, ordered: .above); detached = panel
                }
                let y = max(screen.visibleFrame.minY + 16, parent.frame.maxY - height)
                detached?.appearance = parent.effectiveAppearance
                let target = NSRect(x: x, y: y, width: width, height: height)
                if detached?.frame != target { detached?.setFrame(target, display: true) }
                if detached?.isVisible == false { detached?.orderFront(nil) }; return
            }
        }
        if detached != nil { hosting.removeFromSuperview(); detachPanel(); hosting.rootView = GuideCard(model: model, compact: true); addSubview(hosting) }
        let width = min(348, max(240, bounds.width - 40))
        let height = min(model.cardHeight, max(200, bounds.height - Theme.searchHeight - Theme.footerHeight - 28))
        let x = max(20, min(bounds.width - width - 20, anchorRect.maxX - width))
        let y = lower ? bounds.height - Theme.footerHeight - height - 12 : max(Theme.searchHeight + 8, anchorRect.maxY + 10)
        hosting.frame = NSRect(x: x, y: max(Theme.searchHeight + 8, min(bounds.height - height - Theme.footerHeight - 8, y)), width: width, height: height)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, detached == nil else { return nil }
        let local = convert(point, from: superview)
        return hosting.frame.contains(local) ? super.hitTest(point) : nil
    }
}

struct GuideSettingsHeader: View {
    @ObservedObject var model: GuideModel
    var primary: () -> Void
    var returnToSearch: () -> Void
    var body: some View {
        if model.step == .contentSetup {
            GuideCard(model: model, compact: true, primary: primary, secondary: {
                if model.content.folders > 0 { returnToSearch() } else { model.dismiss() }
            }).frame(height: 300).padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 4)
        }
    }
}
