#if DEBUG
import AppKit
import OilFindCore
import ImageIO
import UniformTypeIdentifiers

/// Explicit validation mode: only synthetic files, an isolated preferences suite,
/// and a six-item in-memory index. No AppDelegate, scanners, watchers, OCR, or model.
final class WorkflowDemo: NSObject, NSApplicationDelegate {
    private let panel: SearchPanel
    private let content: AIConversationContent
    private var conversation: AIConversationWindow?
    private let root: URL
    private let preferences: UserDefaults
    private let topics: AITopicManager
    private init(root: URL) throws {
        self.root = root
        guard let preferences = UserDefaults(suiteName: "app.localfind.workflow-preview.data") else { throw WorkflowFailure.unavailable("Workflow preview preferences") }
        self.preferences = preferences
        panel = SearchPanel(snapshot: true, preferences: preferences, activating: true)
        let content = AIConversationContent(topic: AITopic(id: "fox-find-synthetic-conversation", provider: .claude,
            title: L10n.local("产品摄影 · 设计方向（演示）", "Product photography · Direction (demo)"), project: root.path),
            messages: [.init(role: "user", text: L10n.local("保留中性灰背景，交付可编辑源文件与预览图片。", "Keep a neutral gray background. Deliver editable source files and preview images.")),
                       .init(role: "assistant", text: L10n.local("下一步：对照原图确认尺寸，整理已选定的文件，再开始下一轮设计。", "Next: compare the original image dimensions, collect the chosen files, then continue the design."))], truncated: false)
        self.content = content
        let databaseURL = root.appendingPathComponent("demo-conversations.sqlite")
        let index = try AITopicIndex(url: databaseURL)
        try index.upsert(content.topic)
        for (i, message) in content.messages.enumerated() { try index.message(content.topic.key, key: "\(i)", body: message.text, role: message.role) }
        topics = AITopicManager(defaults: preferences, url: databaseURL, locations: .init(home: root), detectProviders: { [.claude] })
        topics.installSnapshot(url: databaseURL)
        super.init()
        let controller = panel.searchController
        controller.aiTopics = topics
        controller.openConversationClient = { _, completion in completion(.unavailable) }
        let names = ["", "Studio-preview.png", "Studio-original.png", "Studio-copy.png", "Studio-alternative.png", "Delivery-notes.txt"]
        var buffer = ScanBuffer()
        buffer.ids = names.indices.map(UInt32.init); buffer.parents = names.map { _ in 0 }
        buffer.sizes = try names.map { name in name.isEmpty ? 0 : IndexStore.encodeSize(UInt64(try WorkflowFiles.inspect(WorkFile(path: root.appendingPathComponent(name).path)).size)) }
        buffer.mtimes = names.map { _ in UInt32(Date().timeIntervalSince1970) }
        buffer.flags = names.indices.map { $0 == 0 ? 1 : 0 }; buffer.depths = names.indices.map { $0 == 0 ? 0 : 1 }
        buffer.kinds = [1, 4, 4, 4, 4, 3]; buffer.nameLens = names.map { UInt32($0.utf8.count) }; buffer.nameBytes = Array(names.joined().utf8)
        let store = IndexStore(scan: ScanOutput(buffers: [buffer], count: names.count, homeIndex: .max, elapsed: 0, finishedAt: 0), config: IndexConfig(rootPath: root.path))
        // Match SearchPresentation's primary-source identity. A different display
        // name makes live results look stale and schedules endless refreshes.
        controller.additionalSources = { [SearchSource(id: "startup", displayName: "", isOnline: true, store: store)] }
        try controller.prepareSnapshot(state: "results", query: "Studio", options: .init(), store: store, selection: 0)
        controller.onSettings = { [weak self] in self?.showConversation() }
        // This regular, standalone preview must stay visible when the operator
        // switches back to the validation tools. Keep explicit Escape dismissal.
        panel.level = .normal
        controller.hidePanel = { [weak self] in
            guard let self, self.panel.isKeyWindow else { return }
            self.panel.orderOut(nil)
        }
        if !preferences.bool(forKey: "workflow.demo.seeded") {
            controller.workCollection.add(WorkFile(path: root.appendingPathComponent("Delivery-notes.txt").path))
            controller.workCollection.edit(title: L10n.local("产品摄影 · 继续整理", "Product photography · Continue"), instructions: L10n.local("确认图片版本，沿用已选定的视觉方向。", "Confirm the image version and keep the selected visual direction."))
            preferences.set(true, forKey: "workflow.demo.seeded")
        }
    }
    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoxFind-Workflow-Preview")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, size, variant) in [("Studio-preview.png", 240, false), ("Studio-original.png", 720, false), ("Studio-alternative.png", 240, true)] {
            let url = root.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) { try drawFixture(url, size: size, variant: variant) }
        }
        let copy = root.appendingPathComponent("Studio-copy.png")
        if !FileManager.default.fileExists(atPath: copy.path) { try FileManager.default.copyItem(at: root.appendingPathComponent("Studio-preview.png"), to: copy) }
        let notes = root.appendingPathComponent("Delivery-notes.txt")
        if !FileManager.default.fileExists(atPath: notes.path) { try "Synthetic demonstration files only.\nCompare versions, collect sources, and continue your work.\n".write(to: notes, atomically: true, encoding: .utf8) }
        let app = NSApplication.shared
        app.appearance = NSAppearance(named: .darkAqua)
        app.setActivationPolicy(.regular)
        let delegate = try WorkflowDemo(root: root)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
    private static func drawFixture(_ url: URL, size: Int, variant: Bool) throws {
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw WorkflowFailure.unavailable(url.path) }
        let side = CGFloat(size)
        context.setFillColor(CGColor(gray: 0.88, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(variant ? NSColor.systemOrange.cgColor : NSColor(calibratedRed: 0.30, green: 0.42, blue: 0.57, alpha: 1).cgColor)
        context.fillEllipse(in: CGRect(x: side * 0.18, y: side * 0.18, width: side * 0.64, height: side * 0.64))
        context.setFillColor(CGColor(gray: 0.98, alpha: 1)); context.fill(CGRect(x: side * 0.44, y: side * 0.15, width: side * 0.12, height: side * 0.70))
        guard let image = context.makeImage() else { throw WorkflowFailure.unavailable(url.path) }
        CGImageDestinationAddImage(destination, image, nil)
        if !CGImageDestinationFinalize(destination) { throw WorkflowFailure.unavailable(url.path) }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(), application = NSMenuItem(), actions = NSMenu()
        menu.addItem(application); application.submenu = actions
        for (title, selector, key) in [
            (L10n.local("显示演示搜索", "Show demo search"), #selector(showSearch), "1"),
            (L10n.local("收集篮与继续资料", "Collection and context pack"), #selector(showCollection), "2"),
            (L10n.local("演示对话摘录", "Demo conversation excerpts"), #selector(showConversation), "3"),
            (L10n.local("退出验证版", "Quit preview"), #selector(quit), "q")
        ] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key); item.target = self; actions.addItem(item)
        }
        NSApp.mainMenu = menu
        WorkflowTextKeys.installEditingMenu()
        NSApp.activate(ignoringOtherApps: true); showSearch()
    }
    @objc private func showSearch() { panel.show(source: .menu) }
    @objc private func showCollection() { panel.searchController.showCollection() }
    @objc private func showConversation() {
        conversation?.close()
        let window = AIConversationWindow(content: content, query: "", snapshot: false)
        window.openButton.isEnabled = false
        window.onCollect = { [weak self] in self?.panel.searchController.workCollection.add($0) ?? false }
        window.onCopy = { [content] in NSPasteboard.general.clearContents(); NSPasteboard.general.setString(content.markdown, forType: .string) }
        conversation = window; window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil)
    }
    @objc private func quit() { topics.stop(); NSApp.terminate(nil) }
    // Search uses an NSPanel, which AppKit does not count as a normal app window.
    // Closing a menu or auxiliary window must not end the entire validation session.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
#endif
