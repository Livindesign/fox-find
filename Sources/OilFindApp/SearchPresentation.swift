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
    var refinementRunning = false
    var refinementPaused = false
    private(set) var refinementOrigin: SearchPresentation?
    private(set) var refinementFilter: AssetRefinement?
    private var refinementOrder: [Int]?
    private var refinementAccepted: [Int] = []
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
                        if x == nil && y == nil {
                            let lx = result.details[a.source.id]?[a.id]?.lexicalScore ?? 0
                            let ly = result.details[b.source.id]?[b.id]?.lexicalScore ?? 0
                            if lx != ly { return lx > ly }
                        }
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
    /// Bounded work per interaction; resume holds the exact original result snapshot.
    /// Slow ImageIO calls stay on a shared four-worker pool, never the UI/search queue.
    func refined(_ filter: AssetRefinement, reader: AssetMetadataReader, cancelled: () -> Bool,
                 progress: ((SearchPresentation) -> Void)? = nil, budget: TimeInterval = .infinity,
                 resume: SearchPresentation? = nil,
                 inspect: ((String, Date) -> AssetMetadata?)? = nil) -> SearchPresentation? {
        guard filter.active else { return self }
        let previous = resume?.refinementOrigin === self && resume?.refinementFilter == filter ? resume : nil
        var accepted = previous?.refinementAccepted ?? [], checked = previous?.refinementChecked ?? 0
        var unknown = previous?.refinementUnknown ?? 0, lastUpdate = Date()
        let deadline = budget.isFinite ? Date().addingTimeInterval(max(0, budget)) : Date.distantFuture
        let order: [Int]?
        if let previous { order = previous.refinementOrder }
        else if let interval = filter.captured {
            let paths = reader.captureCandidates(interval)
            var candidates: [String: Set<UInt32>] = [:]
            for source in sources {
                source.store.read {
                    guard source.store.hashReady else { return }
                    candidates[source.id] = Set(paths.compactMap { source.store.resolve(path: $0) })
                }
            }
            if candidates.values.contains(where: { !$0.isEmpty }) {
                var first: [Int] = [], rest: [Int] = []
                for i in 0..<count {
                    if i % 256 == 0 && cancelled() { return nil }
                    if let hit = row(i), candidates[hit.source.id]?.contains(hit.id) == true { first.append(i) }
                    else { rest.append(i) }
                }
                order = first + rest
            } else { order = nil }
        } else { order = nil }
        func snapshot(running: Bool) -> SearchPresentation {
            let result = single.map(SearchPresentation.init) ?? SearchPresentation(multiple!)
            result.details = details; result.supplementedRows = accepted.sorted().compactMap { row($0) }; result.refinementChecked = checked
            result.refinementOrder = order; result.refinementAccepted = accepted
            result.refinementTotal = count; result.refinementUnknown = unknown
            result.refinementLimited = checked < count || count < total || unknown > 0
            result.refinementRunning = running && checked < count
            result.refinementPaused = !running && checked < count
            result.refinementOrigin = self; result.refinementFilter = filter
            return result
        }
        guard !cancelled() else { return nil }
        progress?(snapshot(running: true))
        while checked < count && Date() < deadline {
            guard !cancelled() else { return nil }
            let end = min(count, checked + 4), start = checked
            let batch = MetadataRefinementBatch()
            for i in start..<end {
                guard let hit = row(order?[i] ?? i) else { batch.set(i, .skipped); continue }
                let file: (String, Date)? = hit.source.store.read {
                    let store = hit.source.store
                    guard Int(hit.id) < store.count, store.isLive(hit.id) else { return nil }
                    if filter.needsMedia && store.kind[Int(hit.id)] != 4 && store.kind[Int(hit.id)] != 5 { return nil }
                    return (store.path(hit.id), store.modified(hit.id))
                }
                guard let file else { batch.set(i, .skipped); continue }
                batch.add(i) {
                    let info: AssetMetadata?
                    if let inspect { info = inspect(file.0, file.1) }
                    else { info = hit.source.isOnline ? reader.read(path: file.0, modified: file.1, media: filter.needsMedia) : reader.offline(path: file.0, modified: file.1, media: filter.needsMedia) }
                    guard let info, filter.hasRequiredMetadata(info) else { return .unknown }
                    return filter.matches(info) ? .matched : .skipped
                }
            }
            while !batch.finished && Date() < deadline && !cancelled() { batch.wait() }
            batch.cancelPending()
            guard !cancelled() else { return nil }
            // Commit only a contiguous prefix. A late worker may warm the cache, but
            // cannot lose a match or mutate an already delivered result snapshot.
            for i in start..<end {
                guard let outcome = batch.get(i) else { break }
                if outcome == .matched { accepted.append(order?[i] ?? i) }
                if outcome == .unknown { unknown += 1 }
                checked += 1
            }
            if checked < end { break }
            if Date().timeIntervalSince(lastUpdate) > 0.35 { progress?(snapshot(running: true)); lastUpdate = Date() }
        }
        guard !cancelled() else { return nil }; return snapshot(running: false)
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
        result.refinementRunning = refinementRunning; result.refinementPaused = refinementPaused
        result.refinementOrigin = refinementOrigin; result.refinementFilter = refinementFilter
        result.refinementOrder = refinementOrder; result.refinementAccepted = refinementAccepted
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

private final class MetadataRefinementBatch {
    enum Outcome { case matched, skipped, unknown }
    private static let queue: OperationQueue = {
        let queue = OperationQueue(); queue.name = "app.localfind.metadata.read"
        queue.maxConcurrentOperationCount = 4; queue.qualityOfService = .utility
        return queue
    }()
    private let lock = NSLock(), group = DispatchGroup()
    private var outcomes: [Int: Outcome] = [:]
    private var operations: [Operation] = []
    func set(_ index: Int, _ outcome: Outcome) { lock.lock(); outcomes[index] = outcome; lock.unlock() }
    func get(_ index: Int) -> Outcome? { lock.lock(); defer { lock.unlock() }; return outcomes[index] }
    func add(_ index: Int, read: @escaping () -> Outcome) {
        group.enter()
        let operation = BlockOperation { [weak self] in
            autoreleasepool { let outcome = read(); self?.set(index, outcome) }
        }
        operation.completionBlock = { [group] in group.leave() }
        operations.append(operation); Self.queue.addOperation(operation)
    }
    var finished: Bool { group.wait(timeout: .now()) == .success }
    func wait() { _ = group.wait(timeout: .now() + 0.02) }
    func cancelPending() { operations.filter { !$0.isExecuting && !$0.isFinished }.forEach { $0.cancel() } }
}
