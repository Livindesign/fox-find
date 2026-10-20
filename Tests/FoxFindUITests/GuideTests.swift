import AppKit
import XCTest
import Combine
import FoxFindCore
@testable import FoxFindApp

final class GuideTests: XCTestCase {
    override func setUp() { super.setUp(); _ = NSApplication.shared }
    private func isolated(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "FoxGuideTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
    private func fixture() -> IndexStore {
        _ = NSApplication.shared
        let names = [""] + (1...100).map { "Guide-\($0).txt" }
        var b = ScanBuffer()
        b.ids = (0...100).map(UInt32.init); b.parents = Array(repeating: 0, count: 101)
        b.sizes = Array(repeating: 128, count: 101); b.mtimes = Array(repeating: 1, count: 101)
        b.flags = [1] + Array(repeating: 128, count: 100); b.depths = [0] + Array(repeating: 1, count: 100)
        b.kinds = [1] + Array(repeating: 3, count: 100)
        b.nameLens = names.map { UInt32($0.utf8.count) }; b.nameBytes = Array(names.joined().utf8)
        return IndexStore(scan: ScanOutput(buffers: [b], count: 101, homeIndex: .max, elapsed: 0, finishedAt: 0), config: IndexConfig(rootPath: "/synthetic-fox-guide"))
    }
    private func key(_ code: UInt16, text: String = "", flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                        context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }
    func testUpgradeStaysQuietAndExplicitReplayWorks() throws {
        try isolated { defaults in
            let old = GuideModel(defaults: defaults, returningUser: true)
            old.send(.start); XCTAssertFalse(old.active)
            XCTAssertEqual(old.step, .dismissed)
            old.send(.replay); XCTAssertEqual(old.step, .search)
            old.dismiss()
            XCTAssertFalse(GuideModel(defaults: defaults, returningUser: true).active)
        }
    }
    func testRealEventsAreRequiredAndSkipPersists() throws {
        try isolated { defaults in
            let guide = GuideModel(defaults: defaults, returningUser: false)
            guide.send(.useResult); guide.send(.contentMatch); XCTAssertEqual(guide.step, .idle)
            guide.send(.start); XCTAssertEqual(guide.step, .search)
            guide.resultsChanged(available: false, previewable: false); XCTAssertEqual(guide.step, .search)
            guide.resultsChanged(available: true, previewable: true); XCTAssertEqual(guide.step, .result)
            guide.send(.useResult); XCTAssertEqual(guide.step, .contentOffer)
            guide.send(.configureContent); XCTAssertEqual(guide.step, .contentSetup)
            guide.updateContent(.init(folders: 1, indexed: 12)); XCTAssertEqual(guide.step, .contentSetup)
            guide.send(.searchContent); XCTAssertEqual(guide.step, .contentSearch)
            guide.resultsChanged(available: true, previewable: true); XCTAssertEqual(guide.step, .contentSearch)
            guide.resultsChanged(available: true, previewable: true, contentMatch: true); XCTAssertEqual(guide.step, .success)
            guide.send(.finish); XCTAssertFalse(guide.active)
            XCTAssertEqual(GuideModel(defaults: defaults, returningUser: true).step, .finished)
        }
    }
    func testEveryStageCanBeDismissedAndUnknownStateDoesNotStartTour() throws {
        for stage in ["search", "result", "contentOffer", "contentSetup", "contentSearch", "success"] {
            var progress = GuideProgress(saved: stage, returningUser: false)
            progress.send(.dismiss); progress.send(.results); progress.send(.contentMatch)
            XCTAssertEqual(progress.step, .dismissed)
        }
        XCTAssertEqual(GuideProgress(saved: "future-version", returningUser: false).step, .dismissed)
    }
    func testContentStatusDoesNotClaimReadyWithoutFoldersOrWhileDisabled() throws {
        XCTAssertFalse(ContentGuideStatus(folders: 0, indexed: 20).searchable)
        XCTAssertFalse(ContentGuideStatus(enabled: false, folders: 1, indexed: 20).searchable)
        XCTAssertTrue(ContentGuideStatus(paused: true, folders: 1, indexed: 20).searchable, "Paused indexes retain searchable contents")
        try isolated { defaults in
            defaults.set("contentSetup", forKey: GuideModel.storageKey)
            let model = GuideModel(defaults: defaults, returningUser: false)
            model.updateContent(.init(running: true, folders: 1, total: 40))
            XCTAssertFalse(model.content.searchable)
            for chinese in [false, true] {
                L10n.snapshotChinese = chinese
                XCTAssertFalse(model.title.isEmpty); XCTAssertFalse(model.message.isEmpty)
                XCTAssertNotNil(model.primaryTitle)
                model.updateContent(.init(hasError: true, folders: 1))
                XCTAssertFalse(model.content.searchable)
                model.updateContent(.init(running: true, folders: 1, indexed: 1, completed: 1, total: 40))
                XCTAssertTrue(model.content.searchable)
            }
            L10n.snapshotChinese = nil
        }
    }
    func testCalloutDoesNotStealEditorAndEscapeDismissesOnlyGuide() throws {
        try isolated { defaults in
            let panel = SearchPanel(snapshot: true, preferences: defaults), c = panel.searchController
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.makeFirstResponder(c.searchField.input)
            let editor = panel.firstResponder
            let frame = c.results.frame
            let guide = GuideModel(defaults: defaults, returningUser: false)
            guide.send(.start); c.guide = guide
            c.view.layoutSubtreeIfNeeded()
            XCTAssertTrue(editor === panel.firstResponder)
            XCTAssertEqual(c.results.frame, frame)
            let overlay = try XCTUnwrap(c.guideOverlay)
            XCTAssertNil(overlay.hitTest(NSPoint(x: 80, y: 30)), "The highlighted field must remain clickable")
            XCTAssertNotNil(overlay.hitTest(NSPoint(x: overlay.cardFrame.midX, y: overlay.cardFrame.midY)))
            var hides = 0; c.hidePanel = { hides += 1 }
            XCTAssertFalse(c.handleKey(key(48)), "During guidance Tab belongs to native focus navigation")
            let button = NSButton(title: "Guide action", target: nil, action: nil)
            overlay.addSubview(button); panel.makeFirstResponder(button)
            XCTAssertFalse(c.handleKey(key(36)), "Return must reach the focused guide action")
            XCTAssertFalse(c.handleKey(key(49)), "Space must not preview a file when a guide action is focused")
            button.removeFromSuperview(); panel.makeFirstResponder(c.searchField.input)
            XCTAssertTrue(c.handleKey(key(53))); XCTAssertEqual(guide.step, .dismissed); XCTAssertEqual(hides, 0)
            XCTAssertNil(c.guideOverlay)
            XCTAssertTrue(c.handleKey(key(53))); XCTAssertEqual(hides, 1)
        }
    }
    func testMarkedChineseTextKeepsEscapeForComposition() throws {
        try isolated { defaults in
            let panel = SearchPanel(snapshot: true, preferences: defaults), c = panel.searchController
            panel.makeFirstResponder(c.searchField.input)
            let guide = GuideModel(defaults: defaults, returningUser: false); guide.send(.start); c.guide = guide
            let editor = try XCTUnwrap(c.searchField.input.currentEditor() as? NSTextView)
            editor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertFalse(c.handleKey(key(53)))
            XCTAssertEqual(guide.step, .search)
            editor.unmarkText()
        }
    }
    func testResultsAdvanceGuideButClearingDoesNotLeaveAPreviewButton() throws {
        try isolated { defaults in
            let c = SearchViewController(snapshot: true, preferences: defaults); _ = c.view
            let guide = GuideModel(defaults: defaults, returningUser: false); guide.send(.start); c.guide = guide
            c.searchField.text = "Guide"
            c.present(try XCTUnwrap(Searcher.search(.parse("Guide"), in: fixture())))
            XCTAssertEqual(guide.step, .result); XCTAssertTrue(guide.hasResult)
            c.searchField.text = ""; c.startSearch()
            XCTAssertFalse(guide.hasResult); XCTAssertEqual(guide.cardStep, .search); XCTAssertNil(c.results.result)
            c.showActions(); XCTAssertEqual(guide.step, .result, "An empty actions menu is not a successful result interaction")
        }
    }
    func testLeavingContentModeDismissesTheContentSpecificHint() throws {
        try isolated { defaults in
            defaults.set("contentSearch", forKey: GuideModel.storageKey)
            let c = SearchViewController(snapshot: true, preferences: defaults); _ = c.view
            let guide = GuideModel(defaults: defaults, returningUser: false); c.guide = guide
            c.beginGuidedContentSearch()
            XCTAssertEqual(c.toolsBar.mode, .contents)
            XCTAssertTrue(c.searchField.text.isEmpty)
            c.toolsBar.onMode?(.names)
            XCTAssertEqual(guide.step, .dismissed)
            XCTAssertNil(c.guideOverlay)
        }
    }
    func testActionsTemporarilyHideGuideWithoutLosingProgress() throws {
        try isolated { defaults in
            let c = SearchViewController(snapshot: true, preferences: defaults); _ = c.view
            let guide = GuideModel(defaults: defaults, returningUser: false); guide.send(.start); c.guide = guide
            c.searchField.text = "Guide"; c.present(try XCTUnwrap(Searcher.search(.parse("Guide"), in: fixture())))
            c.showActions(); c.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(guide.step, .contentOffer); XCTAssertEqual(c.guideOverlay?.isHidden, true)
            c.closeActions(); XCTAssertEqual(c.guideOverlay?.isHidden, false)
            c.toggleSyntax(true); XCTAssertEqual(c.guideOverlay?.isHidden, true)
            c.toggleSyntax(false); XCTAssertEqual(c.guideOverlay?.isHidden, false)
        }
    }
    func testGuideFitsCompactAndStandardWindowsWithoutMovingResults() throws {
        try isolated { defaults in
            for size in [NSSize(width: 680, height: 500), Theme.panelSize] {
                for step in ["search", "result", "contentOffer", "contentSearch", "success"] {
                    defaults.set(step, forKey: GuideModel.storageKey)
                    let c = SearchViewController(snapshot: true, preferences: defaults); _ = c.view
                    c.view.frame.size = size; c.view.layoutSubtreeIfNeeded()
                    let resultFrame = c.results.frame, footerFrame = c.footer.frame
                    c.guide = GuideModel(defaults: defaults, returningUser: false)
                    c.view.layoutSubtreeIfNeeded()
                    let overlay = try XCTUnwrap(c.guideOverlay)
                    XCTAssertTrue(c.view.bounds.contains(overlay.cardFrame), "\(step) at \(size)")
                    XCTAssertFalse(overlay.cardFrame.intersects(c.searchField.frame))
                    XCTAssertFalse(overlay.cardFrame.intersects(c.footer.frame))
                    XCTAssertEqual(resultFrame, c.results.frame); XCTAssertEqual(footerFrame, c.footer.frame)
                }
            }
        }
    }
    func testStatusUpdatesDoNotReloadOrScrollResultsInEitherView() throws {
        try isolated { defaults in
            let store = fixture(), found = try XCTUnwrap(Searcher.search(.parse("Guide"), in: store))
            for grid in [false, true] {
                let c = SearchViewController(snapshot: true, preferences: defaults); _ = c.view
                c.view.frame.size = Theme.panelSize; c.setGridMode(grid)
                c.searchField.text = "Guide"; c.present(found); c.view.layoutSubtreeIfNeeded()
                c.results.select(45)
                let guide = GuideModel(defaults: defaults, returningUser: false); guide.send(.replay); c.guide = guide
                let scroll = c.results.scrollOrigin, reloads = c.results.grid.reloadCount, selection = c.results.selectedID
                for index in 1...100 {
                    guide.updateContent(.init(running: true, folders: 1, indexed: index, completed: index, total: 100))
                    c.view.layoutSubtreeIfNeeded()
                }
                XCTAssertEqual(c.results.scrollOrigin, scroll); XCTAssertEqual(c.results.selectedID, selection)
                XCTAssertEqual(c.results.grid.reloadCount, reloads)
                print("GUIDE_STABILITY grid=\(grid) updates=100 reloads=\(c.results.grid.reloadCount - reloads) scrollUnchanged=\(c.results.scrollOrigin == scroll)")
            }
        }
    }
    func testGuideScrollRenderingBudget() throws {
        guard ProcessInfo.processInfo.environment["FOXFIND_GUIDE_PERF"] == "1" else { throw XCTSkip("Opt-in guide rendering comparison") }
        try isolated { defaults in
            let store = fixture(), result = try XCTUnwrap(Searcher.search(.parse("Guide"), in: store))
            var metrics = [String: Double]()
            for grid in [false, true] {
                let panel = SearchPanel(snapshot: true, preferences: defaults), c = panel.searchController
                panel.setContentSize(NSSize(width: 900, height: 600))
                c.view.frame.size = NSSize(width: 900, height: 600)
                c.setGridMode(grid); c.searchField.text = "Guide"; c.present(result)
                c.view.layoutSubtreeIfNeeded()
                let container: NSView = grid ? c.results.grid : c.results
                let scroll = try XCTUnwrap(container.subviews.compactMap { $0 as? NSScrollView }.first)
                for enabled in [false, true] {
                    if enabled {
                        let guide = GuideModel(defaults: defaults, returningUser: false); guide.send(.replay)
                        guide.resultsChanged(available: true, previewable: true); c.guide = guide
                    }
                    c.view.layoutSubtreeIfNeeded()
                    var samples = [Double]()
                    for i in 0..<110 {
                        let start = CFAbsoluteTimeGetCurrent()
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(i % 16) * 90))
                        scroll.reflectScrolledClipView(scroll.contentView)
                        c.view.layoutSubtreeIfNeeded(); c.view.displayIfNeeded()
                        if i >= 10 { samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000) }
                        RunLoop.current.run(until: Date().addingTimeInterval(0.001))
                    }
                    samples.sort()
                    metrics["\(grid ? "grid" : "list")_guide_\(enabled ? "on" : "off")_p95_ms"] = samples[95]
                    XCTAssertLessThan(samples[95], 16.7)
                }
            }
            let data = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
            print("GUIDE_PERF " + String(decoding: data, as: UTF8.self))
        }
    }
    func testSettingsEscapeOnlyDismissesAnActiveContentGuide() throws {
        try isolated { defaults in
            defaults.set("contentSetup", forKey: GuideModel.storageKey)
            let guide = GuideModel(defaults: defaults, returningUser: false)
            let window = SettingsWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
            window.guide = guide
            XCTAssertTrue(window.performKeyEquivalent(with: key(53)))
            XCTAssertEqual(guide.step, .dismissed)
            XCTAssertFalse(window.performKeyEquivalent(with: key(53)))
        }
    }
}
