import AppKit
import QuartzCore
import CoreText

// Product-wide tokens. See docs/UI-DESIGN-SYSTEM.md before adding UI.
enum Theme {
    enum Surface {
        static let windowRadius: CGFloat = 22, sectionRadius: CGFloat = 14, controlRadius: CGFloat = 10
        static let stroke: CGFloat = 0.5
        static let section = NSColor(white: 1, alpha: 0.035)
        static let border = NSColor(white: 1, alpha: 0.075)
        static let divider = NSColor(white: 1, alpha: 0.07)
        static func tintOpacity(dark: Bool) -> CGFloat { dark ? 0.86 : 0.82 }
    }
    enum Ink {
        static let primary = NSColor(white: 0.94, alpha: 1)
        static let body = NSColor(white: 0.82, alpha: 1)
        static let secondary = NSColor(white: 0.68, alpha: 1)
        static let muted = NSColor(white: 0.56, alpha: 1)
        static let icon = NSColor(white: 0.75, alpha: 1)
    }
    enum Control {
        static let horizontalInset: CGFloat = 16, height: CGFloat = 36, footerHeight: CGFloat = 38
        static let secondary = NSColor(white: 1, alpha: 0.055)
        static let hover = NSColor(white: 1, alpha: 0.11), pressed = NSColor(white: 1, alpha: 0.15)
        static let primary = NSColor(white: 0.89, alpha: 1), primaryHover = NSColor(white: 0.98, alpha: 1)
        static let primaryPressed = NSColor(white: 0.72, alpha: 1), primaryInk = NSColor(white: 0.13, alpha: 1)
        static let border = NSColor(white: 1, alpha: 0.12), focus = NSColor(white: 1, alpha: 0.58)
        static let rowHover = NSColor(white: 1, alpha: 0.045), rowSelected = NSColor(white: 1, alpha: 0.095)
        static let textSelection = NSColor(white: 1, alpha: 0.17)
        static let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    }
    enum Space {
        static let small: CGFloat = 8, control: CGFloat = 12, group: CGFloat = 16, page: CGFloat = 24
    }
    enum Motion {
        static var panelIn: CASpringAnimation { spring(stiffness: 500, damping: 36) }
        static var selection: CASpringAnimation { spring(stiffness: 1400, damping: 64) }
        static var chip: CASpringAnimation { spring(stiffness: 900, damping: 50) }
        static let panelInFade = 0.12, panelOut = 0.13
        static let selectionRepeat = 0.045, crossfade = 0.12, press = 0.08
        static let toastIn = 0.16, toastOut = 0.12, toastStay = 2.4
        static let nudge = 0.22, hover = 0.08, keycap = 0.07, reducedFade = 0.1
        static let panelInScale: CGFloat = 0.96, panelInOffset: CGFloat = 8
        static let panelOutScale: CGFloat = 0.985, pressScale: CGFloat = 0.985
        static let accessoryScale: CGFloat = 0.8, toastOffset: CGFloat = 6, nudgeOffset: CGFloat = 9
        static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        private static func spring(stiffness: CGFloat, damping: CGFloat) -> CASpringAnimation {
            let animation = CASpringAnimation()
            animation.mass = 1; animation.stiffness = stiffness; animation.damping = damping
            animation.duration = animation.settlingDuration
            return animation
        }
        static func basic(_ duration: Double, _ curve: CAMediaTimingFunctionName = .easeInEaseOut) -> CABasicAnimation {
            let animation = CABasicAnimation(); animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: curve)
            return animation
        }
        // Read the presentation value before replacing the model target or its animation.
        static func animate(_ layer: CALayer, _ path: String, to value: Any, using animation: CABasicAnimation?, from: Any? = nil) {
            let start = from ?? layer.presentation()?.value(forKeyPath: path) ?? layer.value(forKeyPath: path)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.setValue(value, forKeyPath: path); layer.removeAnimation(forKey: path)
            if let animation {
                animation.keyPath = path; animation.fromValue = start; animation.toValue = value
                layer.add(animation, forKey: path)
            }
            CATransaction.commit()
        }
        static func reveal(_ view: NSView) {
            view.wantsLayer = true
            guard let layer = view.layer else { return }
            animate(layer, "opacity", to: Float(1), using: basic(reduced ? 0.1 : 0.18), from: Float(0))
            if !reduced { animate(layer, "transform.translation.y", to: 0, using: basic(0.2, .easeOut), from: 6) }
        }
        static func frame(_ view: NSView, to rect: NSRect, using animation: CABasicAnimation?) {
            // Repeated layout passes must not submit the same layer geometry.
            // An in-flight animation still needs to be cancelled or retargeted.
            if view.frame == rect, view.layer?.animation(forKey: "position") == nil,
               view.layer?.animation(forKey: "bounds") == nil { return }
            guard let layer = view.layer else { view.frame = rect; return }
            let position = layer.presentation()?.position ?? layer.position
            let bounds = layer.presentation()?.bounds ?? layer.bounds
            view.frame = rect
            animate(layer, "position", to: NSValue(point: layer.position), using: animation?.copy() as? CABasicAnimation, from: NSValue(point: position))
            animate(layer, "bounds", to: NSValue(rect: layer.bounds), using: animation?.copy() as? CABasicAnimation, from: NSValue(rect: bounds))
        }
        static func opacity(_ view: NSView, to value: Float, using animation: CABasicAnimation?) {
            if Float(view.alphaValue) == value, view.layer?.animation(forKey: "opacity") == nil { return }
            let start = view.layer?.presentation()?.opacity ?? Float(view.alphaValue)
            view.alphaValue = CGFloat(value)
            if let layer = view.layer { animate(layer, "opacity", to: value, using: animation, from: start) }
        }
    }
    static let panelSize = NSSize(width: 960, height: 650)
    static let corner = Surface.windowRadius
    static let searchHeight: CGFloat = 88
    static let filterHeight: CGFloat = 48
    static let toolsHeight: CGFloat = 44
    static let footerHeight: CGFloat = 78
    static let rowHeight: CGFloat = 68
    static var accent: NSColor { AppearancePreferences.shared.accent }
    static func glassTint(dark: Bool) -> NSColor {
        // Explicit sRGB keeps the approved charcoal value stable across color spaces.
        let level: CGFloat = dark ? 0.115 : 0.95
        return NSColor(srgbRed: level, green: level, blue: level, alpha: 1)
    }
    static func accentText(_ view: NSView) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let background = glassTint(dark: dark)
            return AppearancePreferences.shared.readableAccent(on: background)
        }
    }
    static func dark(_ view: NSView) -> Bool {
        view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
    static func pixel(_ view: NSView) -> CGFloat { 1 / (view.window?.backingScaleFactor ?? 2) }
    static func place(_ view: NSView, _ frame: NSRect) {
        if view.frame != frame { view.frame = frame }
    }
    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight) -> NSImage {
        if let image = FunctionalIcons.image(name) { return image }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "questionmark.square", accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: size, height: size))
        return image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight)) ?? image
    }
    static let filterCorner = Surface.controlRadius
    static func label(_ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        return label
    }
    static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// A passive backing plate never intercepts a row or button's native hit testing.
