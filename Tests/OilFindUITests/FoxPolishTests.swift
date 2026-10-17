import AppKit
import XCTest
import OilFindCore
@testable import OilFindApp

final class FoxPolishTests: XCTestCase {
    override func setUp() { super.setUp(); _ = NSApplication.shared }
    func testDismissalSurvivesManualReplayAndRelaunch() throws {
        let suite = "FoxPolish." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let guide = GuideModel(defaults: defaults, returningUser: false)
        guide.send(.start); guide.dismiss()
        let relaunched = GuideModel(defaults: defaults, returningUser: true)
        relaunched.send(.start); XCTAssertFalse(relaunched.active)
        relaunched.send(.replay); XCTAssertTrue(relaunched.active)
        XCTAssertFalse(GuideModel(defaults: defaults, returningUser: true).active, "Manual replay must not re-enable startup tips")
    }
    func testUnchangedResultsDoNotRefreshGuide() {
        let suite = "FoxGuideChanges." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let guide = GuideModel(defaults: defaults, returningUser: false); guide.send(.start)
        guide.resultsChanged(available: true, previewable: true)
        var changes = 0; guide.onChange = { changes += 1 }
        for _ in 0..<100 { guide.resultsChanged(available: true, previewable: true) }
        XCTAssertEqual(changes, 0)
        guide.resultsChanged(available: false, previewable: false); XCTAssertEqual(changes, 1)
    }
    func testArtworkDecodeBudgetAndMenuIcon() throws {
        var bytes = 0
        for name in ["fox-original", "01-search", "02-actions", "03-content"] {
            let image = try XCTUnwrap(FunctionalIcons.art(name))
            let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            XCTAssertLessThanOrEqual(max(cg.width, cg.height), name == "fox-original" ? 64 : 640)
            bytes += cg.bytesPerRow * cg.height
        }
        print("GUIDE_DECODE_BYTES \(bytes)")
        XCTAssertLessThan(bytes, 4_000_000)
        XCTAssertTrue(try XCTUnwrap(FunctionalIcons.image("status-fox")).isTemplate)
    }
    func testCompactActionsPreserveNavigationAndExecutionWithoutSearchField() {
        for chinese in [true, false] {
            L10n.snapshotChinese = chinese; defer { L10n.snapshotChinese = nil }
            let controller = SearchViewController(snapshot: true); _ = controller.view
            controller.view.frame.size = Theme.panelSize; controller.view.layoutSubtreeIfNeeded()
            let palette = controller.actionPalette
            XCTAssertLessThanOrEqual(palette.frame.width, 390)
            var executed = 0
            palette.show((0..<30).map { index in SearchAction(id: "\(index)", title: "Action \(index)", symbol: "folder", run: { executed = index }) }, title: "A long file name for actions.pdf")
            palette.layoutSubtreeIfNeeded()
            XCTAssertEqual(palette.scroll.scrollerStyle, .overlay)
            XCTAssertFalse(palette.subviews.contains { $0 is NSSearchField })
            XCTAssertFalse(palette.layer!.masksToBounds)
            XCTAssertGreaterThan(palette.layer!.shadowOpacity, 0)
            palette.move(23)
            XCTAssertEqual(palette.table.selectedRow, 23)
            palette.activate(); XCTAssertEqual(executed, 23)
        }
    }
    func testTypingAndActionsNeverTurnTheGuidePage() throws {
        let suite = "FoxGuideStable." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let guide = GuideModel(defaults: defaults, returningUser: false); guide.send(.start)
        guide.navigate(1)
        let title = guide.title, message = guide.message, button = guide.primaryTitle
        for _ in 0..<100 {
            guide.resultsChanged(available: false, previewable: false)
            XCTAssertFalse(guide.primaryEnabled)
            guide.resultsChanged(available: true, previewable: true)
            guide.send(.useResult)
            XCTAssertEqual(guide.cardNumber, 2)
            XCTAssertEqual(guide.title, title); XCTAssertEqual(guide.message, message)
            XCTAssertEqual(guide.primaryTitle, button)
        }
        guide.navigate(-1); guide.returnToLiveStep()
        guide.resultsChanged(available: true, previewable: true)
        XCTAssertEqual(guide.cardNumber, 1, "Focusing the editor keeps the tip the user selected")
        guide.navigate(1); guide.navigate(1); guide.send(.configureContent)
        XCTAssertEqual(guide.cardStep, .contentSetup, "Explicit setup still opens the live setup guide")
    }
    func testColdIconLookupNeverBlocksTheScrollingThreadAndSkipsStaleRequests() {
        let image = NSImage(size: NSSize(width: 32, height: 32))
        var resolutions = 0, completions = 0
        let lock = NSLock()
        let icons = IconProvider { _, _ in
            XCTAssertFalse(Thread.isMainThread)
            lock.lock(); resolutions += 1; lock.unlock()
            Thread.sleep(forTimeInterval: 0.05) // Simulate slow Launch Services.
            return image
        }
        let start = CFAbsoluteTimeGetCurrent()
        for i in 0..<40 {
            _ = icons.icon(name: "fixture.ext\(i)", path: "/fixture/\(i)", flags: 0, kind: 3,
                           isRelevant: { i == 39 }) { _ in completions += 1 }
        }
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        XCTAssertLessThan(elapsed, 16.7, "Cold rows must not synchronously ask Launch Services")
        let deadline = Date().addingTimeInterval(3)
        while !icons.isIdle && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(icons.isIdle); XCTAssertEqual(completions, 1)
        lock.lock(); let resolved = resolutions; lock.unlock()
        XCTAssertEqual(resolved, 1); XCTAssertEqual(icons.discardedRequests, 39)
        print("FOX_COLD_ICONS rows=40 main_ms=\(elapsed) stale_skipped=\(icons.discardedRequests) resolved=\(resolved)")
    }

