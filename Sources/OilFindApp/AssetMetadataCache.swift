import Foundation
import SQLite3

/// Small per-file records, read only on the serial metadata queue.
final class AssetMetadataCache {
    private var db: OpaquePointer?
    private let lock = NSLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK { sqlite3_close(db); db = nil; return }
        sqlite3_busy_timeout(db, 1000)
        sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; CREATE TABLE IF NOT EXISTS metadata(path TEXT PRIMARY KEY,stamp TEXT NOT NULL,payload BLOB NOT NULL)", nil, nil, nil)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    deinit { sqlite3_close(db) }
    func read(path: String, stamp: String?, prefix: String? = nil) -> AssetMetadata? {
        lock.lock(); defer { lock.unlock() }; guard let db else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT stamp,payload FROM metadata WHERE path=?", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, path, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let stored = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
        guard stamp == nil || stored == stamp, prefix == nil || stored.hasPrefix(prefix!), let bytes = sqlite3_column_blob(statement, 1) else { return nil }
        return try? JSONDecoder().decode(AssetMetadata.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1))))
    }
    /// Priority hints only: every candidate is validated against the current file
    /// before display, and rows absent from this cache are still inspected.
    func captureCandidates(_ interval: DateInterval) -> [String] {
        lock.lock(); defer { lock.unlock() }; guard let db else { return [] }
        var statement: OpaquePointer?
        let sql = "SELECT path FROM metadata WHERE json_extract(payload,'$.capturedAt') >= ? AND json_extract(payload,'$.capturedAt') < ? LIMIT 10000"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, interval.start.timeIntervalSinceReferenceDate)
        sqlite3_bind_double(statement, 2, interval.end.timeIntervalSinceReferenceDate)
        var paths: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bytes = sqlite3_column_text(statement, 0) else { continue }
            let path = String(cString: bytes)
            if path.hasSuffix("#media") { paths.append(String(path.dropLast(6))) }
        }
        return paths
    }
    func put(path: String, stamp: String, info: AssetMetadata) {
        guard let data = try? JSONEncoder().encode(info) else { return }
        lock.lock(); defer { lock.unlock() }; guard let db else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO metadata(path,stamp,payload) VALUES(?,?,?)", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, path, -1, transient); sqlite3_bind_text(statement, 2, stamp, -1, transient)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32(data.count), transient) }
        sqlite3_step(statement)
    }
}
