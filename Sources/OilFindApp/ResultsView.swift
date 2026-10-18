import AppKit
import QuartzCore
import OilFindCore

struct ResultItem {
    let detail: SupplementaryHit?
    let id: UInt32
    let source: SearchSource
    let name: String, parentPath: String, path: String
    let size: UInt64, modified: Date, flags: UInt8, kind: UInt8
    func sameDisplay(as other: ResultItem) -> Bool {
        guard id == other.id, source.id == other.source.id, source.store === other.source.store,
              source.isOnline == other.source.isOnline, source.displayName == other.source.displayName,
              name == other.name, parentPath == other.parentPath, path == other.path,
              size == other.size, modified == other.modified, flags == other.flags, kind == other.kind else { return false }
        if let detail, let rhs = other.detail { return detail.samePresentation(as: rhs) }
        return detail == nil && other.detail == nil
    }
}

private final class ResultRow: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override var isEmphasized: Bool { get { true } set {} }
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
}

final class ResultCell: NSTableCellView {
    override var isFlipped: Bool { true }
    override var backgroundStyle: NSView.BackgroundStyle { get { .normal } set {} }
    private let icon = NSImageView()
    let favoriteButton = FavoriteStarButton(frame: .zero)
    let actionsButton = ToolbarButton(symbol: "ellipsis")
    private let nameLabel = Theme.label(13.5, .medium, .labelColor)
    private let detailLabel = Theme.label(11.5, .regular, .secondaryLabelColor)
    private let pathLabel = Theme.label(11.5, .regular, .secondaryLabelColor)
    private let dateLabel = Theme.label(11.5, .regular, .secondaryLabelColor)
    private let sizeLabel = Theme.label(11.5, .regular, .tertiaryLabelColor)
    private(set) var configuration = 0
    private var displayedItem: ResultItem?
    var displayedResult: ResultItem? { displayedItem }
    private var displayedQuery = ""
    private var displayingThumbnail = false
    private var detailTextWidth: CGFloat = 0
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        pathLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.lineBreakMode = .byTruncatingTail
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.imageAlignment = .alignCenter
        icon.wantsLayer = true
        dateLabel.alignment = .right; sizeLabel.alignment = .right
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        actionsButton.iconOnly = true; actionsButton.title = L10n.text("hint.actions")
        actionsButton.toolTip = L10n.text("workspace.actions"); actionsButton.setAccessibilityLabel(L10n.text("hint.actions"))
        [icon, nameLabel, detailLabel, pathLabel, dateLabel, sizeLabel, favoriteButton, actionsButton].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        let compact = bounds.width < 650
        Theme.place(icon, NSRect(x: 22, y: (bounds.height - 34) / 2, width: 34, height: 34))
        Theme.place(favoriteButton, NSRect(x: bounds.width - 74, y: (bounds.height - 30) / 2, width: 30, height: 30))
        Theme.place(actionsButton, NSRect(x: bounds.width - 42, y: (bounds.height - 30) / 2, width: 30, height: 30))
        let width = max(0, bounds.width - (compact ? 156 : 292))
        Theme.place(nameLabel, NSRect(x: 68, y: 11, width: width, height: 18))
        let detailWidth = detailLabel.isHidden ? 0 : min(width * 0.67, detailTextWidth)
        Theme.place(detailLabel, NSRect(x: 68, y: 34, width: detailWidth, height: 16))
        Theme.place(pathLabel, NSRect(x: 68 + detailWidth, y: 34, width: max(0, width - detailWidth), height: 16))
        if dateLabel.isHidden != compact { dateLabel.isHidden = compact; sizeLabel.isHidden = compact }
        Theme.place(dateLabel, NSRect(x: bounds.width - 206, y: 12, width: 124, height: 16))
        Theme.place(sizeLabel, NSRect(x: bounds.width - 206, y: 34, width: 124, height: 16))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateThumbnailStyle()
    }
    private func updateThumbnailStyle() {
        icon.layer?.cornerRadius = displayingThumbnail ? 3 : 0
        icon.layer?.masksToBounds = displayingThumbnail
        icon.layer?.borderWidth = displayingThumbnail ? 0.5 : 0
        effectiveAppearance.performAsCurrentDrawingAppearance {
            icon.layer?.borderColor = NSColor.separatorColor.cgColor
            icon.layer?.backgroundColor = (displayingThumbnail ? NSColor.quaternaryLabelColor.withAlphaComponent(0.08) : NSColor.clear).cgColor
        }
    }
    func configure(_ item: ResultItem, query: Query, icons: IconProvider, isFavorite: Bool = false, onToggleFavorite: (() -> Void)? = nil, onlyIfChanged: Bool = false) {
        if onlyIfChanged, displayedItem?.sameDisplay(as: item) == true, displayedQuery == query.raw,
           favoriteButton.isFavorite == isFavorite { return }
        displayedItem = item; displayedQuery = query.raw
        favoriteButton.isFavorite = isFavorite
        favoriteButton.onPress = onToggleFavorite; favoriteButton.isEnabled = onToggleFavorite != nil
        favoriteButton.toolTip = L10n.text(isFavorite ? "file.unfavorite" : "file.favorite") + " · " + item.name
        configuration += 1
        let token = configuration
        displayingThumbnail = false
        updateThumbnailStyle()
        let name = NSMutableAttributedString(string: item.name, attributes: [.font: nameLabel.font!, .foregroundColor: item.source.isOnline ? NSColor.labelColor : NSColor.tertiaryLabelColor])
        for range in item.source.isOnline ? Presentation.highlightRanges(name: item.name, query: query) : [] {
            name.addAttributes([.foregroundColor: Theme.accentText(self), .font: NSFont.systemFont(ofSize: 13.5, weight: .semibold)], range: range)
        }
        nameLabel.attributedStringValue = name
        pathLabel.stringValue = Presentation.abbreviate(path: item.parentPath, home: NSHomeDirectory()) + (item.source.isOnline ? "" : " · " + L10n.text("source.offline"))
        detailLabel.isHidden = item.detail == nil
        detailLabel.stringValue = ""
        detailTextWidth = 0
        if let detail = item.detail {
            let decoration = detail.presentation
            let text = NSMutableAttributedString(string: decoration.text + " · ", attributes: [.font: detailLabel.font!, .foregroundColor: NSColor.secondaryLabelColor])
            for range in decoration.highlights where NSMaxRange(range) <= text.length { text.addAttribute(.foregroundColor, value: Theme.accentText(self), range: range) }
            detailLabel.attributedStringValue = text; detailLabel.toolTip = decoration.text
            detailTextWidth = ceil(text.size().width)
        }
        dateLabel.stringValue = Presentation.dateText(item.modified, now: Date(), calendar: .current, chinese: L10n.chinese)
        sizeLabel.stringValue = item.kind == 2 ? L10n.text("meta.app") : item.flags & SiftFlag.dir != 0 && item.flags & SiftFlag.package == 0 ? L10n.text("meta.folder") : Presentation.sizeText(item.size)
        toolTip = item.path
        icon.image = icons.icon(name: item.name, path: item.path, flags: item.flags, kind: item.kind, resolveFileIcon: item.source.isOnline, isRelevant: { [weak self] in self?.configuration == token && self?.visibleRect.isEmpty == false }) { [weak self] image in
            guard let self, self.configuration == token, !self.displayingThumbnail else { return }
            self.icon.image = image
        }
        if item.detail?.thumbnail == true && item.source.isOnline {
            icons.thumbnail(path: item.path, modified: item.modified, isRelevant: { [weak self] in self?.configuration == token && self?.visibleRect.isEmpty == false }) { [weak self] image in
                guard let self, self.configuration == token else { return }
                self.icon.image = image
                self.displayingThumbnail = true
                self.updateThumbnailStyle()
            }
        }
        needsLayout = true
    }
}

