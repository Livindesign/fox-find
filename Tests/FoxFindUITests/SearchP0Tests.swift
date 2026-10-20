import AppKit
import XCTest
import FoxFindCore
@testable import FoxFindApp

private final class ControlledContent: SupplementarySearchProvider {
    var isEnabled = true
    var semanticStatus: SupplementarySearchStatus?
    var returnsHits = true
    var work: () -> Void = {}
    var semanticWork: (() -> Void)?
    var supportsSimilarity: Bool { semanticWork != nil }
    func prepareSemantic(_ query: Query, options: SearchOptions, sources: [SearchSource], isCancelled: @escaping () -> Bool) -> (() -> [SupplementaryHit])? {
        guard let work = semanticWork else { return nil }
        return { work(); return self.returnsHits ? [.init(sourceID:"fixture",entryID:3,detail:"Semantic result",semanticScore:0.9)] : [] }
    }
    func prepareSimilarity(path: String, query: Query, options: SearchOptions, sources: [SearchSource], isCancelled: @escaping () -> Bool) -> () -> [SupplementaryHit] {
        { [.init(sourceID:"fixture",entryID:3,detail:"Similar image",semanticScore:0.9)] }
    }
    func sourcesDidChange(_ sources: [SearchSource]) {}
    func userActivity(visible: Bool, typing: Bool) {}
    func prepareSearch(_ query: Query, options: SearchOptions, sources: [SearchSource], isCancelled: @escaping () -> Bool) -> () -> [SupplementaryHit] {
        let work = self.work
        return { work(); return self.returnsHits ? [.init(sourceID: "fixture", entryID: 2, detail: "invoice in indexed text")] : [] }
    }
}

