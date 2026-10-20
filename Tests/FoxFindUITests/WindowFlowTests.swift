import AppKit
import XCTest
@testable import FoxFindApp

final class WindowFlowTests: XCTestCase {
    private func fixture(_ run: (SearchPanel, UserDefaults) throws -> Void) rethrows {
        _ = NSApplication.shared
        let suite = "FoxWindowFlow-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let panel = SearchPanel(snapshot: true, preferences: defaults, activating: true)
        defer {
            panel.searchController.auxiliaryWindows.suspend()
            panel.close(); defaults.removePersistentDomain(forName: suite)
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        try run(panel, defaults)
    }
    private func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.06)) }
    func testCollectionCloseReturnsToSearchAndDoesNotResurrectEarlierTool() throws {
        try fixture { panel, _ in
            let c = panel.searchController
            c.searchField.text = "Studio"
            panel.makeKeyAndOrderFront(nil)
            c.showCollection()
            let collection = try XCTUnwrap(c.auxiliaryWindows.active)
            XCTAssertTrue(collection.isVisible); XCTAssertTrue(collection.canBecomeKey)
            XCTAssertFalse(panel.isVisible)
            // Opening search again hides the collection without deleting its data.
            panel.restoreFromAuxiliary()
            XCTAssertFalse(collection.isVisible); XCTAssertNil(c.auxiliaryWindows.active)
            let preview = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 160), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            preview.isReleasedWhenClosed = false
            c.auxiliaryWindows.present(preview, from: panel)
            preview.close(); drain()
            XCTAssertTrue(panel.isVisible); XCTAssertFalse(collection.isVisible)
            XCTAssertEqual(c.searchField.text, "Studio")
            c.showCollection(); XCTAssertTrue(c.auxiliaryWindows.active === collection)
            collection.close(); drain()
            XCTAssertTrue(panel.isVisible); XCTAssertTrue(panel.canBecomeKey)
        }
    }
    func testReplacingOrLeavingPreviewCancelsItsPendingReturn() {
        _ = NSApplication.shared
        let flow = AuxiliaryWindows()
        var returns = 0; flow.onReturn = { returns += 1 }
        let one = NSWindow(), two = NSWindow()
        one.isReleasedWhenClosed = false; two.isReleasedWhenClosed = false
        defer { flow.suspend(); one.close(); two.close() }
        flow.present(one, from: nil); one.close()
        flow.present(two, from: nil); drain()
        XCTAssertEqual(returns, 0); XCTAssertTrue(two.isVisible)
        two.close(); flow.suspend(); drain()
        XCTAssertEqual(returns, 0)
    }
    func testPaletteAndNativeMenusKeepBackgroundHoverSuspendedUntilBothClose() {
        fixture { panel, _ in
            let c = panel.searchController, menu = NSMenu()
            c.actionPalette.show([SearchAction(id: "noop", title: "Action", run: {})], title: "File")
            XCTAssertTrue(c.results.menuTracking)
            c.menuWillOpen(menu)
            c.actionPalette.isHidden = true
            XCTAssertTrue(c.results.menuTracking)
            c.menuDidClose(menu); drain()
            XCTAssertFalse(c.results.menuTracking)
            c.actionPalette.show([], title: "Tools")
            XCTAssertTrue(c.results.menuTracking)
            c.dismissActions(outside: NSPoint(x: 0, y: 0))
            XCTAssertTrue(c.actionPalette.isHidden); XCTAssertFalse(c.results.menuTracking)
        }
    }
    func testEveryAppMenuBranchHasAnIconInBothLanguages() {
        fixture { panel, _ in
            func check(_ menu: NSMenu) {
                for item in menu.items where !item.isSeparatorItem {
                    XCTAssertNotNil(item.image, item.title)
                    XCTAssertEqual(item.image?.size, NSSize(width: 14, height: 14), item.title)
                    if let submenu = item.submenu { check(submenu) }
                }
            }
            for chinese in [true, false] {
                L10n.snapshotChinese = chinese
                defer { L10n.snapshotChinese = nil }
                let c = panel.searchController
                for menu in [c.makeMoreMenu(), c.makeRefinementMenu(), c.contextMenu(), c.makeMatchMenu()] {
                    MenuIcons.decorate(menu); check(menu)
                }
                let edit = NSMenu()
                for action in ["undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:"] {
                    edit.addItem(NSMenuItem(title: action, action: Selector(action), keyEquivalent: ""))
                }
                MenuIcons.decorate(edit); check(edit)
            }
        }
    }
    func testCollectionShortcutAndCopyAreScopedToTheirWindow() throws {
        try fixture { panel, _ in
            let c = panel.searchController
            let pasteboard = NSPasteboard.withUniqueName(); c.resultPasteboard = pasteboard
            defer { pasteboard.releaseGlobally() }
            c.workCollection.add(WorkFile(path: "/Example/Studio.png"))
            panel.makeKeyAndOrderFront(nil)
            let open = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "b", charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11))
            XCTAssertTrue(c.handleKey(open))
            let collection = try XCTUnwrap(c.auxiliaryWindows.active)
            let copy = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: collection.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            XCTAssertFalse(panel.performKeyEquivalent(with: copy))
            XCTAssertTrue(collection.performKeyEquivalent(with: copy))
            XCTAssertTrue(pasteboard.string(forType: .string)?.contains("/Example/Studio.png") == true)
            collection.close(); drain()
            let priorClipboard = pasteboard.string(forType: .string)
            c.filters.selectConversations()
            let collect = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
            XCTAssertTrue(c.handleKey(collect))
            XCTAssertEqual(c.workCollection.value.count, 1)
            XCTAssertEqual(pasteboard.string(forType: .string), priorClipboard)
            XCTAssertNil(c.auxiliaryWindows.active)
        }
    }
    func testCompactStatusLayoutAndSnapshotsInBothLanguages() throws {
        _ = NSApplication.shared
        for chinese in [true, false] {
            L10n.snapshotChinese = chinese
            defer { L10n.snapshotChinese = nil }
            let status = StateView(.empty)
            status.frame = NSRect(x: 0, y: 0, width: 640, height: 350)
            status.appearance = NSAppearance(named: .darkAqua)
            status.configure(diagnostic: nil, hasNoAccess: true, assistance: .init(
                title: L10n.local("部分文件需要重试", "Some files need a retry"),
                message: L10n.local("已处理的内容仍可搜索。打开内容设置，查看并重试失败项目。", "Processed content is still searchable. Review and retry failed files in content settings."),
                actionTitle: L10n.local("查看内容设置…", "Content settings…"), canSearch: false, indexedFiles: 12))
            status.layoutSubtreeIfNeeded()
            XCTAssertTrue(status.bounds.contains(status.assistanceButton.frame))
            XCTAssertTrue(status.bounds.contains(status.grant.frame))
            XCTAssertFalse(status.grant.frame.intersects(status.assistanceButton.frame))
            var clicks = 0; status.onAssistance = { clicks += 1 }; status.assistanceButton.performClick(nil)
            XCTAssertEqual(clicks, 1)
            guard let directory = ProcessInfo.processInfo.environment["FOX_WORKFLOW_SNAPSHOTS"] else { continue }
            let window = NSWindow(contentRect: status.bounds, styleMask: [], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = status.appearance
            let surface = PanelSurface(snapshot: true); window.contentView = surface; surface.addSubview(status)
            surface.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
            window.appearance?.performAsCurrentDrawingAppearance { surface.cacheDisplay(in: surface.bounds, to: bitmap) }
            let url = URL(fileURLWithPath: directory); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent(chinese ? "status-zh.png" : "status-en.png"))
            window.close()
        }
    }
}
