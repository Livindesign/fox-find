import Foundation
import OilFindApp
import OilFindCore

final class ContentSearch: SupplementarySearchProvider {
    let database: ContentDatabase
    let settings: ContentSettings
    let engine: ContentEngine
    var semantic: SemanticSearch?
    var supportsSimilarity: Bool { isEnabled && settings.semanticEnabled && semantic?.engine.models.ready == true && settings.semanticPieces > 0 }
    var isEnabled: Bool { settings.enabled && !settings.folders.isEmpty }
    init(database: ContentDatabase, settings: ContentSettings, engine: ContentEngine) {
        self.database = database; self.settings = settings; self.engine = engine
    }
    func sourcesDidChange(_ sources: [SearchSource]) { engine.updateSources(sources); semantic?.engine.updateSources(sources) }
    func userActivity(visible: Bool, typing: Bool) {
        engine.userActivity(typing: typing)
        semantic?.engine.userActivity(typing: typing)
    }
    func prepareSimilarity(path: String, query: Query, options: SearchOptions, sources: [SearchSource], isCancelled: @escaping () -> Bool) -> () -> [SupplementaryHit] {
        semantic?.prepare(query, options: options, sources: sources, image: path, cancelled: isCancelled) ?? { [] }
    }
    func prepareSearch(_ query: Query, options: SearchOptions, sources: [SearchSource], isCancelled: @escaping () -> Bool) -> () -> [SupplementaryHit] {
        prepareSearch(query, options: options, sources: sources, contentOnly: false, isCancelled: isCancelled)
    }
    func prepareSearch(_ query: Query, options: SearchOptions, sources: [SearchSource], contentOnly: Bool, isCancelled: @escaping () -> Bool) -> () -> [SupplementaryHit] {
        let enabled = isEnabled, folders = settings.folders, extraction = settings.options, db = database
        return {
            guard enabled, (!query.isEmpty || contentOnly), !isCancelled() else { return [] }
            return Self.search(query, options: options, sources: sources, database: db, folders: folders, extraction: extraction, contentOnly: contentOnly, cancelled: isCancelled)
        }
    }
    func prepareSemantic(_ query: Query, options: SearchOptions, sources: [SearchSource], isCancelled: @escaping () -> Bool) -> (() -> [SupplementaryHit])? {
        guard supportsSimilarity, SemanticSearch.phrase(query) != nil else { return nil }
        return semantic?.prepare(query, options: options, sources: sources, cancelled: isCancelled)
    }
    func prepareSemantic(_ query: Query, options: SearchOptions, sources: [SearchSource], accepts: @escaping SupplementaryFileFilter, isCancelled: @escaping () -> Bool) -> (() -> [SupplementaryHit])? {
        guard supportsSimilarity, SemanticSearch.phrase(query) != nil else { return nil }
        return semantic?.prepare(query, options: options, sources: sources, accepts: accepts, cancelled: isCancelled)
    }
    func prepareSimilarity(path: String, query: Query, options: SearchOptions, sources: [SearchSource], accepts: @escaping SupplementaryFileFilter, isCancelled: @escaping () -> Bool) -> () -> [SupplementaryHit] {
        semantic?.prepare(query, options: options, sources: sources, image: path, accepts: accepts, cancelled: isCancelled) ?? { [] }
    }
    func preparePreview(source: SearchSource, entryID: UInt32) -> () -> ExtractedTextPreview? {
        let db = database, folders = settings.folders, enabled = isEnabled, extraction = settings.options
        return {
            guard enabled else { return nil }
            let info: (String, UInt32, UInt64)? = source.store.read {
                guard Int(entryID) < source.store.count, source.store.isLive(entryID) else { return nil }
                return (source.store.path(entryID), source.store.mtime[Int(entryID)], source.store.size(entryID))
            }
            guard let (path, mtime, size) = info,
                  folders.contains(where: { ExcludedFolders.contains($0, path: path) }) else { return nil }
            let root = source.store.rootPath == "/" ? "" : source.store.rootPath
            guard let row = try? db.record(source: source.id, path: String(path.dropFirst(root.count))),
                  row.mtime == mtime, row.size == size, row.fingerprint.hasSuffix("#" + extraction.fingerprint) else { return nil }
            return ExtractedTextPreview(path: path, text: row.text, note: row.note, isOnline: source.isOnline, segments: row.segments, sourceStamp: row.fingerprint.components(separatedBy: "#").first)
        }
    }
    func preparePreview(source: SearchSource, entryID: UInt32, isCancelled: @escaping () -> Bool) -> () -> TextPreviewOutcome {
        let cached = preparePreview(source: source, entryID: entryID), chinese = settings.chinese
        return {
            func t(_ zh: String, _ en: String) -> String { chinese ? zh : en }
            guard !isCancelled() else { return .cancelled }
            guard let path = source.store.read({ () -> String? in
                guard Int(entryID) < source.store.count, source.store.isLive(entryID) else { return nil }
                return source.store.path(entryID)
            }) else { return .unavailable(t("文件已不在当前索引中，请重新搜索。", "File no longer indexed. Search again.")) }
            let url = URL(fileURLWithPath: path)
            let value = cached()
            if !source.isOnline {
                if let value, !value.text.isEmpty { return .ready(value) }
                return .unavailable(t("磁盘未连接，且没有可用文字缓存。请连接磁盘后重试。", "Drive offline with no usable text cache. Reconnect and retry."))
            }
            do {
                let stamp = try ContentExtractor.stamp(url)
                // Never display stale text when the file changed before the name index refreshed.
                if let value, value.sourceStamp == stamp, !value.text.isEmpty,
                   url.pathExtension.lowercased() != "pdf" || !value.segments.isEmpty { return .ready(value) }
                // Manual preview is independent of background indexing preferences. No persistent cache is written.
                let extracted = try ContentExtractor().extract(url, options: .init(images: true, labels: false, documents: true), cancelled: isCancelled)
                guard !isCancelled() else { return .cancelled }
                guard try ContentExtractor.stamp(url) == stamp else {
                    return .unavailable(t("提取期间文件已变化，请重试。", "File changed during extraction. Please retry."))
                }
                guard !extracted.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return .unavailable(t("此文件未提取到文字；扫描 PDF 已尝试本机 OCR。可按空格查看原文件。", "No text found; local OCR was attempted for scanned PDFs. Press Space to view the original."))
                }
                let note = ContentIssue(path: path, note: extracted.note).reason(chinese: chinese)
                return .ready(ExtractedTextPreview(path: path, text: extracted.text, note: note, isOnline: true,
                                                  segments: extracted.segments, sourceStamp: stamp, isCached: false))
            } catch ExtractionFailure.cancelled { return .cancelled }
            catch {
                guard !isCancelled() else { return .cancelled }
                let reason = ContentIssue(path: path, note: (error as? ExtractionFailure)?.rawValue ?? "unavailable").reason(chinese: chinese)
                return .unavailable(reason + t("。可按空格查看原文件。", ". Press Space to view the original."))
            }
        }
    }
    func prepareDiagnosis(path: String, sources: [SearchSource]) -> () -> String {
        let enabled = settings.enabled, folders = settings.folders, db = database, chinese = settings.chinese
        return {
            func t(_ zh: String, _ en: String) -> String { chinese ? zh : en }
            guard enabled else { return t("内容搜索未启用", "Content search is disabled") }
            guard folders.contains(where: { ExcludedFolders.contains($0, path: path) }) else { return t("此路径未加入内容索引文件夹", "Outside content indexing folders") }
            for source in sources {
                let root = source.store.rootPath == "/" ? "" : source.store.rootPath
                guard root.isEmpty || path.hasPrefix(root + "/") else { continue }
                if let record = try? db.record(source: source.id, path: String(path.dropFirst(root.count))) {
                    if source.isOnline, let stamp = try? ContentExtractor.stamp(URL(fileURLWithPath: path)), !record.fingerprint.hasPrefix(stamp + "#") {
                        return t("文件已变化，内容缓存等待更新", "File changed; content cache awaits refresh")
                    }
                    return (record.text.isEmpty ? t("无可用文字", "No extracted text") : t("内容缓存可用", "Content cache available")) + (record.note.isEmpty ? "" : " · " + record.note)
                }
            }
            return t("尚无内容缓存：等待索引，或文件格式不受支持", "No content cache: pending indexing or unsupported format")
        }
    }
    static func search(_ query: Query, options: SearchOptions, sources: [SearchSource], database: ContentDatabase,
                       folders: [String], extraction: ExtractionOptions, contentOnly: Bool = false, cancelled: @escaping () -> Bool) -> [SupplementaryHit] {
        let atoms = query.clauses.flatMap(\.alternatives)
        let needles = atoms.compactMap { atom -> String? in
            guard !atom.negated, case .name(let bytes, _) = atom.matcher, !bytes.isEmpty else { return nil }
            return String(decoding: bytes, as: UTF8.self)
        }
        guard !needles.isEmpty || contentOnly else { return [] }
        var hits = [SupplementaryHit]()
        for source in sources {
            guard !cancelled() else { return [] }
            let store = source.store
            // Stream text rows instead of retaining the entire matched corpus in memory.
            // IndexStore locks cover only one candidate; SQLite reads never run under that lock.
            try? database.visitCandidates(needles: needles, sources: [source.id], cancelled: cancelled) { row in
                if cancelled() || hits.count >= 1000 { return false }
                let path = (store.rootPath == "/" ? "" : store.rootPath) + row.path
                guard folders.contains(where: { ExcludedFolders.contains($0, path: path) }),
                      row.fingerprint.hasSuffix("#" + extraction.fingerprint) else { return true }
                let id: UInt32? = Searcher.withEntryPredicates(atoms, options: options, in: store, isCancelled: cancelled) { matches in
                    guard store.hashReady, let id = store.resolve(path: path), store.isLive(id),
                          store.mtime[Int(id)] == row.mtime, store.size(id) == row.size,
                          options.kind == nil || store.kind[Int(id)] == options.kind else { return nil }
                    var ordinal = 0
                    for clause in query.clauses {
                        var matched = false
                        for atom in clause.alternatives {
                            let fileMatches = matches(ordinal, id); ordinal += 1
                            if case .name(let bytes, let sensitive) = atom.matcher {
                                let needle = String(decoding: bytes, as: UTF8.self)
                                let inContent = row.text.range(of: needle, options: sensitive ? [] : [.caseInsensitive, .diacriticInsensitive]) != nil
                                let positive = contentOnly ? inContent : (fileMatches || inContent)
                                matched = matched || (atom.negated ? !positive : positive)
                            } else { matched = matched || (atom.negated ? !fileMatches : fileMatches) }
                        }
                        if !matched { return nil }
                    }
                    return id
                }
                if let id {
                    // Keep only a small snippet in displayed hits, not each document's full text.
                    let presentation = Self.snippet(row.text, needles: needles)
                    hits.append(SupplementaryHit(sourceID: source.id, entryID: id, detail: presentation.text,
                                                highlights: presentation.highlights, thumbnail: row.category == "image"))
                }
                return hits.count < 1000
            }
        }
        return cancelled() ? [] : hits
    }
    static func snippet(_ text: String, needles: [String]) -> (text: String, highlights: [NSRange]) {
        let normalized = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let ns = normalized as NSString
        let hit = needles.lazy.map { ns.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }.first { $0.location != NSNotFound }
        let start = max(0, (hit?.location ?? 0) - 45)
        let range = ns.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: min(220, ns.length - start)))
        let piece = (start > 0 ? "…" : "") + ns.substring(with: range) + (NSMaxRange(range) < ns.length ? "…" : "")
        let result = piece as NSString
        let highlights = needles.compactMap { needle -> NSRange? in
            let found = result.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive])
            return found.location == NSNotFound ? nil : found
        }
        return (piece, highlights)
    }
}
