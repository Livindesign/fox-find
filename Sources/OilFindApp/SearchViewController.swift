import AppKit
import PDFKit
import Quartz
import Darwin
import UniformTypeIdentifiers
import OilFindCore

private final class SupplementarySearchBox { var hits: [SupplementaryHit] = [] }

private final class SearchGeneration {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    func current(_ token: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return value == token }
}

final class SearchViewController: NSViewController, NSWindowDelegate, NSMenuDelegate {
    let searchField = SearchField(frame: .zero)
    let filters = FilterBar(frame: .zero)
    let toolsBar = SearchToolsBar(frame: .zero)
    let results = ResultsView(frame: .zero)
    let conversations = AIConversationResultsView(frame: .zero)
    private var conversationWindow: AIConversationWindow?
    private var conversationQuery = ""
    var openConversationClient: (AITopic, @escaping (AITopicActions.OpenResult) -> Void) -> Void = AITopicActions.open
    private let conversationOpenGeneration = SearchGeneration()
    private var openingConversation: String?
    var aiTopics: AITopicManager? {
        didSet {
            aiTopics?.onChange = { [weak self] in
                guard let self, self.filters.aiSelected, self.view.window?.isVisible == true || self.snapshot else { return }
                self.refreshSearch()
            }
            aiTopics?.onAvailabilityChange = { [weak self] in
                guard let self, self.isViewLoaded else { return }
                self.conversationWindow?.close()
                _ = self.conversationOpenGeneration.next(); self.openingConversation = nil
                if self.filters.aiSelected { self.conversations.show([], preserveSelection: false); self.startSearch() }
            }
        }
    }
    let footer = FooterBar(frame: .zero)
    let inlinePreview = InlinePreview(frame: .zero)
    let quickLook = QuickLook()
    let quickResults = QuickResultsView(frame: .zero)
    let applicationCatalog = ApplicationCatalog()
    let contextBar = SearchContextBar(frame: .zero)
    let actionPalette = SearchActionPalette(frame: .zero)
    let shortcuts: SearchShortcuts
    let usage: SearchUsage
    private(set) var naturalPlan: NaturalSearchPlan?
    private var naturalWarning: String? { NaturalSearch.unresolvedConstraint(naturalPlan?.query ?? searchField.text) }
    private(set) var browsingFolder = false
    private(set) var recursiveFolder = false
    private var backStack: [SearchNavigationState] = [], forwardStack: [SearchNavigationState] = []
    private var restoreViewport: SearchNavigationState?
    private let previewGeneration = SearchGeneration()
    private let previewQueue = DispatchQueue(label: "app.localfind.desktop.preview", qos: .userInitiated)
    var openResource: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    private var effectiveFolder: String? { naturalPlan?.folder ?? toolsBar.folder }
    private var effectiveRefinement: AssetRefinement {
        var value = toolsBar.refinement
        if let plan = naturalPlan { value.minWidth = plan.refinement.minWidth ?? value.minWidth; value.minHeight = plan.refinement.minHeight ?? value.minHeight; value.captured = plan.refinement.captured ?? value.captured }
        return value
    }
    var resultPasteboard = NSPasteboard.general
    var launchApplication: (URL, @escaping (Bool) -> Void) -> Void = { url, completion in
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { app, error in
            DispatchQueue.main.async { completion(app != nil && error == nil) }
        }
    }
    private var quickQuery = ""
    private var calculationOnly = false
    private var selectedQuickResult: QuickResult? {
        guard let index = quickResults.selectedIndex, quickResults.items.indices.contains(index) else { return nil }
        return quickResults.items[index]
    }
    private let topLine = SeparatorView(), bottomLine = SeparatorView()
    private let idle = StateView(.idle), empty = StateView(.empty), indexing = StateView(.indexing)
    let syntax = SyntaxReference(frame: .zero)
    private(set) var syntaxVisible = false
    private var diagnostics: [QueryDiagnostic] = []
    private var snapshotNoAccess = false
    private var contentStatusSnapshot: SupplementarySearchStatus?
    private let snapshot: Bool
    private let preferences: UserDefaults
    private let library: SearchLibrary
    let fileFavorites: FileFavorites
    let projects: ProjectFolders
    private let assetQueue = DispatchQueue(label: "app.localfind.desktop.metadata", qos: .utility)
    private lazy var metadata = AssetMetadataReader(cacheURL: snapshot ? nil : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Local Find/metadata.sqlite"))
    private let assetGeneration = SearchGeneration()
    private var historyWork: DispatchWorkItem?
    private var textPreview: ContentPreviewWindow?
    private let queue = DispatchQueue(label: "app.localfind.desktop.search", qos: .userInteractive)
    private let generation = SearchGeneration(), cache = SearchCache()
    private var timer: Timer?
    private var stateView: NSView?
    private var languageObserver: NSObjectProtocol?
    private var themeObserver: NSObjectProtocol?
    private var menuTracking = false, dragging = false
    private var trackedMenus: Set<ObjectIdentifier> = []
    private var manualMenuTracking = false
    private var trashing: Set<URL> = []
    private var selectionAnchor: (sourceID: String, store: IndexStore, id: UInt32, path: String)?
    private var pendingNewSearch: Bool?
    private(set) var searchInFlight = false
    private var refreshRequested = false
    private var refreshWork: DispatchWorkItem?
    private(set) var browsingResults = false
    var previewWithSpace: Bool { preferences.object(forKey: "previewWithSpace") as? Bool ?? true }
    private func setBrowsing(_ browsing: Bool) {
        browsingResults = browsing
        footer.spacePreview = browsing && previewWithSpace
    }
    var manager: IndexManager?
    var supplementaryProvider: SupplementarySearchProvider?
    private(set) var similarityPath: String?
    private var similarityPreviousOptions: SearchOptions?
    private var adoptedConditions: [NaturalQueryCondition] = []
    private(set) var semanticPending = false
    private(set) var semanticAttempted = false
    private var semanticPDF: NSWindowController?
    private let semanticQueue = DispatchQueue(label: "app.localfind.semantic.query", qos: .userInitiated)
    private let supplementQueue = DispatchQueue(label: "app.localfind.desktop.supplement", qos: .userInteractive)
    var additionalSources: (() -> [SearchSource])?
    private var sourceCaches: [String: SearchCache] = [:]
    private var sourceCacheStores: [String: ObjectIdentifier] = [:]
    private var searchSources: [SearchSource] {
        let primary = manager?.store.map { SearchSource(id: "startup", displayName: "", isOnline: true, store: $0) }
        return primary.map { [$0] + (additionalSources?() ?? []) } ?? (additionalSources?() ?? [])
    }
    func sourcesChanged() {
        fileFavorites.reconcile { [weak self] changed in if changed { self?.results.localize() } }
        supplementaryProvider?.sourcesDidChange(searchSources)
        results.cancelPress()
        let contentDisabled = supplementaryProvider?.isEnabled != true && results.result?.hasSupplements == true
        if supplementaryProvider?.isEnabled != true, let result = results.result, result.hasSupplements {
            let base = toolsBar.mode == .contents ? result.supplement([], options: filters.options, only: true) : result.withoutSupplements()
            let row = results.selectedItem.flatMap { base.index(sourceID: $0.source.id, store: $0.source.store, id: $0.id, path: $0.path) } ?? 0
            present(base, selection: row, resetScroll: false)
        }
        // Invalidate displayed actions immediately, including while the panel is hidden.
        if results.selectedItem?.source.isOnline != true { quickLook.close() }
        if let presented = results.result, let multi = presented.multiple {
            let current = Set(searchSources.map(\.id))
            if multi.sources.contains(where: { !current.contains($0.id) }) && current.isEmpty {
                results.clear(preservingViewport: true); setState(.empty)
                footer.text = L10n.text("footer.results", Presentation.countText(0), Presentation.elapsedText(0))
            }
        }
        if contentDisabled { startSearch(preserveSelection: true) }
        else { refreshSearch() }
    }
    var hidePanel: (() -> Void)?
    var onSettings: (() -> Void)?
    var guide: GuideModel? {
        didSet {
            guide?.onChange = { [weak self] in self?.refreshGuide() }
            refreshGuide()
        }
    }
    private(set) var guideOverlay: GuideOverlay?
    func refreshGuide() {
        guard isViewLoaded, let guide else { return }
        guard guide.active else {
            let hadOverlay = guideOverlay != nil
            let restoreFocus = guideOverlay?.isDetachedKey == true
            guideOverlay?.removeFromSuperview(); guideOverlay = nil
            if restoreFocus { view.window?.makeKey() }
            if hadOverlay && view.window?.isVisible == true && view.window?.isKeyWindow == true { searchField.focus() }
            return
        }
        let visible = guide.step != .contentSetup && actionPalette.isHidden && !syntaxVisible
        if visible && guideOverlay == nil {
            let overlay = GuideOverlay(model: guide, allowsDetached: !snapshot); guideOverlay = overlay; view.addSubview(overlay)
        }
        guideOverlay?.isHidden = !visible
        guard visible, let overlay = guideOverlay else { return }
        let anchor: NSView = guide.cardStep == .result ? footer.actions : guide.cardStep == .contentOffer ? searchField.settings : searchField.input
        overlay.frame = view.bounds
        overlay.point(to: anchor, lower: guide.cardStep != .search && guide.cardStep != .contentOffer)
        overlay.layoutSubtreeIfNeeded()
    }
    func performGuideResultAction() {
        guard guide?.hasResult == true else { return }
        showActions()
    }
    func beginGuidedContentSearch() {
        closeActions(); toggleSyntax(false); clearSimilarityMode()
        adoptedConditions = []; naturalPlan = nil; browsingFolder = false; recursiveFolder = false
        toolsBar.folder = nil; toolsBar.refinement = AssetRefinement(); filters.options.kind = nil
        toolsBar.mode = .contents; searchField.text = ""
        startSearch(); searchField.focus()
    }
    private func reportGuideResults(_ result: SearchPresentation? = nil) {
        guard let guide, guide.active else { return }
        let value = result ?? results.result
        let available = !inputIsEmpty && (!quickResults.items.isEmpty || (value?.count ?? 0) > 0)
        guide.resultsChanged(available: available, previewable: available && selectedQuickResult == nil && results.selectedItem?.source.isOnline == true,
                             contentMatch: available && toolsBar.mode == .contents && value?.hasSupplements == true)
    }
    init(snapshot: Bool, preferences: UserDefaults = .standard) {
        self.snapshot = snapshot
        self.preferences = preferences
        self.library = SearchLibrary(defaults: preferences)
        self.fileFavorites = FileFavorites(defaults: preferences)
        self.projects = ProjectFolders(defaults: preferences)
        self.shortcuts = SearchShortcuts(defaults: preferences)
        self.usage = SearchUsage(defaults: preferences)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() { view = PanelSurface(snapshot: snapshot) }
    override func viewDidLoad() {
        super.viewDidLoad()
        [searchField, filters, toolsBar, results, conversations, idle, empty, indexing, quickResults, footer, inlinePreview, syntax, contextBar, actionPalette].forEach(view.addSubview)
        toolsBar.sortControl = filters.sortButton
        inlinePreview.isHidden = true; inlinePreview.allowsLoading = !snapshot
        inlinePreview.onActions = { [weak self] in self?.showActions() }
        inlinePreview.onOpenPage = { [weak self] in self?.previewText() }
        conversations.onSettings = { [weak self] in self?.onSettings?() }
        conversations.onOpen = { [weak self] in self?.openConversation() }
        conversations.onActions = { [weak self] in self?.showActions() }
        conversations.onSelect = { [weak self] in self?.setBrowsing(true) }
        conversations.makeMenu = { [weak self] in
            let menu = NSMenu()
            self?.conversationActions().forEach { menu.addItem($0.menuItem()) }
            return menu
        }
        idle.onFolder = { [weak self] path in self?.enterFolder(path) }
        contextBar.back.onPress = { [weak self] in self?.navigateBack() }
        contextBar.forward.onPress = { [weak self] in self?.navigateForward() }
        contextBar.up.onPress = { [weak self] in self?.navigateUp() }
        contextBar.depth.onPress = { [weak self] in guard let self else { return }; self.recursiveFolder.toggle(); self.startSearch() }
        contextBar.edit.onPress = { [weak self] in self?.clearSearchConditions() }
        contextBar.onMenuTracking = { [weak self] active in self?.trackMenu(active) }
        contextBar.onRemove = { [weak self] in self?.removeSearchCondition($0) }
        contextBar.exitSimilarity.onPress = { [weak self] in self?.exitSimilaritySearch() }
        footer.onActions = { [weak self] in self?.showActions() }
        actionPalette.onClose = { [weak self] in self?.closeActions() }
        quickResults.onSelect = { [weak self] index in self?.selectQuickResult(index) }
        quickResults.onActivate = { [weak self] in self?.activateQuickResult() }
        applicationCatalog.onChange = { [weak self] in
            guard let self else { return }
            self.updateQuickResults(preserveSelection: true)
        }
        if !snapshot { applicationCatalog.refreshIfNeeded() }
        toolsBar.onMode = { [weak self] mode in
            guard let self else { return }
            if mode != .contents && self.guide?.step == .contentSearch { self.guide?.dismiss() }
            self.toolsBar.mode = mode; self.startSearch(); self.searchField.focus()
        }
        toolsBar.onMatch = { [weak self] in
            guard let self else { return }
            self.toolsBar.match.present(self.makeMatchMenu())
        }
        toolsBar.onScope = { [weak self] in self?.showScopeMenu() }
        results.isFavorite = { [weak self] item in self?.fileFavorites.contains(sourceID: item.source.id, path: item.path) ?? false }
        results.onToggleFavorite = { [weak self] item in self?.toggleFileFavorite(item) }
        toolsBar.onRefine = { [weak self] in self?.showRefinementMenu() }
        toolsBar.onMore = { [weak self] in self?.showMoreMenu() }
        toolsBar.list.onPress = { [weak self] in self?.setGridMode(false) }
        toolsBar.grid.onPress = { [weak self] in self?.setGridMode(true) }
        setGridMode(preferences.bool(forKey: "search.grid"))
        syntax.isHidden = true
        syntax.onExample = { [weak self] example in
            guard let self else { return }; self.setBrowsing(false); self.searchField.text = example; self.toggleSyntax(false); self.searchField.focus(); self.startSearch()
        }
        searchField.onSelectionChange = { [weak self] in self?.refreshDiagnostics() }
        searchField.onChange = { [weak self] in
            guard let self else { return }
            self.clearSimilarityMode(); self.adoptedConditions = []
            self.setBrowsing(false); self.startSearch()
        }
        searchField.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        filters.onKindChange = { [weak self] in
            guard let self else { return }
            if self.filters.aiSelected {
                self.setBrowsing(false)
                self.clearSimilarityMode(); self.naturalPlan = nil; self.adoptedConditions = []
                self.browsingFolder = false; self.recursiveFolder = false
                self.toolsBar.folder = nil; self.toolsBar.refinement = AssetRefinement()
                return
            }
            self.adoptNaturalConditions()
            let typeTokens = self.adoptedConditions.filter { $0.token.hasPrefix("kind:") || $0.token == "ext:pdf" }
            for value in typeTokens { self.searchField.text = self.searchField.text.replacingOccurrences(of: value.token, with: "") }
            self.adoptedConditions.removeAll { typeTokens.contains($0) }
            if self.searchField.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { self.searchField.text = "*" }
        }
        filters.onChange = { [weak self] in self?.searchField.focus(); self?.startSearch() }
        filters.onSortChange = { [weak self] in
            guard let self, !self.snapshot else { return }
            UserDefaults.standard.set(FilterBar.sortName(self.filters.options.sort), forKey: "sortKey")
            UserDefaults.standard.set(self.filters.options.ascending, forKey: "sortAscending")
        }
        filters.onMenuTracking = { [weak self] tracking in
            self?.trackMenu(tracking)
        }
        if !snapshot { results.currentSource = { [weak self] id in self?.searchSources.first { $0.id == id } } }
        results.onPointerSelection = { [weak self] in
            self?.supplementaryProvider?.userActivity(visible: true, typing: true)
            self?.selectQuickResult(nil); self?.setBrowsing(true)
        }
        results.onOpen = { [weak self] in self?.openSelected() }
        results.onSelection = { [weak self] in
            self?.quickLook.refresh()
            if let self, !self.inlinePreview.isHidden { self.inlinePreview.show(self.results.selectedItem) }
            if let self, let item = self.results.selectedItem {
                if self.selectionAnchor?.path != item.path { _ = self.previewGeneration.next() }
                self.selectionAnchor = (item.source.id, item.source.store, item.id, item.path)
                if self.guide?.hasResult == true { self.reportGuideResults() }
            }
        }
        results.onContextMenu = { [weak self] _ in self?.contextMenu() }
        results.onRefreshApplied = { [weak self] result in self?.resultDidChange(result) }
        results.onInteractionBegan = { [weak self] in
            // Scrolling is foreground work too: yield background semantic indexing.
            self?.supplementaryProvider?.userActivity(visible: true, typing: true)
        }
        results.onDragging = { [weak self] active in
            self?.dragging = active
            if !active { self?.hideIfInactive() }
        }
        quickLook.selectedURL = { [weak self] in
            guard let self, self.results.selectedItem?.source.isOnline == true else { return nil }
            return self.selectedURL
        }
        quickLook.selectedRevision = { [weak self] in
            guard let item = self?.results.selectedItem else { return nil }
            return QuickLook.Revision(size: item.size, modified: item.modified)
        }
        quickLook.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        searchField.onSettings = { [weak self] in self?.onSettings?() }
        empty.onAssistance = { [weak self] in
            guard let self else { return }
            if self.results.result?.refinementPaused == true { self.continueRefinement() }
            else if self.empty.assistance?.actionTitle == L10n.text("tools.clearConditions") { self.clearSearchConditions() }
            else { self.onSettings?() }
        }
        languageObserver = NotificationCenter.default.addObserver(forName: L10n.changed, object: nil, queue: .main) { [weak self] _ in self?.localize() }
        themeObserver = NotificationCenter.default.addObserver(forName: AppearancePreferences.changed, object: AppearancePreferences.shared, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.filters.localize(); self.toolsBar.refreshColors(); self.results.localize()
            func redraw(_ node: NSView) { node.needsDisplay = true; node.subviews.forEach(redraw) }
            redraw(self.view)
        }
        setState(.idle)
        if !snapshot {
            filters.options = SettingsPreferences.searchOptions()
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.refreshProgress() }
        }
        localize()
    }
    deinit {
        _ = previewGeneration.next()
        timer?.invalidate()
        historyWork?.cancel()
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
    }
    private func localize() {
        footer.spacePreview = browsingResults && previewWithSpace
        filters.localize(); footer.localize(); idle.localize(); empty.localize(); indexing.localize(); syntax.localize(); results.localize()
        searchField.localize()
        toolsBar.localize(); quickResults.localize(); updateContextBar()
        if let result = results.result { updateFooter(result) }
        else if stateView === indexing { footer.text = L10n.text("footer.indexing", Presentation.countText(indexing.count)) }
        else if stateView === idle { footer.text = L10n.text("idle.footer") }
        refreshProgress()
        updateQuickFooter()
        guide?.localize()
        view.needsLayout = true
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        let w = view.bounds.width, h = view.bounds.height, px = Theme.pixel(view)
        searchField.frame = NSRect(x: 0, y: 0, width: w, height: Theme.searchHeight)
        topLine.frame = NSRect(x: 0, y: Theme.searchHeight, width: w, height: px)
        filters.frame = NSRect(x: 0, y: Theme.searchHeight + px, width: w, height: Theme.filterHeight)
        toolsBar.frame = NSRect(x: 0, y: Theme.searchHeight + Theme.filterHeight + px, width: w, height: Theme.toolsHeight)
        toolsBar.isHidden = filters.aiSelected
        let contextTop: CGFloat = Theme.searchHeight + Theme.filterHeight + (filters.aiSelected ? 0 : Theme.toolsHeight) + px
        let contextHeight: CGFloat = contextBar.isHidden ? 0 : 32
        contextBar.frame = NSRect(x: 0, y: contextTop, width: w, height: contextHeight)
        let top = contextTop + contextHeight
        let region = NSRect(x: 0, y: top, width: w, height: max(0, h - top - Theme.footerHeight))
        let quickHeight = quickResults.desiredHeight
        quickResults.frame = NSRect(x: 0, y: top, width: w, height: quickHeight)
        let fileRegion = NSRect(x: 0, y: top + quickHeight, width: w, height: max(0, region.height - quickHeight))
        let showsPreview = !filters.aiSelected && !results.gridMode && w >= 850 && stateView == nil && results.selectedItem != nil && !calculationOnly
        [idle, empty, indexing].forEach { $0.frame = fileRegion }
        let previewWidth = floor(w * 0.43)
        var resultRegion = fileRegion
        if showsPreview { resultRegion.size.width = w - previewWidth - 32 }
        // Assign the final width once. Expanding the list and shrinking it again
        // on every layout invalidated both tables and collection layout twice.
        results.frame = resultRegion
        conversations.frame = fileRegion
        let previewAppearing = inlinePreview.isHidden && showsPreview
        inlinePreview.isHidden = !showsPreview
        if previewAppearing { Theme.Motion.reveal(inlinePreview) }
        if showsPreview {
            let width = previewWidth
            inlinePreview.frame = NSRect(x: w - width - 20, y: fileRegion.minY + 4, width: width, height: max(0, fileRegion.height - 8))
            inlinePreview.show(results.selectedItem)
        } else { inlinePreview.clear() }
        syntax.frame = region
        let actionWidth = min(L10n.chinese ? 350 : 390, w - 48)
        let actionHeight = filters.aiSelected ? min(420, CGFloat(actionPalette.actions.count) * 42 + 82) : 420
        actionPalette.frame = NSRect(x: w - 24 - actionWidth, y: Theme.searchHeight + 8, width: actionWidth, height: min(actionHeight, max(240, h - Theme.searchHeight - Theme.footerHeight - 20)))
        bottomLine.frame = NSRect(x: 0, y: h - 34 - px, width: w, height: px)
        footer.frame = NSRect(x: 0, y: h - Theme.footerHeight, width: w, height: Theme.footerHeight)
        if guide?.active == true { searchField.layoutSubtreeIfNeeded(); footer.layoutSubtreeIfNeeded() }
        refreshGuide()
    }
    func setState(_ state: StateView.State?) {
        _ = view
        let previous: NSView = stateView ?? ((filters.aiSelected ? conversations : results) as NSView)
        stateView = state == .idle ? idle : state == .empty ? empty : state == .indexing ? indexing : nil
        view.needsLayout = true
        let target: NSView = stateView ?? ((filters.aiSelected ? conversations : results) as NSView)
        footer.actionable = !syntaxVisible && stateView == nil && (results.result?.total ?? 0) > 0
        guard previous !== target || target.isHidden else { return }
        let animate = !snapshot && view.window?.isVisible == true && previous !== target
        for item in [results, conversations, idle, empty, indexing] as [NSView] {
            let visible = item === target
            if visible { item.isHidden = false }
            Theme.Motion.opacity(item, to: visible ? 1 : 0, using: animate ? Theme.Motion.basic(Theme.Motion.crossfade) : nil)
            if !visible {
                if animate {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.crossfade) { [weak self, weak item] in
                        guard let self, let item else { return }
                        let current: NSView = self.stateView ?? ((self.filters.aiSelected ? self.conversations : self.results) as NSView)
                        if item !== current { item.isHidden = true }
                    }
                } else { item.isHidden = true }
            }
        }
        synchronizeQuickVisibility()
    }
    func panelWillShow() {
        aiTopics?.visibilityChanged(true)
        if filters.aiSelected { startSearch(preserveSelection: true); return }
        fileFavorites.reconcile { [weak self] changed in if changed { self?.results.localize() } }
        setBrowsing(false)
        if !snapshot { applicationCatalog.refreshIfNeeded() }
        supplementaryProvider?.userActivity(visible: true, typing: false)
        let currentQuery = editingQuery(store: manager?.store)
        // Activating/reopening an accessory app can occur during every external UI
        // action. Keep an explicitly paused scan even when index versions changed;
        // Continue validates the original snapshot before doing more work.
        if let result = results.result, result.refinementPaused,
           result.query.raw == currentQuery.raw, result.refinementFilter == effectiveRefinement,
           result.hasSameSources(as: searchSources) { return }
        if !refreshRequested, let result = results.result, result.isCurrent(searchSources),
           result.query.raw == currentQuery.raw, !currentQuery.isTimeDependent,
           Date().timeIntervalSince(result.createdAt) <= 600 { return }
        startSearch(preserveSelection: true)
    }