final class TintPlate: FlippedView {
    let radius: CGFloat
    let color: (NSView) -> NSColor
    init(radius: CGFloat, color: @escaping (NSView) -> NSColor) {
        self.radius = radius; self.color = color
        super.init(frame: .zero); wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        color(self).setFill(); NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
}

final class SeparatorView: NSView {
    override func draw(_ dirtyRect: NSRect) { NSColor.separatorColor.setFill(); bounds.fill() }
}

// Center the visible glyphs, not NSTextField's line box and top inset.
// Core Text also accounts for the fallback font used for Chinese titles.
final class FilterTitleView: NSView {
    var stringValue = "" { didSet { if stringValue != oldValue { rebuild() } } }
    var font: NSFont? { didSet { rebuild() } }
    var textColor: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }
    private var line: CTLine?
    private var ink = CGRect.zero
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    private func rebuild() {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13.5, weight: .medium),
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: stringValue, attributes: attributes))
        self.line = line; ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let line, !ink.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState(); defer { context.restoreGState() }
        textColor.setFill(); context.textMatrix = .identity
        context.textPosition = CGPoint(x: bounds.midX - ink.midX, y: bounds.midY - ink.midY)
        CTLineDraw(line, context)
    }
}

// Native buttons retain keyboard and accessibility behavior while drawing the specified chrome.
class ChromeButton: NSButton {
    enum Style { case filter, plain, primary, tonal }
    let chromeStyle: Style
    var active = false { didSet { if active != oldValue { updateFilterText(); needsDisplay = true } } }
    var hovered = false { didSet { normalLabel.textColor = hovered ? .labelColor : .secondaryLabelColor; needsDisplay = true } }
    var onPress: (() -> Void)?
    var trailingSymbol: NSImage?
    var leadingSymbol: NSImage? { didSet { filterIcon.image = leadingSymbol; needsLayout = true; needsDisplay = true } }
    private let filterIcon = NSImageView()
    var textTint: NSColor?
    private var tracking: NSTrackingArea?
    private let normalLabel = FilterTitleView()
    private let activeLabel = FilterTitleView()
    init(_ title: String, style: Style, size: CGFloat, weight: NSFont.Weight) {
        chromeStyle = style
        super.init(frame: .zero)
        self.title = title; font = .systemFont(ofSize: size, weight: weight)
        isBordered = false; bezelStyle = .regularSquare; setButtonType(.momentaryChange)
        target = self; action = #selector(pressed)
        if style == .filter {
            filterIcon.imageScaling = .scaleProportionallyUpOrDown; addSubview(filterIcon)
            for label in [normalLabel, activeLabel] {
                label.stringValue = title; label.font = font; label.wantsLayer = true; addSubview(label)
            }
            activeLabel.alphaValue = 0
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func refreshColors() {
        normalLabel.stringValue = title; activeLabel.stringValue = title
        activeLabel.textColor = Theme.accentText(self); needsDisplay = true
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshColors() }
    override var acceptsFirstResponder: Bool { false }
    @objc private func pressed() { onPress?() }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func layout() {
        super.layout()
        if chromeStyle == .filter {
            let inset: CGFloat = leadingSymbol == nil ? 16 : 39
            filterIcon.frame = NSRect(x: 16, y: (bounds.height - 17) / 2, width: 17, height: 17)
            [normalLabel, activeLabel].forEach { $0.frame = NSRect(x: inset, y: 0, width: max(0, bounds.width - inset - 16), height: bounds.height) }
        }
    }
    private func updateFilterText() {
        guard chromeStyle == .filter else { return }
        let animation = window?.isVisible == true ? Theme.Motion.basic(Theme.Motion.crossfade) : nil
        Theme.Motion.opacity(normalLabel, to: active ? 0 : 1, using: animation)
        Theme.Motion.opacity(activeLabel, to: active ? 1 : 0, using: animation?.copy() as? CABasicAnimation)
    }
    override func draw(_ dirtyRect: NSRect) {
        let pressed = cell?.isHighlighted == true
        var color: NSColor = hovered ? .labelColor : .secondaryLabelColor
        switch chromeStyle {
        case .filter:
            activeLabel.textColor = Theme.accentText(self)
            if !active && hovered {
                NSColor.labelColor.withAlphaComponent(0.06).setFill()
                NSBezierPath(roundedRect: bounds, xRadius: Theme.filterCorner, yRadius: Theme.filterCorner).fill()
            }
            filterIcon.contentTintColor = active ? Theme.accentText(self) : (hovered ? .labelColor : .secondaryLabelColor)
            return
        case .primary:
            let accent = Theme.accent
            let fill = pressed ? accent.blended(withFraction: 0.08, of: .black)! : hovered ? accent.blended(withFraction: 0.06, of: .white)! : accent
            fill.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
            color = AppearancePreferences.foreground(on: fill)
        case .tonal:
            let base = active ? Theme.accent : AppearancePreferences.shared.surface
            let fill = hovered || pressed ? base.blended(withFraction: pressed ? 0.13 : 0.07, of: AppearancePreferences.foreground(on: base))! : base
            fill.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
            let ink = AppearancePreferences.foreground(on: fill).withAlphaComponent(isEnabled ? 1 : 0.4)
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingMiddle
            let textSize = (title as NSString).size(withAttributes: [.font: font!])
            (title as NSString).draw(in: NSRect(x: 8, y: (bounds.height - textSize.height) / 2, width: max(0, bounds.width - 16), height: textSize.height + 1), withAttributes: [.font: font!, .foregroundColor: ink, .paragraphStyle: paragraph])
            return
        case .plain: break
        }
        let textSize = (title as NSString).size(withAttributes: [.font: font!])
        let extra: CGFloat = trailingSymbol == nil ? 0 : 16
        let x = (bounds.width - textSize.width - extra) / 2
        color = textTint ?? color
        (title as NSString).draw(at: NSPoint(x: x, y: (bounds.height - textSize.height) / 2), withAttributes: [.font: font!, .foregroundColor: isEnabled ? color : color.withAlphaComponent(0.4)])
        if let trailingSymbol {
            let rect = NSRect(x: x + textSize.width + 6, y: (bounds.height - 10) / 2, width: 10, height: 10)
            let tinted = trailingSymbol.copy() as! NSImage
            tinted.lockFocus(); color.set(); NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop); tinted.unlockFocus()
            tinted.draw(in: rect)
        }
    }
}