private final class ResultTable: NSTableView {
    var minimumDocumentHeight: CGFloat = 0
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(NSSize(width: newSize.width, height: max(newSize.height, minimumDocumentHeight)))
    }
    var contextMenu: ((Int) -> NSMenu?)?
    var onPointerMove: (() -> Void)?
    var onPointerExit: (() -> Void)?
    var onPointerReselection: (() -> Void)?
    var onPointerSelection: (() -> Void)?
    private(set) var selectingWithPointer = false
    private var tracking: NSTrackingArea?
    override var acceptsFirstResponder: Bool { false }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); window?.acceptsMouseMovedEvents = true
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func mouseMoved(with event: NSEvent) { onPointerMove?() }
    override func mouseEntered(with event: NSEvent) { onPointerMove?() }
    override func mouseExited(with event: NSEvent) { onPointerExit?() }
    override func mouseDown(with event: NSEvent) {
        selectingWithPointer = true; defer { selectingWithPointer = false }
        if row(at: convert(event.locationInWindow, from: nil)) >= 0 { onPointerSelection?() }
        // Reselecting a row does not emit a selection-change notification.
        if selectedRow >= 0, row(at: convert(event.locationInWindow, from: nil)) == selectedRow { onPointerReselection?() }
        super.mouseDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        selectingWithPointer = true; defer { selectingWithPointer = false }
        onPointerSelection?()
        if row == selectedRow { onPointerReselection?() }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return contextMenu?(row)
    }
}

final class TransientResultScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    var onDrag: ((Bool) -> Void)?
    override var isFlipped: Bool { true }
    // The native hit target stays wide. Only the painted thumb is narrow.
    var thumbColor: NSColor { Theme.dark(enclosingScrollView ?? self) ? NSColor.white.withAlphaComponent(0.27) : NSColor.black.withAlphaComponent(0.24) }
    var thumbFrame: NSRect {
        let track = bounds.insetBy(dx: 0, dy: 4)
        let height = min(track.height, max(24, track.height * knobProportion))
        return NSRect(x: bounds.midX - 2, y: track.minY + max(0, track.height - height) * CGFloat(doubleValue), width: 4, height: height)
    }
    override func rect(for part: NSScroller.Part) -> NSRect {
        if part == .knob { let thumb = thumbFrame; return NSRect(x: bounds.minX, y: thumb.minY, width: bounds.width, height: thumb.height) }
        if part == .knobSlot { return bounds.insetBy(dx: 0, dy: 4) }
        return super.rect(for: part)
    }
    override func draw(_ dirtyRect: NSRect) { drawKnob() }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
    override func drawKnob() {
        guard knobProportion > 0, knobProportion < 1 else { return }
        thumbColor.setFill(); NSBezierPath(roundedRect: thumbFrame, xRadius: 2, yRadius: 2).fill()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        onDrag?(true); defer { onDrag?(false) }
        super.mouseDown(with: event)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        alphaValue < 0.05 ? nil : super.hitTest(point)
    }
}

