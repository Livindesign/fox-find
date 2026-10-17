import AppKit
import OilFindCore

final class StateView: FlippedView {
    enum State { case idle, empty, indexing }
    let state: State
    private var diagnostic: QueryDiagnostic?
    private var hasNoAccess = false
    private(set) var count = 0
    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let titleLabel = Theme.label(14, .medium, .secondaryLabelColor)
    private let noAccess = Theme.label(12, .regular, .secondaryLabelColor)
    let grant = NSButton(title: L10n.text("empty.grant"), target: nil, action: nil)
    private(set) var assistance: SupplementarySearchStatus?
    var onAssistance: (() -> Void)?
    let assistanceButton = NSButton(title: "", target: nil, action: nil)
    private let body = Theme.label(12, .regular, .tertiaryLabelColor)
    init(_ state: State) {
        self.state = state
        super.init(frame: .zero); wantsLayer = true
        titleLabel.alignment = .center; body.alignment = .center
        [icon, spinner, titleLabel, body, noAccess, grant, assistanceButton].forEach(addSubview)
        assistanceButton.target = self; assistanceButton.action = #selector(openAssistance); assistanceButton.bezelStyle = .rounded; assistanceButton.isHidden = true
        noAccess.stringValue = L10n.text("empty.noAccess"); noAccess.alignment = .center
        grant.target = self; grant.action = #selector(grantAccess); grant.bezelStyle = .rounded
        noAccess.isHidden = true; grant.isHidden = true
        body.maximumNumberOfLines = 3; body.lineBreakMode = .byWordWrapping
        spinner.style = .spinning; spinner.controlSize = .regular
        icon.isHidden = state == .indexing; spinner.isHidden = state != .indexing
        switch state {
        case .idle:
            icon.image = Theme.symbol("text.magnifyingglass", size: 34, weight: .light); icon.contentTintColor = .tertiaryLabelColor
            titleLabel.stringValue = L10n.text("idle.title"); body.stringValue = L10n.text("idle.body")
        case .empty:
            icon.image = Theme.symbol("magnifyingglass", size: 34, weight: .light); icon.contentTintColor = .tertiaryLabelColor
            titleLabel.stringValue = L10n.text("empty.title"); body.stringValue = L10n.text("empty.body")
        case .indexing:
            titleLabel.stringValue = L10n.text("indexing.title"); updateCount(0); spinner.startAnimation(nil)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func grantAccess() { Permissions.openSettings() }
    @objc private func openAssistance() { onAssistance?() }
    func configure(diagnostic: QueryDiagnostic?, hasNoAccess: Bool, assistance: SupplementarySearchStatus? = nil) {
        self.assistance = diagnostic == nil ? assistance : nil
        self.diagnostic = diagnostic; self.hasNoAccess = hasNoAccess
        titleLabel.stringValue = L10n.text(diagnostic == nil ? "empty.title" : "diag.title")
        body.stringValue = diagnostic.map(L10n.diagnostic) ?? L10n.text("empty.body")
        if let assistance = self.assistance {
            titleLabel.stringValue = assistance.title; body.stringValue = assistance.message
            assistanceButton.title = assistance.actionTitle
        }
        assistanceButton.isHidden = self.assistance == nil || self.assistance?.actionTitle.isEmpty == true
        noAccess.isHidden = !hasNoAccess; grant.isHidden = !hasNoAccess; needsLayout = true
    }
    func updateCount(_ count: Int) { self.count = count; body.stringValue = L10n.text("indexing.body", Presentation.countText(count)) }
    func localize() {
        noAccess.stringValue = L10n.text("empty.noAccess"); grant.title = L10n.text("empty.grant")
        switch state {
        case .idle: titleLabel.stringValue = L10n.text("idle.title"); body.stringValue = L10n.text("idle.body")
        case .empty: configure(diagnostic: diagnostic, hasNoAccess: hasNoAccess, assistance: assistance)
        case .indexing: titleLabel.stringValue = L10n.text("indexing.title"); updateCount(count)
        }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let iconSize: CGFloat = state == .indexing ? 32 : 34
        let bodyHeight: CGFloat = assistance == nil ? 36 : 54
        let actionHeight: CGFloat = assistanceButton.isHidden ? 0 : 44
        let total = iconSize + 14 + 20 + 6 + bodyHeight + actionHeight + (grant.isHidden ? 0 : 64)
        var y = (bounds.height - total) / 2
        icon.frame = NSRect(x: (bounds.width - iconSize) / 2, y: y, width: iconSize, height: iconSize)
        spinner.frame = icon.frame; y += iconSize + 14
        titleLabel.frame = NSRect(x: 24, y: y, width: bounds.width - 48, height: 20); y += 26
        let bodyWidth = min(520, max(0, bounds.width - 48))
        body.frame = NSRect(x: (bounds.width - bodyWidth) / 2, y: y, width: bodyWidth, height: bodyHeight)
        y += bodyHeight + 10
        let buttonWidth = min(bounds.width - 48, max(180, assistanceButton.intrinsicContentSize.width + 24))
        assistanceButton.frame = NSRect(x: (bounds.width - buttonWidth) / 2, y: y, width: buttonWidth, height: 30)
        y += actionHeight
        noAccess.frame = NSRect(x: 24, y: y, width: bounds.width - 48, height: 18)
        grant.frame = NSRect(x: (bounds.width - 150) / 2, y: y + 24, width: 150, height: 28)
    }
}
