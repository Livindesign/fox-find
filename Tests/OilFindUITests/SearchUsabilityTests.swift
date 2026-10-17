import AppKit
import XCTest
import OilFindCore
@testable import OilFindApp

final class SearchUsabilityTests: XCTestCase {
    private func fixture() throws -> (SearchViewController, IndexStore) {
        _ = NSApplication.shared
        let suite = "FoxUsability-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let names = [""] + (1...80).map { "photography-\($0).pdf" }
        var b = ScanBuffer()
        b.ids = (0...80).map(UInt32.init); b.parents = Array(repeating: 0, count: 81)
        b.sizes = Array(repeating: 2048, count: 81); b.mtimes = Array(repeating: 10, count: 81)
        b.flags = [1] + Array(repeating: 128, count: 80); b.depths = [0] + Array(repeating: 1, count: 80)
        b.kinds = [1] + Array(repeating: 3, count: 80); b.nameLens = names.map { UInt32($0.utf8.count) }; b.nameBytes = Array(names.joined().utf8)
        let store = IndexStore(scan: ScanOutput(buffers: [b], count: 81, homeIndex: .max, elapsed: 0, finishedAt: 0), config: IndexConfig(rootPath: "/usability-fixture"))
        defaults.set(false, forKey: "search.inlinePreview") // Legacy preference must no longer hide list previews.
        let controller = SearchViewController(snapshot: true, preferences: defaults)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 650)
        try controller.prepareSnapshot(state: "results", query: "photography", options: .init(sort: .name, ascending: true), store: store, selection: 0)
        controller.resultPasteboard = NSPasteboard(name: .init("FoxUsability-" + UUID().uuidString))
        return (controller, store)
    }
    func testListAlwaysShowsPreviewAndGridUsesFullWidth() throws {
        let (c, _) = try fixture()
        c.setGridMode(false); c.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(c.inlinePreview.isHidden)
        XCTAssertLessThan(c.results.frame.maxX, c.inlinePreview.frame.minX)
        c.setGridMode(true); c.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(c.inlinePreview.isHidden); XCTAssertEqual(c.results.frame.width, c.view.bounds.width)
        c.setGridMode(false); c.view.layoutSubtreeIfNeeded(); XCTAssertFalse(c.inlinePreview.isHidden)
        c.view.setFrameSize(NSSize(width: 700, height: 650)); c.view.needsLayout = true; c.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(c.inlinePreview.isHidden, "Narrow windows keep readable result widths")
    }
    func testPartialMetadataScanNeverClaimsNoMatchesAndOffersResume() throws {
        let (c, store) = try fixture()
        let base = SearchPresentation(try XCTUnwrap(Searcher.search(.parse("photography"), in: store)))
        let paused = try XCTUnwrap(base.refined(.init(tag: "Test"), reader: AssetMetadataReader(), cancelled: { false }, budget: 0))
        c.present(paused)
        let empty = try XCTUnwrap(c.view.subviews.compactMap { $0 as? StateView }.first { $0.state == .empty })
        XCTAssertEqual(empty.assistance?.title, L10n.text("asset.paused"))
        XCTAssertEqual(empty.assistance?.actionTitle, L10n.text("asset.continue"))
        XCTAssertTrue(c.makeMoreMenu().items.contains { $0.identifier?.rawValue == "continueMetadata" })
        var running: SearchPresentation?
        _ = base.refined(.init(tag: "Test"), reader: AssetMetadataReader(), cancelled: { false }, progress: { running = $0 }, budget: 0)
        c.present(try XCTUnwrap(running))
        XCTAssertEqual(empty.assistance?.title, L10n.text("asset.checking"))
        XCTAssertTrue(empty.assistanceButton.isHidden)
    }
    private func flatten(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(flatten) ?? []) } }
    func testReopeningAndViewChangesPreservePausedMetadataSnapshot() throws {
        let (c, store) = try fixture()
        c.additionalSources = { [SearchSource(id: "startup", displayName: "", isOnline: true, store: store)] }
        c.toolsBar.refinement = .init(tag: "Test")
        let base = SearchPresentation(try XCTUnwrap(Searcher.search(.parse("photography"), in: store)))
        let paused = try XCTUnwrap(base.refined(c.toolsBar.refinement, reader: AssetMetadataReader(), cancelled: { false }, budget: 0))
        c.present(paused)
        // Simulate a queued refresh after a filesystem change, including reopens
        // caused by external clients. Neither should restart a paused scan.
        store.write { store.version += 1 }
        c.indexChanged()
        for grid in [true, false, true] {
            c.setGridMode(grid); c.panelWillShow()
            XCTAssertFalse(c.searchInFlight)
            XCTAssertTrue(c.results.result === paused)
        }
        c.searchField.text = "another-query"
        c.panelWillShow()
        XCTAssertTrue(c.searchInFlight, "New query must still search")
        c.searchField.text = ""; c.startSearch()
        XCTAssertNil(c.results.result)
    }
    func testContextAndPaletteShareActionIdentityNamesAvailabilityAndShortcuts() throws {
        let (c, _) = try fixture()
        let menu = flatten(c.contextMenu()).filter { $0.identifier != nil }, actions = c.makeActions()
        XCTAssertEqual(Set(menu.compactMap { $0.identifier?.rawValue }), Set(actions.map(\.id)))
        XCTAssertEqual(menu.first?.identifier?.rawValue, "open")
        XCTAssertEqual(menu.last?.identifier?.rawValue, "trash")
        for action in actions {
            let item = try XCTUnwrap(menu.first { $0.identifier?.rawValue == action.id })
            XCTAssertEqual(item.title, action.title); XCTAssertEqual(item.isEnabled, action.enabled)
            XCTAssertEqual(item.keyEquivalent, action.keyEquivalent); XCTAssertEqual(item.keyEquivalentModifierMask, action.modifiers)
        }
        for id in ["copyFile", "copyPath", "favorite", "openWith", "share", "alias", "terminal"] { XCTAssertTrue(actions.contains { $0.id == id }, id) }
        XCTAssertFalse(c.makeMoreMenu().items.contains { $0.identifier?.rawValue == "trash" })
    }
    func testRetainedMenuUsesOriginalFileAndNeverReplacementSource() throws {
        let (c, store) = try fixture()
        let original = try XCTUnwrap(c.results.selectedItem)
        let menu = c.contextMenu(), copy = try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == "copyPath" })
        c.results.select(5)
        (copy.representedObject as? SearchMenuAction)?.invoke(nil)
        XCTAssertEqual(c.resultPasteboard.string(forType: .string), original.path)
        c.resultPasteboard.clearContents()
        let replacement = try fixture().1
        c.results.currentSource = { _ in SearchSource(id: "startup", displayName: "changed", isOnline: true, store: replacement) }
        (copy.representedObject as? SearchMenuAction)?.invoke(nil)
        XCTAssertNil(c.resultPasteboard.string(forType: .string))
        XCTAssertGreaterThan(store.count, 0)
    }
    func testMenuDefersRefreshAndKeepsSelectionInBothViews() throws {
        for grid in [false, true] {
            let (c, store) = try fixture(); c.setGridMode(grid); c.results.select(12)
            let before = c.results.selectedItem?.path, menu = c.contextMenu()
            c.menuWillOpen(menu)
            let next = try XCTUnwrap(Searcher.search(.parse("photography-7"), in: store))
            c.results.refresh(next)
            XCTAssertEqual(c.results.result?.count, 80); XCTAssertEqual(c.results.selectedItem?.path, before)
            c.menuDidClose(menu)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            XCTAssertEqual(c.results.result?.count, next.items.count)
        }
    }
    func testClosingSubmenuDoesNotUnlockParentMenuResults() throws {
        let (c, store) = try fixture(), parent = NSMenu(), child = NSMenu()
        c.menuWillOpen(parent); c.menuWillOpen(child)
        c.results.refresh(try XCTUnwrap(Searcher.search(.parse("photography-7"), in: store)))
        c.menuDidClose(child); RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(c.results.result?.count, 80)
        c.menuDidClose(parent); RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertLessThan(c.results.result?.count ?? 80, 80)
    }
    func testNaturalConditionsCanBeRemovedOneAtATimeWithoutChangingDateMeaning() throws {
        let (c, _) = try fixture()
        c.searchField.text = "下载目录最近7天拍摄图片"; c.startSearch()
        XCTAssertEqual(Set(c.contextBar.conditions.map(\.id)), ["folder", "captured", "token:kind:image"])
        c.removeSearchCondition("folder")
        XCTAssertNil(c.toolsBar.folder); XCTAssertNotNil(c.toolsBar.refinement.captured)
        XCTAssertTrue(c.searchField.text.contains("kind:image")); XCTAssertFalse(c.searchField.text.contains("dm:"))
        c.removeSearchCondition("captured")
        XCTAssertNil(c.toolsBar.refinement.captured); XCTAssertTrue(c.searchField.text.contains("kind:image"))
        c.removeSearchCondition("token:kind:image")
        XCTAssertEqual(c.searchField.text, "*"); XCTAssertTrue(c.contextBar.conditions.isEmpty)
        c.searchField.text = "下载目录最近7天修改PDF"; c.startSearch(); c.clearSearchConditions()
        XCTAssertEqual(c.searchField.text, "*"); XCTAssertTrue(c.contextBar.conditions.isEmpty)
    }
    func testChoosingCategoryReplacesNaturalTypeAndSortingDoesNot() throws {
        let (c, _) = try fixture()
        c.searchField.text = "下载目录最近7天拍摄图片"; c.startSearch()
        XCTAssertEqual(c.filters.interpretedKind, 4)
        XCTAssertTrue(c.toolsBar.scope.title.contains("Downloads"))
        c.filters.options.sort = .size; c.filters.onChange?()
        XCTAssertEqual(c.filters.interpretedKind, 4)
        c.filters.select(3)
        XCTAssertEqual(c.filters.options.kind, 3); XCTAssertFalse(c.searchField.text.contains("kind:image"))
        XCTAssertNotNil(c.toolsBar.refinement.captured)
    }
    func testPaletteShortcutFollowsResizingAndStaysSeparateFromTitle() {
        let cell = SearchActionCell(frame: .zero)
        cell.configure(SearchAction(id: "page", title: "查看匹配内容 · 第 7 页", shortcut: "⌘⇧Y", run: {}), startsGroup: true)
        for width: CGFloat in [380, 480, 520] {
            cell.frame = NSRect(x: 0, y: 0, width: width, height: 48); cell.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(cell.shortcutLabel.frame.minX, cell.nameLabel.frame.maxX)
            XCTAssertLessThanOrEqual(cell.shortcutLabel.frame.maxX, width - 10)
            XCTAssertEqual(cell.shortcutLabel.frame.midY, 24)
        }
    }
    func testOverflowKeepsAllConditionsReachableWithoutClipping() {
        let context = SearchContextBar(frame: NSRect(x: 0, y: 0, width: 720, height: 32))
        context.update(text: nil, browsing: false, canBack: false, canForward: false, recursive: false,
                       conditions: (1...8).map { .init(id: String($0), title: "Very long filter condition \($0)") })
        context.layoutSubtreeIfNeeded()
        XCTAssertFalse(context.overflow.isHidden)
        XCTAssertTrue(context.chipButtons.contains { $0.isHidden })
        for button in context.chipButtons where !button.isHidden {
            XCTAssertLessThanOrEqual(button.convert(button.bounds, to: context).maxX, context.overflow.frame.minX)
        }
        XCTAssertLessThan(context.overflow.frame.maxX, context.edit.frame.minX)
    }
    func testSimilarityHasExplicitExitAndRestoresCategoryOnEditOrClear() throws {
        let (c, _) = try fixture()
        c.filters.options.kind = 3; c.filters.options.sort = .size
        c.findSimilar(path: "/reference.jpg")
        XCTAssertEqual(c.filters.options.kind, 4); XCTAssertFalse(c.contextBar.exitSimilarity.isHidden)
        XCTAssertTrue(c.contextBar.label.stringValue.contains("reference.jpg"))
        c.contextBar.exitSimilarity.performClick(nil)
        XCTAssertNil(c.similarityPath); XCTAssertEqual(c.filters.options.kind, 3); XCTAssertEqual(c.filters.options.sort, .size)
        XCTAssertNil(c.results.result); XCTAssertEqual(c.searchField.text, "")
        c.findSimilar(path: "/reference.jpg"); c.searchField.text = "contract"; c.searchField.onChange?()
        XCTAssertNil(c.similarityPath); XCTAssertEqual(c.filters.options.kind, 3)
    }
    func testListActionsAndLongPassageNeverOverlapMetadata() throws {
        let (c, _) = try fixture(), item = try XCTUnwrap(c.results.selectedItem)
        let hit = SupplementaryHit(sourceID: "startup", entryID: item.id, detail: String(repeating: "可能相关 · 漫长的匹配段落 ", count: 50), semanticScore: 0.8, matchedPage: 7)
        c.present(try XCTUnwrap(c.results.result).supplement([hit], options: .init(), only: true))
        for width: CGFloat in [720, 900, 1200] {
            c.view.frame.size.width = width; c.view.layoutSubtreeIfNeeded()
            let cell = try XCTUnwrap(c.results.tableView(NSTableView(), viewFor: nil, row: 0) as? ResultCell)
            cell.frame = NSRect(x: 0, y: 0, width: width, height: 50); cell.layoutSubtreeIfNeeded()
            XCTAssertEqual(cell.actionsButton.frame.midY, 25)
            let labels = cell.subviews.compactMap { $0 as? NSTextField }
            for label in labels { XCTAssertLessThanOrEqual(label.frame.maxX, cell.actionsButton.frame.minX) }
            XCTAssertTrue(c.makeActions().contains { $0.title == L10n.text("semantic.openPage", "7") })
        }
    }
    func testDarkLightChineseEnglishLayoutsAndSnapshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["FOXFIND_UX_SNAPSHOTS"] else { throw XCTSkip("Opt-in visual acceptance artifacts") }
        defer { L10n.snapshotChinese = nil }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for chinese in [true, false] { for dark in [true, false] { for width: CGFloat in [720, 900, 1200] {
            L10n.snapshotChinese = chinese
            let (c, store) = try fixture()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 650), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); window.contentViewController = c
            defer { window.close() }
            c.toolsBar.refinement.tag = chinese ? "产品摄影" : "Product Photography"
            c.toolsBar.refinement.minWidth = 1921
            try c.prepareSnapshot(state: "results", query: "下载目录最近7天拍摄图片", options: .init(), store: store, selection: 0)
            c.view.frame = NSRect(x: 0, y: 0, width: width, height: 650)
            c.view.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(c.results.frame.height, 350); XCTAssertEqual(c.footer.frame.maxY, 650)
            let buttons = [c.toolsBar.scope, c.toolsBar.refine, c.toolsBar.match, c.toolsBar.list, c.toolsBar.grid, c.toolsBar.more]
            for pair in zip(buttons, buttons.dropFirst()) { XCTAssertLessThanOrEqual(pair.0.frame.maxX, pair.1.frame.minX) }
            let image = try XCTUnwrap(c.view.bitmapImageRepForCachingDisplay(in: c.view.bounds))
            window.appearance?.performAsCurrentDrawingAppearance { c.view.cacheDisplay(in: c.view.bounds, to: image) }
            let path = "\(directory)/\(chinese ? "zh" : "en")-\(dark ? "dark" : "light")-\(Int(width)).png"
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
            if width == 900 && chinese {
                c.toolsBar.refinement = AssetRefinement()
                try c.prepareSnapshot(state: "results", query: "photography", options: .init(), store: store, selection: 0)
                if let file = c.results.selectedItem, let result = c.results.result {
                    let hit = SupplementaryHit(sourceID: "startup", entryID: file.id, detail: "可能相关 · 第 7 页：使用柔光箱和侧逆光控制水晶表面反射", semanticScore: 0.9, matchedPage: 7, matchedStamp: "fixture")
                    c.present(result.supplement([hit], options: .init(), only: false))
                }
                for mode in ["list", "grid", "actions", "similarity"] {
                    c.setGridMode(mode == "grid")
                    if mode == "actions" { c.showActions() }
                    if mode == "similarity" { c.closeActions(); c.findSimilar(path: "/reference-photo.jpg"); c.setState(nil) }
                    c.view.layoutSubtreeIfNeeded()
                    let picture = try XCTUnwrap(c.view.bitmapImageRepForCachingDisplay(in: c.view.bounds))
                    window.appearance?.performAsCurrentDrawingAppearance { c.view.cacheDisplay(in: c.view.bounds, to: picture) }
                    try XCTUnwrap(picture.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "\(directory)/\(mode)-\(dark ? "dark" : "light").png"))
                }
            }

        } } }
    }
}
