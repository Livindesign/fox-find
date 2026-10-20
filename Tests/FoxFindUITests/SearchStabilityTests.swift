import AppKit
import XCTest
import FoxFindCore
@testable import FoxFindApp

private final class StabilityProvider: SupplementarySearchProvider {
    var isEnabled = true
    var gate: DispatchSemaphore?
    var empty = false
    var prepared = 0
    var onStarted: (() -> Void)?
    var onLexicalStarted: (() -> Void)?
    func sourcesDidChange(_ sources: [SearchSource]) {}
    func userActivity(visible: Bool, typing: Bool) {}
    func prepareSearch(_ query: Query, options: SearchOptions, sources: [SearchSource], isCancelled: @escaping () -> Bool) -> () -> [SupplementaryHit] {
        let started = onLexicalStarted
        return { started?(); return [] }
    }
    func prepareSemantic(_ query: Query, options: SearchOptions, sources: [SearchSource], isCancelled: @escaping () -> Bool) -> (() -> [SupplementaryHit])? {
        prepared += 1
        let gate = gate, empty = empty, onStarted = onStarted
        return {
            onStarted?()
            if let gate { _ = gate.wait(timeout: .now() + 4) }
            guard !isCancelled(), !empty else { return [] }
            return (1...80).map { .init(sourceID: "fixture", entryID: UInt32($0), detail: "Matched passage \($0)", semanticScore: 0.9) }
        }
    }
}

