import AppKit
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import XCTest
@testable import OilFindApp
@testable import OilFindCore

final class AssetWorkspaceTests: XCTestCase {
    private func preferences(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "FoxFindAssetTest-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }; try body(defaults)
    }
    private func fixture(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FoxFindAssets-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }; try body(folder)
    }
    private func index(_ root: URL, names: [String]) -> IndexStore {
        let names = [""] + names
        var buffer = ScanBuffer()
        buffer.ids = names.indices.map { UInt32($0) }; buffer.parents = names.map { _ in 0 }; buffer.sizes = names.map { _ in 100 }; buffer.mtimes = names.map { _ in 20 }
        buffer.flags = names.indices.map { $0 == 0 ? 1 : 128 }; buffer.depths = names.indices.map { $0 == 0 ? 0 : 1 }; buffer.kinds = names.map { _ in 4 }
        buffer.nameLens = names.map { UInt32($0.utf8.count) }; buffer.nameBytes = Array(names.joined().utf8)
        return IndexStore(scan: ScanOutput(buffers: [buffer], count: names.count, homeIndex: .max, elapsed: 0, finishedAt: 0), config: IndexConfig(rootPath: root.path))
    }
    private func image(_ url: URL, width: Int, height: Int, orientation: Int = 1) throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(ctx.makeImage()), [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
    func testCaptureDateUsesRealEXIFAndUnknownMetadataStaysUnknown() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-14T12:00:00Z")!
        let range = DateInterval(start: now.addingTimeInterval(-7 * 86400), end: now)
        let filter = AssetRefinement(captured: range)
        try fixture { root in
            for (name, date, offset) in [("recent.jpg", "2026:10:13 20:00:00", "+08:00"), ("old.jpg", "2020:01:01 00:00:00", "+00:00"), ("unknown.jpg", "", "")] {
                let url = root.appendingPathComponent(name)
                let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
                let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
                let exif: [CFString: Any] = date.isEmpty ? [:] : [kCGImagePropertyExifDateTimeOriginal: date, kCGImagePropertyExifOffsetTimeOriginal: offset]
                CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [kCGImagePropertyExifDictionary: exif] as CFDictionary)
                XCTAssertTrue(CGImageDestinationFinalize(destination))
            }
            let store = index(root, names: ["recent.jpg", "old.jpg", "unknown.jpg"])
            let source = SearchSource(id: "capture", displayName: "Capture", isOnline: true, store: store)
            let cache = root.appendingPathComponent("metadata.sqlite"), reader = AssetMetadataReader(cacheURL: cache)
            let base = SearchPresentation(try XCTUnwrap(MultiSearcher.search(.parse("kind:image"), in: [source])))
            let result = try XCTUnwrap(base.refined(filter, reader: reader, cancelled: { false }))
            XCTAssertEqual(result.count, 1); XCTAssertEqual(result.refinementUnknown, 1); XCTAssertEqual(result.refinementChecked, 3)
            XCTAssertEqual(result.row(0).map { $0.source.store.path($0.id) }, root.appendingPathComponent("recent.jpg").path)
            let offline = AssetMetadataReader(cacheURL: cache).offline(path: root.appendingPathComponent("recent.jpg").path, modified: Date(timeIntervalSince1970: 20), media: true)
            XCTAssertEqual(offline?.capturedAt, now.addingTimeInterval(-86400))
            XCTAssertTrue(filter.matches(try XCTUnwrap(offline)))
        }
        func properties(_ date: String, offset: String? = nil) -> [CFString: Any] {
            var exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: date]
            if let offset { exif[kCGImagePropertyExifOffsetTimeOriginal] = offset }
            return [kCGImagePropertyExifDictionary: exif]
        }
        XCTAssertEqual(AssetMetadataReader.captureDate(properties("2026:10:14 20:00:00"), localZone: TimeZone(secondsFromGMT: 28800)!), now)
        XCTAssertNil(AssetMetadataReader.captureDate(properties("2026:02:30 12:00:00")))
        XCTAssertNil(AssetMetadataReader.captureDate(properties("2026:10:14 12:00:00", offset: "+14:59")))
        XCTAssertNil(AssetMetadataReader.captureDate([kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFDateTime: "2026:10:14 12:00:00"]]))
        let legacy = Data("{\"readable\":true,\"width\":8,\"height\":8,\"tags\":[]}".utf8)
        XCTAssertNil(try JSONDecoder().decode(AssetMetadata.self, from: legacy).capturedAt)
    }
    func testRealImageDimensionsOrientationAndFinderTagFiltering() throws {
        try fixture { root in
            let url = root.appendingPathComponent("rotated.jpg")
            try image(url, width: 120, height: 80, orientation: 6)
            try (url as NSURL).setResourceValue(["Fox Find Test"], forKey: .tagNamesKey)
            let reader = AssetMetadataReader(), info = reader.read(path: url.path, modified: Date())
            XCTAssertEqual(info.width, 80); XCTAssertEqual(info.height, 120)
            XCTAssertTrue(AssetFilter.portrait.matches(info)); XCTAssertFalse(AssetFilter.landscape.matches(info))
            XCTAssertTrue(AssetRefinement(media: .portrait, tag: "fox find test").matches(info), "Metadata: \(info)")
            XCTAssertFalse(AssetRefinement(media: .portrait, tag: "fox").matches(info))
            let store = index(root, names: ["rotated.jpg"])
            let source = SearchSource(id: "drive", displayName: "Assets", isOnline: true, store: store)
            let base = SearchPresentation(try XCTUnwrap(MultiSearcher.search(.parse("jpg"), in: [source])))
            let filtered = try XCTUnwrap(base.refined(.init(media: .portrait, tag: "Fox Find Test"), reader: reader, cancelled: { false }))
            XCTAssertEqual(filtered.count, 1); XCTAssertEqual(filtered.refinementChecked, 1); XCTAssertFalse(filtered.refinementLimited)
            XCTAssertNil(base.refined(.init(media: .portrait), reader: reader, cancelled: { true }))
            let offline = SearchSource(id: "drive", displayName: "Assets", isOnline: false, store: store)
            let disconnected = SearchPresentation(try XCTUnwrap(MultiSearcher.search(.parse("jpg"), in: [offline])))
            XCTAssertEqual(disconnected.refined(.init(media: .portrait), reader: reader, cancelled: { false })?.count, 1, "Previously cached metadata remains available offline")
            let unknown = disconnected.refined(.init(media: .portrait), reader: AssetMetadataReader(), cancelled: { false })
            XCTAssertEqual(unknown?.count, 0); XCTAssertEqual(unknown?.refinementUnknown, 1)
        }
    }
    func testRealVideoDuration() throws {
        _ = NSApplication.shared
        try fixture { root in
            let movie = root.appendingPathComponent("sample.mov")
            let writer = try AVAssetWriter(outputURL: movie, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 32])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 32])
            writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 32, kCVPixelFormatType_32ARGB, nil, &buffer), kCVReturnSuccess)
            let pixel = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            memset(CVPixelBufferGetBaseAddress(pixel), 0, CVPixelBufferGetDataSize(pixel)); CVPixelBufferUnlockBaseAddress(pixel, [])
            for second in [0, 4] {
                let deadline = Date().addingTimeInterval(3)
                while !input.isReadyForMoreMediaData && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
                XCTAssertTrue(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(second), timescale: 1)))
            }
            input.markAsFinished(); writer.endSession(atSourceTime: CMTime(value: 5, timescale: 1))
            let finished = expectation(description: "video encoded"); writer.finishWriting { finished.fulfill() }; wait(for: [finished], timeout: 5)
            XCTAssertEqual(writer.status, .completed)
            var info = AssetMetadata()
            DispatchQueue(label: "test.video").sync { info = AssetMetadataReader().read(path: movie.path, modified: Date()) }
            XCTAssertEqual(info.width, 64); XCTAssertEqual(info.height, 32)
            XCTAssertEqual(try XCTUnwrap(info.duration), 5, accuracy: 0.1)
            XCTAssertTrue(AssetFilter.shortVideo.matches(info))
        }
    }
    func testMediaBoundariesAndCompleteRefinementCoverage() throws {
        XCTAssertTrue(AssetFilter.shortVideo.matches(.init(width: 1920, height: 1080, duration: 60)))
        XCTAssertFalse(AssetFilter.longVideo.matches(.init(duration: 60)))
        XCTAssertTrue(AssetFilter.longVideo.matches(.init(duration: 61)))
        XCTAssertFalse(AssetFilter.landscape.matches(.init(width: 1920, height: 1080, duration: 20)))
        XCTAssertTrue(AssetFilter.large.matches(.init(width: 2160, height: 3840)))
        XCTAssertFalse(AssetFilter.square.matches(.init()))
        let store = index(URL(fileURLWithPath: "/generated"), names: (0..<1002).map { "asset-\($0).jpg" })
        let source = SearchSource(id: "offline", displayName: "", isOnline: false, store: store)
        let base = SearchPresentation(try XCTUnwrap(MultiSearcher.search(.parse("jpg"), in: [source])))
        let filtered = try XCTUnwrap(base.refined(.init(media: .large), reader: AssetMetadataReader(), cancelled: { false }))
        XCTAssertEqual(filtered.refinementChecked, 1002); XCTAssertEqual(filtered.refinementUnknown, 1002)
        XCTAssertTrue(filtered.refinementLimited, "Unknown offline metadata must remain visible as a coverage limitation")
    }
    func testMetadataDeadlineResumeCancellationAndLateReads() throws {
        let store = index(URL(fileURLWithPath: "/synthetic"), names: (0..<24).map { "photo-\($0).jpg" })
        let base = SearchPresentation(try XCTUnwrap(Searcher.search(.parse("jpg"), in: store)))
        let reader = AssetMetadataReader(), filter = AssetRefinement(media: .landscape)
        let lock = NSLock(); var active = 0, peak = 0
        let inspect: (String, Date) -> AssetMetadata? = { _, _ in
            lock.lock(); active += 1; peak = max(peak, active); lock.unlock()
            Thread.sleep(forTimeInterval: 0.1)
            lock.lock(); active -= 1; lock.unlock()
            return .init(width: 20, height: 10)
        }
        var phases: [Bool] = []
        let start = Date()
        let partial = try XCTUnwrap(base.refined(filter, reader: reader, cancelled: { false }, progress: { phases.append($0.refinementRunning) }, budget: 0.25, inspect: inspect))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        XCTAssertTrue(partial.refinementPaused); XCTAssertFalse(partial.refinementRunning)
        XCTAssertLessThan(partial.refinementChecked!, 24); XCTAssertGreaterThan(partial.refinementChecked!, 0)
        XCTAssertEqual(phases.first, true)
        let count = partial.count
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(partial.count, count, "Late readers must not mutate delivered results")
        let resumed = try XCTUnwrap(base.refined(filter, reader: reader, cancelled: { false }, budget: 2, resume: partial, inspect: inspect))
        XCTAssertEqual(resumed.count, 24); XCTAssertEqual(resumed.refinementChecked, 24)
        XCTAssertFalse(resumed.refinementPaused); XCTAssertFalse(resumed.refinementRunning)
        XCTAssertLessThanOrEqual(peak, 4)
        let cancellation = Date().addingTimeInterval(0.03), began = Date()
        XCTAssertNil(base.refined(filter, reader: reader, cancelled: { Date() >= cancellation }, inspect: { _, _ in
            Thread.sleep(forTimeInterval: 0.3); return .init(width: 20, height: 10)
        }))
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.15)
        Thread.sleep(forTimeInterval: 0.35)
    }
    func testCachedCaptureCandidatesArePrioritizedButRevalidatedAndDoNotExcludeUncachedFiles() throws {
        try fixture { root in
            let names = (0..<12).map { "photo-\($0).jpg" }
            let store = index(root, names: names); store.write { store.buildHash() }
            let base = SearchPresentation(try XCTUnwrap(Searcher.search(.parse("jpg"), options: .init(sort: .name, ascending: true), in: store)))
            let cacheURL = root.appendingPathComponent("cache.sqlite"), cache = AssetMetadataCache(url: cacheURL)
            let date = Date(timeIntervalSince1970: 1000), filter = AssetRefinement(captured: DateInterval(start: date, duration: 100))
            let cachedPath = try XCTUnwrap(base.row(11)).source.store.path(try XCTUnwrap(base.row(11)).id)
            cache.put(path: cachedPath + "#media", stamp: "stale", info: .init(capturedAt: date))
            let lock = NSLock(); var inspected: [String] = []
            let result = try XCTUnwrap(base.refined(filter, reader: AssetMetadataReader(cacheURL: cacheURL), cancelled: { false }, inspect: { path, _ in
                lock.lock(); inspected.append(path); lock.unlock()
                // Stale cached candidate no longer matches; all uncached files do.
                return .init(capturedAt: path == cachedPath ? date.addingTimeInterval(1000) : date)
            }))
            XCTAssertTrue(inspected.prefix(4).contains(cachedPath), "A later cached candidate must appear in the first batch")
            XCTAssertEqual(result.count, 11); XCTAssertEqual(result.refinementChecked, 12)
            XCTAssertEqual((0..<result.count).compactMap { result.row($0)?.id }, (0..<11).compactMap { base.row($0)?.id }, "Keep the requested sort order")
        }
    }
    func testMetadataSerialAndConcurrentBenchmark() throws {
        guard ProcessInfo.processInfo.environment["FOX_METADATA_BENCHMARK"] == "1" else { throw XCTSkip("Opt-in metadata benchmark") }
        try fixture { root in
            let names = (0..<400).map { "photo-\($0).jpg" }
            for name in names { try image(root.appendingPathComponent(name), width: 128, height: 64) }
            let store = index(root, names: names)
            let base = SearchPresentation(try XCTUnwrap(Searcher.search(.parse("jpg"), in: store)))
            let filter = AssetRefinement(media: .landscape)
            var serial: [Double] = [], parallel: [Double] = []
            for run in 0..<4 {
                for concurrent in (run % 2 == 0 ? [false, true] : [true, false]) {
                    let reader = AssetMetadataReader(cacheURL: root.appendingPathComponent("cache-\(run)-\(concurrent).sqlite"))
                    let start = Date(); var matches = 0
                    if concurrent { matches = try XCTUnwrap(base.refined(filter, reader: reader, cancelled: { false })).count }
                    else {
                        for i in 0..<base.count {
                            let hit = try XCTUnwrap(base.row(i)), file = store.read { (store.path(hit.id), store.modified(hit.id)) }
                            if filter.matches(reader.read(path: file.0, modified: file.1)) { matches += 1 }
                        }
                    }
                    let ms = Date().timeIntervalSince(start) * 1000
                    if concurrent { parallel.append(ms) } else { serial.append(ms) }
                    XCTAssertEqual(matches, 400)
                }
            }
            print("METADATA_BENCHMARK files=400 serial_ms=\(serial) concurrent_ms=\(parallel)")
        }
    }
    func testProjectPersistenceAndOldSavedSearchMigration() throws {
        try preferences { defaults in
            let projects = ProjectFolders(defaults: defaults); projects.add("/generated/A/../A"); projects.add("/generated/A")
            XCTAssertEqual(projects.folders.count, 1); XCTAssertEqual(ProjectFolders(defaults: defaults).folders.first?.name, "A")
            projects.remove("/generated/A"); XCTAssertTrue(ProjectFolders(defaults: defaults).folders.isEmpty)
            let old = Data(#"[{"query":"invoice","mode":"combined","sort":"relevance","ascending":false}]"#.utf8)
            defaults.set(old, forKey: "search.favorites")
            let library = SearchLibrary(defaults: defaults); XCTAssertEqual(library.favorites.count, 1); XCTAssertNil(library.favorites[0].assetFilter)
            let search = SavedSearch(query: "jpg", folder: "/generated/A", assetFilter: .portrait, finderTag: "Client")
            library.toggleFavorite(search)
            XCTAssertEqual(SearchLibrary(defaults: defaults).favorites.first, search)
        }
    }
    func testGridRelayoutsWhenScrollerOccupiesViewport() throws {
        _ = NSApplication.shared
        let grid = AssetGridView(frame: NSRect(x: 0, y: 0, width: 900, height: 349))
        let window = NSWindow(contentRect: grid.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = grid
        let collection = grid.collection
        let scroll = try XCTUnwrap(collection.enclosingScrollView)
        let flow = try XCTUnwrap(collection.collectionViewLayout as? AssetGridLayout)
        for style in [NSScroller.Style.legacy, .overlay] {
            scroll.scrollerStyle = style
            for width: CGFloat in [900, 800, 900] {
                window.setContentSize(NSSize(width: width, height: 349))
                grid.reload(count: 6, selection: 0)
                grid.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                grid.layoutSubtreeIfNeeded()
                let first = try XCTUnwrap(flow.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)))
                let second = try XCTUnwrap(flow.layoutAttributesForItem(at: IndexPath(item: 1, section: 0)))
                let lastInRow = try XCTUnwrap(flow.layoutAttributesForItem(at: IndexPath(item: grid.columns - 1, section: 0)))
                XCTAssertEqual(first.frame.minY, lastInRow.frame.minY)
                XCTAssertLessThanOrEqual(second.frame.minX - first.frame.maxX, 12)
                XCTAssertLessThanOrEqual(lastInRow.frame.maxX, scroll.contentView.bounds.width - 16)
            }
        }
    }
    func testCompactToolbarMenusApplyFiltersAndKeepRemovedShortcutsInactive() throws {
        _ = NSApplication.shared
        try preferences { defaults in
            let legacy = Data("preserved legacy selection".utf8)
            defaults.set(legacy, forKey: "file.basket")
            let controller = SearchViewController(snapshot: true, preferences: defaults)
            controller.view.frame = NSRect(origin: .zero, size: Theme.panelSize)
            try controller.prepareSnapshot(state: "results", query: "jpg", options: .init(), store: index(URL(fileURLWithPath: "/generated"), names: ["a.jpg", "b.jpg"]), selection: 0)
            controller.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(controller.results.frame.minY, Theme.searchHeight + Theme.filterHeight + Theme.toolsHeight + Theme.pixel(controller.view), accuracy: 0.5)
            controller.toolsBar.grid.performClick(nil)
            XCTAssertTrue(controller.results.gridMode); XCTAssertTrue(controller.toolsBar.grid.iconOnly)
            controller.toolsBar.list.performClick(nil)
            XCTAssertFalse(controller.results.gridMode); XCTAssertEqual(controller.results.selectedRow, 0)
            let mediaMenu = try XCTUnwrap(controller.makeRefinementMenu().items.first { $0.submenu?.items.contains { $0.representedObject as? String == AssetFilter.portrait.rawValue } == true }?.submenu)
            let portrait = try XCTUnwrap(mediaMenu.items.first { $0.representedObject as? String == AssetFilter.portrait.rawValue })
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(portrait.action), to: portrait.target, from: portrait))
            XCTAssertEqual(controller.toolsBar.refinement.media, .portrait)
            controller.toolsBar.refinement.tag = "Client A"
            XCTAssertEqual(controller.toolsBar.refine.title, L10n.text("tools.filterCount", "2"))
            XCTAssertTrue(controller.toolsBar.refine.toolTip?.contains("Client A") == true)
            let clear = try XCTUnwrap(controller.makeRefinementMenu().items.first { $0.title == L10n.text("tools.clearFilters") })
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(clear.action), to: clear.target, from: clear))
            XCTAssertFalse(controller.toolsBar.refinement.active)
            controller.projects.add("/generated")
            let projects = try XCTUnwrap(controller.makeScopeMenu().items.first { $0.title == L10n.text("asset.project") }?.submenu)
            let project = try XCTUnwrap(projects.items.first { $0.representedObject as? String == "/generated" })
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(project.action), to: project.target, from: project))
            XCTAssertEqual(controller.toolsBar.folder, "/generated")
            XCTAssertTrue(controller.makeMoreMenu().items.contains { $0.title == L10n.text("tools.export") && $0.action != nil })
            XCTAssertNotNil(controller.makeMoreMenu().items.first { $0.title == L10n.text("tools.library") }?.submenu)
            for flags: NSEvent.ModifierFlags in [.command, [.command, .shift]] {
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: "b", charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11))
                XCTAssertFalse(controller.handleKey(event))
            }
            XCTAssertEqual(defaults.data(forKey: "file.basket"), legacy)
        }
    }
    func testGridSelectionFavoritesAndLayoutStayInSync() throws {
        _ = NSApplication.shared
        try preferences { defaults in
            let controller = SearchViewController(snapshot: true, preferences: defaults)
            let store = index(URL(fileURLWithPath: "/generated"), names: (1...8).map { "asset-\($0).jpg" })
            controller.view.frame = NSRect(origin: .zero, size: Theme.panelSize)
            try controller.prepareSnapshot(state: "results", query: "jpg", options: .init(), store: store, selection: 0)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: Theme.panelSize), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentViewController = controller
            controller.setGridMode(true); controller.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(controller.results.grid.count, 8)
            let collection = controller.results.grid.collection
            let flow = try XCTUnwrap(collection.collectionViewLayout as? AssetGridLayout)
            collection.layoutSubtreeIfNeeded()
            let first = try XCTUnwrap(flow.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)))
            let fourth = try XCTUnwrap(flow.layoutAttributesForItem(at: IndexPath(item: 3, section: 0)))
            XCTAssertEqual(first.frame.minY, fourth.frame.minY, "Collection: \(collection.frame), grid: \(controller.results.grid.frame), item: \(flow.itemSize), fourth: \(fourth.frame)")
            controller.results.select(1); XCTAssertEqual(controller.results.grid.collection.selectionIndexPaths, [IndexPath(item: 1, section: 0)])
            controller.toggleSelectedFileFavorite()
            XCTAssertTrue(controller.contextMenu().items.first { $0.identifier?.rawValue == "favorite" }?.state == .on)
            controller.setGridMode(false); XCTAssertEqual(controller.results.selectedRow, 1)
            controller.setGridMode(true); XCTAssertTrue(defaults.bool(forKey: "search.grid"))
            controller.projects.add("/generated"); XCTAssertTrue(controller.makeProjectMenu().items.contains { $0.representedObject as? String == "/generated" })
        }
    }
}