final class ResultScrollView: NSScrollView {
    // Overriding scrollWheel disables AppKit responsive scrolling unless the
    // subclass explicitly opts back in. Our hook only schedules idle work;
    // the stationary viewport mask is safe for compositor-driven scrolling.
    override class var isCompatibleWithResponsiveScrolling: Bool { true }
    // macOS reapplies its preferred legacy style when attaching a window. Keep this
    // viewport's explicitly requested overlay behavior local to Fox Find.
    override var scrollerStyle: NSScroller.Style {
        get { super.scrollerStyle }
        set { super.scrollerStyle = .overlay }
    }
    var onScrollWheel: ((NSEvent) -> Void)?
    private let viewportMask = CALayer()
    private let edgeMask = CAGradientLayer()
    private let scrollerMask = CALayer()
    private var boundsObserver: NSObjectProtocol?
    private var idleTimer: Timer?
    private var lastScroll = Date.distantPast
    private var lastOrigin = NSPoint.zero
    private var draggingScroller = false
    private(set) var scrollIndicatorVisible = false
    private(set) var fadesTop = false, fadesBottom = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollerStyle = .overlay; autohidesScrollers = true
        let scroller = TransientResultScroller()
        scroller.scrollerStyle = .overlay; scroller.wantsLayer = true; scroller.alphaValue = 0
        scroller.onDrag = { [weak self] dragging in
            self?.draggingScroller = dragging; self?.revealScrollIndicator()
        }
        verticalScroller = scroller
        // The viewport mask stays stationary. A mask on the scrolling clip
        // layer changes on every pixel and invalidates AppKit's backing store.
        wantsLayer = true
        viewportMask.addSublayer(edgeMask); viewportMask.addSublayer(scrollerMask)
        scrollerMask.backgroundColor = NSColor.black.cgColor
        layer?.mask = viewportMask
        contentView.postsBoundsChangedNotifications = true
        edgeMask.startPoint = CGPoint(x: 0.5, y: 0); edgeMask.endPoint = CGPoint(x: 0.5, y: 1)
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: contentView, queue: .main) { [weak self] _ in
            guard let self else { return }
            let origin = self.contentView.bounds.origin
            if origin != self.lastOrigin { self.lastOrigin = origin; self.revealScrollIndicator() }
            self.updateEdgeFade()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { idleTimer?.invalidate(); if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) } }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hideScrollIndicator() }
    }
    func revealScrollIndicator() {
        guard (documentView?.frame.height ?? 0) > contentView.bounds.height + 1 else { return }
        lastScroll = Date()
        if !scrollIndicatorVisible {
            scrollIndicatorVisible = true
            if let verticalScroller { Theme.Motion.opacity(verticalScroller, to: 1, using: Theme.Motion.basic(0.1)) }
        }
        // One timer per scroll gesture, rather than a new scheduled job per frame.
        if idleTimer == nil {
            let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
                guard let self else { return }
                if !self.draggingScroller && Date().timeIntervalSince(self.lastScroll) >= 0.75 { self.hideScrollIndicator() }
            }
            idleTimer = timer; RunLoop.main.add(timer, forMode: .common)
        }
    }
    private func hideScrollIndicator() {
        idleTimer?.invalidate(); idleTimer = nil; scrollIndicatorVisible = false
        if let verticalScroller { Theme.Motion.opacity(verticalScroller, to: 0, using: Theme.Motion.basic(Theme.Motion.reduced ? 0.1 : 0.2)) }
    }
    override func layout() { super.layout(); updateEdgeFade() }
    override func reflectScrolledClipView(_ cView: NSClipView) { super.reflectScrolledClipView(cView); updateEdgeFade() }
    func updateEdgeFade() {
        let rect = contentView.bounds, documentHeight = documentView?.frame.height ?? 0
        guard rect.height > 0 else { return }
        let total = documentHeight + contentInsets.top + contentInsets.bottom
        if let scroller = verticalScroller {
            let proportion = min(1, rect.height / max(1, total))
            let progress = min(1, max(0, (rect.minY + contentInsets.top) / max(1, total - rect.height)))
            if scroller.knobProportion != proportion || scroller.doubleValue != progress {
                scroller.knobProportion = proportion; scroller.doubleValue = progress; scroller.needsDisplay = true
            }
        }
        let up = rect.minY > -contentInsets.top + 1
        let down = rect.maxY < documentHeight + contentInsets.bottom - 1
        let maskRect = bounds
        let scrollerRect = verticalScroller?.frame ?? .zero
        let changed = up != fadesTop || down != fadesBottom || edgeMask.frame != maskRect || scrollerMask.frame != scrollerRect || edgeMask.colors == nil
        fadesTop = up; fadesBottom = down
        guard changed else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        viewportMask.frame = maskRect; edgeMask.frame = maskRect
        // Keep the narrow thumb fully visible, outside the fading content area.
        scrollerMask.frame = scrollerRect
        if changed {
            let edge = min(24 / rect.height, 0.12)
            edgeMask.locations = [0, NSNumber(value: Double(edge)), NSNumber(value: Double(1 - edge)), 1]
            let top = isFlipped ? up : down, bottom = isFlipped ? down : up
            edgeMask.colors = [(top ? NSColor.clear : .black).cgColor, NSColor.black.cgColor, NSColor.black.cgColor, (bottom ? NSColor.clear : .black).cgColor]
        }
        CATransaction.commit()
    }
    override func scrollWheel(with event: NSEvent) {
        revealScrollIndicator(); onScrollWheel?(event); super.scrollWheel(with: event)
    }
}

