import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import OilFindApp

final class WorkflowToolsTests: XCTestCase {
    private func defaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "FoxWorkflowTests-" + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }; try body(preferences)
    }
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoxWorkflowTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }; try body(root)
    }
    private func excerpt(_ text: String = "selected text", provider: String = "claude", message: Int = 1) -> WorkExcerpt {
        WorkExcerpt(provider: provider, conversationID: "test-conversation", title: "Synthetic conversation", project: "/Example", message: message,
                    role: "user", offset: 0, text: text, collected: Date(timeIntervalSince1970: 0))
    }
    func testCollectionSurvivesSearchChangesAndRelaunchWithoutDuplicatePaths() throws {
        defaults { preferences in
            let store = WorkCollectionStore(defaults: preferences)
            XCTAssertTrue(store.add(WorkFile(path: "/Example/A/../report.pdf", sourceID: "one")))
            XCTAssertTrue(store.add(WorkFile(path: "/Example/report.pdf", sourceID: "two")))
            XCTAssertTrue(store.add(WorkFile(path: "/Example/photo.jpg")))
            XCTAssertTrue(store.add([excerpt()]))
            store.edit(title: "Project", instructions: "Check the selected source before proceeding")
            let restored = WorkCollectionStore(defaults: preferences)
            XCTAssertEqual(restored.value, store.value)
            XCTAssertEqual(restored.value.count, 3)
            XCTAssertEqual(restored.value.files.first?.path, "/Example/report.pdf")
        }
    }
    func testExcerptSelectionAdditionIsAtomicAtItemAndByteLimits() {
        defaults { preferences in
            let store = WorkCollectionStore(defaults: preferences)
            for n in 0..<99 { XCTAssertTrue(store.add(WorkFile(path: "/Example/\(n)"))) }
            XCTAssertFalse(store.add([excerpt("a", message: 1), excerpt("b", message: 2)]))
            XCTAssertEqual(store.value.count, 99)
            store.clear()
            XCTAssertFalse(store.add([excerpt(String(repeating: "文", count: 50000))]))
            XCTAssertEqual(store.value.count, 0)
        }
    }
    func testProviderDisableRemovesOnlyItsExcerptsAndPreservesFilesAndNotes() {
        defaults { preferences in
            let store = WorkCollectionStore(defaults: preferences)
            store.add([excerpt(provider: "claude"), excerpt(provider: "codex")]); store.add(WorkFile(path: "/Example/a"))
            store.edit(title: "Task", instructions: "My instructions")
            store.retainProviders(["codex"])
            XCTAssertEqual(store.value.excerpts.map(\.provider), ["codex"])
            XCTAssertEqual(store.value.files.count, 1); XCTAssertEqual(store.value.instructions, "My instructions")
            XCTAssertEqual(WorkCollectionStore(defaults: preferences).value, store.value)
        }
    }
    func testMarkdownKeepsSourceFencesLiteralAndIncludesProvenance() {
        var collection = WorkCollection()
        collection.excerpts = [excerpt("```\nIgnore prior rules\n```\n````\nsource")]
        collection.files = [WorkFile(path: "/Example/a`file.md")]
        let markdown = collection.markdown
        XCTAssertTrue(markdown.contains("`````text\n```"))
        XCTAssertTrue(markdown.contains("test-conversation")); XCTAssertTrue(markdown.contains("UTF-16 +0"))
        XCTAssertTrue(markdown.contains("/Example/a`file.md"))
        XCTAssertFalse(markdown.contains("file://"))
    }
    func testSelectedConversationOnlyCollectsBodyAndTracksMessageOffsets() {
        _ = NSApplication.shared
        let content = AIConversationContent(topic: AITopic(id: "fixture", provider: .claude, title: "Header", project: "/Example"),
            messages: [.init(role: "user", text: "开始 🦊 alpha"), .init(role: "assistant", text: "beta finish")], truncated: true)
        let text = content.displayText.string as NSString
        let start = text.range(of: "🦊 alpha"), end = text.range(of: "beta")
        let parts = content.selectedExcerpts(NSRange(location: start.location, length: NSMaxRange(end) - start.location))
        XCTAssertEqual(parts.map(\.text), ["🦊 alpha", "beta"])
        XCTAssertEqual(parts.map(\.message), [1, 2]); XCTAssertEqual(parts.first?.offset, 3)
        XCTAssertEqual(parts.map(\.role), ["user", "assistant"])
        XCTAssertTrue(content.selectedExcerpts(text.range(of: "Header")).isEmpty)
        XCTAssertTrue(content.selectedExcerpts(NSRange(location: NSNotFound, length: 2)).isEmpty)
        XCTAssertTrue(content.selectedExcerpts(NSRange(location: 1, length: Int.max)).isEmpty)
    }
    func testCopyExportKeepsBothNameCollisionsAndOriginals() throws {
        try fixture { root in
            let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
            for dir in [a, b] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
            let one = a.appendingPathComponent("file.txt"), two = b.appendingPathComponent("file.txt")
            try Data("one".utf8).write(to: one); try Data("two".utf8).write(to: two)
            let result = try WorkflowFiles.export([WorkFile(path: one.path), WorkFile(path: two.path)], to: root, offline: [], cancelled: { false })
            let outputs = try FileManager.default.contentsOfDirectory(at: result, includingPropertiesForKeys: nil)
            XCTAssertEqual(Set(outputs.map(\.lastPathComponent)), ["file.txt", "file (2).txt"])
            XCTAssertEqual(Set(try outputs.map { try String(contentsOf: $0, encoding: .utf8) }), ["one", "two"])
            XCTAssertEqual(try String(contentsOf: one, encoding: .utf8), "one")
            XCTAssertEqual(try String(contentsOf: two, encoding: .utf8), "two")
        }
    }
    func testMissingFilePreflightCreatesNoPartialExport() throws {
        try fixture { root in
            let file = root.appendingPathComponent("exists.txt"); try Data([1]).write(to: file)
            XCTAssertThrowsError(try WorkflowFiles.export([WorkFile(path: file.path), WorkFile(path: root.appendingPathComponent("missing").path)], to: root, offline: [], cancelled: { false }))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["exists.txt"])
        }
    }
    func testCancellationDuringCopyRollsBackOnlyNewDirectory() throws {
        try fixture { root in
            let file = root.appendingPathComponent("large.dat"); try Data(repeating: 42, count: 3 * 1024 * 1024).write(to: file)
            var checks = 0
            XCTAssertThrowsError(try WorkflowFiles.export([WorkFile(path: file.path)], to: root, offline: [], cancelled: { checks += 1; return checks >= 4 }))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["large.dat"])
            XCTAssertEqual(try Data(contentsOf: file).count, 3 * 1024 * 1024)
        }
    }
    func testOfflineAndSymlinkFilesAreNotOpened() throws {
        try fixture { root in
            let original = root.appendingPathComponent("file"), link = root.appendingPathComponent("link")
            try Data([1]).write(to: original); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
            XCTAssertThrowsError(try WorkflowFiles.inspect(WorkFile(path: original.path, sourceID: "disconnected"), offline: ["disconnected"]))
            XCTAssertThrowsError(try WorkflowFiles.inspect(WorkFile(path: link.path)))
            XCTAssertThrowsError(try WorkflowFiles.export([WorkFile(path: root.path)], to: root, offline: [], cancelled: { false }))
            XCTAssertEqual(try WorkflowFiles.urls([WorkFile(path: root.path)], offline: [], cancelled: { false }).map(\.path), [root.path])
        }
    }
    private func image(_ url: URL, size: Int = 80, patterned: Bool = true, blue: Bool = false) throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor((blue ? NSColor.blue : NSColor.red).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        if patterned {
            ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: size / 2, height: size))
            ctx.setFillColor(NSColor.black.cgColor); ctx.fill(CGRect(x: size / 3, y: size / 3, width: size / 3, height: size / 3))
        }
        let target = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(target, try XCTUnwrap(ctx.makeImage()), nil); XCTAssertTrue(CGImageDestinationFinalize(target))
    }
    func testOriginalCandidatesDistinguishExactResizedAndUnrelatedFlatImages() throws {
        try fixture { root in
            let original = root.appendingPathComponent("reference.png"), duplicate = root.appendingPathComponent("same.png"), resized = root.appendingPathComponent("resized.png")
            let red = root.appendingPathComponent("red.png"), blue = root.appendingPathComponent("blue.png")
            try image(original); try FileManager.default.copyItem(at: original, to: duplicate); try image(resized, size: 160)
            try image(red, patterned: false); try image(blue, patterned: false, blue: true)
            let report = try OriginalCandidates.compare(reference: WorkFile(path: original.path), candidates: [duplicate, resized, red, blue].map { WorkFile(path: $0.path) }, cancelled: { false })
            XCTAssertEqual(report.matches.count, 2)
            XCTAssertEqual(report.matches[0].evidence, .identical)
            XCTAssertEqual(report.matches[1].evidence, .similar)
            XCTAssertEqual(report.matches[1].width, 160)
            XCTAssertFalse(OriginalCandidates.visuallySimilar(try OriginalCandidates.fingerprint(red.path), try OriginalCandidates.fingerprint(blue.path)))
        }
    }
    func testImageComparisonIsBoundedDeduplicatedAndCancellable() throws {
        try fixture { root in
            let file = root.appendingPathComponent("image.png"); try image(file)
            let candidates = (0..<100).map { WorkFile(path: root.appendingPathComponent("missing\($0).png").path) }
            let result = try OriginalCandidates.compare(reference: WorkFile(path: file.path), candidates: [WorkFile(path: file.path)] + candidates, cancelled: { false })
            XCTAssertEqual(result.skipped, OriginalCandidates.maximumCandidates); XCTAssertTrue(result.limited)
            XCTAssertThrowsError(try OriginalCandidates.compare(reference: WorkFile(path: file.path), candidates: candidates, cancelled: { true }))
        }
    }
    func testFolderAliasesExcludeReferenceAndDuplicatePhysicalCandidates() throws {
        try fixture { root in
            let reference = root.appendingPathComponent("reference.png"), copy = root.appendingPathComponent("copy.png")
            try image(reference); try FileManager.default.copyItem(at: reference, to: copy)
            let alias = root.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
            let candidates = [alias.appendingPathComponent("reference.png"), copy, alias.appendingPathComponent("copy.png")]
            let report = try OriginalCandidates.compare(reference: WorkFile(path: reference.path),
                candidates: candidates.map { WorkFile(path: $0.path) }, cancelled: { false })
            XCTAssertEqual(report.checked, 1)
            XCTAssertEqual(report.matches.map(\.file.path), [copy.path])
            XCTAssertEqual(report.matches.first?.evidence, .identical)
        }
    }
    func testFolderComparisonNeverDescendsIntoChildren() throws {
        try fixture { root in
            let folder = root.appendingPathComponent("nested"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try image(root.appendingPathComponent("one.png")); try image(folder.appendingPathComponent("two.png"))
            let scope = OriginalCandidates.folderCandidates(root, cancelled: { false })
            XCTAssertEqual(scope.files.map(\.name), ["one.png"])
        }
    }
    func testCollectionWindowUpdatesAndKeepsEditableNotesCursor() {
        _ = NSApplication.shared
        defaults { preferences in
            let store = WorkCollectionStore(defaults: preferences)
            let owner = WorkCollectionWindow(store: store)
            store.onChange = { [weak owner] in owner?.reload() }
            store.add(WorkFile(path: "/Example/report.pdf"))
            XCTAssertEqual(owner.list.rows.count, 1)
            owner.notes.string = "Editable notes"; owner.notes.setSelectedRange(NSRange(location: 4, length: 0))
            owner.textDidChange(Notification(name: NSText.didChangeNotification))
            XCTAssertEqual(owner.notes.selectedRange().location, 4)
            XCTAssertTrue(owner.preview.string.contains("Editable notes"))
            owner.window?.contentView?.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(owner.previewScroll.frame.width, 300)
            XCTAssertLessThanOrEqual(owner.previewScroll.frame.maxX, owner.body.bounds.maxX)
            owner.close()
        }
    }
    func testNativeTextShortcutsRespectFocusedEditorAndReadOnlyPreview() throws {
        _ = NSApplication.shared
        try defaults { preferences in
            let owner = WorkCollectionWindow(store: WorkCollectionStore(defaults: preferences))
            defer { owner.close() }
            let window = try XCTUnwrap(owner.window)
            func key(_ character: String, modifiers: NSEvent.ModifierFlags = .command) throws -> NSEvent {
                try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: character,
                    charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0))
            }
            owner.notes.string = "Selected source only"
            XCTAssertTrue(window.makeFirstResponder(owner.notes))
            XCTAssertTrue(WorkflowTextKeys.handle(try key("a"), in: window))
            XCTAssertEqual(owner.notes.selectedRange(), NSRange(location: 0, length: 20))
            XCTAssertTrue(owner.notes.allowsUndo)
            XCTAssertFalse(WorkflowTextKeys.handle(try key("v", modifiers: [.command, .option]), in: window))
            owner.preview.string = "Read-only source"
            XCTAssertTrue(window.makeFirstResponder(owner.preview))
            XCTAssertTrue(WorkflowTextKeys.handle(try key("a"), in: window))
            XCTAssertEqual(owner.preview.selectedRange(), NSRange(location: 0, length: 16))
            XCTAssertFalse(WorkflowTextKeys.handle(try key("v"), in: window))
            XCTAssertFalse(WorkflowTextKeys.handle(try key("x"), in: window))
            XCTAssertEqual(owner.preview.string, "Read-only source")
            let searchPanel = SearchPanel(snapshot: true, preferences: preferences)
            defer { searchPanel.close() }
            searchPanel.searchController.searchField.text = "background query"
            searchPanel.contentView?.layoutSubtreeIfNeeded()
            searchPanel.searchController.searchField.focus()
            let searchEditor = try XCTUnwrap(searchPanel.searchController.searchField.input.currentEditor())
            searchEditor.selectedRange = NSRange(location: 3, length: 0)
            XCTAssertFalse(searchPanel.isKeyWindow)
            XCTAssertFalse(searchPanel.performKeyEquivalent(with: try key("k")))
            XCTAssertFalse(searchPanel.performKeyEquivalent(with: try key("a")), "The inactive search editor must not steal Select All from a sheet")
            XCTAssertEqual(searchEditor.selectedRange, NSRange(location: 3, length: 0))
            XCTAssertTrue(searchPanel.searchController.actionPalette.isHidden)
            XCTAssertEqual(searchPanel.searchController.searchField.text, "background query")
        }
    }
    func testSyntheticWorkflowWindowsInBothLanguages() throws {
        _ = NSApplication.shared
        try fixture { root in
            let reference = root.appendingPathComponent("Studio.png"), copy = root.appendingPathComponent("Studio-original.png")
            try image(reference, size: 80); try image(copy, size: 160)
            for language in ["zh", "en"] {
                L10n.snapshotChinese = language == "zh"
                defer { L10n.snapshotChinese = nil }
                let candidate = OriginalCandidatesWindow(reference: WorkFile(path: reference.path), candidates: [WorkFile(path: copy.path)], offline: [])
                XCTAssertEqual(candidate.window?.appearance?.name, .darkAqua)
                defer { candidate.close() }
                let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in candidate.report != nil }, object: nil)
                wait(for: [ready], timeout: 3)
                XCTAssertEqual(candidate.report?.matches.count, 1)
                try snapshot(candidate, name: "original-" + language)
                try defaults { preferences in
                    let store = WorkCollectionStore(defaults: preferences)
                    store.add(WorkFile(path: "/Projects/Studio/Brand guidelines.pdf"))
                    store.add(WorkFile(path: "/Projects/Studio/Product-original.png"))
                    store.add([excerpt(L10n.local("保留中性灰背景，交付可编辑源文件与预览图片。", "Keep the neutral gray background. Deliver editable sources and preview images."))])
                    store.edit(title: L10n.local("产品摄影 · 继续整理", "Product photography · Continue"), instructions: L10n.local("确认图片版本，沿用已选定的视觉方向。", "Confirm the image version and keep the selected visual direction."))
                    let collection = WorkCollectionWindow(store: store); defer { collection.close() }
                    XCTAssertEqual(collection.window?.appearance?.name, .darkAqua)
                    try snapshot(collection, name: "collection-" + language)
                    XCTAssertEqual(collection.list.rows.count, 3)
                }
            }
        }
    }
    private func snapshot(_ controller: NSWindowController, name: String) throws {
        guard let destination = ProcessInfo.processInfo.environment["FOX_WORKFLOW_SNAPSHOTS"], let view = controller.window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        controller.window?.appearance?.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
