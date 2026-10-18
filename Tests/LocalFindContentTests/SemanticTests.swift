import XCTest
import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import OilFindCore
import OilFindApp
import FoxFindSemanticCore
@testable import LocalFindContent

final class SemanticTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FoxSemanticTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at:root) }
    private func vector(_ value: Float = 1) -> [Float] { [value] + [Float](repeating:0,count:767) }
    private func file(_ name: String = "one.pdf", stamp: String = "a") -> SemanticFile {
        SemanticFile(source:"fixture",path:root.appendingPathComponent(name).path,stamp:stamp,mtime:1,size:100)
    }
    func testCheckpointReopenVersionAndChangedFileDropStaleVectors() throws {
        let url = root.appendingPathComponent("index.sqlite"), f = file()
        do {
            let db = try SemanticDatabase(url:url); try db.prepare(f)
            try db.append([SemanticPiece(ordinal:0,page:1,text:"第一段",image:false,vector:vector())],to:f,cursor:1,done:false)
        }
        let db = try SemanticDatabase(url:url)
        XCTAssertEqual(try db.progress(f)?.cursor,1); XCTAssertEqual(try db.progress(f)?.done,false)
        try db.prepare(f)
        try db.append([SemanticPiece(ordinal:1000,page:2,text:"第二段",image:false,vector:vector(0.9))],to:f,cursor:2,done:true)
        XCTAssertEqual(try db.stats().pieces,2)
        let matches = try db.search(vector:vector(),cancelled:{false},accepts:{_ in true})
        XCTAssertEqual(matches.count,1); XCTAssertEqual(matches.first?.page,1)
        let changed = file(stamp:"b"); try db.prepare(changed)
        XCTAssertEqual(try db.stats().pieces,0); XCTAssertNil(try db.progress(f))
        XCTAssertThrowsError(try db.append([],to:f,cursor:3,done:true))
        XCTAssertEqual(try db.progress(changed)?.cursor,0)
    }
    func testStreamingTopKConstraintsCancellationAndImageThreshold() throws {
        let db = try SemanticDatabase(url:root.appendingPathComponent("index.sqlite"))
        for i in 0..<120 {
            let f = file("\(i).png"); try db.prepare(f)
            try db.append([SemanticPiece(ordinal:0,page:0,text:"",image:true,vector:vector(1-Float(i)/200))],to:f,cursor:1,done:true)
        }
        let found = try db.search(vector:vector(),imagesOnly:true,limit:5,cancelled:{false},accepts:{ !$0.path.hasSuffix("0.png") })
        XCTAssertEqual(found.count,5); XCTAssertTrue(found[0].score >= found[4].score)
        XCTAssertFalse(found.contains { $0.file.path.hasSuffix("0.png") })
        XCTAssertTrue(try db.search(vector:vector(),cancelled:{true},accepts:{_ in true}).isEmpty)
        XCTAssertTrue(try db.search(vector:[.nan],cancelled:{false},accepts:{_ in true}).isEmpty)
        try db.removeMissing(source:"fixture",paths:[file("1.png").path]); XCTAssertEqual(try db.stats().files,1)
        try db.purge(folders:[root.appendingPathComponent("different").path]); XCTAssertEqual(try db.stats().pieces,0)
    }
    func testStructuredQueryEligibilityAndUnicodeChunkCoverage() {
        XCTAssertEqual(SemanticSearch.phrase(.parse("白色水晶 ext:png !ext:jpg")),"白色水晶")
        for raw in ["", "a", "foo|bar", "\"exact phrase\"", "*", "file*.png", "regex:abc", "摄影 !secret"] { XCTAssertNil(SemanticSearch.phrase(.parse(raw)),raw) }
        let text = String(repeating:"白色水晶💎",count:1000), chunks = SemanticEngine.chunks(text)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 800 }); XCTAssertTrue(chunks.last!.hasSuffix("水晶💎"))
        XCTAssertEqual(chunks[0].suffix(80),chunks[1].prefix(80)); XCTAssertTrue(SemanticEngine.chunks("").isEmpty)
    }
    func testLexicalReaderDoesNotBlockWriter() throws {
        let db = try ContentDatabase(url:root.appendingPathComponent("content.sqlite"))
        let record = ContentRecord(source:"a",path:"/a",fingerprint:"a",text:"水晶",category:"text",note:"",mtime:1,size:4)
        try db.put(record)
        let entered = expectation(description:"read snapshot"), wrote = expectation(description:"writer completed")
        let release = DispatchSemaphore(value:0), done = expectation(description:"reader finished")
        DispatchQueue.global().async {
            try? db.visitCandidates(needles:["水晶"],sources:["a"],cancelled:{false}) { _ in
                entered.fulfill(); _ = release.wait(timeout:.now()+3); return false
            }; done.fulfill()
        }
        wait(for:[entered],timeout:2)
        DispatchQueue.global().async { try? db.put(record); wrote.fulfill() }
        wait(for:[wrote],timeout:1); release.signal(); wait(for:[done],timeout:2)
    }
    func testMissingFoldersAreExplainedAndDoNotLaunchSemanticQueries() throws {
        let defaults = UserDefaults(suiteName: "FoxSemanticSetup-" + UUID().uuidString)!
        let settings = ContentSettings(defaults: defaults); settings.semanticEnabled = true; settings.chinese = true
        let db = try ContentDatabase(url: root.appendingPathComponent("content.sqlite"))
        let content = ContentSearch(database: db, settings: settings, engine: ContentEngine(database: db, settings: settings))
        XCTAssertFalse(content.supportsSimilarity)
        XCTAssertEqual(content.semanticStatus?.title, "还没有添加内容文件夹")
        XCTAssertNil(content.prepareSemantic(.parse("水晶如何布光"), options: .init(), sources: [], isCancelled: { false }))
        settings.folders = [root.path]; settings.semanticEnabled = false
        XCTAssertEqual(content.semanticStatus?.title, "按描述和相似图片搜索尚未开启")
    }
    func testContentCoverageDistinguishesOutsideScopeFromAnEmptyIndexedFolder() throws {
        let suite = "FoxCoverage-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ContentSettings(defaults: defaults); settings.chinese = true
        settings.folders = ["/fixture/Downloads"]; settings.enabled = true; settings.semanticEnabled = true
        let db = try ContentDatabase(url: root.appendingPathComponent("scope.sqlite"))
        let provider = ContentSearch(database: db, settings: settings, engine: ContentEngine(database: db, settings: settings))
        XCTAssertEqual(provider.contentStatus(in: "/fixture/Desktop")?.title, "这个文件夹还没有识别内容")
        XCTAssertEqual(provider.contentStatus(in: "/fixture/Downloads-other")?.canSearch, false)
        XCTAssertEqual(provider.contentStatus(in: "/fixture/Downloads/project")?.title, provider.semanticStatus?.title)
        XCTAssertEqual(provider.contentStatus(in: "/fixture")?.title, provider.semanticStatus?.title)
        settings.semanticFiles = 25; settings.semanticRunning = true
        XCTAssertTrue(provider.semanticStatus?.summary.contains("25") == true)
        XCTAssertTrue(provider.semanticStatus?.summary.contains("仍在继续") == true)
        XCTAssertEqual(provider.semanticStatus?.folders, ["/fixture/Downloads"])
    }
    func testExactIdentifiersSkipEmbeddingButDescriptionsKeepHardAlternatives() {
        for input in ["P202601092289", "report.pdf", "2026_budget", "report-2026.pdf kind:doc", "白色水晶 !合同", "foo|bar"] {
            XCTAssertNil(SemanticSearch.phrase(.parse(input)), input)
        }
        XCTAssertEqual(SemanticSearch.phrase(.parse("白色背景 kind:image|kind:video size:<=2mb")), "白色背景")
        XCTAssertEqual(SemanticSearch.phrase(.parse("白色背景 path:微信|path:wechat|path:weixin dm:month7")), "白色背景")
        XCTAssertEqual(SemanticSearch.phrase(.parse("red crystal on white background kind:image")), "red crystal on white background")
    }
    private func runtime() throws -> (URL, URL) {
        let env = ProcessInfo.processInfo.environment
        guard let model = env["FOX_FIND_TEST_MODELS"], let helper = env["FOX_FIND_TEST_HELPER"] else { throw XCTSkip("Set FOX_FIND_TEST_MODELS and FOX_FIND_TEST_HELPER for real-model acceptance") }
        return (URL(fileURLWithPath:helper),URL(fileURLWithPath:model))
    }
    func testRealModelChineseRetrievalAndBoundedCancellation() throws {
        let (helper,models) = try runtime()
        let worker = SemanticWorkerClient(executable:helper,models:models,textOnly:true); defer { worker.close() }
        let vectors = try worker.embed([Prompts.query("水晶拍摄如何布光"),Prompts.document(title:"摄影",text:"使用柔光箱与侧逆光拍摄水晶，控制镜面反射，让晶体通透。"),Prompts.document(title:"合同",text:"房屋租赁合同约定每月租金和押金。")])
        func dot(_ a:[Float],_ b:[Float]) -> Float { zip(a,b).reduce(0) { $0+$1.0*$1.1 } }
        XCTAssertGreaterThan(dot(vectors[0],vectors[1]),dot(vectors[0],vectors[2])+0.1)
        worker.close(); let start = Date()
        XCTAssertThrowsError(try worker.embed(["test"],cancelled:{ Date().timeIntervalSince(start)>0.15 }))
        XCTAssertLessThan(Date().timeIntervalSince(start),0.5)
    }
    func testRealModelPDFBatchResumesAndKeepsPhysicalPage() throws {
        let (helper,models) = try runtime()
        let url = root.appendingPathComponent("many-pages.pdf")
        let data = NSMutableData(), consumer = CGDataConsumer(data:data)!
        var box = CGRect(x:0,y:0,width:400,height:500)
        let context = CGContext(consumer:consumer,mediaBox:&box,nil)!
        for i in 1...13 {
            context.beginPDFPage(nil)
            let content = i == 13 ? "Crystal product photography uses soft lighting and backlighting to reveal transparency." : "The apartment rental agreement specifies the deposit, monthly rent and lease duration."
            let line = CTLineCreateWithAttributedString(NSAttributedString(string:content,attributes:[.font:NSFont.systemFont(ofSize:10)]))
            context.textPosition = CGPoint(x:15,y:400); CTLineDraw(line,context); context.endPDFPage()
        }
        context.closePDF(); try (data as Data).write(to:url)
        let f = SemanticFile(source:"fixture",path:url.path,stamp:try ContentExtractor.stamp(url),mtime:1,size:UInt64(data.length))
        let db = try SemanticDatabase(url:root.appendingPathComponent("index.sqlite")); try db.prepare(f)
        let worker = SemanticWorkerClient(executable:helper,models:models,textOnly:false); defer { worker.close() }
        XCTAssertFalse(try SemanticEngine.indexBatch(file:f,database:db,worker:worker,cancelled:{false}))
        XCTAssertEqual(try db.progress(f)?.cursor,12)
        XCTAssertTrue(try SemanticEngine.indexBatch(file:f,database:db,worker:worker,cancelled:{false}))
        XCTAssertEqual(try db.stats().pieces,13)
        let q = try worker.embed([Prompts.query("水晶产品拍摄的灯光")])[0]
        let result = try db.search(vector:q,cancelled:{false},accepts:{_ in true})
        XCTAssertEqual(result.first?.page,13)
    }
    func testRealImageAndDocumentPipelineWithFiltersAndOfflineCache() throws {
        let (helper,modelsURL) = try runtime()
        let docs = root.appendingPathComponent("docs"); try FileManager.default.createDirectory(at:docs,withIntermediateDirectories:true)
        let reference = try XCTUnwrap(Bundle.module.url(forResource:"landscape",withExtension:"jpg",subdirectory:"Fixtures"))
        let screen = try XCTUnwrap(Bundle.module.url(forResource:"screen",withExtension:"png",subdirectory:"Fixtures"))
        try FileManager.default.copyItem(at:reference,to:docs.appendingPathComponent("landscape.jpg"))
        try FileManager.default.copyItem(at:screen,to:docs.appendingPathComponent("screen.png"))
        let input = try XCTUnwrap(CGImageSourceCreateWithURL(reference as CFURL,nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(input,0,nil))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(docs.appendingPathComponent("camera.heic") as CFURL,UTType.heic.identifier as CFString,1,nil))
        CGImageDestinationAddImage(destination,image,nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        try "使用柔光箱与侧逆光拍摄水晶，控制反射，让晶体通透。".write(to:docs.appendingPathComponent("crystal.txt"),atomically:true,encoding:.utf8)
        let config = IndexConfig(rootPath:docs.path)
        let scan = try XCTUnwrap(Scanner(config:config,threads:1).run()), store = IndexStore(scan:scan,config:config)
        store.write { store.buildHash() }
        let source = SearchSource(id:"fixture",displayName:"Fixture",isOnline:true,store:store)
        let db = try SemanticDatabase(url:root.appendingPathComponent("semantic.sqlite"))
        let worker = SemanticWorkerClient(executable:helper,models:modelsURL,textOnly:false)
        for item in ContentEngine.candidates(source,folders:[docs.path],options:.init(),cancelled:{false}) {
            let file = SemanticFile(source:item.source,path:item.path,stamp:try ContentExtractor.stamp(URL(fileURLWithPath:item.path)),mtime:item.mtime,size:item.size)
            try db.prepare(file); XCTAssertTrue(try SemanticEngine.indexBatch(file:file,database:db,worker:worker,cancelled:{false}))
        }
        worker.close()
        let suite = "FoxSemanticPipeline-" + UUID().uuidString, defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let settings = ContentSettings(defaults:defaults); settings.folders = [docs.path]; settings.semanticEnabled = true
        let models = SemanticModels(directory:modelsURL); models.ready = true
        let engine = SemanticEngine(database:db,settings:settings,models:models,helper:helper)
        let search = SemanticSearch(database:db,engine:engine); defer { search.close(); engine.stop() }
        func hits(_ query: Query, offline: Bool = false, accepts: @escaping SupplementaryFileFilter = { _,_ in true }) -> [SupplementaryHit] {
            search.prepare(query,options:.init(),sources:[SearchSource(id:source.id,displayName:source.displayName,isOnline:!offline,store:store)],accepts:accepts,cancelled:{false})()
        }
        let text = "水晶产品拍摄如何布光 ext:txt"
        let result = hits(.parse(text)); XCTAssertEqual(result.count,1)
        XCTAssertEqual(store.name(try XCTUnwrap(result.first?.entryID)),"crystal.txt")
        XCTAssertEqual(hits(.parse(text),offline:true).count,1)
        XCTAssertTrue(hits(.parse(text + " !crystal")).isEmpty)
        XCTAssertTrue(hits(.parse(text).scoped(to:root.appendingPathComponent("other").path)).isEmpty)
        XCTAssertTrue(hits(.parse(text),accepts:{_,_ in false}).isEmpty)
        let similar = search.prepare(.parse("*"),options:.init(kind:4),sources:[source],image:reference.path,cancelled:{false})()
        XCTAssertEqual(Set(similar.map { store.name($0.entryID) }),Set(["landscape.jpg","camera.heic"]),"Camera HEIC must work; unrelated screen must not be similar")
        let photos = hits(.parse("蓝天太阳和绿色山丘的风景图片 ext:jpg"))
        XCTAssertEqual(store.name(try XCTUnwrap(photos.first?.entryID)),"landscape.jpg")
    }
    func testMetadataEligibilityPrecedesTopK() throws {
        let db = try SemanticDatabase(url:root.appendingPathComponent("semantic.sqlite"))
        for i in 0..<100 {
            let f = file("\(i).png"); try db.prepare(f)
            try db.append([SemanticPiece(ordinal:0,page:0,text:"",image:true,vector:vector(1-Float(i)/1000))],to:f,cursor:1,done:true)
        }
        let matches = try db.search(vector:vector(),imagesOnly:true,limit:3,cancelled:{false},qualifies: { $0.file.path.hasSuffix("99.png") },accepts:{_ in true})
        XCTAssertEqual(matches.count,1); XCTAssertTrue(matches[0].file.path.hasSuffix("99.png"))
    }

}