    func cancelPendingPreviews() {
        _ = previewGeneration.next()
    }
    func indexChanged() {
        fileFavorites.reconcile { [weak self] changed in if changed { self?.results.localize() } }
        supplementaryProvider?.sourcesDidChange(searchSources)
        if view.window?.isVisible == true { refreshSearch() }
    }
    func managerStateChanged(_ state: IndexManager.State) {
        aiTopics?.backgroundIndexingChanged(state == .scanning)
        guard !filters.aiSelected else { return }
        refreshProgress()
        if manager?.store == nil && !inputIsEmpty && quickResults.items.isEmpty { setState(.indexing) }
    }
    private func refreshProgress() {
        guard !filters.aiSelected else { return }
        guard view.window?.isVisible == true || snapshot else { return }
        let status = supplementaryProvider?.contentStatus(in: effectiveFolder)
        if let result = results.result, result.query.isEmpty || status != contentStatusSnapshot {
            contentStatusSnapshot = status
            if result.total == 0 { configureEmpty(result) }
            updateFooter(result)
        }
        guard let manager else { return }
        searchField.indexing = manager.state == .scanning || manager.isRescanning
        if manager.store == nil && !inputIsEmpty && quickResults.items.isEmpty {
            let count = manager.scannedCount
            indexing.updateCount(count); footer.text = L10n.text("footer.indexing", Presentation.countText(count))
        }
    }
    func startSearch(preserveSelection: Bool = false) {
        aiTopics?.cancelSearch()
        if !preserveSelection && searchField.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { guide?.resultsChanged(available: false, previewable: false) }
        refreshWork?.cancel(); refreshWork = nil; refreshRequested = false
        searchInFlight = false
        if let path = similarityPath, searchField.text != L10n.text("semantic.reference", URL(fileURLWithPath:path).lastPathComponent) { clearSimilarityMode() }
        if !actionPalette.isHidden { closeActions() }
        if !preserveSelection {
            _ = previewGeneration.next()
            _ = conversationOpenGeneration.next(); openingConversation = nil
        }
        naturalPlan = filters.aiSelected || similarityPath != nil || searchField.editor.hasMarkedText() ? nil : NaturalSearch.parse(searchField.text, projects: projects.folders)
        updateContextBar()
        _ = assetGeneration.next()
        if !snapshot && !preserveSelection && !filters.aiSelected { scheduleHistory() }
        pendingNewSearch = preserveSelection
        results.cancelPendingRefresh()
        search(refresh: false, preserveSelection: preserveSelection)
    }
    private func refreshSearch() {
        // A paused scan is explicitly resumed by the user; filesystem churn must not restart it.
        guard results.result?.refinementPaused != true else { return }
        refreshRequested = true
        guard !searchInFlight, refreshWork == nil, !menuTracking, actionPalette.isHidden else { return }
        // One trailing refresh per burst. Never cancel model work because the index changed.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.refreshWork = nil
            guard !self.searchInFlight, !self.menuTracking, self.actionPalette.isHidden,
                  self.results.result?.refinementPaused != true else { return }
            self.refreshRequested = false
            if let preserve = self.pendingNewSearch {
                self.search(refresh: false, preserveSelection: preserve)
            } else {
                self.search(refresh: true, preserveSelection: true)
            }
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
    private func finishSearch(_ token: Int) {
        guard generation.current(token) else { return }
        searchInFlight = false; semanticPending = false; pendingNewSearch = nil
        if let result = results.result { configureEmpty(result); updateQuickFooter() }
        if refreshRequested { refreshSearch() }
    }
    private func search(refresh: Bool, preserveSelection: Bool) {
        supplementaryProvider?.userActivity(visible: view.window?.isVisible == true, typing: !refresh && !preserveSelection)
        let token = generation.next()
        searchInFlight = false
        if filters.aiSelected { searchConversations(token: token, preserveSelection: refresh || preserveSelection); return }
        guard !inputIsEmpty else { showIdle(); return }
        updateQuickResults(preserveSelection: refresh || preserveSelection)
        if calculationOnly {
            pendingNewSearch = nil; selectionAnchor = nil; diagnostics = []
            results.clear(); quickLook.close(); textPreview?.close(); setState(.empty)
            synchronizeQuickVisibility(); updateQuickFooter(); return
        }
        let sources = searchSources
        guard let store = sources.first?.store else {
            results.clear(); setState(.indexing); synchronizeQuickVisibility(); refreshProgress(); updateQuickFooter(); return
        }
        var options = filters.options
        if !snapshot { options.pinyin = UserDefaults.standard.bool(forKey: "pinyinEnabled") }
        let query = editingQuery(store: store), previous = results.result
        searchInFlight = true
        let atomicRefresh = (refresh || preserveSelection) && previous?.query.raw == query.raw
        let cancelled = { [generation] in !generation.current(token) }
        let filtersOnly = naturalPlan?.filtersOnly == true
        let contentOnly = (toolsBar.mode == .contents && !filtersOnly) || similarityPath != nil
        let refinement = effectiveRefinement, metadataReader = metadata
        let accepts: SupplementaryFileFilter = { source, id in
            guard !cancelled() else { return false }
            guard refinement.active else { return true }
            guard let value = source.store.read({ () -> (String,Date,UInt8)? in
                guard Int(id) < source.store.count, source.store.isLive(id) else { return nil }
                return (source.store.path(id), source.store.modified(id), source.store.kind[Int(id)])
            }) else { return false }
            if refinement.needsMedia && ![UInt8(4), UInt8(5)].contains(value.2) { return false }
            let info = source.isOnline ? metadataReader.read(path:value.0,modified:value.1,media:refinement.needsMedia) : metadataReader.offline(path:value.0,modified:value.1,media:refinement.needsMedia)
            return info.map { refinement.hasRequiredMetadata($0) && refinement.matches($0) } ?? false
        }
        let supplementary = similarityPath.map { supplementaryProvider?.prepareSimilarity(path: $0, query: query, options: options, sources: sources, accepts: accepts, isCancelled: cancelled) } ?? (toolsBar.mode == .names || filtersOnly ? nil : supplementaryProvider?.prepareSearch(query, options: options, sources: sources, contentOnly: contentOnly, isCancelled: cancelled))
        let semantic = similarityPath == nil && toolsBar.mode != .names && !filtersOnly && naturalWarning == nil ? supplementaryProvider?.prepareSemantic(query, options: options, sources: sources, accepts: accepts, isCancelled: cancelled) : nil
        semanticAttempted = semantic != nil || similarityPath != nil
        semanticPending = semanticAttempted && !atomicRefresh
        let complete = DispatchGroup(), semanticBox = SupplementarySearchBox()
        if let semantic { complete.enter(); semanticQueue.async { semanticBox.hits = semantic(); complete.leave() } }
        let group = DispatchGroup()
        let box = SupplementarySearchBox()
        if let supplementary {
            group.enter()
            supplementQueue.async { box.hits = supplementary(); group.leave() }
        }
        let anchor = refresh || preserveSelection ? selectionAnchor : nil
        queue.async { [weak self] in
            guard let self, self.generation.current(token) else { return }
            let found: SearchPresentation
            if sources.count == 1 && sources[0].id == "startup" {
                if !self.sourceCaches.isEmpty { self.sourceCaches.removeAll(); self.sourceCacheStores.removeAll() }
                if previous?.single?.store !== store { self.cache.removeAll() }
                guard let result = self.cache.lookup(query: query, options: options, store: store)
                    ?? Searcher.search(query, options: options, in: store, previous: previous?.single, isCancelled: { !self.generation.current(token) }), self.generation.current(token) else { return }
                self.cache.insert(result); found = SearchPresentation(result)
            } else {
                if previous?.single != nil { self.cache.removeAll() }
                self.sourceCaches = self.sourceCaches.filter { key, _ in sources.contains { $0.id == key } }
                self.sourceCacheStores = self.sourceCacheStores.filter { key, _ in sources.contains { $0.id == key } }
                for source in sources {
                    let identity = ObjectIdentifier(source.store)
                    if self.sourceCacheStores[source.id] != identity {
                        self.sourceCaches[source.id] = SearchCache(); self.sourceCacheStores[source.id] = identity
                    }
                }
                guard let result = MultiSearcher.search(query, options: options, in: sources, previous: previous?.multiple, caches: self.sourceCaches, isCancelled: { !self.generation.current(token) }), self.generation.current(token) else { return }
                found = SearchPresentation(result)
            }
            let anchoredRow = anchor.flatMap { found.index(sourceID: $0.sourceID, store: $0.store, id: $0.id, path: $0.path) }
            let row = anchoredRow ?? 0
            let base = contentOnly ? found.supplement([], options: options, only: true) : found
            let hasProviders = supplementary != nil || semantic != nil
            func combined(_ hits: [SupplementaryHit]) -> SearchPresentation {
                // Keep the compact filename arrays when providers add nothing.
                hits.isEmpty && !contentOnly ? found : found.supplement(hits, options: options, only: contentOnly)
            }
            func publish(_ value: SearchPresentation, final: Bool, update: Bool = false) {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation.current(token) else { return }
                    // Source replacement/removal invalidates IDs. A version change in the same
                    // store is safe to display (rows/actions validate liveness), then reconcile.
                    guard value.hasSameSources(as: self.searchSources) else {
                        if final { self.refreshRequested = true; self.finishSearch(token) }
                        return
                    }
                    if final && !value.isCurrent(self.searchSources) { self.refreshRequested = true }
                    self.diagnostics = query.diagnostics
                    if final { self.semanticPending = false }
                    self.deliver(value, token: token,
                                 refresh: atomicRefresh || refresh || update || (hasProviders && final),
                                 selection: row, atomic: atomicRefresh,
                                 completion: final ? { [weak self] in self?.finishSearch(token) } : nil)
                }
            }
            if !hasProviders { publish(base, final: true); return }
            if !atomicRefresh { publish(base, final: false) }
            group.notify(queue: self.queue) { [weak self] in
                guard let self, self.generation.current(token) else { return }
                let lexical = combined(box.hits)
                guard semantic != nil else { publish(lexical, final: true); return }
                // Keep the last complete presentation throughout a passive refresh.
                if !atomicRefresh && !box.hits.isEmpty { publish(lexical, final: false, update: true) }
                complete.notify(queue: self.queue) { [weak self] in
                    guard let self, self.generation.current(token) else { return }
                    let identities = Set(box.hits.map { $0.sourceID + ":" + String($0.entryID) })
                    let extra = semanticBox.hits.filter { !identities.contains($0.sourceID + ":" + String($0.entryID)) }
                    publish(combined(box.hits + extra), final: true)
                }
            }
        }
    }

