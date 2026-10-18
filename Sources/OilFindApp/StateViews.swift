import AppKit
import OilFindCore

final class StateView: FlippedView {
    enum State { case idle, empty, indexing }
    let state: State
    private var diagnostic: QueryDiagnostic?
    private var hasNoAccess = false
    private(set) var count = 0
    var onFolder: ((String) -> Void)?
    private var folderButtons: [NSButton] = []
    private let folderNames = ["Downloads", "Documents", "Desktop", "Applications"]
    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let titleLabel = Theme.label(14, .medium, .secondaryLabelColor)
    private let noAccess = Theme.label(12, .regular, .secondaryLabelColor)
    let grant = GlassButton(L10n.local("管理权限…", "Permissions…"), symbol: "lock.open", emphasis: .quiet)
    private let accessDivider = TintPlate(radius: 0) { _ in Theme.Surface.divider }
    private(set) var assistance: SupplementarySearchStatus?
    var onAssistance: (() -> Void)?
    let assistanceButton = GlassButton("", symbol: "arrow.right", emphasis: .secondary)
    private let body = Theme.label(12, .regular, .tertiaryLabelColor)
    init(_ state: State) {
        self.state = state
        super.init(frame: .zero); wantsLayer = true
        titleLabel.alignment = state == .idle ? .center : .left; body.alignment = titleLabel.alignment
        [icon, spinner, titleLabel, body, noAccess, grant, assistanceButton, accessDivider].forEach(addSubview)
        assistanceButton.onPress = { [weak self] in self?.onAssistance?() }; assistanceButton.isHidden = true
        noAccess.stringValue = L10n.local("部分文件夹未授权", "Some folders need access"); noAccess.alignment = .left
        noAccess.toolTip = L10n.text("empty.noAccess")
        grant.onPress = { Permissions.openSettings() }; accessDivider.isHidden = true
        noAccess.isHidden = true; grant.isHidden = true
        body.cell?.usesSingleLineMode = false; body.cell?.wraps = true
        body.maximumNumberOfLines = 3; body.lineBreakMode = .byWordWrapping
        spinner.style = .spinning; spinner.controlSize = .regular
        icon.isHidden = state == .indexing; spinner.isHidden = state != .indexing
        switch state {
        case .idle:
            for (index, glyph) in ["face-downloads", "face-document", "face-desktop", "face-applications"].enumerated() {
                let button = NSButton(title: "", target: self, action: #selector(openFolder(_:)))
                button.image = FunctionalIcons.image(glyph)?.copy() as? NSImage; button.image?.size = NSSize(width: 30, height: 30)
                button.imagePosition = .imageAbove; button.imageScaling = .scaleProportionallyDown
                button.isBordered = false; button.font = .systemFont(ofSize: 11); button.contentTintColor = .secondaryLabelColor
                button.tag = index; folderButtons.append(button); addSubview(button)
            }
            localizeFolders()
            icon.isHidden = true
            titleLabel.font = .systemFont(ofSize: 20, weight: .medium)
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
    private func localizeFolders() {
        let names = L10n.chinese ? ["下载", "文稿", "桌面", "应用程序"] : ["Downloads", "Documents", "Desktop", "Applications"]
        for (button, name) in zip(folderButtons, names) { button.title = name; button.setAccessibilityLabel(name) }
    }
    @objc private func openFolder(_ sender: NSButton) {
        let name = folderNames[sender.tag]
        onFolder?(name == "Applications" ? "/Applications" : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(name).path)
    }
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
        titleLabel.toolTip = titleLabel.stringValue; body.toolTip = body.stringValue
        assistanceButton.setAccessibilityLabel(assistanceButton.title)
        noAccess.isHidden = !hasNoAccess; grant.isHidden = !hasNoAccess; accessDivider.isHidden = !hasNoAccess; needsLayout = true
    }
    func updateCount(_ count: Int) { self.count = count; body.stringValue = L10n.text("indexing.body", Presentation.countText(count)) }
    func localize() {
        localizeFolders()
        noAccess.stringValue = L10n.local("部分文件夹未授权", "Some folders need access"); noAccess.toolTip = L10n.text("empty.noAccess")
        grant.title = L10n.local("管理权限…", "Permissions…"); grant.setAccessibilityLabel(grant.title)
        switch state {
        case .idle: titleLabel.stringValue = L10n.text("idle.title"); body.stringValue = L10n.text("idle.body")
        case .empty: configure(diagnostic: diagnostic, hasNoAccess: hasNoAccess, assistance: assistance)
        case .indexing: titleLabel.stringValue = L10n.text("indexing.title"); updateCount(count)
        }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        if state == .idle {
            let center = bounds.midY - 64
            titleLabel.frame = NSRect(x: 24, y: center, width: bounds.width - 48, height: 30)
            body.frame = NSRect(x: 24, y: center + 40, width: bounds.width - 48, height: 36)
            let total: CGFloat = 352
            for (index, button) in folderButtons.enumerated() {
                button.frame = NSRect(x: (bounds.width - total) / 2 + CGFloat(index) * 88, y: center + 90, width: 88, height: 68)
            }
            return
        }
        let width = min(440, max(0, bounds.width - 48)), x = (bounds.width - width) / 2
        let textX = x + 40, textWidth = max(0, width - 40)
        let bodyHeight = min(58, max(18, ceil(body.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 100)).height ?? 18)))
        let actionHeight: CGFloat = assistanceButton.isHidden ? 0 : 52
        let total = 24 + 8 + bodyHeight + actionHeight + (grant.isHidden ? 0 : 64)
        var y = max(24, (bounds.height - total) / 2)
        icon.frame = NSRect(x: x, y: y, width: 26, height: 26); spinner.frame = icon.frame
        titleLabel.frame = NSRect(x: textX, y: y, width: textWidth, height: 24); y += 32
        body.frame = NSRect(x: textX, y: y, width: textWidth, height: bodyHeight); y += bodyHeight + 16
        let buttonWidth = min(textWidth, Theme.textWidth(assistanceButton.title, font: Theme.Control.font) + 60)
        assistanceButton.frame = NSRect(x: textX, y: y, width: buttonWidth, height: 36); y += actionHeight
        accessDivider.frame = NSRect(x: textX, y: y, width: textWidth, height: 0.5); y += 12
        let grantWidth = min(140, textWidth * 0.43)
        noAccess.frame = NSRect(x: textX, y: y + 8, width: max(0, textWidth - grantWidth - 8), height: 18)
        grant.frame = NSRect(x: x + width - grantWidth, y: y, width: grantWidth, height: 34)
    }
}
