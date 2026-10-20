import AppKit
import XCTest
import FoxFindCore
@testable import FoxFindApp

final class FileActionCapabilitiesTests: XCTestCase {
    final class Provider: SupplementarySearchProvider {
        var isEnabled = true
        var previewRequests = 0
        func sourcesDidChange(_ sources: [SearchSource]) {}
        func userActivity(visible: Bool, typing: Bool) {}
        func prepareSearch(_ query: Query, options: SearchOptions, sources: [SearchSource], isCancelled: @escaping () -> Bool) -> () -> [SupplementaryHit] { { [] } }
        func preparePreview(source: SearchSource, entryID: UInt32, isCancelled: @escaping () -> Bool) -> () -> TextPreviewOutcome {
            previewRequests += 1
            return { .unavailable("Synthetic fixture") }
        }
    }
    private func fixture() throws -> (SearchViewController, Provider, IndexStore) {
        _ = NSApplication.shared
        let names = ["", "Example.app", "Folder", "Fake.pdf", "Report.pdf", "Photo.JPG", "Notes.md", "Sheet.xlsx", "Clip.mov", "Sound.mp3", "Archive.zip", "Design.psd", "Slides.key", "Link.txt", "Large.pdf"]
        var b = ScanBuffer()
        b.ids = names.indices.map(UInt32.init); b.parents = Array(repeating: 0, count: names.count)
        b.sizes = Array(repeating: 2000, count: names.count); b.sizes[names.count - 1] = 70 * 1024 * 1024
        b.mtimes = Array(repeating: 10, count: names.count)
        b.flags = [1, 65, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 65, 2, 0]
        b.depths = [0] + Array(repeating: 1, count: names.count - 1)
        b.kinds = [1, 2, 1, 1, 3, 4, 3, 3, 5, 6, 8, 4, 3, 3, 3]
        b.nameLens = names.map { UInt32($0.utf8.count) }; b.nameBytes = Array(names.joined().utf8)
        let store = IndexStore(scan: .init(buffers: [b], count: names.count, homeIndex: .max, elapsed: 0, finishedAt: 0), config: .init(rootPath: "/synthetic-actions"))
        let defaults = UserDefaults(suiteName: "ActionCapabilities-" + UUID().uuidString)!
        let controller = SearchViewController(snapshot: true, preferences: defaults), provider = Provider()
        controller.supplementaryProvider = provider
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 650)
        try controller.prepareSnapshot(state: "results", query: "*", options: .init(), store: store, selection: 0)
        return (controller, provider, store)
    }
    private func select(_ name: String, in c: SearchViewController) throws {
        let row = try XCTUnwrap((0..<(c.results.result?.count ?? 0)).first { c.results.item(at: $0)?.name == name })
        c.results.select(row)
    }
    private func menuItems(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(menuItems) ?? []) } }

    func testUnknownSystemSymbolDoesNotCrashMenuRendering() {
        _ = NSApplication.shared
        XCTAssertGreaterThan(Theme.symbol("foxfind.synthetic.unknown", size: 14, weight: .regular).size.width, 0)
    }

    func testFormatsAndContainersHaveConsistentMenuAndPaletteCapabilities() throws {
        let (c, _, _) = try fixture()
        for grid in [false, true] {
            c.setGridMode(grid)
            for (name, text, enter, openWith, similar) in [
                ("Example.app", false, false, false, false), ("Folder", false, true, false, false),
                ("Fake.pdf", false, true, false, false), ("Report.pdf", true, false, true, false),
                ("Photo.JPG", true, false, true, true), ("Notes.md", true, false, true, false),
                ("Sheet.xlsx", true, false, true, false), ("Clip.mov", false, false, true, false),
                ("Sound.mp3", false, false, true, false), ("Archive.zip", false, false, true, false),
                ("Design.psd", false, false, true, false), ("Slides.key", false, false, true, false),
                ("Link.txt", false, false, true, false)
            ] {
                try select(name, in: c)
                let actions = c.makeFileActions(), ids = Set(actions.map(\.id))
                XCTAssertEqual(ids.contains("previewText"), text, name)
                XCTAssertEqual(ids.contains("enterFolder"), enter, name)
                XCTAssertEqual(ids.contains("openWith"), openWith, name)
                XCTAssertEqual(ids.contains("similarity"), similar, name)
                XCTAssertEqual(ids.contains("originalCandidates"), similar, name)
                XCTAssertTrue(ids.contains("collectFile"), name)
                let menu = menuItems(c.contextMenu()).filter { $0.identifier != nil }
                XCTAssertEqual(Set(menu.compactMap { $0.identifier?.rawValue }), ids, name)
                for action in actions {
                    let item = try XCTUnwrap(menu.first { $0.identifier?.rawValue == action.id })
                    XCTAssertEqual(item.isEnabled, action.enabled, name)
                }
            }
        }
    }
    func testCollectActionUsesSameIdentityAfterSearchAndUpdatesFooterCount() throws {
        let (c, _, _) = try fixture()
        try select("Report.pdf", in: c)
        let action = try XCTUnwrap(c.makeFileActions().first { $0.id == "collectFile" })
        action.run(); action.run()
        XCTAssertEqual(c.workCollection.value.files.map(\.name), ["Report.pdf"])
        XCTAssertEqual(c.footer.collectionCount, 1)
        try select("Photo.JPG", in: c)
        c.makeFileActions().first { $0.id == "collectFile" }?.run()
        XCTAssertEqual(c.workCollection.value.files.count, 2)
        XCTAssertTrue(c.makeMoreMenu().items.contains { $0.identifier?.rawValue == "collection" })
        c.workCollection.clear()
        XCTAssertTrue(c.footer.collectionButton.isHidden)
    }
    func testShortcutCannotBypassUnsupportedTypesOrSizeLimit() throws {
        let (c, provider, _) = try fixture()
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0, context: nil, characters: "y", charactersIgnoringModifiers: "y", isARepeat: false, keyCode: 16)!
        for name in ["Example.app", "Folder", "Archive.zip", "Clip.mov", "Link.txt", "Large.pdf"] {
            try select(name, in: c)
            XCTAssertTrue(c.handleKey(event)); XCTAssertEqual(provider.previewRequests, 0, name)
        }
        let oversized = try XCTUnwrap(c.makeFileActions().first { $0.id == "previewText" })
        XCTAssertFalse(oversized.enabled); XCTAssertTrue(oversized.detail.contains("64 MB"))
        oversized.run(); XCTAssertEqual(provider.previewRequests, 0)
        try select("Notes.md", in: c)
        XCTAssertTrue(c.handleKey(event)); XCTAssertEqual(provider.previewRequests, 1)
    }
    func testOfflineActionsRetainPathCopyAndUseExplicitCachedTextLabel() throws {
        let (c, _, store) = try fixture()
        c.results.currentSource = { _ in SearchSource(id: "startup", displayName: "Offline fixture", isOnline: false, store: store) }
        try select("Report.pdf", in: c)
        let actions = c.makeFileActions()
        for id in ["open", "reveal", "preview", "copyFile", "openWith", "share", "terminal", "trash"] {
            XCTAssertFalse(try XCTUnwrap(actions.first { $0.id == id }).enabled, id)
        }
        for id in ["copyName", "copyPath", "favorite", "alias", "previewText"] {
            XCTAssertTrue(try XCTUnwrap(actions.first { $0.id == id }).enabled, id)
        }
        XCTAssertEqual(actions.first { $0.id == "previewText" }?.title, L10n.local("查看已索引文字…", "View indexed text…"))
    }
}
