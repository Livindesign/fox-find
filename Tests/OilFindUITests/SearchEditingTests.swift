import AppKit
import XCTest
import OilFindCore
@testable import OilFindApp

final class SearchEditingTests: XCTestCase {
    func testRepeatedFocusAndViewSwitchPreserveInsertionPoint() throws {
        _ = NSApplication.shared
        let suite = "FoxFocus-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let panel = SearchPanel(snapshot: true, preferences: defaults)
        defer { panel.close() }
        panel.contentView?.layoutSubtreeIfNeeded()
        let c = panel.searchController, field = c.searchField
        field.text = "PDF 包装方案"; field.focus()
        let editor = try XCTUnwrap(field.input.currentEditor() as? SearchEditor)
        editor.setSelectedRange(NSRange(location: 4, length: 2))
        for i in 0..<10 {
            field.focus(); c.setGridMode(i % 2 == 0)
            XCTAssertTrue(panel.firstResponder === editor)
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 4, length: 2))
        }
        if #available(macOS 15.0, *) { XCTAssertEqual(editor.writingToolsBehavior, .none) }
        field.focus(selectAll: true)
        XCTAssertEqual(editor.selectedRange().length, field.text.utf16.count)
    }
    private func event(_ character: String, code: UInt16, in window: NSWindow,
                       modifiers: NSEvent.ModifierFlags = .command) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                        characters: character, charactersIgnoringModifiers: character,
                        isARepeat: false, keyCode: code)!
    }

    func testTextEditingShortcutsWorkWithoutAnApplicationMenu() throws {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        defer { pasteboard.clearContents(); pasteboard.writeObjects(saved) }
        pasteboard.clearContents(); pasteboard.setString("unchanged", forType: .string)
        let panel = SearchPanel(snapshot: true)
        defer { panel.close() }
        let field = panel.searchController.searchField
        panel.contentView?.layoutSubtreeIfNeeded()
        field.text = "自媒体 html"
        field.focus()
        let editor = try XCTUnwrap(field.input.currentEditor() as? SearchEditor)
        XCTAssertTrue(panel.firstResponder === editor)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))

        // This headless fixture is not a key window. Test text commands at the
        // controller boundary; inactive-window routing has a separate regression.
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertFalse(panel.performKeyEquivalent(with: event("a", code: 0, in: panel)))
        XCTAssertTrue(panel.searchController.handleKey(event("a", code: 0, in: panel)))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: editor.string.utf16.count))
        XCTAssertTrue(panel.searchController.handleKey(event("c", code: 8, in: panel)))
        XCTAssertEqual(pasteboard.string(forType: .string), "自媒体 html")

        pasteboard.clearContents(); pasteboard.setString("新查询", forType: .string)
        XCTAssertTrue(panel.searchController.handleKey(event("v", code: 9, in: panel)))
        XCTAssertEqual(field.text, "新查询")
        editor.setSelectedRange(NSRange(location: 0, length: 1))
        XCTAssertTrue(panel.searchController.handleKey(event("x", code: 7, in: panel)))
        XCTAssertEqual(pasteboard.string(forType: .string), "新")
        XCTAssertEqual(field.text, "查询")

        XCTAssertFalse(panel.searchController.handleKey(event("a", code: 0, in: panel, modifiers: .control)))
        XCTAssertFalse(panel.searchController.handleKey(event("a", code: 0, in: panel, modifiers: [.command, .control])))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OilFindEditing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("自媒体教程.html")
        try Data().write(to: file)
        let config = IndexConfig(rootPath: root.path, indexSystemDirs: true)
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        try panel.searchController.prepareSnapshot(state: "results", query: "html", options: .init(), store: store, selection: 0)
        field.focus()
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        XCTAssertTrue(panel.searchController.handleKey(event("c", code: 8, in: panel)))
        XCTAssertEqual(pasteboard.string(forType: .string), file.path)
        XCTAssertNotNil(pasteboard.string(forType: .fileURL))
        editor.setSelectedRange(NSRange(location: 0, length: 4))
        XCTAssertTrue(panel.searchController.handleKey(event("c", code: 8, in: panel, modifiers: [.command, .option])))
        XCTAssertEqual(pasteboard.string(forType: .string), file.lastPathComponent)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 4))
    }
}
