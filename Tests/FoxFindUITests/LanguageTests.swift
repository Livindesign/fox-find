import AppKit
import XCTest
import SwiftUI
import FoxFindCore
@testable import FoxFindApp

final class LanguageTests: XCTestCase {
    func testLiteralTranslationKeysExistAndMissingCopyDoesNotCrash() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FoxFindApp")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil))
        let expression = try NSRegularExpression(pattern: #"(?:L10n\.text|\btext)\("([^"]+)"\s*[,)]"#)
        for case let file as URL in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let key = (source as NSString).substring(with: match.range(at: 1))
                XCTAssertTrue(L10n.hasTranslation(for: key), "\(file.lastPathComponent): \(key)")
            }
        }
        let original = L10n.snapshotChinese; defer { L10n.snapshotChinese = original }
        for chinese in [true, false] {
            L10n.snapshotChinese = chinese
            XCTAssertEqual(L10n.text("action.retry"), chinese ? "重试" : "Retry")
            XCTAssertEqual(L10n.text("test.missing.key", "ignored"), chinese ? "暂不可用" : "Unavailable")
        }
    }

    func testFailedConversationSyncSettingsCanRenderAndRetry() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoxTopicRecovery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appendingPathComponent("cache")
        try Data("not a directory".utf8).write(to: blocker)
        let preferences = defaults(); preferences.set(true, forKey: "aiTopicsEnabled")
        let manager = AITopicManager(defaults: preferences, url: blocker.appendingPathComponent("index.sqlite"),
            locations: .init(home: root), importGate: AITopicImportGate(quietInterval: 0),
            detectProviders: { [.codex] })
        defer { manager.stop() }
        manager.start(); manager.requestRefresh(immediate: true)
        func wait(_ condition: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(5)
            while !condition(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            return condition()
        }
        XCTAssertTrue(wait { manager.failed && !manager.indexing })
        let original = L10n.snapshotChinese; defer { L10n.snapshotChinese = original }
        for chinese in [true, false] {
            L10n.snapshotChinese = chinese
            let host = NSHostingView(rootView: AITopicSettings(manager: manager))
            host.frame = NSRect(x: 0, y: 0, width: 500, height: 600)
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.height, 0)
        }
        try FileManager.default.removeItem(at: blocker)
        manager.requestRefresh(immediate: true)
        XCTAssertTrue(wait { !manager.failed && !manager.indexing })
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.url.path))
    }

    private func defaults() -> UserDefaults {
        let name = "FoxFindLanguageTests-\(UUID().uuidString)"
        let result = UserDefaults(suiteName: name)!
        addTeardownBlock { result.removePersistentDomain(forName: name) }
        return result
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func settle(_ window: NSWindow) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func testDefaultAndExplicitLanguagesResolveIndependentlyOfSystem() {
        let store = defaults()
        XCTAssertEqual(AppLanguage.load(from: store), .system)
        store.set("unsupported", forKey: AppLanguage.preferenceKey)
        XCTAssertEqual(AppLanguage.load(from: store), .system)
        XCTAssertTrue(AppLanguage.system.usesChinese(systemLanguages: ["zh-Hans", "en"]))
        XCTAssertTrue(AppLanguage.system.usesChinese(systemLanguages: ["zh-Hant"]))
        XCTAssertFalse(AppLanguage.system.usesChinese(systemLanguages: ["en", "zh-Hans"]))
        XCTAssertFalse(AppLanguage.system.usesChinese(systemLanguages: []))
        XCTAssertTrue(AppLanguage.chinese.usesChinese(systemLanguages: ["en"]))
        XCTAssertFalse(AppLanguage.english.usesChinese(systemLanguages: ["zh-Hans"]))
    }

    func testSettingsPickerPersistsAndUpdatesAnExistingWindow() throws {
        _ = NSApplication.shared
        let store = defaults(), original = L10n.language, snapshot = L10n.snapshotChinese
        L10n.snapshotChinese = nil
        defer { L10n.setLanguage(original, in: store); L10n.snapshotChinese = snapshot }
        L10n.setLanguage(.chinese, in: store)
        let model = SettingsModel(snapshot: true, languageDefaults: store)
        let controller = SettingsWindowController(model: model)
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        settle(window)
        let view = try XCTUnwrap(window.contentView)
        let picker = try XCTUnwrap(descendants(view).compactMap { $0 as? NSPopUpButton }.first {
            $0.itemTitles.contains("English")
        })
        let menu = try XCTUnwrap(picker.menu)
        let english = try XCTUnwrap(menu.items.firstIndex { $0.title == "English" })
        menu.performActionForItem(at: english)
        settle(window)
        XCTAssertEqual(model.language, .english)
        XCTAssertEqual(AppLanguage.load(from: store), .english)
        XCTAssertEqual(window.title, "Fox Find Settings")
        XCTAssertTrue(picker.itemTitles.contains("Follow System"))
        model.setLanguage(.system)
        XCTAssertEqual(AppLanguage.load(from: store), .system)
        XCTAssertEqual(L10n.chinese, AppLanguage.system.usesChinese())
    }

    func testSwitchUpdatesExistingSearchViewsAndKeepsQueryFilterSelectionAndScroll() throws {
        _ = NSApplication.shared
        let preferences = defaults(), original = L10n.language, snapshot = L10n.snapshotChinese
        L10n.snapshotChinese = nil
        defer { L10n.setLanguage(original, in: preferences); L10n.snapshotChinese = snapshot }
        L10n.setLanguage(.chinese, in: preferences)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoxFindLanguage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<30 { try Data().write(to: root.appendingPathComponent("row\(index).txt")) }
        let config = IndexConfig(rootPath: root.path)
        let index = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        let search = SearchViewController(snapshot: true, preferences: preferences)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Theme.panelSize), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = search
        defer { window.close() }
        try search.prepareSnapshot(state: "results", query: "row", options: .init(sort: .name), store: index, selection: 10)
        search.view.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(search.results.subviews.compactMap { $0 as? NSScrollView }.first)
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 200)); scroll.reflectScrolledClipView(scroll.contentView)
        let selection = search.results.selectedID, origin = scroll.contentView.bounds.origin
        search.filters.options.kind = 3
        search.toggleSyntax(true)
        L10n.setLanguage(.english, in: preferences)
        search.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(search.searchField.text, "row")
        XCTAssertEqual(search.filters.options.kind, 3)
        XCTAssertEqual(search.filters.options.sort, .name)
        XCTAssertEqual(search.results.selectedID, selection)
        XCTAssertEqual(scroll.contentView.bounds.origin, origin)
        XCTAssertEqual(table.numberOfRows, 30)
        XCTAssertTrue(search.syntaxVisible)
        XCTAssertEqual(search.searchField.input.placeholderAttributedString?.string, "Search files, folders and apps")
        XCTAssertTrue(descendants(search.filters).compactMap { $0 as? NSButton }.contains { $0.title == "Documents" })
        XCTAssertTrue(descendants(search.syntax).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Pinyin initials, finds 文档" })
        XCTAssertTrue(search.footer.text.contains("items"))
        L10n.setLanguage(.chinese, in: preferences)
        XCTAssertEqual(search.searchField.text, "row")
    }

    func testSearchAndUpdateWindowChangeLanguageWithoutRestrictingSearch() throws {
        _ = NSApplication.shared
        let store = defaults(), original = L10n.language, snapshot = L10n.snapshotChinese
        L10n.snapshotChinese = nil
        defer { L10n.setLanguage(original, in: store); L10n.snapshotChinese = snapshot }
        L10n.setLanguage(.chinese, in: store)
        let search = SearchViewController(snapshot: true)
        _ = search.view
        let update = UpdateManager(snapshot: true)
        update.prepareSnapshot(.latest, manifest: nil)
        let controller = UpdateWindowController(model: update)
        defer { controller.window?.close() }
        L10n.setLanguage(.english, in: store)
        XCTAssertTrue(search.searchField.input.isEnabled)
        XCTAssertEqual(search.searchField.input.placeholderAttributedString?.string, "Search files, folders and apps")
        XCTAssertFalse(descendants(search.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue.localizedCaseInsensitiveContains("license") })
        XCTAssertEqual(controller.window?.title, "Check for Updates…")
        XCTAssertEqual(update.state, .latest)
    }


}
