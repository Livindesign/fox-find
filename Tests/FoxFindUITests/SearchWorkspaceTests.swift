import AppKit
import XCTest
@testable import FoxFindApp
@testable import FoxFindCore

final class SearchWorkspaceTests: XCTestCase {
    func testSavedSearchRestoresScopeTypeModeSortAndBoundsHistory() throws {
        let suite = "LocalFindLibraryTest-" + UUID().uuidString, defaults: UserDefaults
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let library = SearchLibrary(defaults: defaults)
        let value = SavedSearch(query: "合同", mode: .contents, folder: "/Volumes/Archive/项目", kind: 3, sort: "modified", ascending: true)
        library.toggleFavorite(value); library.record(value); library.record(value)
        let restored = SearchLibrary(defaults: defaults)
        XCTAssertEqual(restored.favorites, [value]); XCTAssertEqual(restored.history, [value])
        XCTAssertEqual(restored.favorites.first?.options.kind, 3); XCTAssertEqual(restored.favorites.first?.options.sort, .modified)
        for i in 0..<25 { restored.record(SavedSearch(query: "query-\(i)")) }
        XCTAssertEqual(restored.history.count, 20)
        restored.clearHistory(); restored.toggleFavorite(value)
        XCTAssertTrue(SearchLibrary(defaults: defaults).history.isEmpty); XCTAssertTrue(SearchLibrary(defaults: defaults).favorites.isEmpty)
    }
    func testCSVPreservesCommasQuotesUnicodeAndPreventsFormulas() {
        let csv = SearchExport.csv([["name", "path"], ["项目, \"A\".txt", "/tmp/a\nb"], ["=HYPERLINK(\"bad\")", "safe"]])
        XCTAssertTrue(csv.hasPrefix("\u{feff}\"name\",\"path\"\r\n"))
        XCTAssertTrue(csv.contains("\"项目, \"\"A\"\".txt\""))
        XCTAssertTrue(csv.contains("\"'=HYPERLINK("))
        XCTAssertEqual(SearchExport.cell(" @bad"), "\"' @bad\"")
    }
    func testFolderScopeUsesLiteralBoundariesAndSurvivesSpecialCharacters() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalFindScope-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("项目 [1] \"A\"")
        for path in [folder, root.appendingPathComponent(folder.lastPathComponent + "-other")] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try "test".write(to: path.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        }
        let config = IndexConfig(rootPath: root.path), scan = try XCTUnwrap(Scanner(config: IndexConfig(rootPath: root.path), threads: 1).run())
        let store = IndexStore(scan: scan, config: config)
        let found = try XCTUnwrap(Searcher.search(Query.parse("report").scoped(to: folder.path), in: store))
        XCTAssertEqual(found.total, 1)
        XCTAssertEqual(store.path(try XCTUnwrap(found.items.first)), folder.appendingPathComponent("report.txt").path)
    }
    func testContentOnlyPresentationDoesNotIncludeFilenameMatches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalFindMode-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for file in ["invoice.txt", "memo.txt"] { try "test".write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8) }
        let config = IndexConfig(rootPath: root.path), store = IndexStore(scan: try XCTUnwrap(Scanner(config: IndexConfig(rootPath: root.path), threads: 1).run()), config: config)
        store.write { store.buildHash() }
        let found = try XCTUnwrap(Searcher.search(Query.parse("invoice"), in: store))
        let memo = try XCTUnwrap(store.read { store.resolve(path: root.appendingPathComponent("memo.txt").path) })
        let hits = [SupplementaryHit(sourceID: "startup", entryID: memo, detail: "invoice in contents")]
        XCTAssertEqual(SearchPresentation(found).supplement(hits, options: .init()).count, 2)
        let only = SearchPresentation(found).supplement(hits, options: .init(), only: true)
        XCTAssertEqual(only.count, 1); XCTAssertEqual(only.row(0)?.id, memo)
        XCTAssertEqual(SearchPresentation(found).supplement([], options: .init(), only: true).count, 0)
    }
    func testTextPreviewIsResizableAndContainsCachedText() throws {
        _ = NSApplication.shared
        let controller = ContentPreviewWindow(preview: ExtractedTextPreview(path: "/Volumes/Archive/合同.txt", text: "缓存中的合同全文 preview739", note: "", isOnline: false), query: "合同")
        let window = try XCTUnwrap(controller.window); window.contentView?.layoutSubtreeIfNeeded()
        func texts(_ view: NSView) -> [NSTextView] { (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(texts) }
        let text = try XCTUnwrap(texts(try XCTUnwrap(window.contentView)).first)
        XCTAssertEqual(text.string, "缓存中的合同全文 preview739"); XCTAssertFalse(text.isEditable)
        XCTAssertGreaterThan(text.frame.width, 100); XCTAssertTrue(window.styleMask.contains(.resizable))
        window.close()
    }
}