    func testApplicationGridUsesActualAppIconAndAppCaption() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoxAppIcon-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Crimson.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "test.foxfind.crimson", "CFBundlePackageType": "APPL", "CFBundleName": "Crimson"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let icon = NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
            NSColor(srgbRed: 0.9, green: 0.1, blue: 0.3, alpha: 1).setFill(); rect.fill(); return true
        }
        XCTAssertTrue(NSWorkspace.shared.setIcon(icon, forFile: app.path))
        var b = ScanBuffer()
        b.ids = [0, 1]; b.parents = [0, 0]; b.sizes = [0, 0]; b.mtimes = [0, 0]
        b.flags = [1, 3]; b.depths = [0, 1]; b.kinds = [1, 2]
        b.nameLens = [0, UInt32("Crimson.app".utf8.count)]; b.nameBytes = Array("Crimson.app".utf8)
        let store = IndexStore(scan: ScanOutput(buffers: [b], count: 2, homeIndex: .max, elapsed: 0, finishedAt: 0), config: IndexConfig(rootPath: root.path))
        let source = SearchSource(id: "fixture", displayName: "Fixture", isOnline: true, store: store)
        let file = ResultItem(detail: nil, id: 1, source: source, name: "Crimson.app", parentPath: root.path, path: app.path, size: 0, modified: Date(), flags: 3, kind: 2)
        let grid = AssetGridView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        grid.item = { _ in file }; grid.reload(count: 1, selection: 0); grid.layoutSubtreeIfNeeded()
        let cell = grid.collectionView(grid.collection, itemForRepresentedObjectAt: IndexPath(item: 0, section: 0))
        let imageView = try XCTUnwrap(cell.view.subviews.compactMap { $0 as? NSImageView }.first)
        let deadline = Date().addingTimeInterval(3)
        var loaded = false
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if let cg = imageView.image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let bitmap = NSBitmapImageRep(cgImage: cg)
                if let color = bitmap.colorAt(x: cg.width / 2, y: cg.height / 2)?.usingColorSpace(.sRGB) {
                    loaded = color.redComponent > 0.8 && color.greenComponent < 0.25
                    if loaded { XCTAssertEqual(cg.width, 256) }
                }
            }
        } while !loaded && Date() < deadline
        XCTAssertTrue(loaded, "App tile must resolve its actual file icon, not the folder placeholder")
        XCTAssertTrue(cell.view.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == L10n.text("meta.app") })
    }
    func testScrollbarTracksTopMiddleBottomWithThinInsetThumb() throws {
        let scroll = ResultScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        scroll.hasVerticalScroller = true; scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = FlippedView(frame: NSRect(x: 0, y: 0, width: 280, height: 1000))
        scroll.layoutSubtreeIfNeeded()
        let scroller = try XCTUnwrap(scroll.verticalScroller as? TransientResultScroller)
        var positions: [CGFloat] = []
        for fraction: CGFloat in [0, 0.5, 1] {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: fraction * (1000 - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            XCTAssertEqual(scroller.doubleValue, Double(fraction), accuracy: 0.001)
            positions.append(scroller.thumbFrame.minY)
            XCTAssertEqual(scroller.thumbFrame.width, 4)
            XCTAssertGreaterThanOrEqual(scroller.thumbFrame.minX, 2)
            XCTAssertLessThanOrEqual(scroller.thumbFrame.maxX, scroller.bounds.maxX - 2)
        }
        XCTAssertLessThan(positions[0], positions[1]); XCTAssertLessThan(positions[1], positions[2])
        for name: NSAppearance.Name in [.aqua, .darkAqua] {
            scroll.appearance = NSAppearance(named: name)
            XCTAssertLessThan(scroller.thumbColor.alphaComponent, 0.3)
            XCTAssertEqual(scroller.thumbColor.usingColorSpace(.sRGB)?.redComponent, name == .aqua ? 0 : 1)
        }
    }
    func testMenuCommandsHaveConsistentTemplateIconsAndKeepShortcuts() {
        let menu = AppDelegate().makeMenu()
        for item in menu.items where !item.isSeparatorItem {
            XCTAssertNotNil(item.image, item.title)
            XCTAssertEqual(item.image?.size, NSSize(width: 16, height: 16), item.title)
            XCTAssertEqual(item.image?.isTemplate, true, item.title)
        }
        XCTAssertEqual(menu.items.first { $0.action == #selector(AppDelegate.showSettings) }?.keyEquivalent, ",")
    }
    func testLaunchMenuUsesNativeSwitchAndKeepsStateAndLocalization() throws {
        var enabled = false, actions = 0
        var row: MenuSwitchRow!
        row = MenuSwitchRow(title: "开机启动", image: FunctionalIcons.image("menu-login")) {
            enabled.toggle(); actions += 1; row.update(title: "开机启动", enabled: enabled)
        }
        row.layoutSubtreeIfNeeded()
        row.toggle.performClick(nil)
        XCTAssertEqual(actions, 1); XCTAssertEqual(row.toggle.state, .on)
        row.toggle.performClick(nil)
        XCTAssertEqual(actions, 2); XCTAssertEqual(row.toggle.state, .off)
        row.update(title: "Launch at Login", enabled: true)
        XCTAssertEqual(row.toggle.accessibilityLabel(), "Launch at Login")
        XCTAssertEqual(row.toggle.state, .on)
        XCTAssertEqual(row.toggle.frame.midY, row.bounds.midY, accuracy: 0.5)
        XCTAssertEqual(row.bounds.maxX - row.toggle.frame.maxX, 16, accuracy: 0.5)
        let delegate = AppDelegate(), menu = delegate.makeMenu()
        delegate.menuWillOpen(menu)
        let item = try XCTUnwrap(menu.items.first { $0.view is MenuSwitchRow })
        XCTAssertEqual(item.state, .off, "The switch replaces the checkmark")
        XCTAssertNotNil(item.action, "Keyboard menu activation retains the original command")
    }

    func testScrollingKeepsResponsivePathAndDefersColdImagesUntilIdle() {
        XCTAssertTrue(ResultScrollView.isCompatibleWithResponsiveScrolling)
        let image = NSImage(size: NSSize(width: 32, height: 32))
        var resolved = 0, completed = 0
        let lock = NSLock()
        let icons = IconProvider { _, _ in lock.lock(); resolved += 1; lock.unlock(); return image }
        icons.setPaused(true)
        for i in 0..<40 {
            _ = icons.icon(name: "sample.ext\(i)", path: "/fixture/\(i)", flags: 0, kind: 3) { _ in completed += 1 }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        lock.lock(); let duringScroll = resolved; lock.unlock()
        XCTAssertEqual(duringScroll, 0); XCTAssertEqual(completed, 0); XCTAssertTrue(icons.isIdle)
        icons.setPaused(false)
        _ = icons.icon(name: "sample.ext39", path: "/fixture/39", flags: 0, kind: 3) { _ in completed += 1 }
        let deadline = Date().addingTimeInterval(2)
        while !icons.isIdle && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        lock.lock(); let afterScroll = resolved; lock.unlock()
        XCTAssertEqual(afterScroll, 1); XCTAssertEqual(completed, 1)
    }
    func testLargeGridOnlyLaysOutTheRequestedViewportAndReachesLastItem() throws {
        let grid = AssetGridView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        let window = NSWindow(contentRect: grid.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = grid
        defer { window.close() }
        grid.reload(count: 300_000, selection: 0); grid.layoutSubtreeIfNeeded()
        let layout = try XCTUnwrap(grid.collection.collectionViewLayout as? AssetGridLayout)
        let last = try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: 299_999, section: 0)))
        let visible = layout.layoutAttributesForElements(in: NSRect(x: 0, y: last.frame.minY - 200, width: 900, height: 400))
        XCTAssertLessThanOrEqual(visible.count, grid.columns * 4)
        XCTAssertTrue(visible.contains { $0.indexPath?.item == 299_999 })
        XCTAssertFalse(layout.shouldInvalidateLayout(forBoundsChange: NSRect(x: 0, y: 500, width: grid.collection.bounds.width, height: 400)))
        XCTAssertGreaterThanOrEqual(layout.collectionViewContentSize.height, last.frame.maxY)
        grid.select(299_999, reveal: true); grid.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(grid.collection.selectionIndexPaths, [IndexPath(item: 299_999, section: 0)])
        XCTAssertTrue(grid.scroll.contentView.bounds.intersects(last.frame), "Keyboard navigation must reveal the final result: \(grid.scroll.contentView.bounds), last \(last.frame), document \(grid.collection.frame)")
    }
    func testFilterContentInsetsAndCompactSpacing() {
        let bar = SearchToolsBar(frame: NSRect(x: 0, y: 0, width: 900, height: Theme.toolsHeight))
        bar.layoutSubtreeIfNeeded()
        for button in [bar.scope, bar.refine, bar.match] {
            XCTAssertEqual(button.iconFrame.minX, 16)
            XCTAssertEqual(button.iconFrame.midY, button.bounds.midY)
        }
        XCTAssertEqual(bar.refine.frame.minX - bar.scope.frame.maxX, 4)
        XCTAssertEqual(bar.match.frame.minX - bar.refine.frame.maxX, 4)
    }

    func testSettingsUsesSharedScrollThumbAndPreservesFullContent() throws {
        let controller = SettingsWindowController(model: SettingsModel(snapshot: true))
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        let scroll = try XCTUnwrap(scrollViews(try XCTUnwrap(window.contentView)).first)
        XCTAssertTrue(scroll.verticalScroller is TransientResultScroller)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height)
        let bottom = document.bounds.height - scroll.contentView.bounds.height
        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom)); scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertEqual(scroll.contentView.bounds.minY, bottom, accuracy: 1)
    }

}
