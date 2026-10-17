import XCTest
import AppKit
import PDFKit
import Combine
import SQLite3
@testable import OilFindCore
import OilFindApp
@testable import LocalFindContent

final class ContentIntegrationTests: XCTestCase {
    var root: URL!, cache: URL!, defaults: UserDefaults!, settings: ContentSettings!, db: ContentDatabase!, engine: ContentEngine!
    override func setUpWithError() throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalFind-Fixture-" + UUID().uuidString)
        cache = FileManager.default.temporaryDirectory.appendingPathComponent("LocalFind-Cache-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "LocalFindTest-" + root.lastPathComponent)!
        settings = ContentSettings(defaults: defaults); settings.folders = [root.path]
        db = try ContentDatabase(url: cache.appendingPathComponent("content.sqlite"))
        engine = ContentEngine(database: db, settings: settings)
    }
    override func tearDownWithError() throws {
        engine.stop(); pump(0.1)
        engine = nil; db = nil
        defaults.removePersistentDomain(forName: "LocalFindTest-" + root.lastPathComponent)
        try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: cache)
    }
    func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    func write(_ name: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8); return url
    }
    func source(id: String = "startup", online: Bool = true) throws -> SearchSource {
        let config = IndexConfig(rootPath: root.path, indexSystemDirs: true)
        let scan = try XCTUnwrap(Scanner(config: config, threads: 1).run())
        let store = IndexStore(scan: scan, config: config); store.write { store.buildHash() }
        return SearchSource(id: id, displayName: "Fixture Disk", isOnline: online, store: store)
    }
    func index(_ source: SearchSource, timeout: Double = 25) throws {
        engine.updateSources([source]); pump(0.8)
        let until = Date().addingTimeInterval(timeout)
        while settings.running && Date() < until { pump(0.05) }
        XCTAssertFalse(settings.running, "Indexing did not finish")
        XCTAssertTrue(settings.error.isEmpty, settings.error)
    }
    func hits(_ text: String, source: SearchSource, options: SearchOptions = .init(), cancelled: @escaping () -> Bool = { false }) -> [SupplementaryHit] {
        ContentSearch.search(Query.parse(text), options: options, sources: [source], database: db,
                             folders: settings.folders, extraction: settings.options, cancelled: cancelled)
    }
    func testPersistentUnicodeSearchFiltersNegationAndChanges() throws {
        let a = try write("invoice.txt", "客户为小清妈。检索编号 jade739。café and 100%_literal")
        _ = try write("second.md", "jade739 secret")
        var src = try source(); try index(src)
        XCTAssertEqual(hits("jade739", source: src).count, 2)
        XCTAssertEqual(hits("小清妈", source: src).count, 1)
        XCTAssertEqual(hits("清妈", source: src).count, 1)
        XCTAssertEqual(hits("cafe", source: src).count, 1)
        XCTAssertEqual(hits("100%_literal", source: src).count, 1)
        XCTAssertEqual(hits("invoice jade739 ext:txt", source: src).count, 1)
        XCTAssertEqual(hits("jade739 !secret", source: src).count, 1)
        XCTAssertEqual(hits("jade739 !ext:md", source: src).count, 1)
        XCTAssertEqual(hits("case:jade739", source: src).count, 2)
        XCTAssertTrue(hits("case:JADE739", source: src).isEmpty)
        XCTAssertTrue(hits("jade739 ext:pdf", source: src).isEmpty)
        XCTAssertTrue(hits("jade739", source: src, options: .init(kind: 4)).isEmpty)
        XCTAssertTrue(hits("jade739", source: src, cancelled: { true }).isEmpty)
        let reopened = try ContentDatabase(url: cache.appendingPathComponent("content.sqlite"))
        XCTAssertEqual(try reopened.candidates(needles: ["jade739"], sources: ["startup"], cancelled: { false }).count, 2)
        let snippet = try XCTUnwrap(hits("小清妈", source: src).first).presentation
        XCTAssertTrue(snippet.text.contains("小清妈")); XCTAssertFalse(snippet.highlights.isEmpty)
        try "replacement quartz182 content".write(to: a, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: root.appendingPathComponent("second.md"))
        src = try source(); try index(src)
        XCTAssertTrue(hits("jade739", source: src).isEmpty)
        XCTAssertEqual(hits("quartz182", source: src).count, 1)
        try FileManager.default.moveItem(at: a, to: root.appendingPathComponent("renamed.txt"))
        src = try source(); try index(src)
        XCTAssertEqual(hits("quartz182", source: src).count, 1)
        settings.folders = []; engine.settingsChanged(); try index(src)
        XCTAssertTrue(hits("quartz182", source: src).isEmpty)
        XCTAssertEqual(try db.statistics().indexed, 0)
    }
    func testCapacityProbeDoesNotBlockMainThreadAndStopCancelsPendingIndex() throws {
        _ = try write("pending.txt", "probe739")
        let src = try source(), gate = DispatchSemaphore(value: 0)
        let entered = expectation(description: "probe started off main")
        engine.stop()
        engine = ContentEngine(database: db, settings: settings, availableCapacity: { _ in
            XCTAssertFalse(Thread.isMainThread)
            entered.fulfill(); _ = gate.wait(timeout: .now() + 3)
            return 1_000_000_000
        })
        defer { gate.signal() }
        engine.updateSources([src]); wait(for: [entered], timeout: 2)
        XCTAssertTrue(settings.running)
        let responsive = expectation(description: "main queue responds while probe is blocked")
        DispatchQueue.main.async { responsive.fulfill() }
        wait(for: [responsive], timeout: 0.3)
        engine.stop(); gate.signal(); pump(0.2)
        XCTAssertFalse(settings.running)
        XCTAssertEqual(try db.statistics().indexed, 0)
    }
    func testLowDiskGuardPreservesSearchableCache() throws {
        _ = try write("existing.txt", "cached739")
        let src = try source(); try index(src)
        engine.stop()
        engine = ContentEngine(database: db, settings: settings, availableCapacity: { _ in 0 })
        engine.updateSources([src]); pump(0.9)
        XCTAssertFalse(settings.running); XCTAssertFalse(settings.error.isEmpty)
        XCTAssertEqual(hits("cached739", source: src).count, 1)
        XCTAssertEqual(try db.statistics().indexed, 1)
    }
    func makeImage(_ text: String, at url: URL) throws {
        let image = NSImage(size: NSSize(width: 1500, height: 500), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            (text as NSString).draw(in: NSRect(x: 70, y: 100, width: 1360, height: 300), withAttributes: [.font: NSFont.systemFont(ofSize: 66), .foregroundColor: NSColor.black])
            return true
        }
        let data = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
    func testRealVisionOCRAndScannedPDF() throws {
        let imageURL = root.appendingPathComponent("receipt.png")
        try makeImage("LOCAL FIND\nInvoice AB739  Total 1280", at: imageURL)
        var opts = ExtractionOptions(); opts.labels = false
        let image = try ContentExtractor().extract(imageURL, options: opts)
        XCTAssertTrue(image.text.contains("AB739"), image.text)
        let pdf = PDFDocument(); pdf.insert(try XCTUnwrap(PDFPage(image: NSImage(contentsOf: imageURL)!)), at: 0)
        let url = root.appendingPathComponent("scan.pdf"); XCTAssertTrue(pdf.write(to: url))
        let scan = try ContentExtractor().extract(url, options: opts)
        XCTAssertTrue(scan.text.contains("AB739"), scan.text)
        settings.folders = []; settings.images = false
        let manualSource = try source(), manualID = try XCTUnwrap(manualSource.store.read { manualSource.store.resolve(path: url.path) })
        let manualProvider = ContentSearch(database: db, settings: settings, engine: engine)
        if case .ready(let preview) = manualProvider.preparePreview(source: manualSource, entryID: manualID, isCancelled: { false })() {
            XCTAssertTrue(preview.text.contains("AB739")); XCTAssertEqual(preview.segments.map(\.page), [1]); XCTAssertFalse(preview.isCached)
        } else { XCTFail("Scanned PDF should run OCR on explicit preview without index folders") }
        settings.folders = [root.path]; settings.images = true
        settings.labels = false
        let src = try source(); try index(src)
        XCTAssertEqual(hits("AB739", source: src).count, 2)
        let classification = try ContentExtractor().extract(imageURL, options: ExtractionOptions(images: false, labels: true, documents: false))
        XCTAssertEqual(classification.category, "image")
    }
    func testOfficeXMLAndTextPDF() throws {
        let fixtures: [(String, String, String)] = [
            ("report.docx", "word/document.xml", "<w:document xmlns:w='urn:w'><w:body><w:p><w:r><w:t>客户编号 DOCX739</w:t></w:r></w:p></w:body></w:document>"),
            ("slides.pptx", "ppt/slides/slide1.xml", "<p:sld xmlns:p='urn:p' xmlns:a='urn:a'><a:p><a:r><a:t>PPTX182 presentation</a:t></a:r></a:p></p:sld>"),
            ("sheet.xlsx", "xl/sharedStrings.xml", "<sst xmlns='urn:s'><si><t>XLSX456 金额</t></si></sst>"),
            ("writer.odt", "content.xml", "<o:document xmlns:o='urn:o' xmlns:t='urn:t'><t:p>ODT321 hello</t:p></o:document>")]
        for (name, member, xml) in fixtures {
            let dir = root.appendingPathComponent("zip-" + name)
            let file = dir.appendingPathComponent(member)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try xml.write(to: file, atomically: true, encoding: .utf8)
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = dir; process.arguments = ["-q", root.appendingPathComponent(name).path, member]
            try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
            try FileManager.default.removeItem(at: dir)
            let extracted = try ContentExtractor().extract(root.appendingPathComponent(name), options: .init())
            XCTAssertFalse(extracted.text.isEmpty)
        }
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.string = "Searchable PDF928 invoice"; view.font = NSFont.systemFont(ofSize: 30)
        try view.dataWithPDF(inside: view.bounds).write(to: root.appendingPathComponent("text.pdf"))
        XCTAssertTrue(try ContentExtractor().extract(root.appendingPathComponent("text.pdf"), options: .init()).text.contains("PDF928"))
        let src = try source(); try index(src)
        for word in ["DOCX739", "PPTX182", "XLSX456", "ODT321", "PDF928"] {
            XCTAssertEqual(hits(word, source: src).count, 1, word)
        }
    }
    func testManualPDFPreviewWithoutIndexFoldersExtractsPagesAndRejectsStaleCache() throws {
        let document = PDFDocument()
        for text in ["First page MANUAL739", "Second page MANUAL842"] {
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            view.string = text; view.font = .systemFont(ofSize: 30)
            document.insert(try XCTUnwrap(PDFDocument(data: view.dataWithPDF(inside: view.bounds))?.page(at: 0)), at: document.pageCount)
        }
        let url = root.appendingPathComponent("manual.pdf"); XCTAssertTrue(document.write(to: url))
        let src = try source(), id = try XCTUnwrap(src.store.read { src.store.resolve(path: url.path) })
        settings.folders = []; settings.enabled = false; settings.documents = false; settings.images = false
        let provider = ContentSearch(database: db, settings: settings, engine: engine)
        let work = provider.preparePreview(source: src, entryID: id, isCancelled: { false })
        let ready = expectation(description: "manual preview runs off main")
        DispatchQueue.global(qos: .userInitiated).async {
            if case .ready(let preview) = work() {
                XCTAssertFalse(preview.isCached); XCTAssertEqual(preview.segments.map(\.page), [1, 2])
                XCTAssertTrue(preview.text.contains("MANUAL842")); XCTAssertEqual(preview.sourceStamp, try? ContentExtractor.stamp(url))
            } else { XCTFail("A selected PDF must work without background indexing") }
            ready.fulfill()
        }
        wait(for: [ready], timeout: 10)
        XCTAssertTrue(settings.folders.isEmpty); XCTAssertFalse(settings.enabled)
        XCTAssertEqual(try db.statistics().indexed, 0, "Manual preview must not opt the folder into background indexing")
        if case .cancelled = provider.preparePreview(source: src, entryID: id, isCancelled: { true })() {} else { XCTFail("Cancelled request ran") }
        let offline = SearchSource(id: src.id, displayName: "Offline", isOnline: false, store: src.store)
        if case .unavailable(let reason) = provider.preparePreview(source: offline, entryID: id, isCancelled: { false })() { XCTAssertTrue(reason.contains("offline")) } else { XCTFail("Offline file without cache") }
        settings.enabled = true; settings.documents = true; settings.images = true; settings.folders = [root.path]
        try index(src)
        let cached = try XCTUnwrap(db.record(source: src.id, path: "/manual.pdf"))
        XCTAssertFalse(cached.text.isEmpty)
        document.removePage(at: 0); XCTAssertTrue(document.write(to: url))
        if case .ready(let preview) = provider.preparePreview(source: src, entryID: id, isCancelled: { false })() {
            XCTAssertFalse(preview.isCached); XCTAssertFalse(preview.text.contains("MANUAL739")); XCTAssertEqual(preview.segments.map(\.page), [1])
        } else { XCTFail("Changed file should be extracted again before the name index refreshes") }
    }
    func testManualPreviewFailuresAreActionable() throws {
        let encrypted = PDFDocument()
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200)); view.string = "Locked text"
        encrypted.insert(try XCTUnwrap(PDFDocument(data: view.dataWithPDF(inside: view.bounds))?.page(at: 0)), at: 0)
        XCTAssertTrue(encrypted.write(to: root.appendingPathComponent("locked.pdf"), withOptions: [.userPasswordOption: "test", .ownerPasswordOption: "owner"]))
        _ = try write("broken.pdf", "not a PDF")
        _ = try write("unsupported.bin", "bytes")
        _ = try write("empty.txt", "   ")
        let src = try source(); settings.folders = []
        let provider = ContentSearch(database: db, settings: settings, engine: engine)
        for (name, reason) in [("locked.pdf", "Encrypted PDF"), ("broken.pdf", "Malformed"), ("unsupported.bin", "not supported"), ("empty.txt", "No text found")] {
            let id = try XCTUnwrap(src.store.read { src.store.resolve(path: root.appendingPathComponent(name).path) })
            if case .unavailable(let message) = provider.preparePreview(source: src, entryID: id, isCancelled: { false })() {
                XCTAssertTrue(message.contains(reason), message)
            } else { XCTFail("Expected actionable reason for " + name) }
        }
    }
    func testPDFPositionsPersistMigrateAndRemainAvailableOffline() throws {
        let document = PDFDocument()
        for (number, text) in ["First page SEARCH739", "Second page SEARCH842"].enumerated() {
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            view.string = text; view.font = .systemFont(ofSize: 30)
            let page = try XCTUnwrap(PDFDocument(data: view.dataWithPDF(inside: view.bounds))?.page(at: 0))
            document.insert(page, at: number)
        }
        let url = root.appendingPathComponent("positions.pdf")
        XCTAssertTrue(document.write(to: url))
        let src = try source(); try index(src)
        let row = try XCTUnwrap(db.record(source: "startup", path: "/positions.pdf"))
        XCTAssertEqual(row.segments.map(\.page), [1, 2])
        let second = (row.text as NSString).range(of: "SEARCH842")
        XCTAssertTrue(NSLocationInRange(second.location, NSRange(location: row.segments[1].offset, length: row.segments[1].length)))
        let reopened = try ContentDatabase(url: cache.appendingPathComponent("content.sqlite"))
        XCTAssertEqual(try reopened.record(source: "startup", path: "/positions.pdf")?.segments, row.segments)
        var legacy = row; legacy.segments = []; legacy.fingerprint = legacy.fingerprint.replacingOccurrences(of: "#positions-v2", with: "")
        try db.put(legacy); try index(src)
        XCTAssertEqual(try db.record(source: "startup", path: "/positions.pdf")?.segments.map(\.page), [1, 2])
        let provider = ContentSearch(database: db, settings: settings, engine: engine)
        let id = try XCTUnwrap(src.store.read { src.store.resolve(path: url.path) })
        let preview = try XCTUnwrap(provider.preparePreview(source: src, entryID: id)())
        XCTAssertEqual(preview.sourceStamp, try ContentExtractor.stamp(url))
        let offline = SearchSource(id: "startup", displayName: "Archive", isOnline: false, store: src.store)
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(provider.preparePreview(source: offline, entryID: id)()?.segments.map(\.page), [1, 2])

        let oldURL = cache.appendingPathComponent("old-schema.sqlite")
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(oldURL.path, &raw), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, "CREATE TABLE documents(source TEXT NOT NULL,path TEXT NOT NULL,fingerprint TEXT NOT NULL,text TEXT NOT NULL,category TEXT NOT NULL,note TEXT NOT NULL,mtime INTEGER NOT NULL,size INTEGER NOT NULL,UNIQUE(source,path)); INSERT INTO documents VALUES('startup','/old.txt','old','retained','text','',0,0)", nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)
        let migrated = try ContentDatabase(url: oldURL)
        XCTAssertEqual(try migrated.record(source: "startup", path: "/old.txt")?.text, "retained")
        XCTAssertEqual(try migrated.record(source: "startup", path: "/old.txt")?.segments, [])
    }
    func testOfflineCatalogSurvivesMissingOriginalFiles() throws {
        _ = try write("offline.txt", "Disconnected drive token offline842")
        let src = try source(id: "fixture-volume"); try index(src)
        let catalog = cache.appendingPathComponent("volume.oilfind"); try src.store.save(to: catalog.path)
        try FileManager.default.removeItem(at: root.appendingPathComponent("offline.txt"))
        let loaded = try XCTUnwrap(IndexStore.load(from: catalog.path)); loaded.write { loaded.buildHash() }
        let offline = SearchSource(id: "fixture-volume", displayName: "Archive", isOnline: false, store: loaded)
        XCTAssertEqual(hits("offline842", source: offline).count, 1)
        let names = Searcher.search(Query.parse("offline"), in: loaded)
        XCTAssertEqual(names?.total, 1)
        XCTAssertFalse(offline.isOnline)
    }
    private final class CatalogFixture: ExternalDriveCatalogReading {
        var knownDrives = [ExternalDriveInfo]()
        let subject = PassthroughSubject<Void, Never>()
        var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }
    }
    func testExtensionLoadsAndWithdrawsOfflineDrive() throws {
        _ = try write("catalog.txt", "archive" )
        let uuid = UUID().uuidString
        try index(source(id: uuid))
        let config = IndexConfig(rootPath: root.path, excludedNames: IndexConfig.standard().excludedNames)
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        store.configFingerprint = config.fingerprint(volumeUUID: uuid)
        let catalogURL = cache.appendingPathComponent("external.oilfind")
        try store.save(to: catalogURL.path)
        let catalog = CatalogFixture()
        let disconnected = ExternalDriveInfo(id: uuid, name: "Archive", path: root.path, enabled: true, isConnected: false, catalogURL: catalogURL)
        catalog.knownDrives = [disconnected]
        let ext = LocalFindExtension(dataDirectory: cache, defaults: defaults)
        ext.attachExternalDrives(catalog)
        defer { ext.stop() }
        let deadline = Date().addingTimeInterval(5)
        while ext.searchSources().isEmpty && Date() < deadline { pump(0.05) }
        XCTAssertEqual(ext.searchSources().count, 1)
        XCTAssertFalse(try XCTUnwrap(ext.searchSources().first).isOnline)
        XCTAssertTrue(try XCTUnwrap(ext.searchSources().first).store.hashReady)
        let contentHits = try XCTUnwrap(ext.supplementarySearchProvider).prepareSearch(Query.parse("archive"), options: .init(), sources: ext.searchSources(), isCancelled: { false })()
        XCTAssertEqual(contentHits.count, 1)
        catalog.knownDrives = [ExternalDriveInfo(id: uuid, name: "Archive", path: root.path, enabled: true, isConnected: true, catalogURL: catalogURL)]
        catalog.subject.send()
        XCTAssertTrue(ext.searchSources().isEmpty, "Reconnect must withdraw the offline source before online publication")
        catalog.knownDrives = [disconnected]; catalog.subject.send()
        pump(0.3); ext.settings.offline = false
        XCTAssertTrue(ext.searchSources().isEmpty)
    }
    func testExportDemoArtifacts() throws {
        guard let path = ProcessInfo.processInfo.environment["LOCALFIND_DEMO_OUTPUT"] else { throw XCTSkip("Optional UI fixture export") }
        let destination = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let docs = destination.appendingPathComponent("演示资料")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try "秋季水晶饰品发布计划\n产品摄影预算：1280 元。内容检索在这台 Mac 上完成。".write(to: docs.appendingPathComponent("项目纪要.md"), atomically: true, encoding: .utf8)
        let imageURL = docs.appendingPathComponent("购物小票.png")
        try makeImage("LOCAL FIND\nInvoice AB739  Total 1280", at: imageURL)
        let pdf = PDFDocument(); pdf.insert(try XCTUnwrap(PDFPage(image: NSImage(contentsOf: imageURL)!)), at: 0)
        XCTAssertTrue(pdf.write(to: docs.appendingPathComponent("扫描凭证.pdf")))
        let prefs = UserDefaults(suiteName: "app.localfind.demo")!
        prefs.set([docs.path], forKey: "content.folders"); prefs.set(false, forKey: "content.labels")
        let demoSettings = ContentSettings(defaults: prefs)
        let demoDB = try ContentDatabase(url: destination.appendingPathComponent("content.sqlite"))
        let demoEngine = ContentEngine(database: demoDB, settings: demoSettings)
        let config = IndexConfig(rootPath: docs.path)
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        store.write { store.buildHash() }
        try store.save(to: destination.appendingPathComponent("index.oilfind").path)
        let source = SearchSource(id: "startup", displayName: "", isOnline: true, store: store)
        demoEngine.updateSources([source]); pump(0.8)
        let end = Date().addingTimeInterval(30)
        while demoSettings.running && Date() < end { pump(0.05) }
        demoEngine.stop()
        XCTAssertFalse(demoSettings.running)
        XCTAssertEqual(try demoDB.statistics().indexed, 3)
        XCTAssertEqual(ContentSearch.search(Query.parse("1280"), options: .init(), sources: [source], database: demoDB, folders: [docs.path], extraction: demoSettings.options, cancelled: { false }).count, 3)
    }
    func testBoundsCorruptFilesAndCancelledExtraction() throws {
        let text = try write("safe.txt", "hello")
        XCTAssertThrowsError(try ContentExtractor().extract(text, options: .init(), cancelled: { true }))
        let broken = try write("bad.pdf", "this is not a pdf")
        XCTAssertThrowsError(try ContentExtractor().extract(broken, options: .init()))
        let huge = root.appendingPathComponent("large.txt")
        FileManager.default.createFile(atPath: huge.path, contents: nil)
        let handle = try FileHandle(forWritingTo: huge); try handle.truncate(atOffset: UInt64(ContentExtractor.maxBytes + 1)); try handle.close()
        XCTAssertThrowsError(try ContentExtractor.stamp(huge))
        let link = root.appendingPathComponent("symlink.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: text)
        XCTAssertThrowsError(try ContentExtractor.stamp(link))
        let src = try source(); try index(src)
        XCTAssertGreaterThanOrEqual(settings.skipped, 2)
        XCTAssertEqual(hits("hello", source: src).count, 1)
    }
    func testContentOnlyRequiresAllWordsInTextAndSupportsFilterOnly() throws {
        _ = try write("invoice.txt", "jade739 only")
        _ = try write("memo.txt", "invoice jade739 together")
        let src = try source(); try index(src)
        func only(_ query: String) -> [SupplementaryHit] {
            ContentSearch.search(Query.parse(query), options: .init(), sources: [src], database: db,
                                 folders: settings.folders, extraction: settings.options, contentOnly: true, cancelled: { false })
        }
        XCTAssertEqual(hits("invoice jade739", source: src).count, 2)
        XCTAssertEqual(only("invoice jade739").count, 1)
        XCTAssertEqual(only("jade739 !invoice").count, 1)
        XCTAssertEqual(only("ext:txt").count, 2)
        XCTAssertEqual(only("").count, 2)
    }
    func testPauseKeepsCachedSearchAndResumeIndexesNewFiles() throws {
        _ = try write("first.txt", "pause739")
        var src = try source(); try index(src)
        settings.paused = true; engine.settingsChanged()
        _ = try write("second.txt", "resume821")
        src = try source(); try index(src)
        let provider = ContentSearch(database: db, settings: settings, engine: engine)
        XCTAssertTrue(provider.isEnabled)
        XCTAssertEqual(hits("pause739", source: src).count, 1)
        XCTAssertTrue(hits("resume821", source: src).isEmpty)
        XCTAssertTrue(ContentSettings(defaults: defaults).paused)
        settings.paused = false; engine.settingsChanged(); try index(src)
        XCTAssertEqual(hits("resume821", source: src).count, 1)
    }
    func testOfflineFullTextPreviewRejectsStaleMetadataAndExcludedFolders() throws {
        let url = try write("cached.txt", "Full extracted content preview739")
        let online = try source(id: "disk"); try index(online)
        let id = try XCTUnwrap(online.store.read { online.store.resolve(path: url.path) })
        let provider = ContentSearch(database: db, settings: settings, engine: engine)
        try FileManager.default.removeItem(at: url)
        let offline = SearchSource(id: "disk", displayName: "Archive", isOnline: false, store: online.store)
        let preview = try XCTUnwrap(provider.preparePreview(source: offline, entryID: id)())
        XCTAssertEqual(preview.text, "Full extracted content preview739"); XCTAssertFalse(preview.isOnline)
        settings.folders = []
        XCTAssertNil(provider.preparePreview(source: offline, entryID: id)())
        settings.folders = [root.path]
        online.store.write { online.store.mtime[Int(id)] += 1 }
        XCTAssertNil(provider.preparePreview(source: offline, entryID: id)())
    }
    func testDiagnosticRetryPreservesPartialTextThenReextracts() throws {
        let url = try write("partial.txt", "complete after retry739")
        let src = try source(); try index(src)
        var row = try XCTUnwrap(db.record(source: "startup", path: "/partial.txt"))
        row.text = "old partial739"; row.note = "text-limit"; try db.put(row)
        XCTAssertEqual(try db.diagnostics().first?.note, "text-limit")
        try db.retryIncomplete()
        XCTAssertEqual(hits("partial739", source: src).count, 1)
        XCTAssertTrue(try XCTUnwrap(db.record(source: "startup", path: "/partial.txt")).fingerprint.hasPrefix("retry:"))
        try index(src)
        XCTAssertEqual(hits("retry739", source: src).count, 1)
        XCTAssertTrue(try db.diagnostics().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
    func testChineseOCR() throws {
        let image = root.appendingPathComponent("中文.png")
        try makeImage("项目预算 1280 元\n水晶摄影 合同编号 739", at: image)
        let result = try ContentExtractor().extract(image, options: ExtractionOptions(images: true, labels: false, documents: false))
        XCTAssertTrue(result.text.contains("项目预算"), result.text)
        XCTAssertTrue(result.text.contains("水晶"), result.text)
    }
}
