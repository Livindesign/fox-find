import AppKit
import XCTest
import Darwin
@testable import OilFindApp
@testable import OilFindCore

final class SearchExperienceTests: XCTestCase {
    private func isolated(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "FoxExperience-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
    private func fixture(_ body: (URL, IndexStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoxExperience-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder/sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["report.txt", "report2.txt", "folder/a.txt", "folder/sub/b.txt"] { try "content".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let config = IndexConfig(rootPath: root.path)
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        store.write { store.buildHash() }; try body(root, store)
    }
    func testNaturalFiltersAreConservativeAndKeepResidualKeywords() throws {
        let date = Date(timeIntervalSince1970: 1_792_000_000)
        let pdf = try XCTUnwrap(NaturalSearch.parse("下载文件夹里最近7天修改的PDF", home: "/test", now: date))
        XCTAssertEqual(pdf.folder, "/test/Downloads"); XCTAssertEqual(pdf.query, "dm:7d ext:pdf")
        XCTAssertFalse(pdf.explanation.isEmpty)
        let image = try XCTUnwrap(NaturalSearch.parse("项目A中宽度大于3000的图片", projects: [ProjectFolder(path: "/test/项目A")], now: date))
        XCTAssertEqual(image.folder, "/test/项目A"); XCTAssertEqual(image.refinement.minWidth, 3001); XCTAssertEqual(image.query, "kind:image")
        let keyword = try XCTUnwrap(NaturalSearch.parse("最近3天修改的合同PDF", now: date))
        XCTAssertTrue(keyword.query.contains("合同")); XCTAssertTrue(keyword.query.contains("ext:pdf"))
        for text in ["今天的报告.pdf", "invoice123", "昨天下载的PDF", "kind:image", "=2+3", "\"最近7天修改的PDF\""] { XCTAssertNil(NaturalSearch.parse(text), text) }
    }
    func testChineseCaptureQueryDoesNotUseModificationTime() throws {
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        for phrase in ["下载文件夹最近7天拍摄的图片", "下载文件夹里最近7天拍摄的照片", "下载文件夹近7天拍的图片",
                       "下载目录最近7天拍摄图片", "下载目录最近7天拍摄的图片", "下载目录里最近7天拍摄的照片",
                       "下载目录+最近7天拍摄+图片", "下载文件夹，最近7天拍摄，图片", "下载目录里的最近7天拍摄图片",
                       "找下载目录最近7天拍摄图片"] {
            let plan = try XCTUnwrap(NaturalSearch.parse(phrase, home: "/test", now: now), phrase)
            XCTAssertEqual(plan.folder, "/test/Downloads")
            XCTAssertEqual(plan.query, "kind:image")
            XCTAssertEqual(plan.refinement.captured, DateInterval(start: now.addingTimeInterval(-7 * 86400), end: now))
            XCTAssertTrue(plan.refinement.needsMedia)
        }
        let yesterday = try XCTUnwrap(NaturalSearch.parse("下载文件夹昨天拍摄的照片", home: "/test", now: now))
        let day = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        XCTAssertEqual(yesterday.refinement.captured, Calendar.current.dateInterval(of: .day, for: day))
        XCTAssertEqual(NaturalSearch.parse("下载文件夹最近7天修改的图片", home: "/test", now: now)?.query, "dm:7d kind:image")
        XCTAssertEqual(NaturalSearch.parse("桌面目录最近7天修改的PDF", home: "/test", now: now)?.folder, "/test/Desktop")
        XCTAssertEqual(NaturalSearch.parse("图片目录最近7天拍摄图片", home: "/test", now: now)?.folder, "/test/Pictures")
        XCTAssertEqual(NaturalSearch.parse("下载目录最近7天拍摄的合同图片", home: "/test", now: now)?.query, "合同 kind:image")
        XCTAssertEqual(NaturalSearch.parse("最近7天修改的C++文档", now: now)?.query, "C++ dm:7d kind:doc")
        for text in ["下载文件夹备份.jpg", "下载目录说明.pdf", "拍摄计划.docx", "最近0天拍摄的图片", "最近9999天拍摄的图片"] {
            XCTAssertNil(NaturalSearch.parse(text), text)
        }
        let saved = SavedSearch(query: "kind:image", captured: yesterday.refinement.captured)
        XCTAssertEqual(try JSONDecoder().decode(SavedSearch.self, from: JSONEncoder().encode(saved)), saved)
    }
    func testDirectScopeKeepsChildrenAndExcludesDescendants() throws {
        try fixture { root, store in
            let folder = root.appendingPathComponent("folder").path
            let direct = try XCTUnwrap(Searcher.search(.parse("*").scoped(to: folder, includingSubfolders: false), in: store))
            let recursive = try XCTUnwrap(Searcher.search(.parse("*").scoped(to: folder), in: store))
            XCTAssertEqual(Set(direct.items.map { store.name($0) }), ["a.txt", "sub"])
            XCTAssertTrue(recursive.items.contains { store.name($0) == "b.txt" })
        }
    }
    func testScopeHandlesColdIndexesRootsMissingAndNestedSources() throws {
        try fixture { root, warm in
            for cold in [false, true] {
                let config = IndexConfig(rootPath: root.path)
                let store = cold ? IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config) : warm
                let folder = root.appendingPathComponent("folder").path
                for recursive in [false, true] {
                    let actual = try XCTUnwrap(Searcher.search(.parse("*").scoped(to: folder, includingSubfolders: recursive), in: store))
                    var reference = Query.parse("*")
                    reference.clauses.append(.init(alternatives: [.init(negated: false, matcher: .regex(try NSRegularExpression(pattern: "^" + NSRegularExpression.escapedPattern(for: folder + "/") + (recursive ? "" : "[^/]+$")), onPath: true))]))
                    XCTAssertEqual(Set(actual.items), Set(try XCTUnwrap(Searcher.search(reference, in: store)).items))
                    let query = Query.parse("*").scoped(to: folder, includingSubfolders: recursive)
                    Searcher.withEntryPredicates([query.clauses.last!.alternatives[0]], in: store) { matches in
                        XCTAssertEqual(Set((1..<store.count).map(UInt32.init).filter { matches(0, $0) }), Set(actual.items))
                    }
                }
                XCTAssertEqual(Searcher.search(.parse("*").scoped(to: root.path, includingSubfolders: false), in: store)?.total, 3)
                XCTAssertEqual(Searcher.search(.parse("*").scoped(to: root.appendingPathComponent("missing").path), in: store)?.total, 0)
                XCTAssertEqual(Searcher.search(.parse("*").scoped(to: root.deletingLastPathComponent().path), in: store)?.total, 6)
                XCTAssertEqual(Searcher.search(.parse("*").scoped(to: root.deletingLastPathComponent().path, includingSubfolders: false), in: store)?.total, 0)
            }
        }
    }
    func testDirectoryScopeBudgetOnExistingIndex() throws {
        guard let path = ProcessInfo.processInfo.environment["FOXFIND_PERF_DB"] else { throw XCTSkip("Opt-in directory scope benchmark") }
        let store = try XCTUnwrap(IndexStore.load(from: path)); store.write { store.buildHash() }
        let folder = NSHomeDirectory() + "/Documents/Codex/2026-10-12/re/work/local-find-demo"
        for recursive in [false, true] {
            var reference = Query.parse("*")
            reference.clauses.append(.init(alternatives: [.init(negated: false, matcher: .regex(try NSRegularExpression(pattern: "^" + NSRegularExpression.escapedPattern(for: folder + "/") + (recursive ? "" : "[^/]+$")), onPath: true))]))
            var before = [Double](), after = [Double]()
            for _ in 0..<3 {
                let old = try XCTUnwrap(Searcher.search(reference, in: store))
                let current = try XCTUnwrap(Searcher.search(.parse("*").scoped(to: folder, includingSubfolders: recursive), in: store))
                XCTAssertEqual(Set(current.items), Set(old.items)); before.append(old.elapsedMs); after.append(current.elapsedMs)
            }
            before.sort(); after.sort()
            print("FOX_SCOPE_PERF recursive=\(recursive) entries=\(store.count) before_ms=\(before[1]) after_ms=\(after[1])")
            #if DEBUG
            // Unoptimized path construction is deliberately expensive. The
            // shipping 150 ms gate is measured with the optimized core harness.
            XCTAssertLessThan(after[1], before[1] * 0.1)
            #else
            XCTAssertLessThan(after[1], 150)
            #endif
        }
    }
    func testShortcutPersistenceAliasesAndSafeURLArguments() throws {
        try isolated { defaults in
            let store = SearchShortcuts(defaults: defaults)
            XCTAssertTrue(store.save(SearchShortcut(name: "Project", destination: "/tmp/项目 A", keyword: "客户A")))
            XCTAssertTrue(store.save(SearchShortcut(name: "GitHub", destination: "https://github.com/search?q={query}", keyword: "gh")))
            let restored = SearchShortcuts(defaults: defaults)
            XCTAssertEqual(restored.matches("客户A").first?.name, "Project")
            let link = try XCTUnwrap(restored.matches("gh a&b #你好").first?.resolved(for: "gh a&b #你好"))
            XCTAssertEqual(URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "a&b #你好")
            XCTAssertNil(link.fragment)
            for url in ["javascript:alert(1)", "data:text/plain,hello", "https://user:password@example.org", "file://remote/tmp/a"] { XCTAssertNil(SearchShortcut.validURL(url)) }
            XCTAssertFalse(store.save(SearchShortcut(name: "bad", destination: "https://example.org/{query}")))
            let id = try XCTUnwrap(restored.items.first?.id); restored.remove(id)
            XCTAssertEqual(SearchShortcuts(defaults: defaults).items.count, 1)
        }
    }
    func testBookmarkImportHTMLChromeSafariDeduplicatesAndNeverImportsScriptURLs() throws {
        let html = Data("<DL><DT><A HREF=\"https://example.org/?a=1&amp;b=2\">Project &amp; Docs</A><A HREF='javascript:bad'>bad</A></DL>".utf8)
        let parsed = try BookmarkImport.parse(html, format: "html")
        XCTAssertEqual(parsed.count, 1); XCTAssertEqual(parsed[0].name, "Project & Docs")
        let chrome = Data("{\"roots\":{\"bookmark_bar\":{\"children\":[{\"type\":\"url\",\"name\":\"Docs\",\"url\":\"https://example.org/docs\"}]}}}".utf8)
        XCTAssertEqual(try BookmarkImport.parse(chrome, format: "json").first?.name, "Docs")
        let safari = try PropertyListSerialization.data(fromPropertyList: ["Children": [["URLString": "https://example.org/safari", "URIDictionary": ["title": "Safari"]]]], format: .binary, options: 0)
        XCTAssertEqual(try BookmarkImport.parse(safari, format: "plist").count, 1)
        try isolated { defaults in
            let store = SearchShortcuts(defaults: defaults)
            XCTAssertEqual(store.merge(parsed + parsed), 1); XCTAssertEqual(store.merge(parsed), 0)
        }
        XCTAssertThrowsError(try BookmarkImport.parse(Data(count: 8 * 1024 * 1024 + 1), format: "html"))
    }
    func testLearningPersistsAndOnlyReordersRelevance() throws {
        try isolated { defaults in try fixture { root, store in
            let usage = SearchUsage(defaults: defaults), target = "file:startup|" + root.appendingPathComponent("report2.txt").path
            usage.record(query: "report", target: target); usage.record(query: "REPORT", target: target)
            let scores = SearchUsage(defaults: defaults).scores(for: "report")
            XCTAssertEqual(scores[target], 2)
            let result = SearchPresentation(try XCTUnwrap(Searcher.search(.parse("report"), in: store)))
            let ranked = result.ranked(scores, options: .init())
            XCTAssertEqual(ranked.row(0).map { $0.source.store.name($0.id) }, "report2.txt")
            XCTAssertEqual(Set((0..<ranked.count).compactMap { ranked.row($0)?.id }), Set((0..<result.count).compactMap { result.row($0)?.id }))
            XCTAssertTrue(result.ranked(scores, options: .init(sort: .name)) === result)
            XCTAssertTrue(usage.scores(for: "other").isEmpty); usage.clear(); XCTAssertTrue(SearchUsage(defaults: defaults).entries.isEmpty)
        } }
    }
    func testNavigationRestoresSearchAndClearStaysEmpty() throws {
        _ = NSApplication.shared
        try isolated { defaults in try fixture { root, store in
            let controller = SearchViewController(snapshot: true, preferences: defaults)
            _ = controller.view; controller.additionalSources = { [SearchSource(id: "test", displayName: "", isOnline: true, store: store)] }
            controller.searchField.text = "report"; controller.startSearch()
            waitFor { controller.results.result?.count == 2 }
            controller.enterFolder(root.appendingPathComponent("folder").path)
            waitFor { controller.results.result?.query.raw.contains(";direct]") == true }
            XCTAssertTrue(controller.browsingFolder)
            XCTAssertEqual(controller.results.result?.count, 2)
            controller.navigateBack(); waitFor { controller.results.result?.query.raw == "report" }
            XCTAssertFalse(controller.browsingFolder); XCTAssertEqual(controller.searchField.text, "report")
            controller.navigateForward(); waitFor { controller.browsingFolder && controller.results.result?.query.raw.contains(";direct]") == true }
            controller.searchField.text = ""; controller.startSearch()
            XCTAssertNil(controller.results.result); XCTAssertTrue(controller.quickResults.items.isEmpty)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1)); XCTAssertNil(controller.results.result)
        } }
    }
    func testQuicklinksOpenOnlyOnActionAndKeepEditorCopySemantics() throws {
        _ = NSApplication.shared
        try isolated { defaults in
            let controller = SearchViewController(snapshot: true, preferences: defaults)
            _ = controller.view; controller.shortcuts.save(SearchShortcut(name: "Project Docs", destination: "https://example.org/project", keyword: "docs"))
            var opened = [URL](); controller.openResource = { opened.append($0); return true }
            controller.searchField.text = "docs"; controller.startSearch()
            XCTAssertTrue(opened.isEmpty); XCTAssertEqual(controller.quickResults.items.first?.title, "Project Docs")
            controller.makeActions().first { $0.id == "open" }?.run()
            XCTAssertEqual(opened.count, 1); XCTAssertEqual(controller.usage.entries.first?.query, "docs")
            controller.searchField.text = ""; controller.startSearch(); XCTAssertTrue(controller.quickResults.items.isEmpty)
        }
    }
    func testActionPaletteAndContextBarLayoutAtNarrowWidths() throws {
        _ = NSApplication.shared
        for chinese in [false, true] {
            L10n.snapshotChinese = chinese; defer { L10n.snapshotChinese = nil }
            try isolated { defaults in
                let controller = SearchViewController(snapshot: true, preferences: defaults)
                for width in [720.0, 800, 900] {
                    controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 600)
                    controller.searchField.text = "下载文件夹里最近7天修改的PDF"; controller.startSearch(); controller.view.layoutSubtreeIfNeeded()
                    XCTAssertFalse(controller.contextBar.isHidden)
                    XCTAssertGreaterThan(controller.contextBar.label.frame.width, 300)
                    XCTAssertLessThan(controller.contextBar.label.frame.maxX, controller.contextBar.edit.frame.minX)
                    controller.showActions(); controller.view.layoutSubtreeIfNeeded()
                    XCTAssertFalse(controller.actionPalette.isHidden); XCTAssertGreaterThan(controller.actionPalette.frame.height, 200)
                    XCTAssertEqual(controller.makeActions().filter { $0.id == "importBookmarks" }.count, 1)
                    controller.closeActions()
                }
            }
        }
    }
    func testActionPaletteOwnsNavigationAndDoesNotChangeMainQuery() throws {
        _ = NSApplication.shared
        try isolated { defaults in
            let controller = SearchViewController(snapshot: true, preferences: defaults)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentViewController = controller
            defer { window.close() }
            controller.searchField.text = "original query"; controller.showActions()
            XCTAssertTrue(window.firstResponder === controller.actionPalette)
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
            XCTAssertTrue(controller.handleKey(event))
            XCTAssertEqual(controller.searchField.text, "original query")
            var ran = false
            controller.actionPalette.show([.init(id: "disabled", title: "Unavailable", enabled: false, run: { XCTFail("Disabled action executed") }), .init(id: "fixture", title: "Fixture", run: { ran = true })], title: "Actions")
            func key(_ code: UInt16) throws -> NSEvent {
                try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
            }
            XCTAssertTrue(controller.handleKey(try key(36))); XCTAssertFalse(ran)
            XCTAssertTrue(controller.handleKey(try key(125))); XCTAssertEqual(controller.actionPalette.table.selectedRow, 1)
            XCTAssertTrue(controller.handleKey(try key(126))); XCTAssertEqual(controller.actionPalette.table.selectedRow, 0)
            XCTAssertTrue(controller.handleKey(try key(125)))
            XCTAssertTrue(controller.handleKey(try key(36)))
            XCTAssertTrue(ran); XCTAssertTrue(controller.actionPalette.isHidden)
            controller.showActions(); XCTAssertTrue(controller.handleKey(try key(53)))
            XCTAssertTrue(controller.actionPalette.isHidden); XCTAssertEqual(controller.searchField.text, "original query")
        }
    }
    func testCombinedEntryPerformanceBudget() throws {
        guard ProcessInfo.processInfo.environment["FOXFIND_PERF"] == "1" else { throw XCTSkip("Opt-in combined entry benchmark") }
        try isolated { defaults in
            let shortcuts = SearchShortcuts(defaults: defaults)
            let items = (0..<5000).map { SearchShortcut(name: "Project \($0)", destination: "https://example.org/\($0)", keyword: "p\($0)") }
            XCTAssertEqual(shortcuts.merge(items), 5000)
            let catalog = ApplicationCatalog()
            catalog.replace((0..<500).map { .init(path: "/Applications/Application\($0).app", name: "Application \($0)", bundleID: "test.\($0)") })
            var samples = [Double]()
            for i in 0..<200 {
                let query = i % 2 == 0 ? "Project" : "Application \(i)"
                let start = CFAbsoluteTimeGetCurrent()
                _ = shortcuts.matches(query); _ = catalog.matches(query); _ = NaturalSearch.parse(query); _ = QuickCalculator.evaluate(query)
                samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            }
            samples.sort()
            print("FOX_ENTRY_PERF bookmarks=5000 apps=500 samples=200 p95_ms=\(samples[190])")
            XCTAssertLessThan(samples[190], 16.7)
        }
    }
    func testContentPositionsKeepUnicodePageAndLineMappings() {
        let text = "你好 🦊\nfirst\nsecond contract\npage two contract"
        let offset = ("你好 🦊\nfirst\nsecond contract\n" as NSString).length
        let preview = ExtractedTextPreview(path: "/test.pdf", text: text, note: "", isOnline: false, segments: [.init(offset: 0, length: offset - 1, page: 1), .init(offset: offset, length: ("page two contract" as NSString).length, page: 2)])
        let index = ContentMatchIndex(preview: preview), matches = index.matches("contract")
        XCTAssertEqual(matches.count, 2); XCTAssertEqual(index.page(at: matches[1].location), 2)
        XCTAssertEqual(index.line(at: matches[0].location), 3)
        XCTAssertTrue(NSLocationInRange(matches[1].location, index.context(around: matches[1])))
    }
    func testMetadataChecksPastThousandAndPersistsOfflineCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoxMetadata-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<1100 { try Data().write(to: root.appendingPathComponent(String(format: "%04d.txt", i))) }
        let target = root.appendingPathComponent("1099.txt")
        let data = try PropertyListSerialization.data(fromPropertyList: ["Target\n1"], format: .binary, options: 0)
        _ = data.withUnsafeBytes { setxattr(target.path, "com.apple.metadata:_kMDItemUserTags", $0.baseAddress, data.count, 0, 0) }
        let config = IndexConfig(rootPath: root.path), store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        let base = SearchPresentation(try XCTUnwrap(Searcher.search(.parse("ext:txt"), options: .init(sort: .name, ascending: true), in: store)))
        let url = root.appendingPathComponent("metadata.sqlite"), reader = AssetMetadataReader(cacheURL: url)
        let result = try XCTUnwrap(base.refined(.init(tag: "Target"), reader: reader, cancelled: { false }))
        XCTAssertEqual(result.refinementChecked, 1100); XCTAssertEqual(result.count, 1); XCTAssertFalse(result.refinementLimited)
        let modified = try target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        let cached = AssetMetadataReader(cacheURL: url).offline(path: target.path, modified: Date(timeIntervalSince1970: floor(modified.timeIntervalSince1970)), media: false)
        XCTAssertEqual(cached?.tags, ["Target"])
        XCTAssertNil(base.refined(.init(tag: "Target"), reader: reader, cancelled: { true }))
    }
    func testFavoriteTracksRenameWithoutConfusingCopy() throws {
        try isolated { defaults in try fixture { root, _ in
            let original = root.appendingPathComponent("report.txt"), moved = root.appendingPathComponent("moved.txt")
            let tracked = FileFavorites.tracked(FileFavorite(sourceID: "startup", path: original.path))
            XCTAssertNotNil(tracked.bookmark); XCTAssertNotNil(tracked.identity)
            let favorites = FileFavorites(defaults: defaults); favorites.toggle(tracked)
            try FileManager.default.moveItem(at: original, to: moved)
            try FileManager.default.copyItem(at: moved, to: original)
            let done = expectation(description: "reconcile")
            favorites.reconcile(force: true) { _ in done.fulfill() }; wait(for: [done], timeout: 5)
            XCTAssertTrue(favorites.contains(sourceID: "startup", path: moved.path), "tracked=\(favorites.files.map { $0.path }) expected=\(moved.path) normalized=\(FileFavorite(sourceID: "startup", path: moved.path).path)")
            XCTAssertFalse(favorites.contains(sourceID: "startup", path: original.path))
            XCTAssertEqual(FileFavorites(defaults: defaults).files.first?.path, moved.path)
        } }
    }
    private func waitFor(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(condition())
    }
}
