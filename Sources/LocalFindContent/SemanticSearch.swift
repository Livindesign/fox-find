import Foundation
import OilFindApp
import OilFindCore
import FoxFindSemanticCore

final class SemanticSearch {
    let database: SemanticDatabase, engine: SemanticEngine
    private let lock = NSLock()
    private var textWorker: SemanticWorkerClient?, imageWorker: SemanticWorkerClient?
    private var cachedKey = "", cachedVector = [Float](), lastUsed = Date.distantPast
    init(database: SemanticDatabase, engine: SemanticEngine) { self.database = database; self.engine = engine }
    func close() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }; self.lock.lock(); defer { self.lock.unlock() }
            self.textWorker?.close(); self.imageWorker?.close(); self.textWorker = nil; self.imageWorker = nil
            self.cachedKey = ""; self.cachedVector = []
        }
    }
    /// Structured constraints remain exact. Explicit OR, quoted and wildcard expressions keep lexical semantics.
    static func phrase(_ query: Query) -> String? {
        guard query.diagnostics.isEmpty, !query.raw.contains("\""), !query.raw.contains("*"), !query.raw.contains("?"), query.clauses.allSatisfy({ $0.alternatives.count == 1 }) else { return nil }
        // A negated keyword also applies to full extracted text in lexical search.
        // Do not weaken it into a filename-only predicate for approximate matches.
        if query.clauses.flatMap(\.alternatives).contains(where: { atom in
            if atom.negated, case .name = atom.matcher { return true }; return false
        }) { return nil }
        let words = query.clauses.flatMap(\.alternatives).compactMap { atom -> String? in
            guard !atom.negated, case .name(let bytes,let sensitive) = atom.matcher, !sensitive else { return nil }
            return String(decoding:bytes,as:UTF8.self)
        }.joined(separator:" ")
        return words.count >= 2 && words.count <= 500 ? words : nil
    }
    func prepare(_ query: Query, options: SearchOptions, sources: [SearchSource], image: String? = nil, accepts: @escaping SupplementaryFileFilter = { _,_ in true }, cancelled: @escaping () -> Bool) -> () -> [SupplementaryHit] {
        let settings = engine.settings
        let enabled = settings.enabled && settings.semanticEnabled && engine.models.ready
        let folders = settings.folders, chinese = settings.chinese, documents = settings.documents
        let phrase = image == nil ? Self.phrase(query) : ""
        return { [self] in
            guard enabled, let phrase, !cancelled() else { return [] }
            do {
                let vector = try embedding(phrase:phrase,image:image,cancelled:cancelled)
                let atoms = query.clauses.flatMap(\.alternatives)
                let matches = try database.search(vector:vector,imagesOnly:image != nil,cancelled:cancelled, qualifies: { match in
                    guard let source = sources.first(where: { $0.id == match.file.source }),
                          let id = source.store.read({ source.store.hashReady ? source.store.resolve(path:match.file.path) : nil }) else { return false }
                    return !cancelled() && accepts(source,id)
                }) { file in
                    guard documents || ContentExtractor.imageTypes.contains(URL(fileURLWithPath: file.path).pathExtension.lowercased()), file.path != image, folders.contains(where: { ExcludedFolders.contains($0,path:file.path) }),
                          let source = sources.first(where: { $0.id == file.source }) else { return false }
                    let store = source.store
                    let id: UInt32? = Searcher.withEntryPredicates(atoms,options:options,in:store,isCancelled:cancelled) { check in
                        guard store.hashReady, let id = store.resolve(path:file.path), store.isLive(id), store.mtime[Int(id)] == file.mtime,
                              store.size(id) == file.size, options.kind == nil || store.kind[Int(id)] == options.kind else { return nil }
                        var ordinal = 0
                        for clause in query.clauses {
                            var matched = false
                            for atom in clause.alternatives {
                                defer { ordinal += 1 }
                                if case .name = atom.matcher, !atom.negated { matched = true; continue }
                                let value = check(ordinal,id); matched = matched || (atom.negated ? !value : value)
                            }
                            if !matched { return nil }
                        }
                        return id
                    }
                    return id != nil
                }
                return cancelled() ? [] : matches.compactMap { match in
                    guard let source = sources.first(where: { $0.id == match.file.source }),
                          let id = source.store.read({ source.store.hashReady ? source.store.resolve(path:match.file.path) : nil }) else { return nil }
                    let kind = image != nil ? (chinese ? "相似图片" : "Similar image") : (chinese ? "可能相关" : "Possibly related")
                    let page = match.page > 0 ? (chinese ? " · 第 \(match.page) 页" : " · Page \(match.page)") : ""
                    let excerpt = match.text.replacingOccurrences(of:"\n",with:" ")
                    let detail = kind + page + (excerpt.isEmpty ? "" : " · " + String(excerpt.prefix(160)))
                    return SupplementaryHit(sourceID:match.file.source,entryID:id,detail:detail,thumbnail:match.image && match.page == 0,semanticScore:match.score,matchedPage:match.page > 0 ? match.page : nil,matchedStamp:match.file.stamp)
                }
            } catch {
                if !cancelled() { DispatchQueue.main.async { settings.semanticError = error.localizedDescription } }
                return []
            }
        }
    }
    private func embedding(phrase: String, image: String?, cancelled: () -> Bool) throws -> [Float] {
        while !lock.try() { if cancelled() { throw SemanticError.cancelled }; Thread.sleep(forTimeInterval:0.01) }
        defer { lock.unlock() }
        if cancelled() { throw SemanticError.cancelled }
        let imageStamp = try image.map { try ContentExtractor.stamp(URL(fileURLWithPath:$0)) }
        let key = image.map { "image:\($0):\(imageStamp!)" } ?? "text:" + phrase
        defer { lastUsed = Date(); scheduleIdleRelease() }
        if cachedKey == key { return cachedVector }
        let worker: SemanticWorkerClient
        if image != nil {
            if imageWorker == nil { imageWorker = SemanticWorkerClient(executable:engine.helper,models:engine.models.directory,textOnly:false) }
            worker = imageWorker!
        } else {
            if textWorker == nil { textWorker = SemanticWorkerClient(executable:engine.helper,models:engine.models.directory,textOnly:true) }
            worker = textWorker!
        }
        let vector = try worker.embed([image ?? Prompts.query(phrase)],image:image != nil,cancelled:cancelled)[0]
        cachedKey = key; cachedVector = vector
        return vector
    }
    private func scheduleIdleRelease() {
        DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now() + 30) { [weak self] in
            guard let self, self.lock.try() else { return }; defer { self.lock.unlock() }
            if Date().timeIntervalSince(self.lastUsed) >= 29 {
                self.textWorker?.close(); self.imageWorker?.close(); self.textWorker = nil; self.imageWorker = nil
            }
        }
    }
}
