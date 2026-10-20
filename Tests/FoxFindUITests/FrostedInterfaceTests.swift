import AppKit
import XCTest
import FoxFindCore
import PDFKit
import Quartz
@testable import FoxFindApp

final class FrostedInterfaceTests: XCTestCase {
    override func setUp() { super.setUp(); _ = NSApplication.shared }
    func testDropdownRotationKeepsCenterAcrossTrackingRelayoutAndResize() throws {
        let bar = SearchToolsBar(frame: NSRect(x: 0, y: 0, width: 960, height: 44))
        let window = NSWindow(contentRect: bar.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = bar
        for width: CGFloat in [960, 680, 960] {
            bar.frame.size.width = width; bar.needsLayout = true; bar.layoutSubtreeIfNeeded()
            for button in [bar.scope, bar.refine, bar.match] {
                let frame = button.chevron.frame
                let textFrame = button.textRect
                for expanded in [true, false, true, false] {
                    button.setMenuExpanded(expanded)
                    button.needsLayout = true; button.layoutSubtreeIfNeeded()
                    let chevron = button.chevron, glyph = chevron.glyph
                    XCTAssertEqual(chevron.frame, frame)
                    XCTAssertEqual(button.textRect, textFrame)
                    XCTAssertEqual(chevron.frame.midY, button.bounds.midY, accuracy: 0.01)
                    XCTAssertEqual(glyph.position.x, chevron.bounds.midX, accuracy: 0.01)
                    XCTAssertEqual(glyph.position.y, chevron.bounds.midY, accuracy: 0.01)
                    XCTAssertTrue(CATransform3DIsIdentity(try XCTUnwrap(chevron.layer).transform), "Do not transform AppKit's backing layer")
                    XCTAssertEqual(glyph.transform.m11, expanded ? -1 : 1, accuracy: 0.001)
                    XCTAssertLessThan(textFrame.maxX, chevron.frame.minX)
                }
            }
        }
    }
    func testSearchMethodChoicesHaveIconsAndExactlyOneSelection() {
        let controller = SearchViewController(snapshot: true); _ = controller.view
        for mode in SearchMode.allCases {
            controller.toolsBar.mode = mode
            let items = controller.makeMatchMenu().items
            XCTAssertEqual(items.count, 3)
            XCTAssertTrue(items.allSatisfy { $0.image?.isValid == true && !$0.title.isEmpty })
            XCTAssertEqual(items.filter { $0.state == .on }.count, 1)
            XCTAssertEqual(items.first { $0.state == .on }?.identifier?.rawValue, mode.rawValue)
        }
    }
    func testGuideArtworkHasTransparentOutsideInsteadOfDarkMatte() throws {
        for name in ["01-search", "02-actions", "03-content"] {
            let image = try XCTUnwrap(FunctionalIcons.art(name))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
            XCTAssertTrue(bitmap.hasAlpha, name)
            for point in [(0, 0), (bitmap.pixelsWide - 1, 0), (0, bitmap.pixelsHigh - 1), (bitmap.pixelsWide - 1, bitmap.pixelsHigh - 1)] {
                XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: point.0, y: point.1)).alphaComponent, 0, accuracy: 0.01, name)
            }
        }
    }
    func testBrowseGuideDoesNotCompleteWorkAndExplicitSetupStillWorks() throws {
        let suite = "FoxFrostedGuide." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = GuideModel(defaults: defaults, returningUser: false)
        model.send(.start); model.navigate(1); model.navigate(1)
        XCTAssertEqual(model.cardNumber, 3); XCTAssertEqual(model.step, .search)
        XCTAssertEqual(defaults.string(forKey: GuideModel.storageKey), "search")
        model.navigate(1); XCTAssertEqual(model.cardNumber, 3)
        model.navigate(-1); XCTAssertEqual(model.cardNumber, 2)
        XCTAssertFalse(model.primaryEnabled, "Keep the action in place, disabled until a result is available")
        XCTAssertEqual(model.title, L10n.local("更多操作，顺手就有", "More actions, close at hand"))
        XCTAssertTrue(model.message.contains("⌘K"), "Browsing should explain the tip, not falsely report a failed search")
        model.navigate(-1); model.navigate(-1); XCTAssertEqual(model.cardNumber, 1)
        model.navigate(1); model.navigate(1); model.send(.configureContent)
        XCTAssertEqual(model.step, .contentSetup)
        XCTAssertNil(model.browsedPage)
    }
    func testScrollMaskOnlyFadesEdgesWithMoreContentAndStaysOutOfScroller() throws {
        let scroll = ResultScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        scroll.hasVerticalScroller = true; scroll.automaticallyAdjustsContentInsets = false
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: 1000))
        scroll.documentView = document; scroll.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero); scroll.updateEdgeFade()
        XCTAssertFalse(scroll.fadesTop); XCTAssertTrue(scroll.fadesBottom)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 300)); scroll.updateEdgeFade()
        XCTAssertTrue(scroll.fadesTop); XCTAssertTrue(scroll.fadesBottom)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1000 - scroll.contentView.bounds.height)); scroll.updateEdgeFade()
        XCTAssertTrue(scroll.fadesTop); XCTAssertFalse(scroll.fadesBottom)
        document.frame.size.height = 100; scroll.contentView.scroll(to: .zero); scroll.updateEdgeFade()
        XCTAssertFalse(scroll.fadesTop); XCTAssertFalse(scroll.fadesBottom)
        XCTAssertNil(scroll.contentView.layer?.mask, "The fade must not move with document bounds")
        let mask = try XCTUnwrap(scroll.layer?.mask)
        let gutter = try XCTUnwrap(mask.sublayers?.last)
        XCTAssertEqual(gutter.frame, scroll.verticalScroller?.frame, "The scrollbar stays outside the faded area")
        XCTAssertEqual(gutter.backgroundColor?.alpha, 1)
    }
    func testCategoryOverflowAndFooterStayWithinCompactWindow() {
        for chinese in [true, false] {
            L10n.snapshotChinese = chinese
            defer { L10n.snapshotChinese = nil }
            for width: CGFloat in [680, 720, 960] {
                let filters = FilterBar(frame: NSRect(x: 0, y: 0, width: width, height: Theme.filterHeight))
                filters.layoutSubtreeIfNeeded(); filters.select(8); filters.layoutSubtreeIfNeeded()
                XCTAssertTrue(filters.moreButton.active)
                let buttons = filters.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
                for button in buttons { XCTAssertTrue(filters.bounds.contains(button.frame)) }
                let footer = FooterBar(frame: NSRect(x: 0, y: 0, width: width, height: Theme.footerHeight))
                footer.layoutSubtreeIfNeeded()
                for hint in footer.subviews where !(hint is NSTextField) && !hint.isHidden {
                    XCTAssertGreaterThanOrEqual(footer.bounds.maxY - hint.frame.maxY, 29)
                    XCTAssertGreaterThanOrEqual(hint.frame.minX, 22)
                }
            }
        }
    }
    func testPackagedArtAndCustomVectorsLoad() {
        for name in ["face-all", "face-folder", "face-document", "face-image", "face-applications", "face-downloads", "face-desktop", "search", "settings"] {
            XCTAssertEqual(FunctionalIcons.image(name)?.isValid, true, name)
            XCTAssertEqual(FunctionalIcons.image(name)?.isTemplate, true, name)
        }
        for art in ["fox-original", "01-search", "02-actions", "03-content"] { XCTAssertEqual(FunctionalIcons.art(art)?.isValid, true, art) }
    }
    func testScrollIndicatorAppearsDuringScrollAndFadesAfterIdle() {
        let scroll = ResultScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        scroll.hasVerticalScroller = true
        scroll.documentView = FlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: 1000))
        scroll.layoutSubtreeIfNeeded()
        let window = NSWindow(contentRect: scroll.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = scroll
        scroll.scrollerStyle = .legacy
        XCTAssertEqual(scroll.scrollerStyle, .overlay, "Attaching a window must not restore a permanent scrollbar gutter")
        RunLoop.main.run(until: Date().addingTimeInterval(1.05))
        XCTAssertFalse(scroll.scrollIndicatorVisible)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 180))
        XCTAssertTrue(scroll.scrollIndicatorVisible)
        XCTAssertEqual(scroll.scrollerStyle, .overlay)
        RunLoop.main.run(until: Date().addingTimeInterval(0.45))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 240))
        RunLoop.main.run(until: Date().addingTimeInterval(0.45))
        XCTAssertTrue(scroll.scrollIndicatorVisible, "Continued scrolling keeps the indicator visible")
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertFalse(scroll.scrollIndicatorVisible)
        XCTAssertEqual(scroll.verticalScroller?.alphaValue, 0)
    }
    func testQuickLookFallbackHasOneTeardownOwnerWhenWindowCloses() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FoxPreviewLifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("fixture.txt"); try "Synthetic preview".write(to: file, atomically: true, encoding: .utf8)
        try autoreleasepool {
            let store = IndexStore(scan: ScanOutput(buffers: [], count: 0, homeIndex: .max, elapsed: 0, finishedAt: 0), config: IndexConfig(rootPath: folder.path))
            let source = SearchSource(id: "fixture", displayName: "Fixture", isOnline: true, store: store)
            let item = ResultItem(detail: nil, id: 0, source: source, name: "fixture.txt", parentPath: folder.path, path: file.path, size: 17, modified: Date(), flags: 0, kind: 3)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 450), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let preview = InlinePreview(frame: window.contentView!.bounds); window.contentView = preview
            window.orderFront(nil); preview.show(item)
            let deadline = Date().addingTimeInterval(3)
            while !preview.subviews.contains(where: { $0 is QLPreviewView }) && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            let ql = try XCTUnwrap(preview.subviews.compactMap { $0 as? QLPreviewView }.first)
            XCTAssertFalse(ql.shouldCloseWithWindow)
            XCTAssertGreaterThan(ql.frame.width, 1); XCTAssertGreaterThan(ql.frame.height, 1)
            preview.clear(); window.close()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    func testNativePDFPreviewLoadsAndClearingSelectionRejectsLateWork() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FoxPreview-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("fixture.pdf")
        let image = NSImage(size: NSSize(width: 100, height: 140), flipped: false) { rect in NSColor.white.setFill(); rect.fill(); return true }
        let document = PDFDocument(); document.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        XCTAssertTrue(document.write(to: file))
        let store = IndexStore(scan: ScanOutput(buffers: [], count: 0, homeIndex: .max, elapsed: 0, finishedAt: 0), config: IndexConfig(rootPath: folder.path))
        let source = SearchSource(id: "fixture", displayName: "Fixture", isOnline: true, store: store)
        let item = ResultItem(detail: nil, id: 0, source: source, name: "fixture.pdf", parentPath: folder.path, path: file.path, size: 100, modified: Date(), flags: 0, kind: 3)
        let preview = InlinePreview(frame: NSRect(x: 0, y: 0, width: 400, height: 450))
        preview.show(item)
        let deadline = Date().addingTimeInterval(3)
        while preview.loadedPDFPath == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(preview.loadedPDFPath, file.path)
        preview.clear(); XCTAssertNil(preview.loadedPDFPath)
        preview.show(item); preview.clear()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertNil(preview.loadedPDFPath, "A delayed preview must not reappear after clearing the search")
    }
}