    private var inputIsEmpty: Bool { searchField.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private func updateQuickResults(preserveSelection: Bool) {
        let text = searchField.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = similarityPath == nil && !text.isEmpty && !searchField.editor.hasMarkedText() && toolsBar.mode != .contents && effectiveFolder == nil && !effectiveRefinement.active && naturalPlan == nil
        let previous = selectedQuickResult
        var items: [QuickResult] = []
        calculationOnly = false
        if allowed, filters.options.kind == nil, let calculation = QuickCalculator.evaluate(text) {
            items = [.calculation(calculation)]; calculationOnly = true
        } else if allowed, filters.options.kind == nil || filters.options.kind == 2 {
            let learned = filters.options.sort == .relevance ? usage.scores(for: text) : [:]
            items = applicationCatalog.matches(text, limit: 40).map(QuickResult.application)
            if filters.options.kind == nil {
                items = shortcuts.matches(text).compactMap { item in item.resolved(for: text).map { QuickResult.shortcut(item, $0) } } + items
            }
            var seen = Set<String>()
            items = items.filter { item in
                let key: String
                switch item { case .application(let app): key = app.path; case .shortcut(_, let url): key = url.isFileURL ? url.path : url.absoluteString; case .calculation: key = "calculation" }
                return seen.insert(key).inserted
            }
            items = Array(items.enumerated().sorted {
                let a = learned[$0.element.targetKey, default: 0], b = learned[$1.element.targetKey, default: 0]
                return a == b ? $0.offset < $1.offset : a > b
            }.prefix(3).map(\.element))
        }
        let sameQuery = quickQuery == text
        let selection: Int?
        if preserveSelection && sameQuery {
            selection = previous.flatMap { items.firstIndex(of: $0) } ?? (!browsingResults && !items.isEmpty ? 0 : nil)
        } else { selection = items.isEmpty ? nil : 0 }
        quickQuery = text; quickResults.show(items, selection: selection)
        if !items.isEmpty { reportGuideResults() }
        if selection != nil { results.deselect(); quickLook.close() }
        synchronizeQuickVisibility(); updateQuickFooter(); view.needsLayout = true
    }
    private func synchronizeQuickVisibility() {
        quickResults.isHidden = syntaxVisible || quickResults.items.isEmpty
        if calculationOnly {
            [results, idle, empty, indexing].forEach { $0.isHidden = true }
        } else if let stateView {
            stateView.isHidden = !quickResults.items.isEmpty && (stateView === empty || stateView === indexing)
        }
    }
    private func updateQuickFooter() {
        guard !filters.aiSelected else { return }
        switch selectedQuickResult {
        case .calculation(let calculation):
            footer.context = .calculation; footer.warning = calculation.errorKey != nil
            footer.text = calculation.errorKey.map { L10n.text($0) } ?? L10n.text("quick.local")
            footer.actionable = calculation.value != nil
        case .application:
            footer.context = .application; footer.warning = false; footer.actionable = true
            footer.text = L10n.text("quick.appsReady")
        case .shortcut:
            footer.context = .link; footer.warning = false; footer.actionable = true
            footer.text = L10n.text("workspace.localEntries")
        case nil:
            footer.context = .files
            if let result = results.result { updateFooter(result) }
        }
    }
    private func selectQuickResult(_ index: Int?) {
        quickResults.selectedIndex = index
        if index != nil { results.deselect(); quickLook.close() }
        updateQuickFooter()
        if guide?.hasResult == true { reportGuideResults() }
    }
    private func activateQuickResult() {
        switch selectedQuickResult {
        case .calculation(let calculation):
            guard calculation.value != nil else { return }
            resultPasteboard.clearContents(); resultPasteboard.setString(calculation.output, forType: .string)
            footer.showToast(.copiedPath, value: calculation.output)
        case .shortcut(let shortcut, let url):
            if openResource(url) {
                usage.record(query: searchField.text, target: "shortcut:" + shortcut.id)
                library.record(currentSearch); hidePanel?()
            } else { footer.warning = true; footer.text = L10n.text("workspace.actionFailed", shortcut.name) }
        case .application(let app):
            let search = currentSearch
            launchApplication(URL(fileURLWithPath: app.path)) { [weak self] success in
                guard let self else { return }
                if success { self.guide?.send(.useResult); self.usage.record(query: search.query, target: "app:" + app.path); self.library.record(search); self.hidePanel?() }
                else { self.footer.warning = true; self.footer.text = L10n.text("quick.failed") }
            }
        case nil: break
        }
    }
    private func handleQuickKey(_ event: NSEvent, command: Bool, option: Bool, key: String) -> Bool {
        guard !quickResults.items.isEmpty else { return false }
        if let index = quickResults.selectedIndex {
            switch event.keyCode {
            case 36, 76:
                if command, case .application(let app) = selectedQuickResult {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)]); hidePanel?()
                } else if command, case .shortcut(_, let url) = selectedQuickResult, url.isFileURL {
                    NSWorkspace.shared.activateFileViewerSelecting([url]); hidePanel?()
                } else if !command { activateQuickResult() }
                return true
            case 125, 121, 119:
                setBrowsing(true)
                if index + 1 < quickResults.items.count && event.keyCode == 125 { selectQuickResult(index + 1) }
                else if let result = results.result, result.count > 0 {
                    selectQuickResult(nil); results.select(event.keyCode == 119 || command ? result.count - 1 : 0)
                }
                return true
            case 126, 116, 115:
                setBrowsing(true); selectQuickResult(command || event.keyCode != 126 ? 0 : max(0, index - 1)); return true
            case 51 where command: return true
            default: break
            }
            if command && key == "c" {
                if case .application(let app) = selectedQuickResult {
                    let value = option ? app.name : app.path
                    resultPasteboard.clearContents(); resultPasteboard.setString(value, forType: .string)
                    footer.showToast(.copiedPath, value: value)
                } else if case .shortcut(let shortcut, let url) = selectedQuickResult {
                    resultPasteboard.clearContents(); resultPasteboard.setString(option ? shortcut.name : (url.isFileURL ? url.path : url.absoluteString), forType: .string)
                    footer.showToast(.copiedPath, value: url.isFileURL ? url.path : url.absoluteString)
                } else { activateQuickResult() }
                return true
            }
            if command && ["y", "d"].contains(key) && !event.modifierFlags.contains(.shift) { return true }
            if event.keyCode == 49 && browsingResults && previewWithSpace { return true }
        } else if [126, 115].contains(event.keyCode) && (command || results.selectedRow <= 0 || event.keyCode == 115) {
            setBrowsing(true); selectQuickResult(command || event.keyCode == 115 ? 0 : quickResults.items.count - 1); return true
        }
        return false
    }
    private func showIdle() {
        semanticPending = false; semanticAttempted = false
        restoreViewport = nil
        calculationOnly = false; quickQuery = ""; quickResults.show([], selection: nil); footer.context = .files
        view.needsLayout = true
        _ = assetGeneration.next(); historyWork?.cancel(); pendingNewSearch = nil
        selectionAnchor = nil; diagnostics = []; setBrowsing(false)
        results.clear(); quickLook.close(); textPreview?.close()
        refreshDiagnostics(); setState(.idle); footer.warning = false; footer.text = L10n.text("idle.footer")
    }
    func present(_ result: SearchResult, selection: Int = 0, resetScroll: Bool = true) { present(SearchPresentation(result), selection: selection, resetScroll: resetScroll) }
    func present(_ result: SearchPresentation, selection: Int = 0, resetScroll: Bool = true) {
        results.show(result, selection: selection, resetScroll: resetScroll)
        resultDidChange(result)
        if let state = restoreViewport { results.select(state.selection); results.restoreScroll(state.scroll); restoreViewport = nil }
    }
    private func editingQuery(store: IndexStore?) -> Query {
        Query.parse(similarityPath != nil ? "*" : (naturalPlan?.query ?? searchField.text), store: store, editingRange: naturalPlan != nil || searchField.input.currentEditor() == nil ? nil : searchField.editor.selectedRange(), isComposing: searchField.editor.hasMarkedText(), pathExists: { [self] path in
            if searchSources.contains(where: { source in source.store.read { source.store.containsPath(path) } }) { return true }
            var info = stat(); return path.withCString { stat($0, &info) == 0 }
        }).scoped(to: effectiveFolder, includingSubfolders: !browsingFolder || recursiveFolder)
    }
    private func refreshDiagnostics() {
        guard !filters.aiSelected, !calculationOnly else { return }
        let query = editingQuery(store: manager?.store ?? results.result?.store)
        guard let result = results.result, result.query.raw == query.raw else { return }
        diagnostics = query.diagnostics
        configureEmpty(result); updateFooter(result); updateQuickFooter()
    }
    private func configureEmpty(_ result: SearchPresentation) {
        var assistance: SupplementarySearchStatus?
        if toolsBar.mode != .names || similarityPath != nil {
            if semanticPending {
                assistance = .init(title: L10n.text("semantic.searching"), message: L10n.text("semantic.searchingHelp"), actionTitle: "")
            } else if let status = supplementaryProvider?.contentStatus(in: effectiveFolder), !status.canSearch || semanticAttempted {
                assistance = status
            }
        }
        if assistance == nil && !contextBar.conditions.isEmpty {
            assistance = .init(title: L10n.text("empty.title"), message: L10n.text("empty.filteredHelp"), actionTitle: L10n.text("tools.clearConditions"))
        }
        if effectiveRefinement.captured != nil, result.refinementUnknown > 0 {
            assistance = .init(title: L10n.local("没有找到符合拍摄日期的文件", "No files match the capture date"),
                               message: L10n.local("部分文件没有可读取的拍摄日期，未计入结果。如需其他年份，请在搜索中写明年份。修改日期不会当作拍摄日期。", "Some files have no readable capture date and were excluded. Specify a year to search another year. Modification dates are not capture dates."), actionTitle: "")
        }
        if result.refinementRunning || result.refinementPaused {
            assistance = .init(title: L10n.text(result.refinementPaused ? "asset.paused" : "asset.checking"),
                               message: L10n.text("asset.scanHelp"),
                               actionTitle: result.refinementPaused ? L10n.text("asset.continue") : "")
        }
        if let warning = naturalWarning { assistance = .init(title: L10n.local("请明确搜索条件", "Clarify search conditions"), message: warning, actionTitle: "") }
        empty.configure(diagnostic: diagnostics.first, hasNoAccess: snapshotNoAccess || result.sources.contains { source in source.store.read { source.store.coverage[.noAccess].count > 0 } }, assistance: assistance)
    }
    func toggleSyntax(_ show: Bool? = nil) {
        let visible = show ?? !syntaxVisible
        syntaxVisible = visible
        refreshGuide()
        quickResults.isHidden = visible || quickResults.items.isEmpty
        footer.actionable = !visible && stateView == nil && (results.result?.total ?? 0) > 0
        syntax.isHidden = false
        Theme.Motion.opacity(syntax, to: visible ? 1 : 0, using: snapshot ? nil : Theme.Motion.chip)
        if let layer = syntax.layer { Theme.Motion.animate(layer, "transform.translation.y", to: visible ? 0 : 8, using: snapshot ? nil : Theme.Motion.chip) }
        if !visible {
            if snapshot { syntax.isHidden = true }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.chip.settlingDuration) { [weak self] in if self?.syntaxVisible == false { self?.syntax.isHidden = true } } }
        }
    }
    private func resultDidChange(_ result: SearchPresentation) {
        configureEmpty(result)
        setState(result.total == 0 ? .empty : nil)
        updateFooter(result)
        refreshProgress()
        if selectedQuickResult != nil { results.deselect() }
        synchronizeQuickVisibility(); updateQuickFooter()
        reportGuideResults(result)
    }
    private func updateFooter(_ result: SearchPresentation) {
        if let warning = naturalWarning { footer.warning = true; footer.text = warning; return }
        if let checked = result.refinementChecked {
            footer.warning = !result.refinementRunning && result.refinementLimited
            footer.text = L10n.text("workspace.refinementProgress", String(result.count), String(checked), String(result.refinementTotal)) + (result.refinementUnknown > 0 ? L10n.text(effectiveRefinement.captured == nil ? "workspace.unknownMetadata" : "workspace.unknownCapture", String(result.refinementUnknown)) : "")
            if result.refinementPaused { footer.text += L10n.text("asset.partialFooter") }
            return
        }
        defer {
            if semanticPending && diagnostics.isEmpty { footer.text += L10n.text("semantic.pendingFooter") }
            else if toolsBar.mode != .names, diagnostics.isEmpty, let status = supplementaryProvider?.contentStatus(in: effectiveFolder), !status.summary.isEmpty {
                footer.text += " · " + status.summary
            }
            footer.statusHelp = supplementaryProvider?.contentStatus(in: effectiveFolder).map { $0.message + "\n" + $0.folders.joined(separator: "\n") } ?? ""
        }
        footer.warning = !diagnostics.isEmpty
        if let diagnostic = diagnostics.first { footer.text = L10n.diagnostic(diagnostic); return }
        if toolsBar.mode == .contents {
            footer.text = L10n.local("内容匹配 \(result.total) 项", "\(result.total) content matches") + (result.total >= 1000 ? L10n.local(" · 已到 1,000 项上限，请缩小范围", " · 1,000-item limit; refine your search") : "")
        } else if result.query.isEmpty {
            let count = Presentation.countText(result.sources.reduce(0) { count, source in count + source.store.read { source.store.liveCount } })
            footer.text = L10n.text("footer.recent", count)
        } else if result.hasSupplements {
            footer.text = L10n.text("footer.contentResults", Presentation.countText(result.total))
        } else {
            footer.text = L10n.text(result.sortedCount < result.total ? "footer.partial" : "footer.results", Presentation.countText(result.total), Presentation.elapsedText(result.elapsedMs))
        }
    }
    func prepareSnapshot(state: String, query: String, options: SearchOptions, store: IndexStore?, selection: Int, additionalSources: [SearchSource] = []) throws {
        _ = view
        searchField.text = ["recent", "idle"].contains(state) ? "" : query; filters.options = options
        if state == "indexing" {
            setState(.indexing); indexing.updateCount(1_234_567); searchField.indexing = true
            footer.text = L10n.text("footer.indexing", Presentation.countText(1_234_567)); return
        }
        if state == "idle" || inputIsEmpty { showIdle(); return }
        naturalPlan = NaturalSearch.parse(searchField.text, projects: projects.folders); updateContextBar()
        updateQuickResults(preserveSelection: false)
        if calculationOnly { setState(.empty); synchronizeQuickVisibility(); updateQuickFooter(); return }
        if let store, let supplementaryProvider {
            let sources = [SearchSource(id: "startup", displayName: "", isOnline: true, store: store)] + additionalSources
            let query = editingQuery(store: store)
            let hits = toolsBar.mode == .names ? [] : supplementaryProvider.prepareSearch(query, options: options, sources: sources, contentOnly: toolsBar.mode == .contents, isCancelled: { false })()
            guard let found = MultiSearcher.search(query, options: options, in: sources) else { throw SnapshotError.failed("Cannot search snapshot index") }
            diagnostics = query.diagnostics
            present(toolsBar.mode == .names ? SearchPresentation(found) : SearchPresentation(found).supplement(hits, options: options, only: toolsBar.mode == .contents), selection: selection); return
        }
        if let store, !additionalSources.isEmpty, let found = MultiSearcher.search(editingQuery(store: store), options: options, in: [SearchSource(id: "startup", displayName: "", isOnline: true, store: store)] + additionalSources) {
            diagnostics = found.query.diagnostics; present(SearchPresentation(found), selection: selection); return
        }
        guard let store, let found = Searcher.search(editingQuery(store: store), options: options, in: store) else { throw SnapshotError.failed("Cannot search snapshot index") }
        diagnostics = Query.parse(searchField.text, store: store).diagnostics
        snapshotNoAccess = state == "no-access"
        present(found, selection: selection)
        if state == "syntax" { toggleSyntax(true) }
        if state == "toast", let item = results.selectedItem { footer.showToast(.copiedPath, value: item.path, snapshot: true) }
        if state == "empty" {
            setState(.empty)
            footer.text = L10n.text("footer.results", Presentation.countText(0), Presentation.elapsedText(found.elapsedMs))
        }
    }
    private var selectedURL: URL? {
        guard stateView == nil else { return nil }
        return results.selectedItem.map { URL(fileURLWithPath: $0.path) }
    }
    func handleKey(_ event: NSEvent) -> Bool {
        if (view.window as? SearchPanel)?.hiding == true { return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command), option = flags.contains(.option)
        if !actionPalette.isHidden {
            if event.keyCode == 53 || (command && event.charactersIgnoringModifiers?.lowercased() == "k") { closeActions(); return true }
            actionPalette.handleKey(event); return true
        }
        let activeEditor = searchField.input.currentEditor()
        if (activeEditor as? NSTextView)?.hasMarkedText() == true { return false }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        // A nonactivating panel has no Edit menu to dispatch text shortcuts.
        if flags.intersection([.command, .control, .option, .shift]) == .command,
           let editor = activeEditor {
            switch key {
            case "a": editor.selectAll(nil); return true
            case "c" where editor.selectedRange.length > 0: editor.copy(nil); return true
            case "x": editor.cut(nil); return true
            case "v": editor.paste(nil); return true
            default: break
            }
        }
        if command && key == "k" { showActions(); return true }
        if command && key == "[" { navigateBack(); return true }
        if command && key == "]" { navigateForward(); return true }
        if command && event.keyCode == 124 { enterSelectedFolder(); return true }
        if option && event.keyCode == 126 { navigateUp(); return true }
        if command && event.keyCode == 44 { toggleSyntax(); return true }
        if syntaxVisible && event.keyCode == 53 { toggleSyntax(false); return true }
        if syntaxVisible { return false }
        if event.keyCode == 53, guideOverlay?.isHidden == false { guide?.dismiss(); return true }
        if event.keyCode == 48, guideOverlay?.isHidden == false { return false }
        if let overlay = guideOverlay, !overlay.isHidden, let responder = view.window?.firstResponder as? NSView,
           responder.isDescendant(of: overlay), flags.intersection([.command, .control, .option]).isEmpty,
           [36, 76, 49, 123, 124, 125, 126].contains(event.keyCode) { return false }
        if filters.aiSelected, handleConversationKey(event, command: command, key: key) { return true }
        if handleQuickKey(event, command: command, option: option, key: key) { return true }
        if [126, 125, 116, 121, 115, 119].contains(event.keyCode) { setBrowsing(true) }
        if event.keyCode == 49 && flags.intersection([.command, .control, .option, .shift]).isEmpty && browsingResults && previewWithSpace {
            previewSelected(); return true
        }
        if results.gridMode && browsingResults && [123, 124].contains(event.keyCode) && !command { results.select(results.selectedRow + (event.keyCode == 123 ? -1 : 1)); return true }
        switch event.keyCode {
        case 115: results.select(0, repeatKey: event.isARepeat); return true
        case 119: results.select((results.result?.count ?? 1) - 1, repeatKey: event.isARepeat); return true
        case 126: if command { results.select(0, repeatKey: event.isARepeat) } else { results.move(-1, repeatKey: event.isARepeat) }; return true
        case 125: if command { results.select((results.result?.count ?? 1) - 1, repeatKey: event.isARepeat) } else { results.move(1, repeatKey: event.isARepeat) }; return true
        case 116: results.page(-1, repeatKey: event.isARepeat); return true
        case 121: results.page(1, repeatKey: event.isARepeat); return true
        case 36, 76: if command { revealSelected() } else { openSelected() }; return true
        case 48: filters.cycle(flags.contains(.shift) ? -1 : 1); return true
        case 53: if quickLook.isVisible { quickLook.close() } else { hidePanel?() }; return true
        case 51 where command: trashSelected(); return true
        default: break
        }
        guard command else { return false }
        switch key {
        case "y": if flags.contains(.shift) { previewText() } else { previewSelected() }; return true
        case "d": if flags.contains(.shift) { toggleSavedSearch() } else { toggleSelectedFileFavorite() }; return true
        case "e" where flags.contains(.shift): exportResults(); return true
        case "c":
            if option { copyName(); return true }
            if searchField.input.currentEditor()?.selectedRange.length ?? 0 > 0 { return false }
            copyPath(); return true
        case "w": hidePanel?(); return true
        case ",": onSettings?(); return true
        case "1"..."9": filters.select((Int(key) ?? 1) - 1); return true
        default: return false
        }
    }
    private func openSelected() {
        if filters.aiSelected { openConversation(); return }
        if selectedQuickResult != nil { activateQuickResult(); return }
        guard stateView == nil, (view.window as? SearchPanel)?.hiding != true, let url = selectedURL else { return }
        guard allowOnlineAction() else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { NSSound.beep(); return }
        library.record(currentSearch)
        results.pressOpen { [weak self] in
            guard self?.allowOnlineAction() == true else { return }
            guard let self, self.openResource(url) else { NSSound.beep(); return }
            if let item = self.results.selectedItem { self.usage.record(query: self.searchField.text, target: "file:" + item.source.id + "|" + item.path) }
            self.guide?.send(.useResult)
            self.hidePanel?()
        }
    }
    private func revealSelected() { guard stateView == nil, let url = selectedURL, allowOnlineAction() else { return }; NSWorkspace.shared.activateFileViewerSelecting([url]); hidePanel?() }
    @discardableResult
    private func allowOnlineAction() -> Bool {
        guard let item = results.selectedItem else { return false }
        // Check the live provider as well as the submitted snapshot during an in-flight refresh.
        let current = searchSources.first { $0.id == item.source.id }
        guard item.source.isOnline && (snapshot || current?.isOnline == true) else {
            footer.warning = true; footer.actionable = false
            footer.text = L10n.text("source.unavailable", item.source.displayName)
            return false
        }
        return snapshot || current?.store === item.source.store
    }
    private func previewSelected() {
        if filters.aiSelected { previewConversation(); return }
        if allowOnlineAction() {
            supplementaryProvider?.userActivity(visible: true, typing: true)
            quickLook.toggle()
            if quickLook.isVisible { guide?.send(.useResult) }
        }
    }
    private func copyPath() {
        guard stateView == nil, let url = selectedURL else { return }
        // Preserve the established keyboard copy formats; the action palette
        // also offers explicit text-only path and file-object actions.
        resultPasteboard.clearContents(); resultPasteboard.writeObjects([url as NSURL])
        resultPasteboard.setString(url.path, forType: .string)
        footer.showToast(.copiedPath, value: url.path)
    }
    private func copyName() {
        guard stateView == nil, let item = results.selectedItem else { return }
        resultPasteboard.clearContents(); resultPasteboard.setString(item.name, forType: .string)
        footer.showToast(.copiedName, value: item.name)
    }
    private func trashSelected() {
        guard stateView == nil, let url = selectedURL, let item = results.selectedItem else { return }
        guard allowOnlineAction(), FileManager.default.fileExists(atPath: url.path), trashing.insert(url).inserted else { return }
        NSWorkspace.shared.recycle([url]) { [weak self] _, error in
            DispatchQueue.main.async {
                self?.trashing.remove(url)
                if error != nil { NSSound.beep() }
                else { self?.footer.showToast(.trashed, value: item.name) }
            }
        }
    }
    func makeMatchMenu() -> NSMenu {
        let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
        for mode in SearchMode.allCases {
            let key = mode == .combined ? "combined" : mode == .names ? "names" : "contents"
            let action = SearchAction(id: mode.rawValue, title: L10n.text(mode == .combined ? "tools.automatic" : "tools." + key),
                                      detail: L10n.text("tools." + key + "Help"), symbol: "text.magnifyingglass", checked: mode == toolsBar.mode) { [weak self] in self?.toolsBar.onMode?(mode) }
            let item = action.menuItem()
            item.image = nil // Search methods are choices; the checkmark is enough.
            menu.addItem(item)
        }
        return menu
    }
    func contextMenu() -> NSMenu {
        let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
        let actions = makeFileActions()
        var group: SearchAction.Group?
        let more = NSMenu(); more.autoenablesItems = false
        for action in actions where action.group != .more && action.group != .destructive {
            if let group, group != action.group { menu.addItem(.separator()) }
            group = action.group; menu.addItem(action.menuItem())
        }
        for action in actions where action.group == .more { more.addItem(action.menuItem()) }
        if !more.items.isEmpty {
            menu.addItem(.separator())
            let item = NSMenuItem(title: L10n.text("tools.more"), action: nil, keyEquivalent: ""); item.submenu = more; menu.addItem(item)
        }
        for action in actions where action.group == .destructive { menu.addItem(.separator()); menu.addItem(action.menuItem()) }
        return menu
    }
    private func pauseForActionMenu() {
        menuTracking = true; results.menuTracking = true
        _ = generation.next(); _ = assetGeneration.next(); results.cancelPendingRefresh()
        refreshWork?.cancel(); refreshWork = nil; refreshRequested = true
        searchInFlight = false; semanticPending = false
    }
    private func trackMenu(_ active: Bool) {
        manualMenuTracking = active
        if active { pauseForActionMenu() } else if trackedMenus.isEmpty { resumeAfterActionMenu() }
    }
    func menuWillOpen(_ menu: NSMenu) { trackedMenus.insert(ObjectIdentifier(menu)); pauseForActionMenu() }
    func menuDidClose(_ menu: NSMenu) {
        trackedMenus.remove(ObjectIdentifier(menu))
        if trackedMenus.isEmpty && !manualMenuTracking { resumeAfterActionMenu() }
    }
    private func resumeAfterActionMenu() {
        menuTracking = false
        // NSMenu delivers the chosen action after it closes. Resume on the next turn.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.menuTracking else { return }
            self.results.menuTracking = false
            if self.actionPalette.isHidden && self.view.window?.isVisible == true { self.refreshSearch() }
            self.hideIfInactive()
        }
    }
    private func hideIfInactive() {
        if view.window?.isKeyWindow == false && view.window?.attachedSheet == nil && !quickLook.isVisible && guideOverlay?.isDetachedKey != true && !menuTracking && !dragging { hidePanel?() }
    }
    func windowDidResignKey(_ notification: Notification) {
        // Quick Look visibility settles after the key-window transition.
        DispatchQueue.main.async { [weak self] in self?.hideIfInactive() }
    }
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        (client as? NSTextField) === searchField.input ? searchField.editor : nil
    }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { selectedURL != nil }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { quickLook.begin(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { quickLook.end(panel) }

    private var currentSearch: SavedSearch {
        SavedSearch(query: searchField.text, mode: toolsBar.mode, folder: toolsBar.folder, kind: filters.options.kind,
                    sort: FilterBar.sortName(filters.options.sort), ascending: filters.options.ascending, assetFilter: toolsBar.refinement.media == .all ? nil : toolsBar.refinement.media, finderTag: toolsBar.refinement.tag.isEmpty ? nil : toolsBar.refinement.tag, minWidth: toolsBar.refinement.minWidth, minHeight: toolsBar.refinement.minHeight, captured: toolsBar.refinement.captured)
    }
    private func scheduleHistory() {
        historyWork?.cancel()
        let value = currentSearch
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.currentSearch == value, self.diagnostics.isEmpty, (self.results.result?.total ?? 0) > 0 else { return }
            self.library.record(value)
        }
        historyWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
    func toggleSelectedFileFavorite() {
        guard let item = results.selectedItem else { return }
        toggleFileFavorite(item)
    }
    private func toggleFileFavorite(_ item: ResultItem) {
        fileFavorites.toggle(FileFavorite(sourceID: item.source.id, path: item.path, sourceName: item.source.displayName))
        if item.source.isOnline { fileFavorites.reconcile(force: true) { [weak self] changed in if changed { self?.results.localize() } } }
        results.localize(); searchField.focus()
    }
    @objc private func toggleSavedSearch() {
        library.toggleFavorite(currentSearch)
        searchField.focus()
    }
    func makeSearchLibraryMenu() -> NSMenu {
        let menu = NSMenu(); menu.delegate = self
        func heading(_ text: String) { let item = NSMenuItem(title: text, action: nil, keyEquivalent: ""); item.isEnabled = false; menu.addItem(item) }
        func add(_ value: SavedSearch, title: String? = nil) {
            let item = NSMenuItem(title: title ?? value.title, action: #selector(restoreSearch(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = value; menu.addItem(item)
        }
        let favoriteMenu = NSMenu(); favoriteMenu.delegate = self
        if fileFavorites.files.isEmpty {
            let hint = NSMenuItem(title: L10n.local("点击结果行的 ☆ 收藏文件", "Click a result's ☆ to favorite a file"), action: nil, keyEquivalent: "")
            hint.isEnabled = false; favoriteMenu.addItem(hint)
        }
        for file in fileFavorites.files {
            let parent = URL(fileURLWithPath: file.path).deletingLastPathComponent().lastPathComponent
            let label = String(file.name.prefix(60)) + " · " + String(parent.prefix(28))
            let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            item.toolTip = file.path; item.image = Theme.symbol("star.fill", size: 12, weight: .regular)
            let actions = NSMenu(); actions.delegate = self; actions.autoenablesItems = false
            for (title, tag) in [(L10n.text("ctx.open"), 0), (L10n.text("ctx.reveal"), 1), (L10n.text("file.unfavorite"), 2)] {
                let action = NSMenuItem(title: title, action: #selector(fileFavoriteAction(_:)), keyEquivalent: "")
                action.target = self; action.tag = tag; action.representedObject = file
                action.isEnabled = tag == 2 || searchSources.contains { $0.id == file.sourceID && $0.isOnline }
                actions.addItem(action)
            }
            item.submenu = actions; favoriteMenu.addItem(item)
        }
        let favoriteRoot = NSMenuItem(title: L10n.text("file.favorites") + " (\(fileFavorites.files.count))", action: nil, keyEquivalent: "")
        favoriteRoot.submenu = favoriteMenu; menu.addItem(favoriteRoot); menu.addItem(.separator())
        let saveSearch = NSMenuItem(title: L10n.text(library.favorites.contains(currentSearch) ? "search.unsave" : "search.save"), action: #selector(toggleSavedSearch), keyEquivalent: "d")
        saveSearch.keyEquivalentModifierMask = [.command, .shift]; saveSearch.target = self; menu.addItem(saveSearch)
        menu.addItem(.separator())
        heading(L10n.local("快捷搜索", "Quick Searches"))
        add(SavedSearch(query: "kind:image dm:7d"), title: L10n.local("最近 7 天的图片", "Images from the last 7 days"))
        add(SavedSearch(query: "ext:pdf"), title: L10n.local("所有 PDF", "All PDFs"))
        add(SavedSearch(query: "kind:video size:>500mb"), title: L10n.local("大于 500 MB 的视频", "Videos larger than 500 MB"))
        add(SavedSearch(query: "ext:docx;xlsx;pptx dm:30d"), title: L10n.local("最近 30 天的 Office 文档", "Office documents from the last 30 days"))
        menu.addItem(.separator()); heading(L10n.text("search.saved"))
        if library.favorites.isEmpty { heading(L10n.local("使用“保存此搜索条件”或 ⌘⇧D", "Use Save This Search or ⌘⇧D")) }
        library.favorites.forEach { add($0) }
        if !library.history.isEmpty {
            menu.addItem(.separator()); heading(L10n.local("最近搜索 · 仅保存在这台 Mac", "Recent Searches · Stored on this Mac"))
            library.history.forEach { add($0) }
            menu.addItem(.separator())
            let clear = NSMenuItem(title: L10n.local("清空搜索历史", "Clear Search History"), action: #selector(clearSearchHistory), keyEquivalent: "")
            clear.target = self; menu.addItem(clear)
        }
        return menu
    }
    @objc private func fileFavoriteAction(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? FileFavorite else { return }
        if sender.tag == 2 { fileFavorites.remove(file); results.localize(); return }
        guard searchSources.contains(where: { $0.id == file.sourceID && $0.isOnline }), FileManager.default.fileExists(atPath: file.path) else {
            let alert = NSAlert(); alert.messageText = L10n.text("file.unavailable")
            alert.informativeText = L10n.text("file.unavailable.help") + "\n\n" + file.path
            if let window = view.window { alert.beginSheetModal(for: window) }
            return
        }
        let url = URL(fileURLWithPath: file.path)
        if sender.tag == 1 { NSWorkspace.shared.activateFileViewerSelecting([url]); hidePanel?() }
        else if NSWorkspace.shared.open(url) { hidePanel?() }
    }
    @objc private func restoreSearch(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? SavedSearch else { return }
        // Legacy saved scopes used an empty query to browse files. Make that intent explicit.
        searchField.text = value.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "*" : value.query
        toolsBar.mode = value.mode; toolsBar.folder = value.folder; filters.options = value.options
        toolsBar.refinement = AssetRefinement(media: value.assetFilter ?? .all, tag: value.finderTag ?? "", minWidth: value.minWidth, minHeight: value.minHeight, captured: value.captured)
        setBrowsing(false); startSearch(); searchField.focus()
    }
    @objc private func clearSearchHistory() { historyWork?.cancel(); library.clearHistory() }
    func makeScopeMenu() -> NSMenu {
        let menu = NSMenu(); menu.delegate = self
        func add(_ title: String, path: String?) {
            let item = NSMenuItem(title: title, action: #selector(selectScope(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = path; item.state = path == toolsBar.folder ? .on : .off; menu.addItem(item)
        }
        add(L10n.local("全部位置", "All Locations"), path: nil)
        for (name, directory) in [(L10n.local("桌面", "Desktop"), FileManager.SearchPathDirectory.desktopDirectory), (L10n.local("文稿", "Documents"), .documentDirectory), (L10n.local("下载", "Downloads"), .downloadsDirectory), (L10n.local("图片", "Pictures"), .picturesDirectory)] {
            if let url = FileManager.default.urls(for: directory, in: .userDomainMask).first { add(name, path: url.path) }
        }
        if let item = results.selectedItem {
            let path = item.source.store.read { item.source.store.flags[Int(item.id)] & SiftFlag.dir != 0 ? item.path : URL(fileURLWithPath: item.path).deletingLastPathComponent().path }
            add(L10n.local("选中结果所在文件夹", "Folder of Selected Result"), path: path)
        }
        menu.addItem(.separator())
        let choose = NSMenuItem(title: L10n.local("选择其他文件夹…", "Choose Folder…"), action: #selector(chooseScope), keyEquivalent: "")
        choose.target = self; menu.addItem(choose)
        let projects = NSMenuItem(title: L10n.text("asset.project"), action: nil, keyEquivalent: "")
        projects.submenu = makeProjectMenu(); menu.addItem(projects)
        return menu
    }
    private func showScopeMenu() {
        toolsBar.scope.present(makeScopeMenu())
    }
    @objc private func selectScope(_ sender: NSMenuItem) { adoptNaturalConditions(); toolsBar.folder = sender.representedObject as? String; startSearch(); searchField.focus() }
    @objc private func chooseScope() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.prompt = L10n.local("限定到此文件夹", "Search This Folder")
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.adoptNaturalConditions(); self.toolsBar.folder = url.resolvingSymlinksInPath().path; self.startSearch(); self.searchField.focus()
        }
    }
    private func previewText() {
        if filters.aiSelected { previewConversation(); return }
        if let page = results.result?.detail(at: results.selectedRow)?.matchedPage, let item = results.selectedItem, item.source.isOnline {
            openSemanticPage(path: item.path, page: page, expectedStamp: results.result?.detail(at: results.selectedRow)?.matchedStamp); return
        }
        guard let item = results.selectedItem, let provider = supplementaryProvider else { return }
        let generation = previewGeneration, request = previewGeneration.next()
        let prepare = provider.preparePreview(source: item.source, entryID: item.id, isCancelled: { !generation.current(request) })
        footer.text = L10n.text("workspace.previewLoading")
        let needles = Query.parse(naturalPlan?.query ?? searchField.text).clauses.flatMap(\.alternatives).compactMap { atom -> String? in
            if !atom.negated, case .name(let bytes, _) = atom.matcher { return String(decoding: bytes, as: UTF8.self) }; return nil
        }
        previewQueue.async { [weak self] in
            let outcome = prepare()
            DispatchQueue.main.async {
                guard let self, generation.current(request) else { return }
                guard self.results.selectedItem?.path == item.path else { return }
                let preview: ExtractedTextPreview
                switch outcome {
                case .ready(let value): preview = value
                case .unavailable(let reason): self.footer.text = reason; return
                case .cancelled: return
                }
                self.library.record(self.currentSearch)
                self.textPreview?.close(); self.textPreview = ContentPreviewWindow(preview: preview, query: needles.first ?? "")
                self.textPreview?.showWindow(nil); self.textPreview?.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
    private func exportResults() {
        guard let result = results.result, result.count > 0, let window = view.window else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.commaSeparatedText]; panel.nameFieldStringValue = "Fox-Find-results.csv"
        let count = min(result.count, 10_000)
        panel.message = L10n.local("导出当前已列出的 \(count) 项（总命中 \(result.total) 项）。", "Export \(count) listed items (\(result.total) total matches).")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.queue.async {
                let formatter = ISO8601DateFormatter()
                var rows = [["name", "path", "source", "online", "size_bytes", "modified_utc", "matched_text"]]
                for i in 0..<count {
                    guard let item = result.row(i) else { continue }
                    let row: [String]? = item.source.store.read {
                        let store = item.source.store
                        guard Int(item.id) < store.count, store.isLive(item.id) else { return nil }
                        return [store.name(item.id), store.path(item.id), item.source.displayName, String(item.source.isOnline), String(store.size(item.id)), formatter.string(from: Date(timeIntervalSince1970: Double(store.mtime[Int(item.id)]))), result.detail(at: i)?.detail ?? ""]
                    }
                    if let row { rows.append(row) }
                }
                do {
                    try SearchExport.csv(rows).write(to: url, atomically: true, encoding: .utf8)
                    DispatchQueue.main.async { self.footer.text = L10n.local("已导出 \(rows.count - 1) 项", "Exported \(rows.count - 1) items") }
                } catch { DispatchQueue.main.async { self.footer.text = error.localizedDescription } }
            }
        }
    }
}

extension SearchViewController {
    func setGridMode(_ enabled: Bool) {
        if results.gridMode != enabled { supplementaryProvider?.userActivity(visible: true, typing: true) }
        results.gridMode = enabled; toolsBar.gridMode = enabled
        view.needsLayout = true
        preferences.set(enabled, forKey: "search.grid"); searchField.focus()
    }
    private func deliver(_ result: SearchPresentation, token: Int, refresh: Bool, selection: Int, atomic: Bool = false, completion: (() -> Void)? = nil, resume: SearchPresentation? = nil) {
        let filter = effectiveRefinement, scores = usage.scores(for: searchField.text), options = filters.options
        let assetToken = assetGeneration.next()
        if !filter.active && scores.isEmpty {
            pendingNewSearch = nil
            if refresh { results.refresh(result) } else { present(result, selection: selection) }
            completion?()
            return
        }
        if filter.active && !atomic { footer.text = L10n.text("asset.checking") }
        let reader = metadata
        assetQueue.async { [weak self] in
            guard let self else { return }
            let cancelled = { !self.generation.current(token) || !self.assetGeneration.current(assetToken) }
            var first = true
            func submit(_ value: SearchPresentation, final: Bool = false) {
                guard !cancelled() else { return }
                let ranked = value.ranked(scores, options: options), reset = first && !refresh
                first = false
                DispatchQueue.main.async { [weak self] in
                    guard let self, !cancelled() else { return }
                    guard ranked.hasSameSources(as: self.searchSources) else {
                        if final { self.refreshRequested = true; completion?() }
                        return
                    }
                    self.pendingNewSearch = nil
                    if reset { self.present(ranked, selection: selection) } else { self.results.refresh(ranked) }
                    if final { completion?() }
                }
            }
            if filter.active {
                if let filtered = result.refined(filter, reader: reader, cancelled: cancelled, progress: atomic ? nil : { submit($0) }, budget: 4, resume: resume) { submit(filtered, final: true) }
            } else { submit(result, final: true) }
        }
    }
    func continueRefinement() {
        guard let previous = results.result, previous.refinementPaused,
              let origin = previous.refinementOrigin else { return }
        guard previous.refinementFilter == effectiveRefinement, origin.isCurrent(searchSources) else { startSearch(); return }
        let token = generation.next()
        searchInFlight = true
        deliver(origin, token: token, refresh: true, selection: results.selectedRow, completion: { [weak self] in self?.finishSearch(token) }, resume: previous)
    }
    func makeRefinementMenu() -> NSMenu {
        let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
        let location = NSMenuItem(title: L10n.text("filter.location"), action: nil, keyEquivalent: "")
        location.submenu = makeScopeMenu(); location.submenu?.delegate = nil; menu.addItem(location)
        let type = NSMenuItem(title: L10n.text("filter.type"), action: nil, keyEquivalent: ""), types = NSMenu()
        for (index, name) in FilterBar.names.enumerated() {
            let action = SearchAction(id: "kind:\(index)", title: L10n.text("filter." + name), checked: Int(filters.options.kind ?? 0) == index) { [weak self] in self?.filters.select(index) }
            types.addItem(action.menuItem())
        }
        type.submenu = types; menu.addItem(type)
        let time = NSMenuItem(title: L10n.text("filter.capture"), action: nil, keyEquivalent: ""), times = NSMenu(); times.autoenablesItems = false
        for days in [0, 7, 30, 90] {
            let action = SearchAction(id: "capture:\(days)", title: days == 0 ? L10n.text("filter.anyTime") : L10n.text("filter.lastDays", String(days))) { [weak self] in
                guard let self else { return }
            if self.filters.aiSelected {
                self.clearSimilarityMode(); self.naturalPlan = nil; self.adoptedConditions = []
                self.browsingFolder = false; self.recursiveFolder = false
                self.toolsBar.folder = nil; self.toolsBar.refinement = AssetRefinement()
                return
            }
            self.adoptNaturalConditions()
                self.toolsBar.refinement.captured = days == 0 ? nil : DateInterval(start: Date().addingTimeInterval(-Double(days) * 86400), end: Date())
                self.startSearch(); self.searchField.focus()
            }
            times.addItem(action.menuItem())
        }
        time.submenu = times; menu.addItem(time); menu.addItem(.separator())
        let media = NSMenuItem(title: toolsBar.refinement.media == .all ? L10n.text("asset.all") : toolsBar.refinement.media.title, action: nil, keyEquivalent: "")
        let options = NSMenu()
        for filter in AssetFilter.allCases {
            let item = NSMenuItem(title: filter == .all ? L10n.text("tools.noMediaFilter") : filter.title, action: #selector(selectMedia(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = filter.rawValue; item.state = filter == toolsBar.refinement.media ? .on : .off; options.addItem(item)
        }
        media.submenu = options; menu.addItem(media)
        let tags = NSMenuItem(title: L10n.text("asset.tags") + (toolsBar.refinement.tag.isEmpty ? "" : ": " + toolsBar.refinement.tag), action: nil, keyEquivalent: "")
        tags.submenu = makeTagsMenu(); menu.addItem(tags)
        let dimensions = NSMenuItem(title: L10n.text("workspace.dimensions"), action: #selector(editDimensions), keyEquivalent: "")
        dimensions.target = self; menu.addItem(dimensions)
        if toolsBar.refinement.captured != nil {
            let capture = NSMenuItem(title: toolsBar.refinement.captureDescription, action: nil, keyEquivalent: "")
            capture.isEnabled = false; menu.addItem(capture)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: L10n.text("tools.clearFilters"), action: #selector(clearRefinement), keyEquivalent: "")
        clear.target = self; clear.isEnabled = toolsBar.refinement.active; menu.addItem(clear)
        menu.addItem(.separator())
        let hint = NSMenuItem(title: L10n.text("workspace.indexingMetadata"), action: nil, keyEquivalent: ""); hint.isEnabled = false; menu.addItem(hint)
        return menu
    }
    private func showRefinementMenu() { toolsBar.refine.present(makeRefinementMenu()) }
    @objc private func clearRefinement() { adoptNaturalConditions(); toolsBar.refinement = AssetRefinement(); startSearch(); searchField.focus() }
    func makeMoreMenu() -> NSMenu {
        let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
        if results.result?.refinementPaused == true {
            menu.addItem(SearchAction(id: "continueMetadata", title: L10n.text("asset.continue")) { [weak self] in self?.continueRefinement() }.menuItem())
            menu.addItem(.separator())
        }
        let library = NSMenuItem(title: L10n.text("tools.library"), action: nil, keyEquivalent: "")
        library.image = Theme.symbol("bookmark", size: 13, weight: .regular)
        library.submenu = makeSearchLibraryMenu(); library.submenu?.delegate = nil; menu.addItem(library)
        menu.addItem(.separator())
        for action in searchActions() { menu.addItem(action.menuItem()) }
        return menu
    }
    private func searchActions() -> [SearchAction] {
        var values = [SearchAction]()
        if supplementaryProvider != nil {
            values.append(SearchAction(id: "chooseSimilarity", title: L10n.text("semantic.choose"), symbol: "photo.on.rectangle.angled", group: .search) { [weak self] in self?.chooseSimilarityImage() })
        }
        values.append(SearchAction(id: "export", title: L10n.text("tools.export"), symbol: "square.and.arrow.up", group: .search,
                                   enabled: (results.result?.count ?? 0) > 0, shortcut: "⌘⇧E", keyEquivalent: "e", modifiers: [.command, .shift]) { [weak self] in self?.exportResults() })
        for (id, symbol, run) in [
            ("addShortcut", "plus", { [weak self] in self?.editShortcut(nil) }),
            ("importBookmarks", "square.and.arrow.down", { [weak self] in self?.importBookmarks() }),
            ("manageShortcuts", "bookmark", { [weak self] in self?.manageShortcuts() })
        ] as [(String, String, () -> Void)] {
            values.append(SearchAction(id: id, title: L10n.text("workspace." + id), symbol: symbol, group: .search, run: run))
        }
        if supplementaryProvider != nil {
            values.append(SearchAction(id: "contentFolders", title: L10n.text("semantic.coverage"), symbol: "folder.badge.gearshape", group: .search) { [weak self] in self?.onSettings?() })
        }
        return values
    }
    private func showMoreMenu() { toolsBar.more.present(makeMoreMenu()) }
    @objc private func exportFromMenu() { exportResults() }
    @objc private func selectMedia(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let filter = AssetFilter(rawValue: raw) else { return }
        toolsBar.refinement.media = filter; startSearch(); searchField.focus()
    }
    private func makeTagsMenu() -> NSMenu {
        let menu = NSMenu()
        let all = NSMenuItem(title: L10n.text("asset.clearTag"), action: #selector(clearTag), keyEquivalent: ""); all.target = self
        all.state = toolsBar.refinement.tag.isEmpty ? .on : .off; menu.addItem(all)
        let choose = NSMenuItem(title: L10n.text("asset.chooseTag"), action: #selector(chooseTag), keyEquivalent: ""); choose.target = self; menu.addItem(choose)
        return menu
    }
    @objc private func clearTag() { toolsBar.refinement.tag = ""; startSearch(); searchField.focus() }
    @objc private func chooseTag() {
        guard let window = view.window else { return }
        let alert = NSAlert(); alert.messageText = L10n.text("asset.tagPrompt"); alert.informativeText = L10n.text("asset.tagHelp")
        alert.addButton(withTitle: L10n.text("asset.apply")); alert.addButton(withTitle: L10n.text("asset.cancel"))
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 28)); input.stringValue = toolsBar.refinement.tag
        input.placeholderString = "Project A"; alert.accessoryView = input
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.toolsBar.refinement.tag = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            self.startSearch(); self.searchField.focus()
        }
        alert.window.makeFirstResponder(input)
    }
    func makeProjectMenu() -> NSMenu {
        let menu = NSMenu()
        let all = NSMenuItem(title: L10n.text("project.all"), action: #selector(selectScope(_:)), keyEquivalent: ""); all.target = self; menu.addItem(all)
        for project in projects.folders {
            let item = NSMenuItem(title: project.name, action: #selector(selectScope(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = project.path; item.toolTip = project.path; item.state = toolsBar.folder == project.path ? .on : .off; menu.addItem(item)
        }
        menu.addItem(.separator())
        let add = NSMenuItem(title: L10n.text("project.add"), action: #selector(addProject), keyEquivalent: ""); add.target = self; menu.addItem(add)
        if projects.folders.contains(where: { $0.path == toolsBar.folder }) {
            let remove = NSMenuItem(title: L10n.text("project.remove"), action: #selector(removeProject), keyEquivalent: ""); remove.target = self; menu.addItem(remove)
        }
        return menu
    }
    @objc private func addProject() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.prompt = L10n.text("asset.apply"); panel.message = L10n.text("project.hint")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let path = url.resolvingSymlinksInPath().path
            self.projects.add(path); self.toolsBar.folder = path; self.startSearch(); self.searchField.focus()
        }
    }
    @objc private func removeProject() {
        if let path = toolsBar.folder { projects.remove(path) }
    }
}

extension SearchViewController {
    private func updateContextBar() {
        if filters.aiSelected { contextBar.isHidden = true; filters.interpretedKind = nil; diagnostics = []; view.needsLayout = true; return }
        toolsBar.contextFolder = naturalPlan?.folder
        let typeNames: [String: UInt8] = ["kind:folder": 1, "kind:app": 2, "kind:doc": 3, "ext:pdf": 3, "kind:image": 4, "kind:video": 5, "kind:audio": 6]
        filters.interpretedKind = (naturalPlan?.conditions ?? adoptedConditions).compactMap { typeNames[$0.token] }.first
        var conditions = [ActiveSearchCondition]()
        if let folder = effectiveFolder { conditions.append(.init(id: "folder", title: URL(fileURLWithPath: folder).lastPathComponent)) }
        if let kind = filters.options.kind, Int(kind) < FilterBar.names.count { conditions.append(.init(id: "kind", title: L10n.text("filter." + FilterBar.names[Int(kind)]))) }
        let refinement = effectiveRefinement
        if refinement.media != .all { conditions.append(.init(id: "media", title: refinement.media.title)) }
        if !refinement.tag.isEmpty { conditions.append(.init(id: "tag", title: refinement.tag)) }
        if let width = refinement.minWidth { conditions.append(.init(id: "width", title: L10n.text("workspace.widthOver", String(width - 1)))) }
        if let height = refinement.minHeight { conditions.append(.init(id: "height", title: L10n.text("workspace.heightOver", String(height - 1)))) }
        if let captured = refinement.captured {
            let days = Int((captured.duration / 86400).rounded())
            let title: String
            if days > 0, abs(captured.end.timeIntervalSinceNow) < 300, abs(captured.duration - Double(days) * 86400) < 1 {
                title = L10n.text("filter.capture") + ": " + L10n.text("filter.lastDays", String(days))
            } else if Calendar(identifier: .gregorian).dateInterval(of: .month, for: captured.start) == captured {
                let formatter = DateFormatter(); formatter.dateFormat = "yyyy/MM"
                title = L10n.text("filter.capture") + ": " + formatter.string(from: captured.start)
            } else {
                let formatter = DateFormatter(); formatter.dateFormat = "yyyy/MM/dd"
                title = L10n.text("filter.capture") + ": " + formatter.string(from: captured.start) + "–" + formatter.string(from: captured.end)
            }
            conditions.append(.init(id: "captured", title: title, help: refinement.captureDescription))
        }
        for value in naturalPlan?.conditions ?? adoptedConditions { conditions.append(.init(id: "token:" + value.token, title: value.title)) }
        contextBar.update(text: browsingFolder ? effectiveFolder : nil, browsing: browsingFolder, canBack: !backStack.isEmpty,
                          canForward: !forwardStack.isEmpty, recursive: recursiveFolder, conditions: conditions, similarity: similarityPath)
        view.needsLayout = true
    }
    private func adoptNaturalConditions() {
        guard let plan = naturalPlan else { return }
        toolsBar.folder = plan.folder ?? toolsBar.folder; toolsBar.refinement = effectiveRefinement
        adoptedConditions = plan.conditions; searchField.text = plan.query; naturalPlan = nil
    }
    func materializeNaturalQuery() {
        adoptNaturalConditions(); startSearch(); searchField.focus()
    }
    func removeSearchCondition(_ id: String) {
        adoptNaturalConditions()
        switch id {
        case "folder": toolsBar.folder = nil; browsingFolder = false
        case "kind": filters.options.kind = nil
        case "media": toolsBar.refinement.media = .all
        case "tag": toolsBar.refinement.tag = ""
        case "width": toolsBar.refinement.minWidth = nil
        case "height": toolsBar.refinement.minHeight = nil
        case "captured": toolsBar.refinement.captured = nil
        default:
            if id.hasPrefix("token:") {
                let token = String(id.dropFirst(6))
                adoptedConditions.removeAll { $0.token == token }
                let pattern = "(?<!\\S)" + NSRegularExpression.escapedPattern(for: token) + "(?!\\S)"
                searchField.text = searchField.text.replacingOccurrences(of: pattern, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if searchField.text.isEmpty { searchField.text = "*" }
        startSearch(); searchField.focus()
    }
    func clearSearchConditions() {
        adoptNaturalConditions()
        for condition in adoptedConditions {
            let pattern = "(?<!\\S)" + NSRegularExpression.escapedPattern(for: condition.token) + "(?!\\S)"
            searchField.text = searchField.text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        adoptedConditions = []; toolsBar.folder = nil; toolsBar.refinement = AssetRefinement(); filters.options.kind = nil; browsingFolder = false
        searchField.text = searchField.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if searchField.text.isEmpty { searchField.text = "*" }
        startSearch(); searchField.focus()
    }
    private func clearSimilarityMode() {
        similarityPath = nil
        if let options = similarityPreviousOptions { filters.options = options }
        similarityPreviousOptions = nil
    }
    func exitSimilaritySearch() {
        clearSimilarityMode(); searchField.text = ""; startSearch(); searchField.focus()
    }
    private var navigationState: SearchNavigationState {
        SearchNavigationState(search: currentSearch, browsing: browsingFolder, recursive: recursiveFolder,
                              selection: results.selectedRow, scroll: results.scrollOrigin, refinement: toolsBar.refinement)
    }
    func enterFolder(_ path: String) {
        backStack.append(navigationState); backStack = Array(backStack.suffix(30)); forwardStack = []
        browsingFolder = true; recursiveFolder = false
        toolsBar.folder = URL(fileURLWithPath: path).standardizedFileURL.path
        toolsBar.mode = .combined; toolsBar.refinement = AssetRefinement(); filters.options.kind = nil
        searchField.text = "*"; startSearch(); searchField.focus()
    }
    func enterSelectedFolder() {
        if case .shortcut(_, let url) = selectedQuickResult, url.isFileURL {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { enterFolder(url.path) }
        } else if let item = results.selectedItem, item.source.store.read({ item.source.store.flags[Int(item.id)] & SiftFlag.dir != 0 && item.source.store.kind[Int(item.id)] != 2 }) {
            enterFolder(item.path)
        }
    }
    func navigateBack() {
        guard let state = backStack.popLast() else { return }
        forwardStack.append(navigationState); restoreNavigation(state)
    }
    func navigateForward() {
        guard let state = forwardStack.popLast() else { return }
        backStack.append(navigationState); restoreNavigation(state)
    }
    func navigateUp() {
        guard browsingFolder, let folder = toolsBar.folder, folder != "/" else { return }
        enterFolder((folder as NSString).deletingLastPathComponent)
    }
    private func restoreNavigation(_ state: SearchNavigationState) {
        browsingFolder = state.browsing; recursiveFolder = state.recursive
        toolsBar.mode = state.search.mode; toolsBar.folder = state.search.folder; toolsBar.refinement = state.refinement
        filters.options = state.search.options; searchField.text = state.search.query
        restoreViewport = state; startSearch(); searchField.focus()
    }
    @objc private func editDimensions() {
        guard let window = view.window else { return }
        let alert = NSAlert(); alert.messageText = L10n.text("workspace.dimensions"); alert.informativeText = L10n.text("workspace.dimensionsHelp")
        alert.addButton(withTitle: L10n.text("workspace.save")); alert.addButton(withTitle: L10n.text("workspace.cancel"))
        let width = NSTextField(string: toolsBar.refinement.minWidth.map(String.init) ?? ""), height = NSTextField(string: toolsBar.refinement.minHeight.map(String.init) ?? "")
        let stack = NSStackView(views: [NSTextField(labelWithString: L10n.text("workspace.width")), width, NSTextField(labelWithString: L10n.text("workspace.height")), height])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6; stack.frame = NSRect(x: 0, y: 0, width: 360, height: 110)
        for field in [width, height] { field.widthAnchor.constraint(equalToConstant: 360).isActive = true }
        alert.accessoryView = stack
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let w = Int(width.stringValue), h = Int(height.stringValue)
            guard (width.stringValue.isEmpty || w.map { (1...1_000_000).contains($0) } == true), (height.stringValue.isEmpty || h.map { (1...1_000_000).contains($0) } == true) else { return }
            self.toolsBar.refinement.minWidth = w; self.toolsBar.refinement.minHeight = h
            self.startSearch(); self.searchField.focus()
        }
    }
    @objc private func showActionsFromMenu() { showActions() }
    func showActions() {
        if syntaxVisible { toggleSyntax(false) }
        _ = generation.next(); _ = assetGeneration.next(); results.cancelPendingRefresh()
        refreshWork?.cancel(); refreshWork = nil; refreshRequested = true
        searchInFlight = false; semanticPending = false
        if selectedQuickResult != nil || results.selectedItem != nil { guide?.send(.useResult) }
        let appearing = actionPalette.isHidden
        actionPalette.show(makeActions(), title: (filters.aiSelected ? conversations.selected?.title : nil) ?? selectedQuickResult?.title ?? results.selectedItem?.name ?? L10n.text("workspace.actionsTitle"))
        view.needsLayout = true
        if appearing { Theme.Motion.reveal(actionPalette) }
    }
    func closeActions() {
        guard !actionPalette.isHidden else { return }
        actionPalette.isHidden = true; searchField.focus(); refreshGuide()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.actionPalette.isHidden, self.view.window?.isVisible == true else { return }
            self.refreshSearch()
        }
    }
    func makeActions() -> [SearchAction] {
        if filters.aiSelected { return conversationActions() }
        if selectedQuickResult == nil, results.selectedItem != nil { return makeFileActions() }
        var values = [SearchAction]()
        func add(_ id: String, _ key: String, _ symbol: String, _ action: @escaping () -> Void) {
            values.append(SearchAction(id: id, title: L10n.text(key), symbol: symbol, run: action))
        }
        var url: URL?
        var name = ""
        switch selectedQuickResult {
        case .application(let app): url = URL(fileURLWithPath: app.path); name = app.name
        case .shortcut(let shortcut, let target): url = target; name = shortcut.name
            add("editShortcut", "workspace.editShortcut", "pencil") { [weak self] in self?.editShortcut(shortcut) }
            add("removeShortcut", "workspace.removeShortcut", "minus.circle") { [weak self] in self?.shortcuts.remove(shortcut.id); self?.startSearch() }
        case .calculation: add("copyAnswer", "quick.copy", "doc.on.doc") { [weak self] in self?.activateQuickResult() }
        case nil: break
        }
        if let url {
            do {
                add("open", "ctx.open", "arrow.up.forward.app") { [weak self] in self?.openSelected() }
            }
            add("alias", "workspace.aliasSelected", "textformat") { [weak self] in self?.editShortcut(SearchShortcut(name: name, destination: url.isFileURL ? url.path : url.absoluteString)) }
            add("copyPath", "ctx.copyPath", "link") { [weak self] in
                self?.resultPasteboard.clearContents(); self?.resultPasteboard.setString(url.isFileURL ? url.path : url.absoluteString, forType: .string)
                self?.footer.showToast(.copiedPath, value: url.isFileURL ? url.path : url.absoluteString)
            }
            if url.isFileURL {
                do {
                    add("copyFile", "workspace.copyFile", "doc.on.doc") { [weak self] in
                        self?.resultPasteboard.clearContents(); self?.resultPasteboard.writeObjects([url as NSURL])
                        self?.footer.showToast(.copiedPath, value: url.lastPathComponent)
                    }
                    add("reveal", "ctx.reveal", "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    add("openWith", "workspace.openWith", "app") { [weak self] in self?.openWith(url) }
                    add("terminal", "workspace.terminal", "terminal") { [weak self] in self?.openTerminal(url) }
                    add("share", "workspace.share", "square.and.arrow.up") { [weak self] in
                        guard let self else { return }
                        NSSharingServicePicker(items: [url]).show(relativeTo: self.toolsBar.more.bounds, of: self.toolsBar.more, preferredEdge: .minY)
                    }
                }

            }
        }
        values += searchActions()
        add("checkPath", "workspace.checkPath", "questionmark.circle") { [weak self] in self?.diagnosePath() }
        add("clearLearning", "workspace.clearLearning", "arrow.counterclockwise") { [weak self] in self?.usage.clear(); self?.footer.text = L10n.text("workspace.learningCleared") }
        return values
    }
    func makeFileActions() -> [SearchAction] {
        guard let file = results.selectedItem else { return [] }
        let url = URL(fileURLWithPath: file.path)
        let online = file.source.isOnline
        let detail = online ? "" : L10n.text("source.offline")
        var values = [SearchAction]()
        func add(_ id: String, _ title: String, _ symbol: String, group: SearchAction.Group = .view,
                 enabled: Bool = true, shortcut: String = "", key: String = "", modifiers: NSEvent.ModifierFlags = .command,
                 checked: Bool = false, _ run: @escaping (SearchViewController) -> Void) {
            values.append(SearchAction(id: id, title: title, detail: enabled ? "" : detail, symbol: symbol, group: group,
                                       enabled: enabled, shortcut: shortcut, keyEquivalent: key, modifiers: modifiers, checked: checked) { [weak self] in
                guard let self, let result = self.results.result,
                      let row = result.index(sourceID: file.source.id, store: file.source.store, id: file.id, path: file.path),
                      let current = self.results.item(at: row), current.path == file.path else { return }
                // A disconnected/replaced source must not turn a retained menu action into a different file action.
                if online && !current.source.isOnline { self.footer.text = L10n.text("source.offline"); return }
                self.selectQuickResult(nil); self.results.select(row); run(self)
            })
        }
        add("open", L10n.text("ctx.open"), "arrow.up.forward.app", enabled: online, shortcut: "↵", key: "\r", modifiers: []) { $0.openSelected() }
        add("reveal", L10n.text("ctx.reveal"), "folder", enabled: online, shortcut: "⌘↵", key: "\r") { $0.revealSelected() }
        add("preview", L10n.text("ctx.preview"), "eye", enabled: online, shortcut: "⌘Y", key: "y") { $0.previewSelected() }
        if file.flags & SiftFlag.dir != 0 && file.kind != 2 {
            add("enterFolder", L10n.text("workspace.enterFolder"), "folder.badge.magnifyingglass") { $0.enterFolder(file.path) }
        } else if supplementaryProvider != nil || file.detail != nil {
            add("previewText", previewActionTitle, "doc.text.magnifyingglass", enabled: online || file.detail?.matchedPage == nil,
                shortcut: "⌘⇧Y", key: "y", modifiers: [.command, .shift]) { $0.previewText() }
        }
        if isSimilarityImageSelected, supplementaryProvider != nil {
            add("similarity", L10n.text("semantic.similar"), "photo.on.rectangle.angled") { $0.findSimilar(path: file.path) }
        }
        add("copyFile", L10n.text("workspace.copyFile"), "doc.on.doc", group: .use, enabled: online) {
            $0.resultPasteboard.clearContents(); $0.resultPasteboard.writeObjects([url as NSURL]); $0.footer.showToast(.copiedPath, value: file.name)
        }
        add("copyPath", L10n.text("ctx.copyPath"), "link", group: .use, shortcut: "⌘C", key: "c") { $0.copyPath() }
        add("copyName", L10n.text("ctx.copyName"), "textformat", group: .use, shortcut: "⌘⌥C", key: "c", modifiers: [.command, .option]) { $0.copyName() }
        let saved = fileFavorites.contains(sourceID: file.source.id, path: file.path)
        add("favorite", L10n.text(saved ? "file.unfavorite" : "file.favorite"), saved ? "star.fill" : "star", group: .use,
            shortcut: "⌘D", key: "d", checked: saved) { $0.toggleFileFavorite(file) }
        add("openWith", L10n.text("workspace.openWith"), "app", group: .use, enabled: online) { $0.openWith(url) }
        add("share", L10n.text("workspace.share"), "square.and.arrow.up", group: .use, enabled: online) {
            NSSharingServicePicker(items: [url]).show(relativeTo: $0.toolsBar.more.bounds, of: $0.toolsBar.more, preferredEdge: .minY)
        }
        add("alias", L10n.text("workspace.aliasSelected"), "textformat.abc", group: .more) { $0.editShortcut(SearchShortcut(name: file.name, destination: file.path)) }
        add("terminal", L10n.text("workspace.terminal"), "terminal", group: .more, enabled: online) { $0.openTerminal(url) }
        add("trash", L10n.text("ctx.trash"), "trash", group: .destructive, enabled: online, shortcut: "⌘⌫", key: "\u{8}") { $0.trashSelected() }
        return values
    }
    private func openSemanticPage(path: String, page: Int, expectedStamp: String?) {
        let generation = previewGeneration, request = previewGeneration.next()
        footer.text = L10n.text("workspace.pdfLoading")
        previewQueue.async { [weak self] in
            let url = URL(fileURLWithPath: path), stamp = ContentMatchIndex.currentStamp(URL(fileURLWithPath: path))
            let document = PDFDocument(url: url)
            let current = stamp != nil && stamp == expectedStamp && stamp == ContentMatchIndex.currentStamp(url)
            DispatchQueue.main.async {
                guard let self, generation.current(request), self.results.selectedItem?.path == path else { return }
                guard current, let document, let target = document.page(at: page - 1) else { self.footer.text = L10n.text("workspace.stalePreview"); return }
                let view = PDFView(); view.document = document; view.autoScales = true; view.go(to: target)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                window.title = url.lastPathComponent + " · " + L10n.text("workspace.page", String(page)); window.contentView = view; window.isReleasedWhenClosed = false; window.center()
                self.semanticPDF?.close(); self.semanticPDF = NSWindowController(window: window); self.semanticPDF?.showWindow(nil)
                self.footer.text = window.title
            }
        }
    }
    private var isSimilarityImageSelected: Bool {
        guard selectedQuickResult == nil, let item = results.selectedItem, item.source.isOnline else { return false }
        return ["png","jpg","jpeg","heic","heif","tif","tiff","bmp","gif","webp","avif"].contains(URL(fileURLWithPath: item.path).pathExtension.lowercased())
    }
    private var previewActionTitle: String {
        if let page = results.result?.detail(at: results.selectedRow)?.matchedPage {
            return L10n.text("semantic.openPage", String(page))
        }
        return L10n.text(results.selectedItem?.detail == nil ? "tools.fileContents" : "tools.previewText")
    }
    @objc private func openSemanticSettings() { onSettings?() }
    @objc private func similarSelectedImage() {
        guard isSimilarityImageSelected, let path = results.selectedItem?.path else { return }
        findSimilar(path: path)
    }
    func findSimilar(path: String) {
        if let status = supplementaryProvider?.semanticStatus, !status.canSearch { onSettings?(); return }
        if similarityPreviousOptions == nil { similarityPreviousOptions = filters.options }
        similarityPath = path; setBrowsing(false); naturalPlan = nil; adoptedConditions = []
        searchField.text = L10n.text("semantic.reference", URL(fileURLWithPath:path).lastPathComponent)
        filters.options.kind = 4; filters.options.sort = .relevance
        startSearch(); searchField.focus()
    }
    @objc private func chooseSimilarityImage() {
        if let status = supplementaryProvider?.semanticStatus, !status.canSearch { onSettings?(); return }
        guard let window = view.window else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        panel.message = L10n.text("semantic.chooseHelp")
        panel.beginSheetModal(for:window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.findSimilar(path:url.path) }
        }
    }
    @objc private func addShortcutFromMenu() { editShortcut(nil) }
    func editShortcut(_ existing: SearchShortcut?) {
        guard let window = view.window else { return }
        let alert = NSAlert(); alert.messageText = L10n.text(existing == nil ? "workspace.addShortcut" : "workspace.editShortcut")
        alert.informativeText = L10n.text("workspace.shortcutHelp")
        alert.addButton(withTitle: L10n.text("workspace.save")); alert.addButton(withTitle: L10n.text("workspace.cancel"))
        let name = NSTextField(string: existing?.name ?? ""), destination = NSTextField(string: existing?.destination ?? ""), alias = NSTextField(string: existing?.keyword ?? "")
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 5
        stack.frame = NSRect(x: 0, y: 0, width: 420, height: 165)
        for (field, key) in [(name, "name"), (destination, "destination"), (alias, "alias")] {
            let label = NSTextField(labelWithString: L10n.text("workspace." + key)); label.font = .systemFont(ofSize: 11)
            stack.addArrangedSubview(label); stack.addArrangedSubview(field); field.widthAnchor.constraint(equalToConstant: 420).isActive = true
            field.setAccessibilityLabel(label.stringValue)
        }
        alert.accessoryView = stack
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            var item = existing ?? SearchShortcut(name: "", destination: "")
            item.name = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            item.destination = destination.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            item.keyword = alias.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if self.shortcuts.save(item) { self.startSearch() }
            else { self.footer.warning = true; self.footer.text = L10n.text("workspace.invalidShortcut") }
        }
        alert.window.makeFirstResponder(name)
    }
    @objc private func manageShortcuts() {
        let actions = shortcuts.items.map { item in
            SearchAction(id: item.id, title: item.name, detail: item.destination, symbol: "bookmark") { [weak self] in
                guard let self else { return }
                self.actionPalette.show([
                    SearchAction(id: "edit", title: L10n.text("workspace.editShortcut"), symbol: "pencil", run: { [weak self] in self?.editShortcut(item) }),
                    SearchAction(id: "remove", title: L10n.text("workspace.removeShortcut"), symbol: "minus.circle", run: { [weak self] in self?.shortcuts.remove(item.id); self?.startSearch() })
                ], title: item.name)
            }
        }
        actionPalette.show(actions, title: L10n.text(actions.isEmpty ? "workspace.emptyShortcuts" : "workspace.manageShortcuts")); view.needsLayout = true
    }
    @objc private func importBookmarks() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = L10n.text("workspace.importHelp")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.assetQueue.async {
                let imported: [SearchShortcut]?
                do {
                    guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8 * 1024 * 1024 else { throw BookmarkImport.Failure.tooLarge }
                    imported = try BookmarkImport.parse(Data(contentsOf: url), format: url.pathExtension)
                } catch { imported = nil }
                DispatchQueue.main.async {
                    if let imported { let count = self.shortcuts.merge(imported); self.startSearch(); self.footer.text = L10n.text("workspace.imported", String(count)) }
                    else { self.footer.warning = true; self.footer.text = L10n.text("workspace.importFailed") }
                }
            }
        }
    }
    private func openWith(_ url: URL) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel(); panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.allowedContentTypes = [.applicationBundle]
        panel.message = L10n.text("workspace.openWith"); panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let application = panel.url else { return }
            NSWorkspace.shared.open([url], withApplicationAt: application, configuration: .init()) { _, error in
                DispatchQueue.main.async { if let error { self?.footer.text = error.localizedDescription } else { self?.hidePanel?() } }
            }
        }
    }
    private func openTerminal(_ url: URL) {
        assetQueue.async { [weak self] in
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let folder = isFolder ? url : url.deletingLastPathComponent()
            DispatchQueue.main.async {
                guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
                NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: .init()) { _, error in
                    DispatchQueue.main.async { if let error { self?.footer.text = error.localizedDescription } else { self?.hidePanel?() } }
                }
            }
        }
    }
    private func diagnosePath() {
        guard let window = view.window else { return }
        let alert = NSAlert(); alert.messageText = L10n.text("workspace.checkPath"); alert.informativeText = L10n.text("workspace.checkHelp")
        alert.addButton(withTitle: L10n.text("workspace.check")); alert.addButton(withTitle: L10n.text("workspace.cancel"))
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 430, height: 28)); input.placeholderString = L10n.text("workspace.path")
        input.stringValue = selectedURL?.path ?? ""; alert.accessoryView = input
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let path = (Query.normalizePaste(input.stringValue) as NSString).expandingTildeInPath
            guard path.hasPrefix("/") else { return }
            let sources = self.searchSources, manager = self.manager, folder = self.effectiveFolder
            let content = self.supplementaryProvider?.prepareDiagnosis(path: path, sources: sources)
            self.assetQueue.async {
                let source = sources.first { source in source.store.read { source.store.containsPath(path) } }
                let explanation = source?.explain(path: path) ?? manager?.explain(path: path)
                var lines = [path]
                if let folder, !ExcludedFolders.contains(folder, path: path) { lines.append(L10n.text("workspace.outOfScope")) }
                if let source, !source.isOnline { lines.append(L10n.text("source.unavailable", source.displayName)) }
                if let explanation { lines.append(L10n.explanation(explanation)) }
                if let content { lines.append(content()) }
                DispatchQueue.main.async {
                    let result = NSAlert(); result.messageText = L10n.text("workspace.diagnosis"); result.informativeText = lines.joined(separator: "\n\n")
                    if let window = self.view.window { result.beginSheetModal(for: window) }
                }
            }
        }
        alert.window.makeFirstResponder(input)
    }
}

extension SearchViewController {
    private func searchConversations(token: Int, preserveSelection: Bool) {
        quickResults.show([], selection: nil); results.clear()
        calculationOnly = false; semanticPending = false; semanticAttempted = false
        pendingNewSearch = nil; selectionAnchor = nil; diagnostics = []
        quickLook.close(); inlinePreview.clear(); setState(nil)
        footer.context = .conversations; footer.warning = false; footer.actionable = false
        let text = searchField.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let manager = aiTopics, manager.isEnabled else {
            conversations.setMessage(L10n.local("开启本地 AI 对话搜索，找回 Codex、Claude Code 和 WorkBuddy 中聊过的内容", "Enable local conversation search for Codex, Claude Code and WorkBuddy"), setup: true)
            footer.text = L10n.local("尚未开启对话来源", "Conversation sources are not enabled"); return
        }
        guard !text.isEmpty else {
            conversations.setMessage(L10n.local("输入关键词，找回聊过的内容", "Search for something you discussed"), setup: false)
            conversationQuery = ""; conversationWindow?.close()
            footer.text = L10n.text("topicsDone", String(manager.count)); return
        }
        let sameQuery = conversationQuery == text
        conversationQuery = text; searchInFlight = true
        if conversations.topics.isEmpty { conversations.setMessage(L10n.local("正在查找本地对话…", "Searching local conversations…"), setup: false) }
        footer.text = L10n.local("正在查找本地对话…", "Searching local conversations…")
        manager.search(text == "*" ? "" : text, provider: nil, limit: 500) { [weak self] response in
            guard let self, self.filters.aiSelected, self.generation.current(token) else { return }
            self.searchInFlight = false
            switch response {
            case .success(let result):
                self.conversations.show(result.topics, preserveSelection: preserveSelection && sameQuery)
                self.footer.actionable = !result.topics.isEmpty
                self.footer.text = L10n.local("本地对话 ", "Local conversations ") + String(result.topics.count) + (result.hasMore ? "+" : "") + " · " + Presentation.elapsedText(result.elapsedMs) + " ms"
                if result.topics.isEmpty && manager.indexing {
                    self.conversations.setMessage(L10n.local("还没有匹配的对话，已开启的来源正在同步", "No matches yet. Enabled sources are still syncing."), setup: false)
                }
            case .failure:
                self.conversations.setMessage(L10n.local("对话索引尚未就绪，请在设置中查看同步状态", "The conversation index is not ready. Check its status in Settings."), setup: true)
                self.footer.text = L10n.text("topicsSyncFailed")
            }
            if self.refreshRequested { self.refreshSearch() }
        }
    }
    private func conversationUnavailable() {
        footer.warning = true
        footer.text = L10n.local("这段对话已不可用，请重新搜索或检查来源设置", "This conversation is unavailable. Search again or check its source.")
    }
    private func openConversation(key: String? = nil) {
        guard let manager = aiTopics, let key = key ?? conversations.selected?.key else { return }
        guard openingConversation != key else { return }
        let request = conversationOpenGeneration.next()
        openingConversation = key
        manager.resolve(key) { [weak self] topic in
            guard let self, self.conversationOpenGeneration.current(request) else { return }
            guard let topic else { self.openingConversation = nil; self.conversationUnavailable(); return }
            if AITopicActions.desktopURL(topic) == nil {
                self.openingConversation = nil
                self.previewConversation(key: key)
                return
            }
            self.footer.warning = false
            self.footer.text = L10n.local("正在打开原会话…", "Opening original conversation…")
            self.openConversationClient(topic) { [weak self] result in
                guard let self, self.conversationOpenGeneration.current(request) else { return }
                self.openingConversation = nil
                switch result {
                case .dispatched:
                    self.conversationWindow?.close(); self.hidePanel?()
                case .unavailable, .failed:
                    let message = result == .unavailable
                        ? L10n.local("找不到可打开此对话的桌面客户端。可预览内容或复制继续会话命令。", "No desktop client is available. Preview the content or copy the resume command.")
                        : L10n.local("未能打开原会话，请重试。也可以预览或复制对话内容。", "Could not open the original. Try again, or preview and copy its content.")
                    self.footer.warning = true; self.footer.text = message
                    self.conversationWindow?.showStatus(message)
                }
            }
        }
    }
    private func previewConversation(key: String? = nil, copy: Bool = false) {
        guard let manager = aiTopics, let key = key ?? conversations.selected?.key else { return }
        let request = previewGeneration.next(), query = searchField.text
        manager.transcript(key) { [weak self] result in
            guard let self, self.previewGeneration.current(request) else { return }
            switch result {
            case .success(let content):
                if copy {
                    self.resultPasteboard.clearContents(); self.resultPasteboard.setString(content.markdown, forType: .string)
                    self.footer.text = content.truncated ? L10n.local("已复制部分对话（原文较长）", "Copied partial conversation (long transcript)") : L10n.local("已复制对话内容", "Conversation copied")
                    self.conversationWindow?.showStatus(self.footer.text)
                } else {
                    self.conversationWindow?.close()
                    let window = AIConversationWindow(content: content, query: query)
                    window.onOpen = { [weak self] in self?.openConversation(key: key) }
                    window.onCopy = { [weak self] in self?.previewConversation(key: key, copy: true) }
                    window.onResume = { [weak self] in
                        manager.resolve(key) { topic in
                            guard let self, let topic else { return }
                            self.resultPasteboard.clearContents(); self.resultPasteboard.setString(topic.resumeCommand, forType: .string)
                            self.conversationWindow?.showStatus(L10n.local("已复制继续会话命令，在终端粘贴运行即可继续。", "Resume command copied. Paste it into Terminal to continue."))
                        }
                    }
                    self.conversationWindow = window; window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil)
                }
            case .failure: self.conversationUnavailable()
            }
        }
    }
    private func conversationActions() -> [SearchAction] {
        guard let topic = conversations.selected, let manager = aiTopics else {
            return [SearchAction(id: "topicSources", title: L10n.local("设置对话来源…", "Set up conversation sources…"), symbol: "gearshape", run: { [weak self] in self?.onSettings?() })]
        }
        let key = topic.key
        var actions = [
            SearchAction(id: "topicPreview", title: L10n.local("查看对话内容", "View conversation"), symbol: "text.bubble", shortcut: "⌘Y", run: { [weak self] in self?.previewConversation(key: key) }),
            SearchAction(id: "topicCopyContent", title: L10n.local("复制对话内容", "Copy conversation"), symbol: "doc.on.doc", group: .use, shortcut: "⌘C", run: { [weak self] in self?.previewConversation(key: key, copy: true) })
        ]
        if AITopicActions.desktopURL(topic) != nil {
            actions.insert(SearchAction(id: "topicOpen", title: L10n.local("在原应用中打开", "Open in original app"), symbol: "arrow.up.forward.app", shortcut: "↩", run: { [weak self] in self?.openConversation(key: key) }), at: 0)
        }
        if UUID(uuidString: topic.id) != nil || AITopicActions.desktopURL(topic) != nil {
            actions.append(SearchAction(id: "topicResume", title: L10n.text("topicsCopyResume"), symbol: "terminal", group: .use, run: { [weak self] in
                manager.resolve(key) { topic in
                    guard let self, let topic else { self?.conversationUnavailable(); return }
                    self.resultPasteboard.clearContents(); self.resultPasteboard.setString(topic.resumeCommand, forType: .string)
                    self.footer.text = L10n.local("已复制继续会话命令", "Resume command copied")
                }
            }))
        }
        actions.append(SearchAction(id: "topicSources", title: L10n.local("管理对话来源…", "Manage conversation sources…"), symbol: "gearshape", group: .more, run: { [weak self] in self?.onSettings?() }))
        return actions
    }
    private func handleConversationKey(_ event: NSEvent, command: Bool, key: String) -> Bool {
        switch event.keyCode {
        case 125: conversations.move(1); setBrowsing(true); return true
        case 126: conversations.move(-1); setBrowsing(true); return true
        case 115: conversations.select(0); setBrowsing(true); return true
        case 119: conversations.select(conversations.topics.count - 1); setBrowsing(true); return true
        case 116: conversations.move(-6); setBrowsing(true); return true
        case 121: conversations.move(6); setBrowsing(true); return true
        case 36, 76: openConversation(); return true
        case 49 where browsingResults && previewWithSpace && !command: previewConversation(); return true
        case 51 where command: return true
        default: break
        }
        if command && key == "y" { previewConversation(); return true }
        if command && key == "c" { previewConversation(copy: true); return true }
        return false
    }
}
