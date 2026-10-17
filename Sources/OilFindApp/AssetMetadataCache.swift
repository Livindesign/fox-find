import Foundation
import SQLite3

/// Small per-file records, read only on the serial metadata queue.
final class AssetMetadataCache {
    private var db: OpaquePointer?
    private let lock = NSLock()
    private var readStatement: OpaquePointer?, writeStatement: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK { sqlite3_close(db); db = nil; return }
        sqlite3_busy_timeout(db, 1000)
        sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; CREATE TABLE IF NOT EXISTS metadata(path TEXT PRIMARY KEY,stamp TEXT NOT NULL,payload BLOB NOT NULL)", nil, nil, nil)
        // Upgrade existing local metadata once; indexed lookup must not parse every
        // JSON blob on each search. Rebuild month keys if the local timezone changes.
        sqlite3_exec(db, "ALTER TABLE metadata ADD COLUMN capture_time REAL", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE metadata ADD COLUMN capture_month INTEGER", nil, nil, nil)
        sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS cache_metadata(key TEXT PRIMARY KEY,value TEXT)", nil, nil, nil)
        var state: OpaquePointer?
        var zone: String?
        if sqlite3_prepare_v2(db, "SELECT value FROM cache_metadata WHERE key='capture-index-zone-v1'", -1, &state, nil) == SQLITE_OK,
           sqlite3_step(state) == SQLITE_ROW, let value = sqlite3_column_text(state, 0) { zone = String(cString: value) }
        sqlite3_finalize(state)
        if zone != TimeZone.current.identifier {
            sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
            let rebuilt = sqlite3_exec(db, "UPDATE metadata SET capture_time=json_extract(payload,'$.capturedAt'), capture_month=CAST(strftime('%m',json_extract(payload,'$.capturedAt')+978307200,'unixepoch','localtime') AS INTEGER)", nil, nil, nil) == SQLITE_OK
            var save: OpaquePointer?
            if rebuilt, sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO cache_metadata VALUES('capture-index-zone-v1',?)", -1, &save, nil) == SQLITE_OK {
                sqlite3_bind_text(save, 1, TimeZone.current.identifier, -1, transient); sqlite3_step(save)
            }
            sqlite3_finalize(save)
            sqlite3_exec(db, rebuilt ? "COMMIT" : "ROLLBACK", nil, nil, nil)
        }
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS metadata_capture_time ON metadata(capture_time); CREATE INDEX IF NOT EXISTS metadata_capture_month ON metadata(capture_month)", nil, nil, nil)
        sqlite3_prepare_v2(db, "SELECT stamp,payload FROM metadata WHERE path=?", -1, &readStatement, nil)
        sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO metadata(path,stamp,payload,capture_time,capture_month) VALUES(?,?,?,?,?)", -1, &writeStatement, nil)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    deinit { sqlite3_finalize(readStatement); sqlite3_finalize(writeStatement); sqlite3_close(db) }
    func read(path: String, stamp: String?, prefix: String? = nil) -> AssetMetadata? {
        lock.lock(); defer { lock.unlock() }; guard db != nil else { return nil }
        guard let statement = readStatement else { return nil }
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        sqlite3_bind_text(statement, 1, path, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let stored = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
        guard stamp == nil || stored == stamp, prefix == nil || stored.hasPrefix(prefix!), let bytes = sqlite3_column_blob(statement, 1) else { return nil }
        return try? JSONDecoder().decode(AssetMetadata.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1))))
    }
    /// Priority hints only: every candidate is validated against the current file
    /// before display, and rows absent from this cache are still inspected.
    func captureCandidates(_ interval: DateInterval?, month: Int? = nil) -> [String] {
        lock.lock(); defer { lock.unlock() }; guard let db else { return [] }
        var statement: OpaquePointer?
        guard interval != nil || month != nil else { return [] }
        let sql = month != nil ? "SELECT path FROM metadata WHERE capture_month=? LIMIT 10000" : "SELECT path FROM metadata WHERE capture_time >= ? AND capture_time < ? LIMIT 10000"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        if let month { sqlite3_bind_int(statement, 1, Int32(month)) }
        else if let interval {
            sqlite3_bind_double(statement, 1, interval.start.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(statement, 2, interval.end.timeIntervalSinceReferenceDate)
        }
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
        lock.lock(); defer { lock.unlock() }; guard db != nil else { return }
        guard let statement = writeStatement else { return }
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        sqlite3_bind_text(statement, 1, path, -1, transient); sqlite3_bind_text(statement, 2, stamp, -1, transient)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32(data.count), transient) }
        if let capture = info.capturedAt {
            sqlite3_bind_double(statement, 4, capture.timeIntervalSinceReferenceDate)
            sqlite3_bind_int(statement, 5, Int32(Calendar(identifier: .gregorian).component(.month, from: capture)))
        }
        sqlite3_step(statement)
    }
}
