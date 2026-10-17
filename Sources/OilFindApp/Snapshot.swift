import AppKit
import OilFindCore

enum SnapshotError: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case .failed(let reason): return reason } }
}

#if DEBUG
enum Snapshot {
    static func run(_ arguments: [String], appExtension: ApplicationExtension? = nil, externalDrives: ExternalDriveCatalog = ExternalDriveCatalog()) throws {
        let allowed = Set(["--snapshot", "--state", "--query", "--filter", "--sort", "--select", "--appearance", "--db", "--settings-scroll", "--language", "--coverage", "--update-notes", "--update-scroll", "--mode", "--scope", "--favorite-row", "--grid", "--media", "--tag", "--apps", "--shortcuts"])
        var values: [String: String] = [:], i = 0, granted = false
        while i < arguments.count {
            if arguments[i] == "--granted" { granted = true; i += 1; continue }
            guard allowed.contains(arguments[i]), i + 1 < arguments.count else { throw SnapshotError.failed("Invalid snapshot argument: \(arguments[i])") }
            values[arguments[i]] = arguments[i + 1]; i += 2
        }
        guard let output = values["--snapshot"], !output.isEmpty else { throw SnapshotError.failed("--snapshot requires an output path") }
        if let language = values["--language"] {
            guard ["zh", "en"].contains(language) else { throw SnapshotError.failed("Invalid language: \(language)") }
            L10n.snapshotChinese = language == "zh"
        }
        defer { L10n.snapshotChinese = nil }
        appExtension?.languageDidChange(chinese: L10n.chinese)
        let state = values["--state"] ?? "results"
        guard ["results", "idle", "recent", "empty", "indexing", "welcome", "toast", "settings", "content-preview", "actions", "menu", "no-access", "diagnostic", "syntax", "update-available", "update-downloading", "update-failed", "update-latest"].contains(state) else { throw SnapshotError.failed("Invalid state: \(state)") }
        let appearance = values["--appearance"] ?? "light"
        guard ["light", "dark"].contains(appearance) else { throw SnapshotError.failed("Invalid appearance: \(appearance)") }
        let filter = values["--filter"] ?? "all"
        guard let kind = FilterBar.names.firstIndex(of: filter) else { throw SnapshotError.failed("Invalid filter: \(filter)") }
        let sort = values["--sort"] ?? "relevance"
        let sorts: [String: SortKey] = ["relevance": .relevance, "name": .name, "modified": .modified, "size": .size]
        guard let key = sorts[sort], let selection = Int(values["--select"] ?? "0"), selection >= 0 else { throw SnapshotError.failed("Invalid sort or selected row") }
        var store: IndexStore?
        if !state.hasPrefix("update-") && !["indexing", "welcome", "settings", "menu"].contains(state) || (state == "settings" && values["--db"] != nil) {
            let fallback = NSHomeDirectory() + "/Library/Caches/Local Find/cli-index.oilfind"
            let defaultPath = FileManager.default.fileExists(atPath: AppDelegate.dbURL.path) ? AppDelegate.dbURL.path : fallback
            let db = NSString(string: values["--db"] ?? defaultPath).expandingTildeInPath
            guard let loaded = IndexStore.load(from: db) else { throw SnapshotError.failed("Cannot load index: \(db)") }
            loaded.write { loaded.buildHash() }
            store = loaded
        }
        if values["--coverage"] == "sample", let store {
            store.write {
                for reason in CoverageReason.allCases {
                    store.coverage.buckets[reason] = CoverageBucket(count: reason == .dependency ? 248 : 3, examples: [reason == .noAccess ? "/Users/demo/Library/Mail" : "/Users/demo/" + reason.rawValue])
                }
            }
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        if state == "menu" {
            app.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
            let delegate = AppDelegate(appExtension: appExtension, externalDrives: externalDrives)
            let menu = delegate.makeMenu()
            guard let screen = NSScreen.main else { throw SnapshotError.failed("Cannot find screen") }
            let capture = MenuSnapshotCapture(menu: menu, output: output)
            let timer = Timer(timeInterval: 0.3, target: capture, selector: #selector(MenuSnapshotCapture.capture), userInfo: nil, repeats: false)
            RunLoop.main.add(timer, forMode: .eventTracking)
            menu.popUp(positioning: nil, at: NSPoint(x: screen.frame.midX, y: screen.frame.midY), in: nil)
            timer.invalidate()
            if let failure = capture.failure { throw failure }
            guard capture.captured else {
                throw SnapshotError.failed("Menu closed before capture")
            }
            return
        }
        if state.hasPrefix("update-") {
            var manifest = try UpdateManifest.parse(Data(#"{"version":"1.2.0","build":5,"url":"https://find.oiloil.org/downloads/Oil-Find-1.2.0.zip","size":1,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","minimumSystemVersion":"14.0","published":"2026-10-04","notes":{"zh":["应用内检查更新：有新版本时提示，一键下载、校验并重启到新版本。","官网新增更新日志。"],"en":["Built-in updates: Fox Find tells you when a new version is out, then downloads, verifies and restarts into it.","A changelog is now on the website."]}}"#.utf8))
            if let text = values["--update-notes"] {
                guard let count = Int(text), (1...20).contains(count) else { throw SnapshotError.failed("Invalid update note count") }
                var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as! [String: Any]
                object["notes"] = ["zh": (0..<count).map { manifest.notes.zh[$0 % 2] }, "en": (0..<count).map { manifest.notes.en[$0 % 2] }]
                manifest = try UpdateManifest.parse(JSONSerialization.data(withJSONObject: object))
            }
            let model = UpdateManager(snapshot: true, current: state == "update-latest" ? UpdateManager.current : UpdateVersion("1.1.0", build: 4)!)
            let states: [String: UpdateState] = ["update-available": .available, "update-downloading": .downloading(0.42), "update-failed": .failed(.signature), "update-latest": .latest]
            model.prepareSnapshot(states[state]!, manifest: state == "update-latest" ? nil : manifest)
            let controller = UpdateWindowController(model: model)
            guard let window = controller.window, let view = window.contentView else { throw SnapshotError.failed("Cannot create update view") }
            window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            view.layoutSubtreeIfNeeded()
            if let text = values["--update-scroll"] {
                guard let fraction = Double(text), (0...1).contains(fraction) else { throw SnapshotError.failed("Invalid update scroll fraction") }
                func findScroll(_ node: NSView) -> NSScrollView? {
                    if let scroll = node as? NSScrollView { return scroll }
                    return node.subviews.lazy.compactMap(findScroll).first
                }
                guard let scroll = findScroll(view), let document = scroll.documentView else { throw SnapshotError.failed("Cannot find update scroll view") }
                let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? maximum * fraction : maximum * (1 - fraction)))
                scroll.reflectScrolledClipView(scroll.contentView)
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                print("update notes scroll: maximum=\(maximum) origin=\(scroll.contentView.bounds.origin.y)")
            }
            try write(view: view, appearance: window.appearance, output: output)
            return
        }
        if state == "welcome" {
            let controller = WelcomeWindowController(granted: granted, snapshot: true)
            guard let window = controller.window, let view = window.contentView else { throw SnapshotError.failed("Cannot create welcome view") }
            window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            controller.resizeToContent(); view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            if let warmup = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: warmup) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            try write(view: view, appearance: window.appearance, output: output)
            return
        }
        if state == "settings" {
            let model = SettingsModel(snapshotStore: store, snapshot: true)
            if values["--coverage"] == "sample" { model.expandedCoverage = ["noAccess", "scope"] }
            let controller = SettingsWindowController(model: model, appExtension: appExtension, externalDrives: externalDrives)
            guard let window = controller.window, let view = window.contentView else { throw SnapshotError.failed("Cannot create settings view") }
            window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
            view.layoutSubtreeIfNeeded()
            // SwiftUI commits its initial layout on the run loop, without showing a window.
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            view.layoutSubtreeIfNeeded()
            if let value = values["--settings-scroll"] {
                guard let fraction = Double(value), (0...1).contains(fraction) else { throw SnapshotError.failed("Invalid settings scroll fraction") }
                func scrollViews(_ view: NSView) -> [NSScrollView] {
                    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
                }
                if let scroll = scrollViews(view).first, let document = scroll.documentView {
                    let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? maximum * fraction : maximum * (1 - fraction)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                    view.layoutSubtreeIfNeeded()
                }
            }
            try write(view: view, appearance: window.appearance, output: output)
            return
        }
        let snapshotSuite = "app.localfind.snapshot." + UUID().uuidString
        let snapshotPreferences = UserDefaults(suiteName: snapshotSuite)!
        defer { snapshotPreferences.removePersistentDomain(forName: snapshotSuite) }
        let panel = SearchPanel(snapshot: true, preferences: snapshotPreferences)
        panel.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        let controller = panel.searchController
        if let path = values["--shortcuts"] {
            let imported = try BookmarkImport.parse(Data(contentsOf: URL(fileURLWithPath: path)), format: URL(fileURLWithPath: path).pathExtension)
            controller.shortcuts.merge(imported)
        }
        if values["--apps"] == "true" {
            let apps = DispatchQueue(label: "snapshot.applications").sync { ApplicationCatalog.discover() }
            controller.applicationCatalog.replace(apps)
            print("launcher applications: \(apps.count)")
        }
        controller.supplementaryProvider = appExtension?.supplementarySearchProvider
        if let value = values["--mode"] {
            guard let mode = SearchMode(rawValue: value) else { throw SnapshotError.failed("Invalid search mode") }
            controller.toolsBar.mode = mode
        }
        controller.toolsBar.folder = values["--scope"]
        try controller.prepareSnapshot(state: state, query: values["--query"] ?? "readme", options: SearchOptions(sort: key, ascending: key == .name, kind: kind == 0 ? nil : UInt8(kind)), store: store, selection: selection, additionalSources: externalDrives.searchSources() + (appExtension?.searchSources() ?? []))
        if values["--media"] == nil, let plan = controller.naturalPlan, plan.refinement.active, let result = controller.results.result {
            var refined: SearchPresentation?
            DispatchQueue(label: "snapshot.natural-metadata").sync { refined = result.refined(plan.refinement, reader: AssetMetadataReader(), cancelled: { false }) }
            if let refined { controller.present(refined) }
        }
        if let raw = values["--media"] {
            guard let filter = AssetFilter(rawValue: raw), let result = controller.results.result else { throw SnapshotError.failed("Invalid media filter") }
            controller.toolsBar.refinement = AssetRefinement(media: filter, tag: values["--tag"] ?? "")
            var refined: SearchPresentation?
            DispatchQueue(label: "snapshot.metadata").sync { refined = result.refined(controller.toolsBar.refinement, reader: AssetMetadataReader(), cancelled: { false }) }
            if let refined { controller.present(refined) }
        }
        if values["--grid"] == "true" { controller.setGridMode(true) }
        if state == "actions" { controller.showActions() }
        if let value = values["--favorite-row"] {
            guard let row = Int(value), row >= 0, row < (controller.results.result?.count ?? 0) else { throw SnapshotError.failed("Invalid favorite row") }
            controller.results.select(row); controller.toggleSelectedFileFavorite(); controller.results.select(selection)
        }
        if state == "content-preview" {
            guard let row = controller.results.result?.row(selection),
                  let prepare = appExtension?.supplementarySearchProvider?.preparePreview(source: row.source, entryID: row.id, isCancelled: { false }) else { throw SnapshotError.failed("No selected result") }
            var outcome: TextPreviewOutcome = .cancelled
            DispatchQueue(label: "snapshot.preview").sync { outcome = prepare() }
            guard case .ready(let preview) = outcome else { throw SnapshotError.failed("No text for selected result: \(outcome)") }
            let previewController = ContentPreviewWindow(preview: preview, query: values["--query"] ?? "")
            guard let window = previewController.window, let view = window.contentView else { throw SnapshotError.failed("Cannot create text preview") }
            window.appearance = panel.appearance; view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            try write(view: view, appearance: window.appearance, output: output); return
        }
        let view = controller.view
        view.frame = NSRect(origin: .zero, size: Theme.panelSize)
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let deadline = Date().addingTimeInterval(1)
        while !controller.results.icons.isIdle && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        if values["--grid"] == "true" { RunLoop.main.run(until: Date().addingTimeInterval(2)) }
        view.layoutSubtreeIfNeeded()
        if let warmup = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: warmup) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        view.layoutSubtreeIfNeeded()
        if values["--grid"] == "true" {
            let collection = controller.results.grid.collection
            let flow = collection.collectionViewLayout as! NSCollectionViewFlowLayout
            print("grid layout: grid=\(controller.results.grid.bounds) collection=\(collection.frame) clip=\(collection.enclosingScrollView!.contentView.bounds) contentSize=\(collection.enclosingScrollView!.contentSize) columns=\(controller.results.grid.columns) item=\(flow.itemSize)")
            for i in 0..<min(4, controller.results.grid.count) { print("grid item \(i): \(flow.layoutAttributesForItem(at: IndexPath(item: i, section: 0))!.frame)") }
        }
        try write(view: view, appearance: panel.appearance, output: output)
    }
    private static func write(view: NSView, appearance: NSAppearance?, output: String) throws {
        let size = view.bounds.size
        let width = Int(size.width * 2), height = Int(size.height * 2)
        guard let suggested = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw SnapshotError.failed("Cannot allocate snapshot bitmap")
        }
        let bitmap: NSBitmapImageRep
        if suggested.pixelsWide == width && suggested.pixelsHigh == height { bitmap = suggested }
        else {
            guard let retina = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
                throw SnapshotError.failed("Cannot allocate 2x snapshot bitmap")
            }
            bitmap = retina
        }
        bitmap.size = size
        appearance?.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw SnapshotError.failed("Cannot encode snapshot PNG") }
        let url = URL(fileURLWithPath: NSString(string: output).expandingTildeInPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url, options: .atomic)
        print("snapshot: \(url.path) \(width)x\(height)")
    }
}

private final class MenuSnapshotCapture: NSObject {
    let menu: NSMenu
    let output: String
    private(set) var failure: Error?
    private(set) var captured = false
    init(menu: NSMenu, output: String) { self.menu = menu; self.output = output }

    @objc func capture() {
        defer { menu.cancelTracking() }
        do {
            let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            guard let info = windows.first(where: {
                ($0[kCGWindowOwnerPID as String] as? Int32) == ProcessInfo.processInfo.processIdentifier
                    && ($0[kCGWindowLayer as String] as? Int ?? 0) > 0
            }), let number = info[kCGWindowNumber as String] as? Int else {
                throw SnapshotError.failed("Cannot find menu window")
            }
            let url = URL(fileURLWithPath: NSString(string: output).expandingTildeInPath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(number), url.path]
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw SnapshotError.failed("Cannot capture menu window") }
            captured = true
            print("snapshot: \(url.path)")
        } catch { failure = error }
    }
}
#endif
