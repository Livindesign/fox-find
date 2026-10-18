import AppKit
import Foundation
import PDFKit
import OilFindApp
import OilFindCore
import FoxFindSemanticCore

final class SemanticEngine {
    let database: SemanticDatabase, settings: ContentSettings, models: SemanticModels
    let helper: URL
    let budget: BackgroundWorkBudget
    private let queue = DispatchQueue(label: "app.localfind.semantic.index",qos: .utility)
    private var sources = [SearchSource](), token: ContentCancellation?
    private var pending: DispatchWorkItem?, running = false, dirty = false, stopped = false
    private var lastInteraction = Date.distantPast
    var onResultsChange: (() -> Void)?
    init(database: SemanticDatabase, settings: ContentSettings, models: SemanticModels, helper: URL, budget: BackgroundWorkBudget = BackgroundWorkBudget()) {
        self.database = database; self.settings = settings; self.models = models; self.helper = helper; self.budget = budget
    }
    func updateSources(_ sources: [SearchSource]) { self.sources = sources; request() }
    func settingsChanged() { token?.cancel(); request() }
    func userActivity(typing: Bool) { if typing { budget.userActivity(); lastInteraction = Date(); token?.cancel(); request(delay: 8) } }
    func stop() { stopped = true; token?.cancel(); pending?.cancel() }
    func clear() {
        token?.cancel()
        queue.async { [weak self] in
            guard let self else { return }
            do { try self.database.clear() } catch { DispatchQueue.main.async { self.settings.semanticError = error.localizedDescription } }
            DispatchQueue.main.async { self.refreshStats(); self.onResultsChange?(); self.request() }
        }
    }
    func request(delay: Double = 2) {
        guard !stopped else { return }
        if running { dirty = true; return }
        pending?.cancel(); let item = DispatchWorkItem { [weak self] in self?.begin() }; pending = item
        DispatchQueue.main.asyncAfter(deadline:.now() + delay,execute:item)
    }
    func refreshStats() {
        queue.async { [weak self] in
            guard let self, let stats = try? self.database.stats() else { return }
            DispatchQueue.main.async { self.settings.semanticFiles = stats.files; self.settings.semanticPieces = stats.pieces; self.settings.semanticIncomplete = stats.incomplete }
        }
    }
    private func begin() {
        guard !stopped, !running else { return }
        guard settings.enabled, settings.semanticEnabled, !settings.paused, models.ready, !settings.folders.isEmpty else { return }
        if Date().timeIntervalSince(lastInteraction) < 8 { request(delay: 8); return }
        if ProcessInfo.processInfo.isLowPowerModeEnabled || [.serious,.critical].contains(ProcessInfo.processInfo.thermalState) {
            settings.semanticStatus = settings.text("节能或设备温度较高，语义索引暂缓", "Semantic indexing waiting for power or temperature"); request(delay: 30); return
        }
        let token = ContentCancellation()
        guard budget.beginBackground(token) else { request(delay: 8); return }
        running = true; dirty = false; settings.semanticRunning = true; settings.semanticError = ""
        self.token = token
        let sources = sources, folders = settings.folders, options = settings.options, db = database
        let helper = helper, models = models.directory, budget = budget
        queue.async { [weak self] in
            let worker = SemanticWorkerClient(executable: helper,models: models,textOnly: false)
            var changed = false
            defer {
                worker.close()
                budget.endBackground(token)
                DispatchQueue.main.async {
                    guard let self else { return }; self.running = false; self.settings.semanticRunning = false
                    self.settings.semanticStatus = ""; self.refreshStats()
                    if changed { self.onResultsChange?() }; if self.dirty || token.cancelled { self.request(delay: 8) }
                }
            }
            budget.prepareBackground?()
            let cancelled = { token.cancelled || ProcessInfo.processInfo.isLowPowerModeEnabled || [.serious,.critical].contains(ProcessInfo.processInfo.thermalState) }
            do {
                let capacity = try? db.url.deletingLastPathComponent().resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
                if let capacity, capacity < 1_000_000_000 { throw SemanticError.unavailable("Less than 1 GB free; semantic indexing paused.") }
                try db.purge(folders: folders)
                var work = [(ContentCandidate,SemanticFile)]()
                for source in sources where source.isOnline {
                    let candidates = ContentEngine.candidates(source,folders: folders,options: ExtractionOptions(images:true,labels:false,documents:options.documents),cancelled:cancelled)
                    if cancelled() { throw SemanticError.cancelled }
                    try db.removeMissing(source: source.id, paths: Set(candidates.map(\.path)))
                    for item in candidates {
                        if cancelled() { throw SemanticError.cancelled }
                        let url = URL(fileURLWithPath:item.path)
                        guard let stamp = try? ContentExtractor.stamp(url) else { continue }
                        let f = SemanticFile(source:item.source,path:item.path,stamp:stamp,mtime:item.mtime,size:item.size)
                        if try db.progress(f)?.done != true { work.append((item,f)) }
                    }
                }
                // Give every file an initial searchable batch before resuming long documents.
                var lastPublish = Date.distantPast
                while !work.isEmpty {
                    var unfinished = [(ContentCandidate,SemanticFile)]()
                    for (item,f) in work {
                        if cancelled() { throw SemanticError.cancelled }
                        DispatchQueue.main.async { self?.settings.semanticStatus = URL(fileURLWithPath:item.path).lastPathComponent }
                        do {
                            try db.prepare(f)
                            let done = try autoreleasepool { try Self.indexBatch(file:f,database:db,worker:worker,cancelled:cancelled) }
                            changed = true; if !done { unfinished.append((item,f)) }
                            if Date().timeIntervalSince(lastPublish) >= 3, let stats = try? db.stats() {
                                lastPublish = Date()
                                DispatchQueue.main.async { [weak self] in
                                    guard let self else { return }
                                    self.settings.semanticFiles = stats.files; self.settings.semanticPieces = stats.pieces; self.settings.semanticIncomplete = stats.incomplete
                                }
                            }
                        } catch SemanticError.cancelled { throw SemanticError.cancelled }
                        catch SemanticError.timeout { throw SemanticError.timeout }
                        catch SemanticError.invalidResponse { throw SemanticError.invalidResponse }
                        catch SemanticError.unavailable(let reason) { throw SemanticError.unavailable(reason) }
                        catch {
                            if cancelled() { throw SemanticError.cancelled }
                            let cursor = (try? db.progress(f)?.cursor) ?? 0
                            try db.append([],to:f,cursor:cursor,done:true,note:String(error.localizedDescription.prefix(300)))
                            DispatchQueue.main.async { self?.settings.semanticError = URL(fileURLWithPath:f.path).lastPathComponent + ": " + error.localizedDescription }
                        }
                    }
                    work = unfinished
                }
            } catch SemanticError.cancelled {} catch { DispatchQueue.main.async { self?.settings.semanticError = error.localizedDescription } }
        }
    }
    /// A page is a checkpoint. Already completed pages survive cancellation and process crashes.
    static func indexBatch(file: SemanticFile, database: SemanticDatabase, worker: SemanticWorkerClient, cancelled: @escaping () -> Bool) throws -> Bool {
        let url = URL(fileURLWithPath:file.path), ext = url.pathExtension.lowercased()
        let cursor = try database.progress(file)?.cursor ?? 0
        func check() throws {
            if cancelled() { throw SemanticError.cancelled }
            guard (try? ContentExtractor.stamp(url)) == file.stamp else { throw SemanticError.unavailable("File changed while indexing") }
        }
        if ContentExtractor.imageTypes.contains(ext) {
            let vectors = try worker.embed([file.path],image:true,cancelled:cancelled); try check()
            try database.append([SemanticPiece(ordinal:0,page:0,text:"",image:true,vector:vectors[0])],to:file,cursor:1,done:true); return true
        }
        if ext == "pdf" {
            guard let pdf = PDFDocument(url:url) else { throw ExtractionFailure.malformed }
            guard !pdf.isLocked else { throw ExtractionFailure.encrypted }
            let total = min(pdf.pageCount,5000), end = min(cursor + 12,total)
            if total == 0 { try database.append([],to:file,cursor:0,done:true,note:"No PDF pages"); return true }
            for i in cursor..<end {
                try autoreleasepool {
                    try check(); guard let page = pdf.page(at:i) else { throw ExtractionFailure.malformed }
                    let text = (page.string ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
                    var pieces = [SemanticPiece]()
                    if text.count >= 30 {
                        for (part,chunk) in Self.chunks(text).enumerated() {
                            let vector = try worker.embed([Prompts.document(title:url.lastPathComponent,text:chunk)],cancelled:cancelled)[0]
                            pieces.append(SemanticPiece(ordinal:i * 1000 + part,page:i+1,text:chunk,image:false,vector:vector))
                        }
                    } else {
                        let image = page.thumbnail(of:NSSize(width:1400,height:1400),for:.mediaBox)
                        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data:tiff), let png = rep.representation(using:.png,properties:[:]) else { throw ExtractionFailure.malformed }
                        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("fox-semantic-\(UUID().uuidString).png")
                        try png.write(to:temporary,options:.atomic); defer { try? FileManager.default.removeItem(at:temporary) }
                        let vector = try worker.embed([temporary.path],image:true,cancelled:cancelled)[0]
                        pieces.append(SemanticPiece(ordinal:i * 1000,page:i+1,text:"",image:true,vector:vector))
                    }
                    try check()
                    try database.append(pieces,to:file,cursor:i+1,done:i+1 == total,note:pdf.pageCount > 5000 ? "PDF exceeds 5000 pages" : "")
                }
            }
            return end == total
        }
        let extracted = try ContentExtractor().extract(url,options:ExtractionOptions(images:false,labels:false,documents:true),cancelled:cancelled)
        let chunks = Self.chunks(extracted.text), end = min(cursor + 24,chunks.count)
        for i in cursor..<end {
            let vector = try worker.embed([Prompts.document(title:url.lastPathComponent,text:chunks[i])],cancelled:cancelled)[0]
            try check(); try database.append([SemanticPiece(ordinal:i,page:0,text:chunks[i],image:false,vector:vector)],to:file,cursor:i+1,done:i+1 == chunks.count,note:extracted.note)
        }
        if chunks.isEmpty { try database.append([],to:file,cursor:0,done:true,note:"No text") }
        return end == chunks.count
    }
    static func chunks(_ text: String, size: Int = 800) -> [String] {
        guard !text.isEmpty, size > 0 else { return [] }
        var result = [String](), start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start,offsetBy:size,limitedBy:text.endIndex) ?? text.endIndex
            result.append(String(text[start..<end])); if end == text.endIndex { break }
            start = text.index(end,offsetBy:-min(80,size / 4),limitedBy:start) ?? end
        }
        return result
    }
}