final class SearchP0Tests: XCTestCase {
    private func fixture() -> IndexStore {
        _ = NSApplication.shared
        let names = ["", "invoice-z.txt", "memo-a.txt", "invoice-b.txt"]
        var b = ScanBuffer(); b.ids = [0,1,2,3]; b.parents = [0,0,0,0]; b.sizes = [0,100,200,300]; b.mtimes = [0,20,10,30]
        b.flags = [1,128,128,128]; b.depths = [0,1,1,1]; b.kinds = [1,3,3,3]
        b.nameLens = names.map { UInt32($0.utf8.count) }; b.nameBytes = Array(names.joined().utf8)
        return IndexStore(scan: ScanOutput(buffers: [b], count: 4, homeIndex: .max, elapsed: 0, finishedAt: 0), config: IndexConfig(rootPath: "/fox-p0-fixture"))
    }
    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let end = Date().addingTimeInterval(2)
        while !predicate(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        XCTAssertTrue(predicate(), file: file, line: line)
    }
    func testMatchModesAreIndependentOfSortAndFavoriteSurvivesViewChanges() throws {
        let store = fixture(), content = ControlledContent()
        let suite = "FoxP0-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let c = SearchViewController(snapshot: true, preferences: defaults); _ = c.view
        c.additionalSources = { [SearchSource(id: "fixture", displayName: "", isOnline: false, store: store)] }
        c.supplementaryProvider = content; c.filters.options = .init(sort: .name, ascending: true)
        c.searchField.text = "invoice"; c.startSearch()
        waitUntil { c.results.result?.count == 3 }
        XCTAssertEqual((0..<3).compactMap { c.results.item(at: $0)?.name }, ["invoice-b.txt", "invoice-z.txt", "memo-a.txt"])
        c.makeMatchMenu().performActionForItem(at: 1)
        waitUntil { c.results.result?.count == 2 }
        XCTAssertEqual(c.filters.options.sort, .name)
        XCTAssertEqual(c.results.item(at: 0)?.name, "invoice-b.txt")
        let chosen = try XCTUnwrap(c.results.item(at: 0)); c.results.onToggleFavorite?(chosen)
        let sortName = NSMenuItem(); sortName.tag = 1
        c.filters.perform(NSSelectorFromString("sortSelected:"), with: sortName)
        waitUntil { c.results.item(at: 0)?.name == "invoice-z.txt" }
        XCTAssertFalse(c.filters.options.ascending)
        XCTAssertEqual(c.toolsBar.mode, .names)
        c.toolsBar.grid.performClick(nil); c.toolsBar.list.performClick(nil)
        XCTAssertTrue(c.results.isFavorite?(chosen) == true)
        c.makeMatchMenu().performActionForItem(at: 2)
        waitUntil { c.results.result?.count == 1 }
        XCTAssertEqual(c.results.item(at: 0)?.name, "memo-a.txt")
        XCTAssertEqual(c.filters.options.sort, .name); XCTAssertFalse(c.filters.options.ascending)
    }
    func testClearCancelsLateContentAndStaysEmptyAfterSourceAndModeChanges() throws {
        for grid in [false, true] {
            let store = fixture(), content = ControlledContent(), gate = DispatchSemaphore(value: 0)
            let began = expectation(description: "content began")
            content.work = { began.fulfill(); _ = gate.wait(timeout: .now() + 2) }
            let c = SearchViewController(snapshot: true); _ = c.view
            c.additionalSources = { [SearchSource(id: "fixture", displayName: "", isOnline: false, store: store)] }
            c.supplementaryProvider = content; c.results.gridMode = grid
            c.searchField.text = "invoice"; c.startSearch()
            wait(for: [began], timeout: 2)
            c.searchField.clear.performClick(nil)
            XCTAssertNil(c.results.result); XCTAssertNil(c.results.selectedItem)
            XCTAssertEqual(c.results.grid.count, 0)
            XCTAssertEqual(c.footer.text, L10n.text("idle.footer")); XCTAssertFalse(c.footer.actionable)
            gate.signal(); RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            XCTAssertNil(c.results.result)
            c.sourcesChanged(); c.panelWillShow(); c.makeMatchMenu().performActionForItem(at: 2)
            c.toolsBar.folder = "/fox-p0-fixture"; c.searchField.text = "  \n "; c.startSearch()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            XCTAssertNil(c.results.result); XCTAssertFalse(c.footer.actionable)
        }
    }
    func testGridCoalescesRefreshUntilGestureEndsAndDoesNotReloadIdenticalResults() throws {
        let store = fixture(), v = ResultsView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        let first = SearchPresentation(try XCTUnwrap(Searcher.search(.parse("invoice"), in: store)))
        let changed = SearchPresentation(try XCTUnwrap(Searcher.search(.parse("memo"), in: store)))
        v.gridMode = true; v.show(first); v.layoutSubtreeIfNeeded()
        let reloads = v.grid.reloadCount
        for _ in 0..<100 { v.refresh(first) }
        XCTAssertEqual(v.grid.reloadCount, reloads)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: v.grid.scroll)
        v.refresh(changed)
        XCTAssertTrue(v.result === first); XCTAssertEqual(v.grid.reloadCount, reloads)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: v.grid.scroll)
        XCTAssertTrue(v.result === changed); XCTAssertEqual(v.grid.reloadCount, reloads + 1)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: v.grid.scroll)
        v.refresh(first); v.clear()
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: v.grid.scroll)
        XCTAssertNil(v.result); XCTAssertEqual(v.grid.count, 0)
    }
    func testFilterAndSortLabelsFitWithoutOverlap() {
        _ = NSApplication.shared; defer { L10n.snapshotChinese = nil }
        for chinese in [true, false] {
            L10n.snapshotChinese = chinese
            for width: CGFloat in [720, 800, 900] {
                let bar = FilterBar(frame: NSRect(x: 0, y: 0, width: width, height: 48))
                for key in [SortKey.name, .modified, .size, .relevance] {
                    bar.options.sort = key; bar.layoutSubtreeIfNeeded(); bar.layout()
                    for button in bar.subviews.compactMap({ $0 as? ChromeButton }) where button !== bar.sortButton {
                        XCTAssertLessThanOrEqual(button.frame.maxX + 8, bar.sortButton.frame.minX)
                    }
                    XCTAssertTrue(bar.sortButton.title.hasPrefix(chinese ? "排序" : "Sort"))
                }
            }
        }
    }
    func testLegacySavedEmptyScopeStillWorksWithoutRevivingResultsAfterClear() {
        let store = fixture(), c = SearchViewController(snapshot: true); _ = c.view
        c.additionalSources = { [SearchSource(id: "fixture", displayName: "", isOnline: false, store: store)] }
        let item = NSMenuItem()
        item.representedObject = SavedSearch(query: "", mode: .names, kind: 3, sort: "name", ascending: true)
        c.perform(NSSelectorFromString("restoreSearch:"), with: item)
        XCTAssertEqual(c.searchField.text, "*")
        waitUntil { c.results.result?.count == 3 }
        c.searchField.clear.performClick(nil)
        XCTAssertNil(c.results.result)
    }
    func testSemanticResultsArriveAfterLexicalAndClearCancelsLateDelivery() throws {
        for clear in [false, true] {
            let store = fixture(), content = ControlledContent(), gate = DispatchSemaphore(value: 0)
            content.semanticWork = { _ = gate.wait(timeout: .now() + 3) }
            let c = SearchViewController(snapshot: true); _ = c.view
            c.additionalSources = { [SearchSource(id:"fixture",displayName:"",isOnline:false,store:store)] }
            c.supplementaryProvider = content; c.searchField.text = "invoice-z"; c.startSearch()
            waitUntil { c.results.result?.count == 2 }
            XCTAssertEqual(c.results.item(at:0)?.name,"invoice-z.txt")
            if clear { c.searchField.clear.performClick(nil) }
            gate.signal()
            if clear {
                RunLoop.main.run(until:Date().addingTimeInterval(0.15)); XCTAssertNil(c.results.result)
            } else {
                waitUntil { c.results.result?.count == 3 }
                XCTAssertEqual(c.results.item(at:1)?.name,"memo-a.txt")
                XCTAssertEqual(c.results.result?.detail(at:2)?.semanticScore,0.9)
            }
        }
    }
    func testImageSimilarityUsesExistingPanelAndTypedQueryExitsImageMode() {
        let store = fixture(), content = ControlledContent(); content.semanticWork = {}
        let c = SearchViewController(snapshot:true); _ = c.view
        c.additionalSources = { [SearchSource(id:"fixture",displayName:"",isOnline:false,store:store)] }
        c.supplementaryProvider = content
        c.findSimilar(path:"/reference.png")
        waitUntil { c.results.result?.count == 1 }
        XCTAssertEqual(c.results.result?.detail(at:0)?.detail,"Similar image")
        c.searchField.clear.performClick(nil); XCTAssertNil(c.results.result)
        c.filters.options.kind = nil; c.searchField.text = "invoice-z"; c.startSearch()
        waitUntil { c.results.result?.count == 3 }
        XCTAssertEqual(c.results.item(at:0)?.name,"invoice-z.txt")
    }

    func testRapidSemanticQueriesCanBeAbandonedBeforeNamesFinish() {
        let store = fixture(), content = ControlledContent(); content.semanticWork = {}
        let c = SearchViewController(snapshot:true); _ = c.view
        c.additionalSources = { [SearchSource(id:"fixture",displayName:"",isOnline:false,store:store)] }
        c.supplementaryProvider = content
        for i in 0..<150 { c.searchField.text = "invoice-\(i)"; c.startSearch() }
        c.searchField.clear.performClick(nil)
        RunLoop.main.run(until:Date().addingTimeInterval(0.5))
        XCTAssertNil(c.results.result); XCTAssertEqual(c.results.grid.count,0)
    }

    func testEmptyContentShowsSetupAndNameModeDoesNot() throws {
        let c = SearchViewController(snapshot: true), store = fixture(), content = ControlledContent()
        content.returnsHits = false
        content.semanticStatus = .init(title: "No folders", message: "Add content folders", actionTitle: "Add folders")
        _ = c.view; c.supplementaryProvider = content
        c.additionalSources = { [SearchSource(id: "fixture", displayName: "", isOnline: false, store: store)] }
        c.searchField.text = "nothingmatches"; c.startSearch()
        waitUntil { c.results.result?.total == 0 }
        let empty = try XCTUnwrap(c.view.subviews.compactMap { $0 as? StateView }.first { $0.state == .empty })
        XCTAssertEqual(empty.assistance?.title, "No folders")
        var settingsOpened = false; c.onSettings = { settingsOpened = true }
        empty.assistanceButton.performClick(nil); XCTAssertTrue(settingsOpened)
        XCTAssertTrue(c.makeMoreMenu().items.contains { $0.title == L10n.text("semantic.choose") })
        c.toolsBar.mode = .names; c.startSearch()
        waitUntil { empty.assistance == nil }
        c.searchField.clear.performClick(nil); XCTAssertNil(c.results.result)
    }
    func testZeroSemanticResultsEndLoadingWithoutStaleCompletion() throws {
        let c = SearchViewController(snapshot: true), store = fixture(), content = ControlledContent(), gate = DispatchSemaphore(value: 0)
        content.returnsHits = false; content.semanticWork = { _ = gate.wait(timeout: .now() + 3) }
        content.semanticStatus = .init(title: "No similar content", message: "4 indexed files", actionTitle: "Settings", canSearch: true, indexedFiles: 4)
        _ = c.view; c.supplementaryProvider = content
        c.additionalSources = { [SearchSource(id: "fixture", displayName: "", isOnline: false, store: store)] }
        c.searchField.text = "nothingmatches"; c.startSearch()
        waitUntil { c.results.result?.total == 0 }
        XCTAssertTrue(c.semanticPending)
        let empty = try XCTUnwrap(c.view.subviews.compactMap { $0 as? StateView }.first { $0.state == .empty })
        XCTAssertEqual(empty.assistance?.title, L10n.text("semantic.searching"))
        gate.signal(); waitUntil { !c.semanticPending }
        XCTAssertEqual(empty.assistance?.title, "No similar content")
        c.searchField.clear.performClick(nil); XCTAssertFalse(c.semanticPending)
    }
    func testImageActionsAreDirectAndPDFMenuNamesPhysicalPage() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["picture.jpg", "book.pdf"] { try Data("fixture".utf8).write(to: root.appendingPathComponent(name)) }
        let config = IndexConfig(rootPath: root.path)
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        let c = SearchViewController(snapshot: true), content = ControlledContent(); _ = c.view
        content.semanticWork = {}; c.supplementaryProvider = content
        let image = try XCTUnwrap(Searcher.search(.parse("picture"), in: store)); c.present(image)
        XCTAssertTrue(c.makeActions().contains { $0.title == L10n.text("semantic.similar") })
        XCTAssertTrue(c.contextMenu().items.contains { $0.title == L10n.text("semantic.similar") })
        let pdf = try XCTUnwrap(Searcher.search(.parse("book"), in: store)), id = try XCTUnwrap(pdf.items.first)
        let hit = SupplementaryHit(sourceID: "startup", entryID: id, detail: "Page 7", semanticScore: 0.9, matchedPage: 7, matchedStamp: "fixture")
        c.present(SearchPresentation(pdf).supplement([hit], options: .init(), only: true))
        XCTAssertTrue(c.makeActions().contains { $0.title == L10n.text("semantic.openPage", "7") })
        XCTAssertTrue(c.contextMenu().items.contains { $0.title == L10n.text("semantic.openPage", "7") })
        XCTAssertFalse(c.contextMenu().items.contains { $0.title == L10n.text("semantic.similar") })
    }

}