// Refresh policy is independent of AppKit and uses the displayed result as its baseline.
enum ResultRefreshAction: Equatable { case replaceResult, reloadVisibleRows, reloadPreservingViewport, deferRefresh }

func resultRefreshAction(oldItems: [UInt32], newItems: [UInt32], sameStore: Bool,
                         sameVersion: Bool, scrolling: Bool, dragging: Bool) -> ResultRefreshAction {
    if scrolling || dragging { return .deferRefresh }
    if sameStore && oldItems == newItems { return sameVersion ? .replaceResult : .reloadVisibleRows }
    return .reloadPreservingViewport
}

final class ResultsView: FlippedView, NSTableViewDataSource, NSTableViewDelegate {
    private let scroll = ResultScrollView()
    var scrollOrigin: NSPoint { (gridMode ? grid.scroll : scroll).contentView.bounds.origin }
    func restoreScroll(_ point: NSPoint) {
        let viewport = gridMode ? grid.scroll : scroll
        viewport.contentView.scroll(to: viewport.contentView.constrainBoundsRect(NSRect(origin: point, size: viewport.contentSize)).origin)
        viewport.reflectScrolledClipView(viewport.contentView)
    }
    private let table = ResultTable()
    let grid = AssetGridView(frame: .zero)
    var gridMode = false { didSet {
        guard oldValue != gridMode else { return }
        scrollEnd?.cancel(); liveScrolling = false; wheelScrolling = false; momentumScrolling = false
        scroll.isHidden = gridMode; grid.isHidden = !gridMode
        if gridMode {
            if gridNeedsReload { reloadGrid() }
            else { grid.refreshVisibleItems(); grid.select(selectedRow, reveal: false) }
        } else {
            grid.suspendPreviews()
            let selectionChanged = table.selectedRow != selectedRow
            if tableNeedsReload { reloadTable() }
            syncTableSelection()
            if selectionChanged && selectedRow >= 0 { table.scrollRowToVisible(selectedRow) }
        }
        finishInteraction(); needsLayout = true
    } }
    private var gridNeedsReload = true
    private var tableNeedsReload = false
    private var tableNeedsLocalization = false
    private func reloadGrid() {
        gridNeedsReload = true
        if gridMode { grid.reload(count: result?.count ?? 0, selection: selectedRow); gridNeedsReload = false }
    }
    private let hoverPlate = TintPlate(radius: 10) { _ in NSColor.labelColor.withAlphaComponent(0.04) }
    private let selectionPlate = TintPlate(radius: 10) { view in
        Theme.accent.withAlphaComponent(Theme.dark(view) ? 0.18 : 0.16)
    }
    private var refreshing = false, repeating = false
    private var pressGeneration = 0
    private var pendingPress = false
    private var hoverRow: Int?
    private var liveScrolling = false, wheelScrolling = false, momentumScrolling = false, dragging = false
    private var scrollEnd: DispatchWorkItem?
    // Keep background work idle throughout a long gesture, without publishing on
    // every wheel frame. Monotonic time also survives wall-clock adjustments.
    var interactionClock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private var lastInteractionReport: TimeInterval?
    // Legacy wheels have no end phase; also bridge the gesture-to-momentum gap.
    private static let scrollQuietPeriod = 0.12
    var menuTracking = false { didSet { if !menuTracking { finishInteraction() } } }
    private var pendingRefresh: SearchPresentation?
    private var pendingLocalization = false, pendingClear = false
    private var selectionIdentity: (sourceID: String, store: IndexStore, id: UInt32, path: String)?
    private var scrolling: Bool { liveScrolling || wheelScrolling || momentumScrolling }
    let icons = IconProvider()
    var result: SearchPresentation?
    var currentSource: ((String) -> SearchSource?)?
    var isFavorite: ((ResultItem) -> Bool)?
    var onToggleFavorite: ((ResultItem) -> Void)?
    var onPointerSelection: (() -> Void)?
    var onOpen: (() -> Void)?
    var onSelection: (() -> Void)?
    var onContextMenu: ((Int) -> NSMenu?)?
    var onDragging: ((Bool) -> Void)?
    var onInteractionActivity: (() -> Void)?
    var onRefreshApplied: ((SearchPresentation) -> Void)?
    // Selection belongs to the result, not to the hidden list's cached row count.
    private(set) var selectedRow = -1
    var selectedID: UInt32? {
        guard let result, selectedRow >= 0 && selectedRow < result.count else { return nil }
        return result.row(selectedRow)?.id
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        wantsLayer = true; table.wantsLayer = true
        table.style = .plain
        table.backgroundColor = .clear; table.headerView = nil; table.rowHeight = Theme.rowHeight
        table.intercellSpacing = .zero; table.usesAutomaticRowHeights = false
        table.selectionHighlightStyle = .regular; table.allowsMultipleSelection = false
        table.focusRingType = .none; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result")); column.resizingMask = .autoresizingMask
        table.addTableColumn(column); table.delegate = self; table.dataSource = self
        table.target = self; table.doubleAction = #selector(doubleClicked)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.contextMenu = { [weak self] row in self?.onContextMenu?(row) }
        table.onPointerSelection = { [weak self] in self?.onPointerSelection?() }
        table.onPointerMove = { [weak self] in self?.recomputeHover() }
        table.onPointerExit = { [weak self] in self?.hideHover() }
        table.onPointerReselection = { [weak self] in self?.updateSelection(animated: false) }
        scroll.onScrollWheel = { [weak self] event in self?.wheelScrolled(event) }
        grid.scroll.onScrollWheel = { [weak self] event in self?.wheelScrolled(event) }
        scroll.documentView = table; addSubview(scroll)
        addSubview(grid); grid.isHidden = true
        grid.item = { [weak self] in self?.item(at: $0) }
        grid.isFavorite = { [weak self] in self?.isFavorite?($0) ?? false }
        grid.onSelect = { [weak self] row in self?.onPointerSelection?(); self?.select(row) }
        grid.onFavorite = { [weak self] in self?.onToggleFavorite?($0) }
        grid.onOpen = { [weak self] in self?.onOpen?() }
        grid.onMenu = { [weak self] in self?.onContextMenu?($0) }
        grid.onDragging = { [weak self] active in self?.dragging = active; self?.onDragging?(active); if !active { self?.finishInteraction() } }
        table.addSubview(hoverPlate, positioned: .below, relativeTo: nil); hoverPlate.alphaValue = 0
        table.addSubview(selectionPlate, positioned: .below, relativeTo: nil); selectionPlate.isHidden = true
        let notifications = NotificationCenter.default
        for viewport in [scroll, grid.scroll] {
            notifications.addObserver(self, selector: #selector(scrollStarted), name: NSScrollView.willStartLiveScrollNotification, object: viewport)
            notifications.addObserver(self, selector: #selector(scrollContinued), name: NSScrollView.didLiveScrollNotification, object: viewport)
            notifications.addObserver(self, selector: #selector(scrollEnded), name: NSScrollView.didEndLiveScrollNotification, object: viewport)
        }
        scroll.contentView.postsBoundsChangedNotifications = true
        notifications.addObserver(self, selector: #selector(clipBoundsChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        if scroll.frame != bounds { scroll.frame = bounds }
        if grid.frame != bounds { grid.frame = bounds }
        let width = scroll.contentSize.width
        if table.tableColumns[0].width != width { table.tableColumns[0].width = width }
        updateSelection(animated: false); recomputeHover()
    }
    func show(_ result: SearchResult, selection: Int = 0, resetScroll: Bool = true) { show(SearchPresentation(result), selection: selection, resetScroll: resetScroll) }
    func refresh(_ result: SearchResult) { refresh(SearchPresentation(result)) }
    func show(_ result: SearchPresentation, selection: Int = 0, resetScroll: Bool = true) {
        if !resetScroll { refresh(result); return }
        cancelPendingRefresh(); hideHover(immediately: true)
        refreshing = true
        table.minimumDocumentHeight = 0
        self.result = result; reloadTable()
        select(selection)
        if resetScroll { scroll.contentView.scroll(to: NSPoint(x: 0, y: -6)); scroll.reflectScrolledClipView(scroll.contentView) }
        updateSelection(animated: false); refreshing = false
        rememberSelection(); recomputeHover(); reloadGrid(); if resetScroll { grid.resetScroll() }; onSelection?()
    }
    func clear(preservingViewport: Bool = false) {
        cancelPendingRefresh()
        if preservingViewport && (scrolling || dragging || menuTracking) { pendingClear = true; return }
        let hadSelection = selectedRow >= 0
        let origin = scroll.contentView.bounds.origin
        if preservingViewport { table.minimumDocumentHeight = max(table.minimumDocumentHeight, origin.y + scroll.contentView.bounds.height) }
        else { table.minimumDocumentHeight = 0 }
        cancelPress(); result = nil; selectionIdentity = nil; grid.reload(count: 0, selection: -1); gridNeedsReload = false
        selectedRow = -1; reloadTable(); syncTableSelection()
        updateSelection(animated: false); hideHover(immediately: true)
        if preservingViewport { scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView) }
        if hadSelection && !refreshing { onSelection?() }
    }
    func cancelPendingRefresh() { pendingRefresh = nil; pendingClear = false }
    func localize() {
        guard !scrolling, !dragging, !menuTracking else { pendingLocalization = true; return }
        pendingLocalization = false
        reloadGrid()
        if gridMode { tableNeedsReload = true; tableNeedsLocalization = true; return }
        let origin = scroll.contentView.bounds.origin
        defer { scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView) }
        let range = table.rows(in: table.visibleRect)
        guard range.location != NSNotFound, range.length > 0 else { return }
        table.reloadData(forRowIndexes: IndexSet(integersIn: range.location..<NSMaxRange(range)), columnIndexes: IndexSet(integer: 0))
    }
    func refresh(_ result: SearchPresentation) {
        // Coalesce before comparing potentially millions of rows during a gesture.
        guard !scrolling, !dragging, !menuTracking else { pendingRefresh = result; return }
        let previous = self.result
        let sameRows = previous?.sameRows(as: result) == true
        let action: ResultRefreshAction = scrolling || dragging ? .deferRefresh : sameRows
            ? (previous?.sameMetadata(as: result) == true ? .replaceResult : .reloadVisibleRows) : .reloadPreservingViewport
        if action == .deferRefresh { pendingRefresh = result; return }
        pendingRefresh = nil; pendingClear = false
        let origin = scroll.contentView.bounds.origin
        // A shorter result must not clamp a passive refresh to the new bottom.
        table.minimumDocumentHeight = max(table.minimumDocumentHeight, origin.y + scroll.contentView.bounds.height)
        var row = selectedRow
        if action == .reloadPreservingViewport {
            row = selectionIdentity.flatMap { result.index(sourceID: $0.sourceID, store: $0.store, id: $0.id, path: $0.path) } ?? max(0, selectedRow)
        }
        refreshing = true; self.result = result
        if gridMode {
            if action != .replaceResult { tableNeedsReload = true }
            if action == .reloadPreservingViewport { setSelection(row, reveal: false) }
        } else { switch action {
        case .replaceResult: break
        case .reloadVisibleRows:
            hideHover(immediately: true)
            let visible = table.rows(in: table.visibleRect)
            if visible.location != NSNotFound {
                let range = NSIntersectionRange(visible, NSRange(location: 0, length: result.count))
                if range.length > 0 {
                    for row in range.location..<NSMaxRange(range) {
                        guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ResultCell,
                              let item = item(at: row) else { continue }
                        cell.configure(item, query: result.query, icons: icons, isFavorite: isFavorite?(item) ?? false,
                                       onToggleFavorite: { [weak self] in self?.onToggleFavorite?(item) }, onlyIfChanged: true)
                    }
                }
            }
        case .reloadPreservingViewport:
            hideHover(immediately: true); table.reloadData()
            setSelection(row, reveal: false)
            var rect = scroll.contentView.bounds; rect.origin = origin
            scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(rect).origin)
            scroll.reflectScrolledClipView(scroll.contentView)
            updateSelection(animated: false)
        case .deferRefresh: break
        } }
        refreshing = false
        if action != .replaceResult { rememberSelection(); recomputeHover(); onSelection?() }
        if action == .reloadVisibleRows {
            if gridMode { grid.refreshVisibleItems() } else { gridNeedsReload = true }
        }
        else if action == .reloadPreservingViewport { reloadGrid() }
        onRefreshApplied?(result)
    }
    private func hideHover(immediately: Bool = false) {
        guard hoverRow != nil || hoverPlate.alphaValue != 0 else { return }
        hoverRow = nil
        Theme.Motion.opacity(hoverPlate, to: 0, using: immediately ? nil : Theme.Motion.basic(Theme.Motion.hover))
    }
    private func recomputeHover() {
        guard !refreshing, !scrolling, !dragging, let window, window.isVisible else { hideHover(immediately: true); return }
        let point = window.mouseLocationOutsideOfEventStream
        guard scroll.contentView.bounds.contains(scroll.contentView.convert(point, from: nil)) else { hideHover(); return }
        let row = table.row(at: table.convert(point, from: nil))
        guard row >= 0, row != selectedRow else { hideHover(); return }
        Theme.Motion.frame(hoverPlate, to: table.rect(ofRow: row).insetBy(dx: 10, dy: 1), using: nil)
        if hoverRow == nil { Theme.Motion.opacity(hoverPlate, to: 1, using: Theme.Motion.basic(Theme.Motion.hover)) }
        hoverRow = row
    }
    @objc private func scrollStarted() {
        reportInteraction(force: !scrolling)
        if !scrolling { grid.setScrolling(true); icons.setPaused(true) }
        liveScrolling = true; hideHover(immediately: true)
    }
    @objc private func scrollContinued() {
        guard scrolling else { return }
        reportInteraction()
    }
    private func reportInteraction(force: Bool = false) {
        let now = interactionClock()
        let due = lastInteractionReport.map({ now - $0 >= 1 }) ?? true
        guard force || due else { return }
        lastInteractionReport = now
        onInteractionActivity?()
    }
    @objc private func scrollEnded() {
        if scrolling { reportInteraction(force: true) }
        liveScrolling = false; finishInteraction()
    }
    @objc private func clipBoundsChanged() {
        hideHover(immediately: true)
        if !scrolling && !dragging {
            DispatchQueue.main.async { [weak self] in self?.recomputeHover() }
        }
    }
    private func wheelScrolled(_ event: NSEvent) {
        reportInteraction(force: !scrolling)
        if !scrolling { grid.setScrolling(true); icons.setPaused(true) }
        wheelScrolling = true; hideHover(immediately: true)
        if !event.momentumPhase.intersection([.began, .changed, .stationary]).isEmpty { momentumScrolling = true }
        if !event.momentumPhase.intersection([.ended, .cancelled]).isEmpty { momentumScrolling = false }
        scrollEnd?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reportInteraction(force: true)
            self.wheelScrolling = false; self.finishInteraction()
        }
        scrollEnd = work; DispatchQueue.main.asyncAfter(deadline: .now() + Self.scrollQuietPeriod, execute: work)
    }
    private func finishInteraction() {
        guard !scrolling, !dragging, !menuTracking else { return }
        grid.setScrolling(false)
        if icons.paused {
            icons.setPaused(false)
            // Resolve only the rows still visible after the gesture ends.
            if !gridMode, let result {
                let range = table.rows(in: table.visibleRect)
                if range.location != NSNotFound {
                    for row in range.location..<NSMaxRange(range) {
                        if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ResultCell,
                           let item = item(at: row) {
                            cell.configure(item, query: result.query, icons: icons, isFavorite: isFavorite?(item) ?? false,
                                           onToggleFavorite: cell.favoriteButton.onPress)
                        }
                    }
                }
            }
        }
        if pendingClear { clear(preservingViewport: true) }
        else if let pendingRefresh { refresh(pendingRefresh) }
        if pendingLocalization { localize() }
        recomputeHover()
    }
    deinit { scrollEnd?.cancel(); NotificationCenter.default.removeObserver(self) }
    func item(at row: Int) -> ResultItem? {
        guard let result, let hit = result.row(row) else { return nil }
        let source: SearchSource
        if let currentSource { guard let current = currentSource(hit.source.id) else { return nil }; source = SearchSource(id: current.id, displayName: current.displayName, isOnline: current.isOnline && current.store === hit.source.store, store: hit.source.store) }
        else { source = hit.source }
        let store = hit.source.store, id = hit.id
        return store.read {
            guard Int(id) < store.count, store.isLive(id) else { return nil }
            let name = store.name(id), parent = store.parentPath(id)
            return ResultItem(detail: result.detail(at: row), id: id, source: source, name: name, parentPath: parent, path: parent == "/" ? "/" + name : parent + "/" + name,
                              size: store.size(id), modified: store.modified(id), flags: store.flags[Int(id)], kind: store.kind[Int(id)])
        }
    }
    var selectedItem: ResultItem? { item(at: selectedRow) }
    func deselect() {
        let changed = selectedRow != -1
        selectedRow = -1; syncTableSelection(); grid.select(-1, reveal: false); updateSelection(animated: false)
        if changed && !refreshing { rememberSelection(); recomputeHover(); onSelection?() }
    }
    func select(_ row: Int, repeatKey: Bool = false) {
        repeating = repeatKey; defer { repeating = false }
        setSelection(row, reveal: true)
    }
    private func setSelection(_ row: Int, reveal: Bool) {
        guard let result, result.count > 0 else { deselect(); return }
        let row = min(max(0, row), result.count - 1)
        let changed = selectedRow != row
        selectedRow = row; syncTableSelection()
        if reveal && !gridMode { table.scrollRowToVisible(row) }
        if gridMode { grid.select(row, reveal: reveal) }
        if changed && !refreshing {
            rememberSelection(); updateSelection(animated: !table.selectingWithPointer); recomputeHover(); onSelection?()
        }
    }
    private func syncTableSelection() {
        guard !gridMode else { return }
        let wasRefreshing = refreshing; refreshing = true
        defer { refreshing = wasRefreshing }
        if selectedRow >= 0 && selectedRow < table.numberOfRows {
            table.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
        } else { table.deselectAll(nil) }
    }
    private func reloadTable() {
        guard !gridMode else { tableNeedsReload = true; return }
        let wasRefreshing = refreshing; refreshing = true
        defer { refreshing = wasRefreshing; tableNeedsLocalization = false }
        tableNeedsReload = false
        if table.numberOfRows != (result?.count ?? 0) {
            table.reloadData()
        } else {
            // A hidden list can keep its prepared rows while the grid searches.
            // Rebind visible cells without rebuilding their AppKit view trees.
            table.enumerateAvailableRowViews { _, row in
                if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ResultCell {
                    configureCell(cell, row: row, onlyIfChanged: !tableNeedsLocalization)
                }
            }
        }
    }
    func move(_ delta: Int, repeatKey: Bool = false) {
        guard let result, result.count > 0 else { return }
        let target = max(0, selectedRow) + delta * (gridMode ? grid.columns : 1)
        if !repeatKey && (target < 0 || target >= result.count) { nudge(delta) }
        select(target, repeatKey: repeatKey)
    }
    func page(_ delta: Int, repeatKey: Bool = false) { select(max(0, selectedRow) + delta * max(1, Int(scroll.contentSize.height / Theme.rowHeight)), repeatKey: repeatKey) }
    private func updateSelection(animated: Bool) {
        if gridMode { grid.select(selectedRow, reveal: false); return }
        guard selectedRow >= 0 else { selectionPlate.isHidden = true; return }
        var rowRect = table.rect(ofRow: selectedRow)
        rowRect.size.width = scroll.contentView.bounds.width
        let rect = rowRect.insetBy(dx: 10, dy: 1)
        let first = selectionPlate.isHidden
        selectionPlate.isHidden = false
        let animation: CABasicAnimation? = animated && !first && !Theme.Motion.reduced
            ? (repeating ? Theme.Motion.basic(Theme.Motion.selectionRepeat, .linear) : Theme.Motion.selection) : nil
        Theme.Motion.frame(selectionPlate, to: rect, using: animation)
    }
    private func nudge(_ direction: Int) {
        guard !Theme.Motion.reduced, let layer = table.layer else { return }
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.y")
        let current = layer.presentation()?.value(forKeyPath: "transform.translation.y") as? CGFloat ?? 0
        animation.values = [current, direction < 0 ? -Theme.Motion.nudgeOffset : Theme.Motion.nudgeOffset, 0]
        animation.keyTimes = [0, 0.5, 1]; animation.duration = Theme.Motion.nudge
        animation.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeOut)]
        layer.add(animation, forKey: "transform.translation.y")
    }
    func pressOpen(_ action: @escaping () -> Void) {
        guard !gridMode, !Theme.Motion.reduced, let layer = selectionPlate.layer else { action(); return }
        pressGeneration += 1; let token = pressGeneration
        pendingPress = true
        let frame = layer.frame; layer.anchorPoint = CGPoint(x: 0.5, y: 0.5); layer.frame = frame
        Theme.Motion.animate(layer, "transform.scale", to: Theme.Motion.pressScale, using: Theme.Motion.basic(Theme.Motion.press))
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.press) { [weak self] in
            guard let self, self.pressGeneration == token, self.pendingPress else { return }
            self.pendingPress = false
            Theme.Motion.animate(layer, "transform.scale", to: 1, using: Theme.Motion.basic(Theme.Motion.press))
            action()
        }
    }
    func cancelPress() {
        guard pendingPress else { return }
        pendingPress = false; pressGeneration += 1
        if let layer = selectionPlate.layer { Theme.Motion.animate(layer, "transform.scale", to: 1, using: Theme.Motion.basic(Theme.Motion.press)) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { result?.count ?? 0 }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("row")
        let view = tableView.makeView(withIdentifier: identifier, owner: self) as? ResultRow ?? ResultRow(frame: .zero)
        view.identifier = identifier; return view
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? ResultCell ?? ResultCell(frame: .zero)
        cell.identifier = identifier
        configureCell(cell, row: row)
        return cell
    }
    private func configureCell(_ cell: ResultCell, row: Int, onlyIfChanged: Bool = false) {
        if !onlyIfChanged {
            cell.actionsButton.title = L10n.text("hint.actions")
            cell.actionsButton.toolTip = L10n.text("workspace.actions")
            cell.actionsButton.setAccessibilityLabel(L10n.text("hint.actions"))
        }
        cell.actionsButton.onPress = { [weak self, weak cell] in
            guard let self, let cell, let displayed = cell.displayedResult,
                  let current = self.item(at: row), current.path == displayed.path,
                  current.source.store === displayed.source.store else { return }
            self.onPointerSelection?(); self.select(row)
            self.onContextMenu?(row)?.popUp(positioning: nil, at: NSPoint(x: 0, y: 30), in: cell.actionsButton)
        }
        if let item = item(at: row), let result {
            cell.configure(item, query: result.query, icons: icons, isFavorite: isFavorite?(item) ?? false, onToggleFavorite: { [weak self] in
                guard let self else { return }
                // A reused row must never apply a star click to a different file.
                guard let current = self.item(at: row), current.path == item.path, current.source.id == item.source.id else { return }
                self.select(row); self.onToggleFavorite?(current)
            }, onlyIfChanged: onlyIfChanged)
        }
    }
    private func rememberSelection() {
        if let item = selectedItem { selectionIdentity = (item.source.id, item.source.store, item.id, item.path) }
        else if result?.count == 0 { selectionIdentity = nil }
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !refreshing, !gridMode else { return }
        selectedRow = table.selectedRow
        rememberSelection(); updateSelection(animated: !table.selectingWithPointer); recomputeHover(); onSelection?()
    }
    @objc private func doubleClicked() { if table.clickedRow >= 0 { onOpen?() } }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let item = item(at: row), item.source.isOnline else { return nil }
        return NSURL(fileURLWithPath: item.path)
    }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        dragging = true; hideHover(immediately: true); onDragging?(true)
    }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false; finishInteraction(); onDragging?(false)
    }
}