final class SearchStabilityTests: XCTestCase {
    func testFastTypingStartsOnlyTheLastContentQueryAndHideCancelsPendingWork() {
        let store = fixture(), provider = StabilityProvider(), controller = SearchViewController(snapshot: true)
        _ = controller.view
        controller.additionalSources = { [SearchSource(id: "fixture", displayName: "", isOnline: false, store: store)] }
        controller.supplementaryProvider = provider
        let started = expectation(description: "only latest text query starts")
        started.assertForOverFulfill = true
        provider.onLexicalStarted = { started.fulfill() }
        for text in ["item", "item-1", "item-12"] {
            controller.searchField.text = text; controller.startSearch()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        wait(for: [started], timeout: 1)
        waitUntil { !controller.searchInFlight }
        let hidden = expectation(description: "hidden window cancels content and AI"); hidden.isInverted = true
        provider.onStarted = { hidden.fulfill() }; provider.onLexicalStarted = { hidden.fulfill() }
        controller.searchField.text = "item-2"; controller.startSearch(); controller.panelWillHide()
        wait(for: [hidden], timeout: 0.4)
        XCTAssertFalse(controller.searchInFlight)
    }
    func testTypingPublishesNamesBeforeStartingOnlyTheLatestAIRequest() {
        let store = fixture(), provider = StabilityProvider()
        let controller = SearchViewController(snapshot: true)
        _ = controller.view
        controller.additionalSources = { [SearchSource(id: "fixture", displayName: "", isOnline: false, store: store)] }
        controller.supplementaryProvider = provider; controller.toolsBar.mode = .combined
        let began = expectation(description: "only latest AI request starts")
        began.assertForOverFulfill = true
        provider.onStarted = { began.fulfill() }
        for text in ["item", "item-1", "item-12"] {
            controller.searchField.text = text; controller.startSearch()
            RunLoop.main.run(until: Date().addingTimeInterval(0.06))
            XCTAssertGreaterThan(controller.results.result?.count ?? 0, 0, "Filename results must not wait for AI")
        }
        wait(for: [began], timeout: 1)
        waitUntil { !controller.searchInFlight }
        XCTAssertEqual(provider.prepared, 3)
    }

    func testClearCancelsAIRequestBeforeItCanLoadAModel() {
        let store = fixture(), provider = StabilityProvider()
        let controller = SearchViewController(snapshot: true)
        _ = controller.view
        controller.additionalSources = { [SearchSource(id: "fixture", displayName: "", isOnline: false, store: store)] }
        controller.supplementaryProvider = provider
        let started = expectation(description: "cancelled AI must not start"); started.isInverted = true
        provider.onStarted = { started.fulfill() }
        controller.searchField.text = "lighting description"; controller.startSearch()
        controller.searchField.clear.performClick(nil)
        wait(for: [started], timeout: 0.4)
        XCTAssertFalse(controller.searchInFlight)
    }
    private func fixture() -> IndexStore {
        _ = NSApplication.shared
        let names = [""] + (1...120).map { "item-\($0).pdf" }
        var b = ScanBuffer()
        b.ids = (0...120).map(UInt32.init); b.parents = Array(repeating: 0, count: 121)
        b.sizes = Array(repeating: 100, count: 121); b.mtimes = Array(repeating: 10, count: 121)
        b.flags = [1] + Array(repeating: 128, count: 120); b.depths = [0] + Array(repeating: 1, count: 120)
        b.kinds = [1] + Array(repeating: 3, count: 120)
        b.nameLens = names.map { UInt32($0.utf8.count) }; b.nameBytes = Array(names.joined().utf8)
        return IndexStore(scan: ScanOutput(buffers: [b], count: 121, homeIndex: .max, elapsed: 0, finishedAt: 0), config: IndexConfig(rootPath: "/stability-fixture"))
    }
    private func controller(_ provider: StabilityProvider, grid: Bool = false, mode: SearchMode = .contents) -> SearchViewController {
        let store = fixture(), c = SearchViewController(snapshot: true)
        _ = c.view; c.view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        c.additionalSources = { [SearchSource(id: "fixture", displayName: "", isOnline: false, store: store)] }
        c.supplementaryProvider = provider; c.toolsBar.mode = mode; c.results.gridMode = grid
        c.searchField.text = "lighting description"; c.startSearch()
        waitUntil { c.results.result?.count == 80 && !c.searchInFlight }
        c.view.layoutSubtreeIfNeeded()
        return c
    }
    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let end = Date().addingTimeInterval(3)
        while !predicate(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        XCTAssertTrue(predicate(), file: file, line: line)
    }
    func testBackgroundRefreshNeverWithdrawsSemanticResultsOrReloadsIdenticalGrid() {
        for mode in [SearchMode.combined, .contents] {
            for grid in [false, true] {
                let p = StabilityProvider(), c = controller(p, grid: grid, mode: mode)
                c.results.select(35); let selected = c.results.selectedID
                let origin = c.results.scrollOrigin, reloads = c.results.grid.reloadCount
                let gate = DispatchSemaphore(value: 0); p.gate = gate
                defer { for _ in 0..<30 { gate.signal() } }
                let began = expectation(description: "semantic refresh started"); p.onStarted = { began.fulfill() }
                c.sourcesChanged(); wait(for: [began], timeout: 2)
                var emptySamples = 0
                for _ in 0..<40 {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.005))
                    if c.results.result?.count != 80 { emptySamples += 1 }
                }
                gate.signal(); waitUntil { !c.searchInFlight && c.results.result?.count == 80 }
                print("STABILITY mode=\(mode) grid=\(grid) emptySamples=\(emptySamples)/40 reloads=\(c.results.grid.reloadCount - reloads)")
                XCTAssertEqual(emptySamples, 0)
                XCTAssertEqual(c.results.selectedID, selected)
                XCTAssertEqual(c.results.scrollOrigin, origin)
                XCTAssertEqual(c.results.grid.reloadCount, reloads)
            }
        }
    }
    func testNotificationsCoalesceWithoutCancellingRunningSearchAndClearWins() {
        let p = StabilityProvider(), c = controller(p)
        let gate = DispatchSemaphore(value: 0); p.gate = gate
        defer { for _ in 0..<40 { gate.signal() } }
        c.sourcesChanged()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        let prepared = p.prepared
        for _ in 0..<20 { c.sourcesChanged() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(p.prepared, prepared, "Index events must not restart an in-flight query")
        p.gate = nil; gate.signal()
        waitUntil { p.prepared == prepared + 1 && !c.searchInFlight }
        c.searchField.text = ""; c.startSearch()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNil(c.results.result); XCTAssertFalse(c.semanticPending)
    }
    func testCompletedEmptyRefreshReplacesOldResultsAndEditingCancelsQueuedRefresh() {
        let p = StabilityProvider(), c = controller(p)
        p.empty = true; c.sourcesChanged()
        waitUntil { c.results.result?.count == 0 && !c.searchInFlight }
        p.empty = false; c.sourcesChanged()
        c.searchField.text = "item-120"; c.toolsBar.mode = .names; c.startSearch()
        waitUntil { c.results.result?.count == 1 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(c.results.selectedItem?.name, "item-120.pdf")
    }
    func testOpeningActionsDoesNotLeaveSearchPermanentlyInFlight() {
        let p = StabilityProvider(), c = controller(p)
        let gate = DispatchSemaphore(value: 0); p.gate = gate
        defer { gate.signal() }
        c.sourcesChanged(); waitUntil { c.searchInFlight }
        c.showActions(); XCTAssertFalse(c.searchInFlight)
        c.closeActions(); p.gate = nil; gate.signal(); c.sourcesChanged()
        waitUntil { p.prepared >= 3 && !c.searchInFlight }
        XCTAssertEqual(c.results.result?.count, 80)
    }
    func testUnchangedFavoritesDoNotPublishChange() {
        let suite = "StabilityFavorites-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let favorites = FileFavorites(defaults: defaults), done = expectation(description: "favorites reconciled")
        favorites.reconcile(force: true) { changed in XCTAssertFalse(changed); done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertNil(defaults.data(forKey: "file.favorites"))
    }
    func testUnrelatedIndexChangesKeepGridAndVisibleCells() throws {
        let store = fixture(), query = Query.parse("item"), view = ResultsView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        let first = SearchPresentation(try XCTUnwrap(Searcher.search(query, in: store)))
        view.gridMode = true; view.show(first); view.layoutSubtreeIfNeeded()
        let reloads = view.grid.reloadCount, item = try XCTUnwrap(view.item(at: 0))
        let cell = ResultCell(frame: NSRect(x: 0, y: 0, width: 900, height: 50)), icons = IconProvider()
        cell.configure(item, query: query, icons: icons)
        let configurations = cell.configuration
        for _ in 0..<20 {
            store.write { store.version += 1 }
            let next = SearchPresentation(try XCTUnwrap(Searcher.search(query, in: store)))
            view.refresh(next)
            cell.configure(try XCTUnwrap(view.item(at: 0)), query: query, icons: icons, onlyIfChanged: true)
        }
        XCTAssertEqual(view.grid.reloadCount, reloads)
        XCTAssertEqual(cell.configuration, configurations)
        cell.configure(item, query: query, icons: icons, isFavorite: true, onlyIfChanged: true)
        XCTAssertEqual(cell.configuration, configurations + 1)
    }
    func testSettledEmptyResultsDoNotReenterLoadingOnIndexNotifications() {
        let p = StabilityProvider(), c = controller(p)
        p.empty = true; c.sourcesChanged()
        waitUntil { c.results.result?.count == 0 && !c.searchInFlight }
        let gate = DispatchSemaphore(value: 0); p.gate = gate
        defer { gate.signal() }
        c.sourcesChanged(); waitUntil { c.searchInFlight }
        XCTAssertFalse(c.semanticPending)
        XCTAssertEqual(c.results.result?.count, 0)
        gate.signal(); waitUntil { !c.searchInFlight }
    }
    func testEmptyProvidersKeepCompactNamePresentation() {
        let p = StabilityProvider(); p.empty = true
        let store = fixture(), c = SearchViewController(snapshot: true); _ = c.view
        c.additionalSources = { [SearchSource(id: "fixture", displayName: "", isOnline: false, store: store)] }
        c.supplementaryProvider = p; c.searchField.text = "item"; c.startSearch()
        waitUntil { c.results.result?.count == 120 && !c.searchInFlight }
        XCTAssertFalse(c.results.result?.hasSupplements ?? true)
    }
    func testSupplementaryMetadataEqualityDetectsRealChanges() throws {
        let store = fixture()
        let base = SearchPresentation(try XCTUnwrap(Searcher.search(.parse("lighting"), in: store)))
        func result(_ text: String = "passage", _ page: Int = 2, _ stamp: String = "v1", _ thumbnail: Bool = false, _ highlights: [NSRange] = []) -> SearchPresentation {
            base.supplement([.init(sourceID: "startup", entryID: 1, detail: text, highlights: highlights, thumbnail: thumbnail, semanticScore: 0.8, matchedPage: page, matchedStamp: stamp)], options: .init())
        }
        XCTAssertTrue(result().sameMetadata(as: result()))
        XCTAssertFalse(result().sameMetadata(as: result("new passage")))
        XCTAssertFalse(result().sameMetadata(as: result("passage", 3)))
        XCTAssertFalse(result().sameMetadata(as: result("passage", 2, "v2")))
        XCTAssertFalse(result().sameMetadata(as: result("passage", 2, "v1", true)))
        XCTAssertFalse(result().sameMetadata(as: result("passage", 2, "v1", false, [NSRange(location: 0, length: 2)])))
    }
}
