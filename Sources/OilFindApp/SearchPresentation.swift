import OilFindCore
import Foundation
import COilFind

/// A submitted query snapshot. The single-store path keeps its original arrays.
final class SearchPresentation {
    let single: SearchResult?
    let multiple: MultiSearchResult?
    private var supplementedRows: [(source: SearchSource, id: UInt32)]?
    private var details: [String: [UInt32: SupplementaryHit]] = [:]
    var refinementChecked: Int?
    var refinementLimited = false
    var refinementTotal = 0
    var refinementUnknown = 0
    private var rowOrder: [Int]?
    let createdAt: Date
    init(_ result: SearchResult) { single = result; multiple = nil; createdAt = result.createdAt }
    init(_ result: MultiSearchResult) { single = nil; multiple = result; createdAt = result.createdAt }
    var query: Query { single?.query ?? multiple!.query }
    var total: Int { supplementedRows?.count ?? single?.total ?? multiple!.total }
    var sortedCount: Int { supplementedRows?.count ?? single?.sortedCount ?? multiple!.sortedCount }
    var elapsedMs: Double { single?.elapsedMs ?? multiple!.elapsedMs }
    var count: Int { supplementedRows?.count ?? single?.items.count ?? multiple!.items.count }
    var store: IndexStore { single?.store ?? multiple!.sources[0].store }
    var sources: [SearchSource] {
        single.map { [SearchSource(id: "startup", displayName: "", isOnline: true, store: $0.store)] } ?? multiple!.sources
    }
    func row(_ index: Int) -> (source: SearchSource, id: UInt32)? {
        guard index >= 0, index < count else { return nil }
        let index = rowOrder?[index] ?? index
        if let supplementedRows { return supplementedRows[index] }
        if let single { return (SearchSource(id: "startup", displayName: "", isOnline: true, store: single.store), single.items[index]) }
        let hit = multiple!.items[index]
        return (multiple!.sources[hit.sourceIndex], hit.entryID)
    }
    func detail(at index: Int) -> SupplementaryHit? {
        guard let row = row(index) else { return nil }; return details[row.source.id]?[row.id]
    }
    func supplement(_ hits: [SupplementaryHit], options: SearchOptions, only: Bool = false) -> SearchPresentation {
        let captured = sources
        func mergeLocked(_ position: Int) -> SearchPresentation {
            if position < captured.count { return captured[position].store.read { mergeLocked(position + 1) } }
            let result = single.map(SearchPresentation.init) ?? SearchPresentation(multiple!)
            var rows = only ? [] : (0..<count).compactMap { row($0) }
            var seen = Dictionary(grouping: rows, by: { $0.source.id }).mapValues { Set($0.map(\.id)) }
            var extra: [(source: SearchSource, id: UInt32)] = []
            for hit in hits {
                guard let source = sources.first(where: { $0.id == hit.sourceID }), Int(hit.entryID) < source.store.count && source.store.isLive(hit.entryID) else { continue }
                result.details[source.id, default: [:]][hit.entryID] = hit
                if seen[source.id, default: []].insert(hit.entryID).inserted { extra.append((source, hit.entryID)) }
            }
            func better(_ a: (source: SearchSource, id: UInt32), _ b: (source: SearchSource, id: UInt32)) -> Bool {
                switch options.sort {
                case .name:
                    let x = a.source.store.nameBytes(a.id), y = b.source.store.nameBytes(b.id)
                    let cmp = sift_name_compare(x.baseAddress, x.count, y.baseAddress, y.count)
                    if cmp != 0 { return options.ascending ? cmp < 0 : cmp > 0 }
                case .size:
                    let x = a.source.store.size(a.id), y = b.source.store.size(b.id)
                    if x != y { return options.ascending ? x < y : x > y }
                case .modified, .relevance:
                    if options.sort == .relevance {
                        let x = result.details[a.source.id]?[a.id]?.semanticScore
                        let y = result.details[b.source.id]?[b.id]?.semanticScore
                        if x == nil && y != nil { return true }
                        if x != nil && y == nil { return false }
                        if let x, let y, x != y { return x > y }
                    }
                    let x = a.source.store.mtime[Int(a.id)], y = b.source.store.mtime[Int(b.id)]
                    if x != y { return options.sort != .relevance && options.ascending ? x < y : x > y }
                }
                return a.source.id == b.source.id ? a.id < b.id : a.source.id < b.source.id
            }
            extra.sort(by: better); rows.append(contentsOf: extra)
            if options.sort != .relevance { rows.sort(by: better) }
            result.supplementedRows = rows; return result
        }
        return mergeLocked(0)
    }
    func refined(_ filter: AssetRefinement, reader: AssetMetadataReader, cancelled: () -> Bool, progress: ((SearchPresentation) -> Void)? = nil) -> SearchPresentation? {
        guard filter.active else { return self }
        var accepted: [(source: SearchSource, id: UInt32)] = [], checked = 0, unknown = 0
        var lastUpdate = Date()
        func snapshot() -> SearchPresentation {
            let result = single.map(SearchPresentation.init) ?? SearchPresentation(multiple!)
            result.details = details; result.supplementedRows = accepted; result.refinementChecked = checked
            result.refinementTotal = count; result.refinementUnknown = unknown
            result.refinementLimited = checked < count || count < total || unknown > 0
            return result
        }
        for i in 0..<count {
            guard !cancelled() else { return nil }
            checked += 1
            guard let hit = row(i) else { continue }
            let file: (String, Date)? = hit.source.store.read {
                let store = hit.source.store
                guard Int(hit.id) < store.count, store.isLive(hit.id) else { return nil }
                if filter.needsMedia && ![UInt8(4), UInt8(5)].contains(store.kind[Int(hit.id)]) { return nil }
                return (store.path(hit.id), store.modified(hit.id))
            }
            if let file {
                let info = hit.source.isOnline ? reader.read(path: file.0, modified: file.1, media: filter.needsMedia) : reader.offline(path: file.0, modified: file.1, media: filter.needsMedia)
                if let info, filter.hasRequiredMetadata(info) { if filter.matches(info) { accepted.append(hit) } }
                else { unknown += 1 }
            }
            if Date().timeIntervalSince(lastUpdate) > 0.35 { progress?(snapshot()); lastUpdate = Date() }
        }
        guard !cancelled() else { return nil }; return snapshot()
    }
    func ranked(_ scores: [String: Int], options: SearchOptions) -> SearchPresentation {
        guard options.sort == .relevance, !scores.isEmpty else { return self }
        var weighted: [String: [UInt32: Int]] = [:]
        for source in sources {
            let prefix = "file:" + source.id + "|"
            source.store.read {
                guard source.store.hashReady else { return }
                for (target, score) in scores where target.hasPrefix(prefix) {
                    if let id = source.store.resolve(path: String(target.dropFirst(prefix.count))) { weighted[source.id, default: [:]][id] = score }
                }
            }
        }
        guard !weighted.isEmpty else { return self }
        var promoted = [(Int, Int)]()
        for i in 0..<count { if let item = row(i), let score = weighted[item.source.id]?[item.id] { promoted.append((i, score)) } }
        guard !promoted.isEmpty else { return self }
        promoted.sort { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        let selected = Set(promoted.map { $0.0 })
        let result = single.map(SearchPresentation.init) ?? SearchPresentation(multiple!)
        result.details = details; result.supplementedRows = supplementedRows
        result.rowOrder = promoted.map { $0.0 } + (0..<count).filter { !selected.contains($0) }
        result.refinementChecked = refinementChecked; result.refinementLimited = refinementLimited
        result.refinementTotal = refinementTotal; result.refinementUnknown = refinementUnknown
        return result
    }
    var hasSupplements: Bool { supplementedRows != nil }
    func withoutSupplements() -> SearchPresentation { single.map(SearchPresentation.init) ?? SearchPresentation(multiple!) }
    func index(sourceID: String, store: IndexStore, id: UInt32, path: String) -> Int? {
        guard let source = sources.first(where: { $0.id == sourceID }) else { return nil }
        let resolved: UInt32? = source.store === store ? id : source.store.read { source.store.hashReady ? source.store.resolve(path: path) : nil }
        guard let resolved else { return nil }
        if rowOrder != nil { return (0..<count).first { row($0).map { $0.source.id == sourceID && $0.id == resolved } == true } }
        if let supplementedRows { return supplementedRows.firstIndex { $0.source.id == sourceID && $0.id == resolved } }
        if let single { return single.items.firstIndex(of: resolved) }
        return multiple!.items.firstIndex { multiple!.sources[$0.sourceIndex].id == sourceID && $0.entryID == resolved }
    }
    func sameRows(as other: SearchPresentation) -> Bool {
        if rowOrder == nil, other.rowOrder == nil, supplementedRows == nil, other.supplementedRows == nil, let single, let rhs = other.single { return single.store === rhs.store && single.items == rhs.items }
        guard count == other.count else { return false }
        for i in 0..<count {
            guard let a = row(i), let b = other.row(i), a.source.id == b.source.id, a.source.store === b.source.store, a.id == b.id else { return false }
        }
        return true
    }
    func sameMetadata(as other: SearchPresentation) -> Bool {
        guard details.count == other.details.count else { return false }
        for (source, hits) in details {
            guard let rhs = other.details[source], hits.count == rhs.count else { return false }
            for (id, hit) in hits {
                guard let otherHit = rhs[id], hit.samePresentation(as: otherHit) else { return false }
            }
        }
        let a = sources, b = other.sources
        guard a.count == b.count else { return false }
        let versions = single.map { [$0.storeVersion] } ?? multiple!.results.map(\.storeVersion)
        let rhs = other.single.map { [$0.storeVersion] } ?? other.multiple!.results.map(\.storeVersion)
        return zip(a, b).allSatisfy { $0.id == $1.id && $0.store === $1.store && $0.isOnline == $1.isOnline && $0.displayName == $1.displayName } && versions == rhs
    }
    func hasSameSources(as current: [SearchSource]) -> Bool {
        let captured = sources
        return captured.count == current.count && zip(captured, current).allSatisfy {
            $0.id == $1.id && $0.store === $1.store && $0.isOnline == $1.isOnline && $0.displayName == $1.displayName
        }
    }
    func isCurrent(_ current: [SearchSource]) -> Bool {
        let captured = sources
        guard captured.count == current.count else { return false }
        let versions = single.map { [$0.storeVersion] } ?? multiple!.results.map(\.storeVersion)
        return captured.indices.allSatisfy { i in
            captured[i].id == current[i].id && captured[i].store === current[i].store && captured[i].isOnline == current[i].isOnline && captured[i].displayName == current[i].displayName && current[i].store.read { current[i].store.version == versions[i] }
        }
    }
}
