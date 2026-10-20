import AppKit
import XCTest
@testable import FoxFindApp

final class AIConversationTests: XCTestCase {
    private func fixture() throws -> (URL, UserDefaults) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fox-conversation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "FoxConversation-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        return (root, defaults)
    }
    private func eventually(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let until = Date().addingTimeInterval(5)
        while !predicate() && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        XCTAssertTrue(predicate(), file: file, line: line)
    }
    func testCompressedSearchAgainstLiteralOracle() throws { try runCoreChecks(fixture().0) }
    func testSourceChangesRenamesDeletionAndRewrites() throws { try runSyncChecks(fixture().0) }
    func testClaudeGatewayDescriptorMapsTranscriptToOriginalSessionOnReturn() throws {
        _ = NSApplication.shared
        let (root, defaults) = try fixture(), locations = AITopicLocations(home: root)
        let project = locations.claude.appendingPathComponent("projects/demo")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased(), desktop = "local_" + UUID().uuidString.lowercased()
        let data = try JSONSerialization.data(withJSONObject: ["type": "user", "message": ["content": "Synthetic gateway conversation"]]) + Data([10])
        try data.write(to: project.appendingPathComponent(id + ".jsonl"))
        let folder = locations.claudeDesktop3P.appendingPathComponent("account/workspace")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor = folder.appendingPathComponent(desktop + ".json")
        try JSONSerialization.data(withJSONObject: ["sessionId": desktop, "cliSessionId": id, "title": "Gateway fixture", "lastActivityAt": 20]).write(to: descriptor)
        let url = root.appendingPathComponent("index.sqlite"), index = try AITopicIndex(url: url)
        let importer = AITopicIndexer(index: index, locations: locations)
        try importer.refresh(providers: [.claude])
        let topic = try XCTUnwrap(index.search("Synthetic gateway").topics.first)
        XCTAssertEqual(topic.desktopID, desktop); XCTAssertEqual(topic.id, id)
        XCTAssertEqual(AITopicActions.desktopURL(topic)?.absoluteString, "claude://claude.ai/epitaxy/" + desktop)
        let manager = AITopicManager(defaults: defaults, url: url, locations: locations, detectProviders: { [.claude] })
        manager.installSnapshot(url: url); defer { manager.stop() }
        let c = SearchViewController(snapshot: true, preferences: defaults); _ = c.view; c.aiTopics = manager
        c.filters.selectConversations(); c.searchField.text = "Synthetic gateway"; c.startSearch()
        eventually { c.conversations.selected != nil }
        var opened: URL?
        c.openConversationClient = { topic, done in opened = AITopicActions.desktopURL(topic); done(.dispatched) }
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        XCTAssertTrue(c.handleKey(enter)); eventually { opened != nil }
        XCTAssertEqual(opened?.absoluteString, "claude://claude.ai/epitaxy/" + desktop)
        try FileManager.default.removeItem(at: descriptor); try importer.refresh(providers: [.claude])
        XCTAssertEqual(try index.topic(topic.key)?.desktopID, "", "Removing the descriptor must revoke a stale native route")
        XCTAssertEqual(try Data(contentsOf: project.appendingPathComponent(id + ".jsonl")), data)
    }
    func testDefaultOffDoesNotCreateAnIndex() throws {
        let (root, defaults) = try fixture(), url = root.appendingPathComponent("index.sqlite")
        let manager = AITopicManager(defaults: defaults, url: url, locations: .init(home: root), detectProviders: { [.codex] })
        manager.start(); defer { manager.stop() }
        XCTAssertFalse(manager.enabled); XCTAssertFalse(manager.isEnabled)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testTranscriptPreservesCaseRoleOrderAndBoundedExtraction() throws {
        let (root, _) = try fixture(), index = try AITopicIndex(url: root.appendingPathComponent("index.sqlite"))
        var topic = AITopic(id: UUID().uuidString, provider: .codex, title: "包装讨论")
        try index.upsert(topic)
        try index.message(topic.key, key: "one", body: "Find My PDF", role: "user")
        try index.message(topic.key, key: "two", body: "文档在 /Projects/Design.pdf", role: "assistant")
        let content = try XCTUnwrap(index.transcript(topic.key))
        XCTAssertEqual(content.messages.map(\.role), ["user", "assistant"])
        XCTAssertEqual(content.messages.map(\.text), ["Find My PDF", "文档在 /Projects/Design.pdf"])
        XCTAssertFalse(content.truncated)
        let limited = try XCTUnwrap(index.transcript(topic.key, byteLimit: 12))
        XCTAssertEqual(limited.messages.count, 1); XCTAssertTrue(limited.truncated)
        XCTAssertTrue(limited.markdown.contains("Find My PDF"))
        try index.message(topic.key, key: "one", body: "Find My PDF", role: "assistant")
        XCTAssertEqual(try index.transcript(topic.key)?.messages.first?.role, "assistant")
        topic.archived = true; try index.upsert(topic)
        XCTAssertNil(try index.transcript(topic.key))
    }
    func testImporterExtractsVisibleMessagesWithoutModifyingSource() throws {
        let (root, _) = try fixture(), project = root.appendingPathComponent(".claude/projects/demo")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent(UUID().uuidString + ".jsonl")
        let rows: [[String: Any]] = [
            ["type": "user", "message": ["content": "包装设计怎么改"]],
            ["type": "assistant", "message": ["content": [["type": "text", "text": "Use a Blue box"], ["type": "thinking", "thinking": "private-thought"]]]],
            ["type": "tool", "message": ["content": "private-tool-output"]]
        ]
        let data = try rows.reduce(into: Data()) { $0.append(try JSONSerialization.data(withJSONObject: $1)); $0.append(10) }
        try data.write(to: file)
        let index = try AITopicIndex(url: root.appendingPathComponent("index.sqlite"))
        try AITopicIndexer(index: index, locations: .init(home: root)).refresh(providers: [.claude])
        let topic = try XCTUnwrap(index.search("包装").topics.first)
        let content = try XCTUnwrap(index.transcript(topic.key))
        XCTAssertEqual(content.messages.map(\.role), ["user", "assistant"])
        XCTAssertFalse(content.markdown.contains("private-")); XCTAssertTrue(content.markdown.contains("Blue"))
        XCTAssertEqual(try Data(contentsOf: file), data)
    }
    func testDisabledSourceRevokesQueuedContentAndResolve() throws {
        let (root, defaults) = try fixture(), url = root.appendingPathComponent("index.sqlite")
        let index = try AITopicIndex(url: url), topic = AITopic(id: UUID().uuidString, provider: .codex, title: "Demo")
        try index.upsert(topic); try index.message(topic.key, key: "one", body: "Visible content", role: "user")
        let manager = AITopicManager(defaults: defaults, url: url, locations: .init(home: root), detectProviders: { [.codex] })
        manager.installSnapshot(url: url); defer { manager.stop() }
        var resolved = false, extracted = false
        manager.transcript(topic.key) { result in
            if case .success = result { XCTFail("Disabled content must not be delivered") }; extracted = true
        }
        manager.resolve(topic.key) { XCTAssertNil($0); resolved = true }
        manager.setEnabled(false)
        eventually { resolved && extracted }
    }
    func testCodexImportExcludesInternalChannelsAndToolRecipients() throws {
        let (root, _) = try fixture(), sessions = root.appendingPathComponent(".codex/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let id = UUID().uuidString, file = sessions.appendingPathComponent("rollout-" + id + ".jsonl")
        func message(_ role: String, _ text: String, _ channel: String? = nil, _ recipient: String? = nil) -> [String: Any] {
            var payload: [String: Any] = ["type": "message", "role": role, "content": [["type": "output_text", "text": text]]]
            payload["channel"] = channel; payload["recipient"] = recipient
            return ["type": "response_item", "payload": payload]
        }
        let rows: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": id, "cwd": "/Projects/Fixture"]],
            message("user", "Public packaging question"),
            message("assistant", "HiddenAnalysisFixture", "analysis"),
            message("assistant", "HiddenSummaryFixture", "summary"),
            message("assistant", "ToolCommandFixture", "commentary", "functions.exec"),
            message("assistant", "Visible progress", "commentary", "all"),
            message("assistant", "Visible final answer", "final"),
            ["type": "agentMessage", "text": "HiddenOuterFixture", "channel": "analysis"],
            ["type": "agentMessage", "text": "Visible legacy answer"]
        ]
        var data = Data()
        for row in rows { data.append(try JSONSerialization.data(withJSONObject: row)); data.append(10) }
        try data.write(to: file)
        let index = try AITopicIndex(url: root.appendingPathComponent("index.sqlite"))
        try AITopicIndexer(index: index, locations: .init(home: root)).refresh(providers: [.codex])
        let content = try XCTUnwrap(index.transcript("codex:" + id))
        XCTAssertEqual(content.messages.map(\.text), ["Public packaging question", "Visible progress", "Visible final answer", "Visible legacy answer"])
        for hidden in ["HiddenAnalysisFixture", "HiddenSummaryFixture", "ToolCommandFixture", "HiddenOuterFixture"] {
            XCTAssertTrue(try index.search(hidden).topics.isEmpty)
            XCTAssertFalse(content.markdown.contains(hidden))
        }
        XCTAssertEqual(try Data(contentsOf: file), data)
    }
    func testRoutesValidateIDsAndResumeCommandEscapesProject() {
        let id = UUID().uuidString
        let topic = AITopic(id: id, provider: .codex, title: "Test", project: "/tmp/it's a $(file)")
        XCTAssertEqual(AITopicActions.desktopURL(topic)?.absoluteString, "codex://threads/" + id)
        XCTAssertTrue(topic.resumeCommand.contains("'\\''")); XCTAssertTrue(topic.resumeCommand.contains("$(file)"))
        XCTAssertNil(AITopicActions.desktopURL(.init(id: "../../bad", provider: .codex, title: "Test")))
        XCTAssertNil(AITopicActions.desktopURL(.init(id: "bad/route", provider: .workbuddy, title: "Test")))
        XCTAssertNil(AITopicActions.desktopURL(.init(id: id, provider: .claude, title: "CLI only")))
    }
    func testClientSelectionPrefersRunningAppAndRejectsHiddenBackupsAndWrongIdentity() throws {
        let (root, _) = try fixture()
        func app(_ name: String, _ id: String) throws -> URL {
            let url = root.appendingPathComponent(name + ".app"), contents = url.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundlePackageType": "APPL"], format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist")); return url
        }
        let current = try app("Current", "com.openai.codex"), other = try app("Other", "example.unrelated")
        let backup = try app(".Old", "com.openai.codex"), installed = try app("Installed", "com.openai.codex")
        XCTAssertEqual(AITopicActions.applicationURL(.codex, running: { _ in [other, backup, current] }, installed: { _ in installed }), current)
        XCTAssertEqual(AITopicActions.applicationURL(.codex, running: { _ in [] }, installed: { _ in installed }), installed)
        XCTAssertNil(AITopicActions.applicationURL(.codex, running: { _ in [other] }, installed: { _ in backup }))
    }
    func testFailedDispatchStaysVisibleAndStaleDispatchCannotCloseNewSearch() throws {
        _ = NSApplication.shared
        let (root, defaults) = try fixture(), url = root.appendingPathComponent("index.sqlite")
        let index = try AITopicIndex(url: url), topic = AITopic(id: UUID().uuidString, provider: .codex, title: "Demo")
        try index.upsert(topic)
        let manager = AITopicManager(defaults: defaults, url: url, locations: .init(home: root), detectProviders: { [.codex] })
        manager.installSnapshot(url: url); defer { manager.stop() }
        let c = SearchViewController(snapshot: true, preferences: defaults); _ = c.view; c.aiTopics = manager
        c.filters.selectConversations(); c.searchField.text = "Demo"; c.startSearch()
        eventually { c.conversations.selected != nil }
        var completions = [(AITopicActions.OpenResult) -> Void](), hides = 0
        c.openConversationClient = { _, done in completions.append(done) }
        c.hidePanel = { hides += 1 }
        let open = try XCTUnwrap(c.makeActions().first { $0.id == "topicOpen" })
        open.run(); open.run()
        eventually { completions.count == 1 }
        completions[0](.failed)
        XCTAssertEqual(hides, 0); XCTAssertTrue(c.footer.warning)
        open.run(); eventually { completions.count == 2 }
        c.searchField.text = "new search"; c.startSearch()
        completions[1](.dispatched)
        XCTAssertEqual(hides, 0, "A late launch response must not hide a newer query")
        c.searchField.text = "Demo"; c.startSearch(); eventually { c.conversations.selected != nil }
        open.run(); eventually { completions.count == 3 }
        manager.setEnabled(false); completions[2](.dispatched)
        XCTAssertEqual(hides, 0, "Disabling a source invalidates queued callbacks")
    }
    func testPreviewUsesFullWindowGlassAndExposesOriginalAndCopyActions() throws {
        _ = NSApplication.shared
        let topic = AITopic(id: UUID().uuidString, provider: .codex, title: "Synthetic preview", project: "/Projects/Demo")
        let content = AIConversationContent(topic: topic, messages: [.init(role: "user", text: "Literal <script>example</script>")], truncated: false)
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let preview = AIConversationWindow(content: content, query: "Literal", snapshot: true)
            let window = try XCTUnwrap(preview.window); defer { preview.close() }
            window.appearance = NSAppearance(named: appearance)
            XCTAssertTrue(window.styleMask.contains(.fullSizeContentView)); XCTAssertTrue(window.contentView is PanelSurface)
            XCTAssertEqual(window.titleVisibility, .hidden)
            for width in [560.0, 760.0, 1000.0] {
                window.setContentSize(NSSize(width: width, height: 600)); window.contentView?.layoutSubtreeIfNeeded()
                XCTAssertGreaterThanOrEqual(preview.scrollView.frame.minY, 44)
                XCTAssertLessThan(preview.scrollView.frame.maxY, preview.openButton.frame.minY)
                XCTAssertGreaterThan(preview.openButton.frame.minX, preview.copyButton.frame.maxX)
                XCTAssertLessThanOrEqual(preview.openButton.frame.maxX, width - 20)
            }
            XCTAssertFalse(preview.textView.isEditable); XCTAssertTrue(preview.textView.string.contains("<script>"))
            var opens = 0, copies = 0
            preview.onOpen = { opens += 1 }; preview.onCopy = { copies += 1 }
            preview.openButton.performClick(nil); preview.copyButton.performClick(nil)
            XCTAssertEqual(opens, 1); XCTAssertEqual(copies, 1)
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
            XCTAssertFalse(window.isKeyWindow)
            XCTAssertFalse(window.performKeyEquivalent(with: event), "An inactive preview must not consume another window's close shortcut")
        }
        let cli = AIConversationWindow(content: .init(topic: .init(id: UUID().uuidString, provider: .claude, title: "CLI"), messages: [], truncated: false), query: "", snapshot: true)
        defer { cli.close() }
        var resumes = 0; cli.onResume = { resumes += 1 }; cli.openButton.performClick(nil)
        XCTAssertEqual(resumes, 1); XCTAssertFalse(cli.textView.string.isEmpty)
    }
    func testLongConversationPreviewLayoutBudget() throws {
        _ = NSApplication.shared
        let topic = AITopic(id: UUID().uuidString, provider: .codex, title: "Long synthetic discussion")
        let messages = (0..<200).map { AIConversationContent.Message(role: $0 % 2 == 0 ? "user" : "assistant", text: String(repeating: "A neutral gray package with clear labels. ", count: 55)) }
        let content = AIConversationContent(topic: topic, messages: messages, truncated: true)
        var samples = [Double]()
        for _ in 0..<5 {
            let start = CFAbsoluteTimeGetCurrent()
            let preview = AIConversationWindow(content: content, query: "", snapshot: true)
            preview.window?.contentView?.layoutSubtreeIfNeeded(); preview.textView.displayIfNeeded()
            samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            XCTAssertTrue(preview.textView.layoutManager?.allowsNonContiguousLayout == true)
            preview.close()
        }
        samples.sort()
        print("FOX_CONVERSATION_PREVIEW bytes=\(messages.reduce(0) { $0 + $1.text.utf8.count }) init_layout_p50_ms=\(samples[2]) max_ms=\(samples[4])")
    }
    func testSearchClearStaleRepliesCategoryIsolationAndSourceDisable() throws {
        _ = NSApplication.shared
        let (root, defaults) = try fixture(), url = root.appendingPathComponent("index.sqlite")
        let index = try AITopicIndex(url: url)
        let first = AITopic(id: UUID().uuidString, provider: .codex, title: "包装设计", modified: 2)
        let second = AITopic(id: UUID().uuidString, provider: .claude, title: "产品摄影", modified: 1)
        try index.upsert(first); try index.message(first.key, key: "one", body: "Blue 包装方案", role: "user")
        try index.upsert(second); try index.message(second.key, key: "one", body: "红色手链布光", role: "user")
        let manager = AITopicManager(defaults: defaults, url: url, locations: .init(home: root), detectProviders: { [.codex, .claude] })
        manager.installSnapshot(url: url); defer { manager.stop() }
        let c = SearchViewController(snapshot: true, preferences: defaults); _ = c.view; c.aiTopics = manager
        c.filters.selectConversations(); c.searchField.text = "包装"; c.startSearch()
        eventually { c.conversations.topics.count == 1 }
        XCTAssertEqual(c.conversations.selected?.key, first.key); XCTAssertFalse(c.conversations.isHidden)
        let space = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        XCTAssertFalse(c.handleKey(space), "An automatic first-row selection must not turn a typed space into preview")
        XCTAssertNil(c.results.result); XCTAssertNil(c.naturalPlan)
        XCTAssertTrue(c.makeActions().contains { $0.id == "topicCopyContent" })
        var opened: URL?; c.openConversationClient = { opened = AITopicActions.desktopURL($0); $1(.dispatched) }
        c.makeActions().first { $0.id == "topicOpen" }?.run()
        eventually { opened != nil }; XCTAssertEqual(opened, first.codexURL)
        c.resultPasteboard = NSPasteboard.withUniqueName()
        c.makeActions().first { $0.id == "topicCopyContent" }?.run()
        eventually { c.resultPasteboard.string(forType: .string)?.contains("Blue") == true }
        c.searchField.text = "红色"; c.startSearch(); c.searchField.text = ""; c.startSearch()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(c.conversations.topics.isEmpty); XCTAssertFalse(c.searchInFlight)
        c.searchField.text = "包装"; c.startSearch(); c.filters.select(4)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(c.conversations.isHidden); XCTAssertFalse(c.filters.aiSelected)
        c.filters.selectConversations(); c.searchField.text = "包装"; c.startSearch()
        eventually { c.conversations.topics.count == 1 }
        manager.setProviderEnabled(.codex, enabled: false)
        eventually { c.conversations.topics.isEmpty }
    }
    func testClearingCacheLeavesSourceUntouchedAndStaysDisabled() throws {
        let (root, defaults) = try fixture(), url = root.appendingPathComponent("index.sqlite")
        let original = root.appendingPathComponent("original.jsonl")
        try Data("original conversation".utf8).write(to: original)
        do { let index = try AITopicIndex(url: url); try index.upsert(.init(id: "demo", provider: .codex, title: "Demo")) }
        let manager = AITopicManager(defaults: defaults, url: url, locations: .init(home: root), detectProviders: { [.codex] })
        manager.installSnapshot(url: url); defer { manager.stop() }
        manager.clearCache(); eventually { !manager.clearing }
        XCTAssertFalse(manager.enabled); XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try String(contentsOf: original), "original conversation")
    }
    func testLargeConversationCorpusAndVirtualList() throws {
        _ = NSApplication.shared
        let (root, _) = try fixture(), index = try AITopicIndex(url: root.appendingPathComponent("large.sqlite"))
        try index.transaction {
            for n in 0..<4000 {
                let topic = AITopic(id: String(n), provider: .codex, title: "包装讨论 \(n)", modified: Double(n))
                try index.upsert(topic)
                try index.message(topic.key, key: "message", body: "包装需要蓝色文字和清楚的产品说明。Revision \(n)", role: "user")
            }
        }
        var elapsed = [Double](), topics = [AITopic]()
        for _ in 0..<21 {
            let start = DispatchTime.now().uptimeNanoseconds
            let result = try index.search("包装 蓝色", limit: 500)
            elapsed.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            XCTAssertEqual(result.topics.count, 500); XCTAssertTrue(result.hasMore)
            topics = result.topics
        }
        let firstQuery = elapsed.removeFirst(); elapsed.sort()
        // Separate result-cache hits from actual compressed-message retrieval.
        let uncachedIndex = try AITopicIndex(url: root.appendingPathComponent("large.sqlite"), readOnly: true, cacheBudgetBytes: 0)
        var uncachedTimes = [Double]()
        for _ in 0..<20 {
            let start = DispatchTime.now().uptimeNanoseconds
            let found = try uncachedIndex.search("包装 蓝色", limit: 500)
            uncachedTimes.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            XCTAssertEqual(found.topics.map(\.key), topics.map(\.key))
            XCTAssertEqual(uncachedIndex.resultCacheHits, 0)
            XCTAssertEqual(uncachedIndex.documentCacheBytes, 0)
        }
        uncachedTimes.sort()
        let view = AIConversationResultsView(frame: NSRect(x: 0, y: 0, width: 900, height: 550))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.close() }
        view.isHidden = false; view.show(topics, preserveSelection: false); view.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(view.subviews.compactMap { $0 as? ResultScrollView }.first)
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        var times = [Double]()
        for n in stride(from: 0, to: 500, by: 5) {
            let start = DispatchTime.now().uptimeNanoseconds
            view.select(n); view.layoutSubtreeIfNeeded()
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        times.sort()
        XCTAssertEqual(view.selected?.key, topics[495].key)
        XCTAssertLessThan(table.subviews.count, 60, "Only visible rows should have native views")
        print("FOX_CONVERSATION_WORKLOAD topics=4000 results=500 first_query_ms=\(firstQuery) uncached_query_p95_ms=\(uncachedTimes[18]) cached_query_p95_ms=\(elapsed[18]) list_layout_p95_ms=\(times[94]) views=\(table.subviews.count)")
    }
}
