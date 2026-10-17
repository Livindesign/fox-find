import AppKit
import XCTest
@testable import OilFindApp
@testable import OilFindCore

final class FileFavoritesTests: XCTestCase {
    private func defaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "FoxFindFavoritesTest-" + UUID().uuidString
        let value = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { value.removePersistentDomain(forName: suite) }
        try body(value)
    }
    private func store(_ names: [String] = ["", "favorite.txt", "other.txt"]) -> IndexStore {
        var buffer = ScanBuffer()
        buffer.ids = names.indices.map { UInt32($0) }; buffer.parents = names.map { _ in 0 }
        buffer.sizes = names.map { _ in 100 }; buffer.mtimes = names.map { _ in 20 }
        buffer.flags = names.indices.map { $0 == 0 ? 1 : 128 }; buffer.depths = names.indices.map { $0 == 0 ? 0 : 1 }
        buffer.kinds = names.map { _ in 3 }; buffer.nameLens = names.map { UInt32($0.utf8.count) }; buffer.nameBytes = Array(names.joined().utf8)
        return IndexStore(scan: ScanOutput(buffers: [buffer], count: names.count, homeIndex: .max, elapsed: 0, finishedAt: 0), config: IndexConfig(rootPath: "/generated"))
    }
    private func prepare(_ controller: SearchViewController, query: String, store: IndexStore) throws {
        controller.view.frame = NSRect(origin: .zero, size: Theme.panelSize)
        try controller.prepareSnapshot(state: "results", query: query, options: .init(), store: store, selection: 0)
        controller.view.layoutSubtreeIfNeeded()
    }
    private func cell(_ controller: SearchViewController, row: Int = 0) throws -> ResultCell {
        try XCTUnwrap(controller.results.tableView(NSTableView(), viewFor: nil, row: row) as? ResultCell)
    }
    func testPersistenceDoesNotConfuseNamesPathsOrDrives() throws {
        try defaults { preferences in
            let favorites = FileFavorites(defaults: preferences)
            let file = FileFavorite(sourceID: "drive-A", path: "/Volumes/Assets/素材/../素材/合同.txt", sourceName: "Assets")
            XCTAssertTrue(favorites.toggle(file))
            let restored = FileFavorites(defaults: preferences)
            XCTAssertTrue(restored.contains(sourceID: "drive-A", path: "/Volumes/Assets/素材/合同.txt"))
            XCTAssertFalse(restored.contains(sourceID: "drive-A", path: "/Volumes/Assets/其他/合同.txt"))
            XCTAssertFalse(restored.contains(sourceID: "drive-B", path: file.path))
            XCTAssertFalse(restored.toggle(file)); XCTAssertTrue(FileFavorites(defaults: preferences).files.isEmpty)
        }
    }
    func testStarSurvivesDifferentQueryControllerRestartAndIndexRebuild() throws {
        _ = NSApplication.shared
        try defaults { preferences in
            let controller = SearchViewController(snapshot: true, preferences: preferences), first = store()
            try prepare(controller, query: "favorite", store: first)
            let initial = try cell(controller)
            XCTAssertFalse(initial.favoriteButton.isFavorite)
            initial.favoriteButton.performClick(nil)
            XCTAssertTrue(try cell(controller).favoriteButton.isFavorite)
            XCTAssertTrue(controller.contextMenu().items.first { $0.identifier?.rawValue == "favorite" }?.state == .on)
            try prepare(controller, query: "other", store: first)
            XCTAssertFalse(try cell(controller).favoriteButton.isFavorite)
            XCTAssertTrue(controller.contextMenu().items.first { $0.identifier?.rawValue == "favorite" }?.state == .off)
            let restarted = SearchViewController(snapshot: true, preferences: preferences)
            try prepare(restarted, query: "txt", store: store(["", "other.txt", "favorite.txt"]))
            let row = try XCTUnwrap((0..<(restarted.results.result?.count ?? 0)).first { restarted.results.item(at: $0)?.name == "favorite.txt" })
            XCTAssertEqual(restarted.results.item(at: row)?.id, 2)
            XCTAssertTrue(try cell(restarted, row: row).favoriteButton.isFavorite)
            try cell(restarted, row: row).favoriteButton.performClick(nil)
            XCTAssertFalse(try cell(restarted, row: row).favoriteButton.isFavorite)
            XCTAssertTrue(FileFavorites(defaults: preferences).files.isEmpty)
        }
    }
    func testContentAndOfflineResultsUseTheSameFavoriteIdentity() throws {
        _ = NSApplication.shared
        try defaults { preferences in
            let controller = SearchViewController(snapshot: true, preferences: preferences), index = store()
            _ = controller.view
            let source = SearchSource(id: "drive-offline", displayName: "Archive", isOnline: false, store: index)
            let base = SearchPresentation(try XCTUnwrap(MultiSearcher.search(.parse("1280"), in: [source])))
            let hit = SupplementaryHit(sourceID: source.id, entryID: 1, detail: "Cached invoice 1280")
            controller.present(base.supplement([hit], options: .init(), only: true))
            controller.toggleSelectedFileFavorite()
            XCTAssertTrue(try cell(controller).favoriteButton.isFavorite)
            controller.present(SearchPresentation(try XCTUnwrap(MultiSearcher.search(.parse("favorite"), in: [source]))))
            XCTAssertTrue(try cell(controller).favoriteButton.isFavorite)
            let menu = try XCTUnwrap(controller.results.onContextMenu?(0))
            XCTAssertTrue(menu.items.contains { $0.title == L10n.text("file.unfavorite") && $0.isEnabled })
            let library = controller.makeSearchLibraryMenu()
            let actions = try XCTUnwrap(library.items.first?.submenu?.items.first?.submenu)
            XCTAssertFalse(actions.items[0].isEnabled); XCTAssertTrue(actions.items[2].isEnabled)
            XCTAssertEqual(FileFavorites(defaults: preferences).files.count, 1)
        }
    }
    func testSearchFavoritesArePreservedAndSeparateFromFileStars() throws {
        _ = NSApplication.shared
        try defaults { preferences in
            let saved = SavedSearch(query: "favorite")
            SearchLibrary(defaults: preferences).toggleFavorite(saved)
            let controller = SearchViewController(snapshot: true, preferences: preferences)
            try prepare(controller, query: "favorite", store: store())
            XCTAssertFalse(try cell(controller).favoriteButton.isFavorite)
            controller.toggleSelectedFileFavorite()
            XCTAssertEqual(SearchLibrary(defaults: preferences).favorites, [saved])
            let menu = controller.makeSearchLibraryMenu()
            XCTAssertTrue(menu.items.contains { ($0.representedObject as? SavedSearch) == saved })
            let saveSearch = try XCTUnwrap(menu.items.first { $0.keyEquivalent == "d" })
            XCTAssertEqual(saveSearch.keyEquivalentModifierMask, [.command, .shift])
            try prepare(controller, query: "no-such-result", store: store())
            XCTAssertEqual(controller.contextMenu().items.first { $0.identifier?.rawValue == "favorite" }?.isEnabled, nil)
        }
    }
    func testReusedCellsResetStarStateAndKeepTextClearOfButton() throws {
        _ = NSApplication.shared
        let source = SearchSource(id: "startup", displayName: "", isOnline: true, store: store())
        let cell = ResultCell(frame: NSRect(x: 0, y: 0, width: 800, height: 50)), icons = IconProvider()
        let item = ResultItem(detail: nil, id: 1, source: source, name: "favorite.txt", parentPath: "/generated", path: "/generated/favorite.txt", size: 100, modified: Date(), flags: 128, kind: 3)
        cell.configure(item, query: .parse("favorite"), icons: icons, isFavorite: true, onToggleFavorite: {})
        XCTAssertTrue(cell.favoriteButton.isFavorite)
        cell.configure(item, query: .parse("favorite"), icons: icons, isFavorite: false, onToggleFavorite: {})
        cell.layoutSubtreeIfNeeded(); cell.layout()
        XCTAssertFalse(cell.favoriteButton.isFavorite)
        XCTAssertEqual(cell.favoriteButton.frame.midY, cell.bounds.midY, accuracy: 0.5)
        let icon = try XCTUnwrap(cell.subviews.compactMap { $0 as? NSImageView }.first)
        XCTAssertLessThan(cell.favoriteButton.frame.maxX, cell.actionsButton.frame.minX)
        let name = try XCTUnwrap(cell.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == item.name })
        XCTAssertLessThan(icon.frame.maxX, name.frame.minX)
        XCTAssertLessThan(name.frame.maxX, cell.favoriteButton.frame.minX)
    }
}
