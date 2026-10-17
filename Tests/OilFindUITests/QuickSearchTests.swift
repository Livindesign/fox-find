import AppKit
import XCTest
import OilFindCore
@testable import OilFindApp

final class QuickSearchTests: XCTestCase {
    private let safari = LauncherApplication(path: "/Applications/Safari.app", name: "Safari", bundleID: "com.apple.Safari", aliases: ["浏览器"])
    private func controller() -> SearchViewController {
        _ = NSApplication.shared
        let suite = "FoxQuickTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let c = SearchViewController(snapshot: true, preferences: defaults); _ = c.view
        c.applicationCatalog.replace([safari])
        return c
    }
    private func key(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }
    func testArithmeticPrecedenceFunctionsAndFormatting() {
        for (input, expected) in [("128*3", "384"), ("(12+8)*3", "60"), ("2^3^2", "512"), ("-2^2", "-4"), ("2^-2", "0.25"), ("0.1+0.2", "0.3"), ("200*15%", "30"), ("15% of 85", "12.75"), ("sqrt(144)", "12"), ("√144", "12"), ("sin(pi/2)", "1"), ("log(1000)", "3"), ("1e3/4", "250"), ("=42", "42"), ("1−2", "-1")] {
            XCTAssertEqual(QuickCalculator.evaluate(input)?.value, expected, input)
        }
    }
    func testUnitsAndDimensions() {
        for (input, output) in [("10 cm to in", "3.93700787402 in"), ("32F to C", "0 °C"), ("100摄氏度转华氏度", "212 °F"), ("2公斤转斤", "4 斤"), ("2 h in min", "120 min"), ("1 GiB to MB", "1073.741824 MB"), ("1GB to MB", "1000 MB")] {
            XCTAssertEqual(QuickCalculator.evaluate(input)?.output, output, input)
        }
        XCTAssertEqual(QuickCalculator.evaluate("1 kg to m")?.errorKey, "quick.unitMismatch")
        XCTAssertEqual(QuickCalculator.evaluate("-274C to K")?.errorKey, "quick.domain")
        XCTAssertEqual(QuickCalculator.evaluate("1e-12 mm to m")?.output, "1e-15 m")
    }
    func testInvalidMathAndFileQueriesStaySafe() {
        XCTAssertEqual(QuickCalculator.evaluate("1/0")?.errorKey, "quick.divideZero")
        XCTAssertEqual(QuickCalculator.evaluate("sqrt(-1)")?.errorKey, "quick.domain")
        XCTAssertEqual(QuickCalculator.evaluate("10^1000")?.errorKey, "quick.domain")
        XCTAssertEqual(QuickCalculator.evaluate("=1+")?.errorKey, "quick.incomplete")
        for query in ["", "42", "2026-10-14", "2026/10/14", "readme.md", "*.jpg", "ext:png", "/Users/test", "1+", "Math.sqrt(4)", "sin", "C++", "1;exit", "pi.txt", String(repeating: "(", count: 1000)] {
            XCTAssertNil(QuickCalculator.evaluate(query), query)
        }
        XCTAssertNil(QuickCalculator.evaluate(String(repeating: "(", count: 100) + "1" + String(repeating: ")", count: 100)))
    }
    func testApplicationNamesAliasesPinyinRankingAndNoQueryIO() {
        let catalog = ApplicationCatalog()
        catalog.replace([.init(path: "/Applications/Safari Technology Preview.app", name: "Safari Technology Preview", bundleID: "preview"), safari])
        XCTAssertEqual(catalog.matches("Safari").first, safari)
        XCTAssertEqual(catalog.matches("SAF").count, 2)
        XCTAssertEqual(catalog.matches("浏览器").first, safari)
        XCTAssertEqual(catalog.matches("liulanqi").first, safari)
        XCTAssertEqual(catalog.matches("llq").first, safari)
        XCTAssertTrue(catalog.matches("*.app").isEmpty)
        XCTAssertTrue(catalog.matches("").isEmpty)
    }
    func testAppDiscoveryStopsAtBundlesAndSkipsBackgroundOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func bundle(_ relative: String, background: Bool = false, menu: Bool = false) throws {
            let app = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundlePackageType": "APPL", "CFBundleName": "Browser", "CFBundleIdentifier": relative, "CFBundleExecutable": "run", "LSBackgroundOnly": background, "LSUIElement": menu]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
            let executable = app.appendingPathComponent("Contents/MacOS/run")
            try Data().write(to: executable); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        try bundle("Real.app"); try bundle("Real.app/Contents/Helpers/Hidden.app"); try bundle("Daemon.app", background: true)
        try bundle("Folder/Menu.app", menu: true)
        let resources = root.appendingPathComponent("Real.app/Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["zh_CN": ["CFBundleDisplayName": "浏览器"]], format: .binary, options: 0).write(to: resources.appendingPathComponent("InfoPlist.loctable"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Alias.app"), withDestinationURL: root.appendingPathComponent("Real.app"))
        let apps = ApplicationCatalog.discover(roots: [root])
        XCTAssertEqual(apps.count, 2)
        XCTAssertTrue(apps.contains { $0.path.hasSuffix("Menu.app") })
        XCTAssertEqual(apps.filter { $0.searchNames.contains("浏览器") }.count, 1)
        XCTAssertTrue(apps.contains { $0.searchNames.contains("liulanqi") })
    }
    func testCalculatorWithoutFileIndexCopiesAndClears() throws {
        let c = controller(), pasteboard = NSPasteboard.withUniqueName(); c.resultPasteboard = pasteboard
        defer { pasteboard.releaseGlobally() }
        c.searchField.text = "128*3"; c.startSearch()
        XCTAssertEqual(c.quickResults.items.count, 1); XCTAssertEqual(c.quickResults.selectedIndex, 0)
        XCTAssertEqual(c.footer.context, .calculation); XCTAssertNil(c.results.result)
        XCTAssertTrue(c.handleKey(key(36, "\r")))
        XCTAssertEqual(pasteboard.string(forType: .string), "384")
        c.searchField.text = "1/0"; c.startSearch(); c.handleKey(key(36, "\r"))
        XCTAssertEqual(pasteboard.string(forType: .string), "384")
        c.searchField.clear.performClick(nil)
        XCTAssertTrue(c.quickResults.items.isEmpty); XCTAssertNil(c.quickResults.selectedIndex)
        XCTAssertEqual(c.footer.context, .files); XCTAssertFalse(c.footer.actionable)
        c.applicationCatalog.replace([safari]); c.panelWillShow()
        XCTAssertTrue(c.quickResults.items.isEmpty)
    }
    func testApplicationLaunchWithoutFileIndexAndFailure() {
        let c = controller(); var opened: URL?, hidden = false
        c.launchApplication = { url, completion in opened = url; completion(true) }
        c.hidePanel = { hidden = true }
        c.searchField.text = "saf"; c.startSearch()
        XCTAssertEqual(c.quickResults.items, [.application(safari)])
        c.handleKey(key(36, "\r")); XCTAssertEqual(opened?.path, safari.path); XCTAssertTrue(hidden)
        c.launchApplication = { _, completion in completion(false) }; hidden = false
        c.handleKey(key(36, "\r")); XCTAssertFalse(hidden); XCTAssertTrue(c.footer.warning)
        XCTAssertEqual(c.footer.text, L10n.text("quick.failed"))
    }
    func testQuickAnswersRespectContentScopeAndCategory() {
        let c = controller(); c.searchField.text = "128*3"
        c.toolsBar.mode = .contents; c.startSearch(); XCTAssertTrue(c.quickResults.items.isEmpty)
        c.toolsBar.mode = .combined; c.toolsBar.folder = "/Applications"; c.startSearch(); XCTAssertTrue(c.quickResults.items.isEmpty)
        c.toolsBar.folder = nil; c.filters.options.kind = 4; c.startSearch(); XCTAssertTrue(c.quickResults.items.isEmpty)
        c.filters.options.kind = nil; c.startSearch(); XCTAssertEqual(c.quickResults.items.count, 1)
        c.toolsBar.refinement = AssetRefinement(media: .landscape, tag: ""); c.startSearch(); XCTAssertTrue(c.quickResults.items.isEmpty)
    }
    func testQuickPanelLayoutInBothLanguagesAndThemes() {
        defer { L10n.snapshotChinese = nil }
        for chinese in [true, false] { for width: CGFloat in [720, 800, 900] { for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            L10n.snapshotChinese = chinese
            let c = controller(); c.view.frame = NSRect(x: 0, y: 0, width: width, height: 600); c.view.appearance = NSAppearance(named: appearance)
            for query in ["safari", "(12345+6789)*1000", "32F to C", "1/0"] {
                c.searchField.text = query; c.startSearch(); c.view.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(c.quickResults.frame.maxY, c.footer.frame.minY)
                XCTAssertGreaterThanOrEqual(c.results.frame.minY, c.quickResults.frame.maxY)
                XCTAssertFalse(c.quickResults.isHidden)
                c.toggleSyntax(true); XCTAssertTrue(c.quickResults.isHidden)
                c.toggleSyntax(false); XCTAssertFalse(c.quickResults.isHidden)
            }
        } } }
    }
    func testKeyboardMovesBetweenAppsAndFilesAndClearRemovesBoth() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("Safari-notes.txt"))
        let config = IndexConfig(rootPath: root.path)
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        for grid in [false, true] {
            let c = controller(); c.setGridMode(grid)
            c.additionalSources = { [.init(id: "fixture", displayName: "", isOnline: true, store: store)] }
            c.searchField.text = "Safari"; c.startSearch()
            let deadline = Date().addingTimeInterval(2)
            while c.results.result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
            XCTAssertEqual(c.results.result?.count, 1); XCTAssertNil(c.results.selectedItem)
            XCTAssertEqual(c.quickResults.selectedIndex, 0)
            c.handleKey(key(125, "\u{f701}"))
            XCTAssertNil(c.quickResults.selectedIndex); XCTAssertEqual(c.results.selectedItem?.name, "Safari-notes.txt")
            XCTAssertEqual(c.footer.context, .files)
            c.handleKey(key(126, "\u{f700}"))
            XCTAssertEqual(c.quickResults.selectedIndex, 0); XCTAssertNil(c.results.selectedItem)
            c.results.onPointerSelection?(); c.results.select(0)
            XCTAssertNil(c.quickResults.selectedIndex); XCTAssertNotNil(c.results.selectedItem)
            c.applicationCatalog.replace([safari])
            XCTAssertNil(c.quickResults.selectedIndex, "A catalog refresh must not steal a file selection")
            c.searchField.clear.performClick(nil); c.sourcesChanged()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            XCTAssertNil(c.results.result); XCTAssertTrue(c.quickResults.items.isEmpty)
        }
    }
    func testQuickSearchPerformanceBudget() {
        let catalog = ApplicationCatalog()
        catalog.replace((0..<500).map { .init(path: "/Applications/Application\($0).app", name: "Application \($0)", bundleID: "test.\($0)") })
        var samples: [Double] = []
        for i in 0..<500 {
            let start = CFAbsoluteTimeGetCurrent()
            _ = catalog.matches("Application \(i)")
            _ = QuickCalculator.evaluate("(128+72)*15%")
            samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        samples.sort()
        print("FOX_QUICK_PERF cached_apps=500 samples=500 p95_ms=\(samples[475])")
        XCTAssertLessThan(samples[475], 10, "Cached application matching and calculation must fit the input frame budget")
    }
}
