import AppKit
import XCTest
import FoxFindCore
@testable import FoxFindApp

final class SupplementarySearchTests: XCTestCase {
    private func store() -> IndexStore {
        let names = ["", "发票.png", "older.png", "newer.png"]
        var buffer = ScanBuffer(); buffer.ids = [0,1,2,3]; buffer.parents = [0,0,0,0]; buffer.sizes = [0,100,200,300]; buffer.mtimes = [0,20,10,30]; buffer.flags = [1,128,128,128]; buffer.depths = [0,1,1,1]; buffer.kinds = [1,4,4,4]; buffer.nameLens = names.map { UInt32($0.utf8.count) }; buffer.nameBytes = Array(names.joined().utf8)
        return IndexStore(scan: ScanOutput(buffers: [buffer], count: 4, homeIndex: .max, elapsed: 0, finishedAt: 0), config: IndexConfig(rootPath: "/generated"))
    }
    func testDetailKeepsFolderAndOnlyFolderTruncates() throws {
        _ = NSApplication.shared
        let source = SearchSource(id: "startup", displayName: "", isOnline: true, store: store())
        let parent = NSHomeDirectory() + "/Desktop/截图/" + String(repeating: "很长的文件夹/", count: 12)
        let cell = ResultCell(frame: NSRect(x: 0, y: 0, width: 760, height: 50)), icons = IconProvider()
        func item(_ detail: SupplementaryHit?) -> ResultItem {
            ResultItem(detail: detail, id: 1, source: source, name: "发票.png", parentPath: parent, path: parent + "/发票.png", size: 100, modified: Date(), flags: 0, kind: 4)
        }
        for reason in ["图中文字：…开具发票的日期…", "图中有：猫", "Text in image: …Invoice date…", "Contains: cat"] {
            cell.configure(item(.init(sourceID: "startup", entryID: 1, detail: reason, highlights: [NSRange(location: 0, length: 2)])), query: .parse("发票"), icons: icons)
            cell.layoutSubtreeIfNeeded()
            let labels = cell.subviews.compactMap { $0 as? NSTextField }
            let detail = try XCTUnwrap(labels.first { $0.stringValue == reason + " · " })
            let path = try XCTUnwrap(labels.first { $0.stringValue == Presentation.abbreviate(path: parent, home: NSHomeDirectory()) })
            XCTAssertFalse(detail.isHidden)
            XCTAssertGreaterThanOrEqual(detail.frame.width, detail.attributedStringValue.size().width)
            XCTAssertEqual(path.frame.minX, detail.frame.maxX)
            XCTAssertEqual(path.lineBreakMode, .byTruncatingMiddle)
            XCTAssertLessThan(path.frame.width, path.attributedStringValue.size().width)
            XCTAssertNotNil(detail.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil))
        }
        cell.configure(item(nil), query: .parse("发票"), icons: icons)
        cell.layoutSubtreeIfNeeded()
        let path = try XCTUnwrap(cell.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("~/Desktop/") })
        XCTAssertEqual(path.frame.minX, 68)
        XCTAssertEqual(path.frame.width, 760 - 292)
    }
    func testThumbnailFitsSquareAndReusedCellKeepsFileIcon() throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("M22-thumbnail-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 200, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let file = dir.appendingPathComponent("wide.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
        let source = SearchSource(id: "startup", displayName: "", isOnline: true, store: store())
        func item(_ thumbnail: Bool) -> ResultItem {
            ResultItem(detail: thumbnail ? .init(sourceID: "startup", entryID: 1, detail: "Generated text", thumbnail: true) : nil, id: 1, source: source, name: "wide.png", parentPath: dir.path, path: file.path, size: 100, modified: Date(timeIntervalSince1970: 1), flags: 0, kind: 4)
        }
        let cell = ResultCell(frame: NSRect(x: 0, y: 0, width: 760, height: 50)), icons = IconProvider()
        cell.configure(item(true), query: .parse("text"), icons: icons)
        cell.layoutSubtreeIfNeeded()
        let icon = try XCTUnwrap(cell.subviews.compactMap { $0 as? NSImageView }.first)
        XCTAssertNotNil(icon.image)
        XCTAssertEqual(icon.layer?.borderWidth, 0)
        let deadline = Date().addingTimeInterval(3)
        while !icons.isIdle && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(icons.isIdle)
        XCTAssertEqual(icon.frame.size, NSSize(width: 34, height: 34))
        XCTAssertEqual(icon.imageScaling, .scaleProportionallyUpOrDown)
        let thumbnail = try XCTUnwrap(icon.image)
        XCTAssertEqual(thumbnail.size.width / thumbnail.size.height, 4, accuracy: 0.01)
        XCTAssertEqual(icon.layer?.borderWidth, 0.5)
        XCTAssertEqual(icon.layer?.cornerRadius, 3)
        XCTAssertNotNil(icon.layer?.backgroundColor)
        let pendingIcons = IconProvider()
        cell.configure(item(true), query: .parse("text"), icons: pendingIcons)
        cell.configure(item(false), query: .parse("text"), icons: pendingIcons)
        while !pendingIcons.isIdle && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        let fileIcon = pendingIcons.icon(name: "wide.png", path: file.path, flags: 0, kind: 4) { _ in }
        XCTAssertTrue(icon.image === fileIcon, "A late thumbnail must not replace the reused row’s resolved file icon")
        XCTAssertEqual(icon.layer?.borderWidth, 0)
        XCTAssertEqual(icon.layer?.cornerRadius, 0)
    }
    func testDedupOrderDetailAndLateSelection() throws {
        _ = NSApplication.shared
        let store = store(), query = Query.parse("发票"), base = SearchPresentation(try XCTUnwrap(Searcher.search(query, in: store)))
        let hits = [1,2,3].map { SupplementaryHit(sourceID: "startup", entryID: UInt32($0), detail: "Additional matching text", highlights: [NSRange(location: 0, length: 10)], thumbnail: true) }
        let view = ResultsView(frame: NSRect(x: 0,y: 0,width: 760,height: 500)); view.show(base)
        let combined = base.supplement(hits, options: .init())
        XCTAssertEqual((0..<combined.count).compactMap { combined.row($0)?.id }, [1,3,2])
        XCTAssertEqual(combined.count, 3); XCTAssertNotNil(combined.detail(at: 0))
        view.refresh(combined); XCTAssertEqual(view.selectedID, 1)
        view.select(1)
        view.refresh(base.supplement(hits + [hits[0]], options: .init()))
        XCTAssertEqual(view.selectedID, 3)
        for options in [SearchOptions(sort: .modified, ascending: true), SearchOptions(sort: .size, ascending: true)] {
            let result = base.supplement(hits, options: options)
            let expected: [UInt32] = options.sort == .size ? [1,2,3] : [2,1,3]
            XCTAssertEqual((0..<result.count).compactMap { result.row($0)?.id }, expected)
        }
        let byName = base.supplement(hits, options: .init(sort: .name, ascending: true))
        XCTAssertEqual((0..<byName.count).compactMap { byName.row($0)?.id }, [3,2,1])
    }
    private final class Provider: SupplementarySearchProvider {
        var isEnabled = true
        let gate = DispatchSemaphore(value: 0)
        var delay = false
        func prepareSearch(_ query: Query, options: SearchOptions, sources: [SearchSource], isCancelled: @escaping () -> Bool) -> () -> [SupplementaryHit] {
            let delayed = delay, enabled = isEnabled
            return { [self] in
                if delayed { gate.wait() }
                guard enabled, !isCancelled() else { return [] }
                return [.init(sourceID: "startup", entryID: 3, detail: "Generated additional text")]
            }
        }
        func sourcesDidChange(_ sources: [SearchSource]) { }
        func userActivity(visible: Bool, typing: Bool) { }
    }
    private final class ManualPreviewProvider: SupplementarySearchProvider {
        var isEnabled = false
        let started: XCTestExpectation, finished: XCTestExpectation
        let gate = DispatchSemaphore(value: 0)
        init(started: XCTestExpectation, finished: XCTestExpectation) { self.started = started; self.finished = finished }
        func prepareSearch(_ query: Query, options: SearchOptions, sources: [SearchSource], isCancelled: @escaping () -> Bool) -> () -> [SupplementaryHit] { { [] } }
        func sourcesDidChange(_ sources: [SearchSource]) {}
        func userActivity(visible: Bool, typing: Bool) {}
        func preparePreview(source: SearchSource, entryID: UInt32, isCancelled: @escaping () -> Bool) -> () -> TextPreviewOutcome {
            return { [self] in
                XCTAssertFalse(Thread.isMainThread); started.fulfill()
                _ = gate.wait(timeout: .now() + 3)
                XCTAssertTrue(isCancelled(), "Clearing input must cancel the pending preview")
                finished.fulfill(); return .unavailable("STALE PREVIEW")
            }
        }
    }
    func testManualPreviewDoesNotBlockInputAndClearingCancelsPublication() throws {
        _ = NSApplication.shared
        let started = expectation(description: "preview started"), finished = expectation(description: "preview finished")
        let provider = ManualPreviewProvider(started: started, finished: finished)
        defer { provider.gate.signal() }
        let controller = SearchViewController(snapshot: true)
        controller.supplementaryProvider = provider
        try controller.prepareSnapshot(state: "results", query: "发票", options: .init(), store: store(), selection: 0)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0, context: nil, characters: "Y", charactersIgnoringModifiers: "y", isARepeat: false, keyCode: 16))
        XCTAssertTrue(controller.handleKey(event))
        wait(for: [started], timeout: 2)
        controller.searchField.text = ""; controller.startSearch()
        XCTAssertEqual(controller.results.result?.count ?? 0, 0)
        provider.gate.signal(); wait(for: [finished], timeout: 2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNotEqual(controller.footer.text, "STALE PREVIEW")
    }
    func testBackgroundPublicationKeepsContentSelectionUntilCompletion() throws {
        _ = NSApplication.shared
        let store = store(), provider = Provider(), controller = SearchViewController(snapshot: true)
        _ = controller.view
        // A generated name index is loaded through the existing offline path.
        let db = FileManager.default.temporaryDirectory.appendingPathComponent("M22-selection-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: db) }
        try store.save(to: db.path)
        let indexManager = IndexManager(config: IndexConfig(rootPath: "/generated"), dbURL: db)
        defer { indexManager.stop() }
        indexManager.startOffline()
        let deadline = Date().addingTimeInterval(3)
        while indexManager.store == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        let loaded = try XCTUnwrap(indexManager.store)
        controller.manager = indexManager; controller.supplementaryProvider = provider
        let base = SearchPresentation(try XCTUnwrap(Searcher.search(Query.parse("发票"), in: loaded)))
        controller.searchField.text = "发票"
        controller.present(base.supplement([.init(sourceID: "startup", entryID: 3, detail: "Generated additional text")], options: .init()), selection: 1)
        XCTAssertEqual(controller.results.selectedID, 3)
        provider.delay = true; controller.sourcesChanged()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(controller.results.selectedID, 3)
        provider.gate.signal()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(controller.results.selectedID, 3)
        provider.isEnabled = false; provider.delay = false; controller.sourcesChanged()
        XCTAssertEqual(controller.results.result?.count, 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(controller.results.result?.count, 1)
    }
    func testStaleAndUnknownMatchesAreIgnored() throws {
        let store = store(), base = SearchPresentation(try XCTUnwrap(Searcher.search(Query.parse("发票"), in: store)))
        let result = base.supplement([.init(sourceID: "absent", entryID: 1, detail: "x"), .init(sourceID: "startup", entryID: 99, detail: "x")], options: .init())
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result.isCurrent([SearchSource(id: "startup", displayName: "", isOnline: true, store: store)]))
        store.write { store.version += 1 }
        XCTAssertFalse(result.isCurrent([SearchSource(id: "startup", displayName: "", isOnline: true, store: store)]))
    }
    func testLexicalRankStaysBelowExactNamesAndAboveSemanticCandidates() throws {
        let store = store(), base = SearchPresentation(try XCTUnwrap(Searcher.search(.parse("发票"), in: store)))
        let hits: [SupplementaryHit] = [
            .init(sourceID: "startup", entryID: 1, detail: "exact name", lexicalScore: 0.01),
            .init(sourceID: "startup", entryID: 2, detail: "focused older document", lexicalScore: 0.9),
            .init(sourceID: "startup", entryID: 3, detail: "incidental newer document", lexicalScore: 0.1)
        ]
        let relevance = base.supplement(hits, options: .init())
        XCTAssertEqual((0..<relevance.count).compactMap { relevance.row($0)?.id }, [1, 2, 3])
        let contents = base.supplement(hits, options: .init(), only: true)
        XCTAssertEqual((0..<contents.count).compactMap { contents.row($0)?.id }, [2, 3, 1])
        let modified = base.supplement(hits, options: .init(sort: .modified, ascending: false))
        XCTAssertEqual((0..<modified.count).compactMap { modified.row($0)?.id }, [3, 1, 2])
        let semantic = base.supplement([hits[1], .init(sourceID: "startup", entryID: 3, detail: "semantic", semanticScore: 0.99)], options: .init())
        XCTAssertEqual((0..<semantic.count).compactMap { semantic.row($0)?.id }, [1, 2, 3])
    }
}
