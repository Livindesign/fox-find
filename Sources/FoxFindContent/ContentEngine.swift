import Foundation
import FoxFindCore

final class ContentCancellation {
    private let lock = NSLock()
    private var value = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

struct ContentCandidate {
    var source: String, relative: String, path: String
    var mtime: UInt32, size: UInt64
}

final class ContentEngine {
    let database: ContentDatabase
    let settings: ContentSettings
    let budget: BackgroundWorkBudget
    private let queue = DispatchQueue(label: "app.localfind.desktop.content", qos: .utility)
    private var sources = [SearchSource]()
    private var token: ContentCancellation?
    private var running = false, dirty = false, stopped = false
    private var pending: DispatchWorkItem?
    private var lastInteraction = Date.distantPast
    private let availableCapacity: (URL) -> Int64?
    var onResultsChange: (() -> Void)?
    init(database: ContentDatabase, settings: ContentSettings, budget: BackgroundWorkBudget = BackgroundWorkBudget(),
         availableCapacity: @escaping (URL) -> Int64? = { try? $0.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage }) {
        self.database = database; self.settings = settings; self.budget = budget; self.availableCapacity = availableCapacity
    }
    func updateSources(_ sources: [SearchSource]) { self.sources = sources; request() }
    func settingsChanged() { token?.cancel(); request() }
    func stop() { stopped = true; pending?.cancel(); token?.cancel() }
    func userActivity(typing: Bool) {
        guard typing else { return }
        budget.userActivity()
        lastInteraction = Date(); token?.cancel(); request(delay: 8)
    }
    func request(delay: Double = 0.6) {
        guard !stopped else { return }
        if running { dirty = true; return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.begin() }
        pending = work; DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    func clear() {
        token?.cancel(); pending?.cancel()
        queue.async { [weak self] in
            guard let self else { return }
            do { try self.database.clear() }
            catch { DispatchQueue.main.async { self.settings.error = error.localizedDescription } }
            DispatchQueue.main.async { self.settings.indexed = 0; self.settings.skipped = 0; self.onResultsChange?(); self.request() }
        }
    }
    func retryIncomplete() {
        token?.cancel()
        queue.async { [weak self] in
            guard let self else { return }
            do { try self.database.retryIncomplete() }
            catch { DispatchQueue.main.async { self.settings.error = error.localizedDescription } }
            DispatchQueue.main.async { self.request() }
        }
    }
    func loadDiagnostics(_ completion: @escaping ([ContentIssue]) -> Void) {
        let roots = Dictionary(sources.map { ($0.id, $0.store.rootPath == "/" ? "" : $0.store.rootPath) }, uniquingKeysWith: { a, _ in a })
        DispatchQueue.global(qos: .utility).async { [database] in
            let rows = (try? database.diagnostics()) ?? []
            let issues = rows.map { ContentIssue(path: (roots[$0.source] ?? "") + $0.path, note: $0.note) }
            DispatchQueue.main.async { completion(issues) }
        }
    }
    private func begin() {
        guard !stopped, !running else { return }
        guard settings.enabled, !settings.paused else { settings.running = false; return }
        if Date().timeIntervalSince(lastInteraction) < 8 { request(delay: 8); return }
        if ProcessInfo.processInfo.isLowPowerModeEnabled || [.serious, .critical].contains(ProcessInfo.processInfo.thermalState) {
            request(delay: 30); return
        }
        let token = ContentCancellation()
        guard budget.beginBackground(token) else { request(delay: 8); return }
        running = true; dirty = false
        let sources = self.sources, folders = settings.folders, options = settings.options, enabled = settings.enabled && !settings.paused
        self.token = token
        settings.running = enabled && !folders.isEmpty; settings.completed = 0; settings.total = 0; settings.error = ""
        let db = database, capacity = availableCapacity, budget = budget
        queue.async { [weak self] in
            var changed = false
            var publishedFirstContent = false
            defer {
                budget.endBackground(token)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.running = false; self.settings.running = false; self.settings.currentFile = ""
                    if changed { self.onResultsChange?() }
                    if self.dirty || token.cancelled { self.request(delay: 8) }
                }
            }
            budget.prepareBackground?()
            // Purgeable-space accounting can block on system services. Never run it on the UI queue.
            guard !token.cancelled else { return }
            if !folders.isEmpty, let available = capacity(db.directory), available < 500 * 1024 * 1024 {
                DispatchQueue.main.async {
                    guard let self, !token.cancelled else { return }
                    self.settings.error = self.settings.text("磁盘可用空间不足 500 MB，暂缓内容索引；已有内容仍可搜索。", "Less than 500 MB free. Content indexing is waiting; cached search remains available.")
                }
                return
            }
            guard !token.cancelled else { return }
            do {
                for source in sources {
                    if token.cancelled { break }
                    let candidates = Self.candidates(source, folders: folders, options: options, cancelled: { token.cancelled })
                    let fingerprints = try db.fingerprints(source: source.id)
                    guard !token.cancelled else { break }
                    let paths = Set(candidates.map(\.relative))
                    let obsolete = fingerprints.keys.filter { !paths.contains($0) }
                    try db.remove(source: source.id, paths: obsolete); changed = changed || !obsolete.isEmpty
                    guard enabled, source.isOnline else { continue }
                    DispatchQueue.main.async { self?.settings.total += candidates.count }
                    var reported = 0
                    for (i, item) in candidates.enumerated() {
                        if token.cancelled { break }
                        let url = URL(fileURLWithPath: item.path)
                        do {
                            let stamp = try ContentExtractor.stamp(url), fingerprint = stamp + (url.pathExtension.lowercased() == "pdf" ? "#positions-v2" : "") + "#" + options.fingerprint
                            if fingerprints[item.relative] != fingerprint {
                                let output = try autoreleasepool { try ContentExtractor().extract(url, options: options, cancelled: { token.cancelled }) }
                                guard !token.cancelled else { break }
                                // Discard a read if the file changed during extraction.
                                guard (try? ContentExtractor.stamp(url)) == stamp else { continue }
                                try db.put(ContentRecord(source: item.source, path: item.relative, fingerprint: fingerprint,
                                                         text: output.text, category: output.category, note: output.note,
                                                         mtime: item.mtime, size: item.size, segments: output.segments)); changed = true
                                // Publish the first usable text once per pass so a new user can
                                // search while the remaining OCR runs. Never count rows on the UI thread.
                                if !publishedFirstContent && !output.text.isEmpty {
                                    publishedFirstContent = true
                                    let stats = try db.statistics()
                                    DispatchQueue.main.async {
                                        guard !token.cancelled else { return }
                                        self?.settings.indexed = stats.indexed; self?.settings.skipped = stats.skipped
                                        self?.onResultsChange?()
                                    }
                                }
                            }
                        } catch {
                            guard !token.cancelled else { break }
                            // Remove stale searchable content immediately, and retain a visible diagnostic count.
                            let fingerprint = ((try? ContentExtractor.stamp(url)) ?? "unavailable") + "#" + options.fingerprint
                            if fingerprints[item.relative] != fingerprint {
                                try db.put(ContentRecord(source: item.source, path: item.relative, fingerprint: fingerprint,
                                                         text: "", category: "skipped", note: String(describing: error),
                                                         mtime: item.mtime, size: item.size)); changed = true
                            }
                        }
                        if i % 8 == 0 || i == candidates.count - 1 {
                            let increment = i + 1 - reported; reported = i + 1
                            DispatchQueue.main.async {
                                guard !token.cancelled else { return }
                                self?.settings.currentFile = url.lastPathComponent
                                self?.settings.completed += increment
                            }
                        }
                    }
                }
                let stats = try db.statistics()
                DispatchQueue.main.async { self?.settings.indexed = stats.indexed; self?.settings.skipped = stats.skipped }
            } catch { DispatchQueue.main.async { self?.settings.error = error.localizedDescription } }
        }
    }
    static func candidates(_ source: SearchSource, folders: [String], options: ExtractionOptions, cancelled: () -> Bool) -> [ContentCandidate] {
        guard !folders.isEmpty else { return [] }
        let store = source.store, count = store.read { store.count }
        let scope = ExcludedFolders.Matcher(folders)
        var result = [ContentCandidate]()
        // Drain bridged names/paths per batch, and release the index lock often
        // enough that FSEvents writers cannot stall foreground result reads.
        for start in stride(from: 1, to: count, by: 256) {
            if cancelled() { break }
            autoreleasepool { store.read {
                for i in start..<min(start + 256, min(count, store.count)) {
                    if i % 32 == 0 && cancelled() { break }
                    let id = UInt32(i)
                    guard store.isLive(id), store.flags[i] & (SiftFlag.dir | SiftFlag.symlink) == 0 else { continue }
                    let ext = (store.name(id) as NSString).pathExtension.lowercased()
                    guard ContentExtractor.supports(ext, options: options) else { continue }
                    let path = store.path(id)
                    guard scope.containsIndexedPath(path) else { continue }
                    let root = store.rootPath == "/" ? "" : store.rootPath
                    result.append(ContentCandidate(source: source.id, relative: String(path.dropFirst(root.count)), path: path,
                                                   mtime: store.mtime[i], size: store.size(id)))
                }
            } }
        }
        return result
    }
}
