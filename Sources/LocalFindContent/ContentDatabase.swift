import Foundation
import SQLite3
import OilFindApp

struct ContentRecord {
    var source: String, path: String, fingerprint: String, text: String, category: String, note: String
    var mtime: UInt32, size: UInt64
    var segments: [ContentTextSegment] = []
    /// Query-local BM25 evidence; larger is better. Never persisted with the document.
    var lexicalScore: Double? = nil
}

/// Serialized writes and independent read snapshots, with WAL and a trigram substring index.
final class ContentDatabase {
    let directory: URL
    private let fileURL: URL
    private var db: OpaquePointer?
    private let lock = NSLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(url: URL, readOnly: Bool = false) throws {
        fileURL = url
        directory = url.deletingLastPathComponent()
        if readOnly {
            guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw failure() }
            sqlite3_busy_timeout(db, 500); return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw failure()
        }
        sqlite3_busy_timeout(db, 3000)
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA secure_delete=ON;")
        try exec("""
        CREATE TABLE IF NOT EXISTS documents (
          source TEXT NOT NULL, path TEXT NOT NULL, fingerprint TEXT NOT NULL,
          text TEXT NOT NULL, category TEXT NOT NULL, note TEXT NOT NULL,
          mtime INTEGER NOT NULL, size INTEGER NOT NULL, UNIQUE(source,path));
        CREATE VIRTUAL TABLE IF NOT EXISTS text_search USING fts5(fold, tokenize='trigram');
        CREATE TRIGGER IF NOT EXISTS documents_delete AFTER DELETE ON documents BEGIN
          DELETE FROM text_search WHERE rowid=old.rowid;
        END;
        """)
        let columns = try statement("PRAGMA table_info(documents)")
        var hasSegments = false
        while sqlite3_step(columns) == SQLITE_ROW { if string(columns, 1) == "segments" { hasSegments = true } }
        sqlite3_finalize(columns)
        if !hasSegments { try exec("ALTER TABLE documents ADD COLUMN segments TEXT NOT NULL DEFAULT '[]'") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    deinit { sqlite3_close(db) }
    private func failure() -> Error {
        NSError(domain: "LocalFind.Database", code: Int(sqlite3_errcode(db)), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
    }
    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func statement(_ sql: String, _ values: [String] = []) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure() }
        for (i, value) in values.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), value, -1, transient) }
        return stmt
    }
    private func string(_ stmt: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
    }
    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping
    }
    func fingerprints(source: String) throws -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        let s = try statement("SELECT path,fingerprint FROM documents WHERE source=?", [source]); defer { sqlite3_finalize(s) }
        var result: [String: String] = [:]
        while sqlite3_step(s) == SQLITE_ROW { result[string(s, 0)] = string(s, 1) }
        return result
    }
    func put(_ record: ContentRecord) throws {
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE")
        do {
            let s = try statement("""
            INSERT INTO documents(source,path,fingerprint,text,category,note,mtime,size,segments) VALUES(?,?,?,?,?,?,?,?,?)
            ON CONFLICT(source,path) DO UPDATE SET fingerprint=excluded.fingerprint,text=excluded.text,
              category=excluded.category,note=excluded.note,mtime=excluded.mtime,size=excluded.size,segments=excluded.segments
            """, [record.source, record.path, record.fingerprint, record.text, record.category, record.note,
                  String(record.mtime), String(record.size), String(data: try JSONEncoder().encode(record.segments), encoding: .utf8) ?? "[]"])
            defer { sqlite3_finalize(s) }
            guard sqlite3_step(s) == SQLITE_DONE else { throw failure() }
            let f = try statement("INSERT OR REPLACE INTO text_search(rowid,fold) SELECT rowid,? FROM documents WHERE source=? AND path=?",
                                  [Self.folded(record.text), record.source, record.path]); defer { sqlite3_finalize(f) }
            guard sqlite3_step(f) == SQLITE_DONE else { throw failure() }
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
    }
    func remove(source: String, paths: [String]) throws {
        guard !paths.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE")
        do {
            let s = try statement("DELETE FROM documents WHERE source=? AND path=?"); defer { sqlite3_finalize(s) }
            for path in paths {
                sqlite3_reset(s); sqlite3_clear_bindings(s)
                sqlite3_bind_text(s, 1, source, -1, transient); sqlite3_bind_text(s, 2, path, -1, transient)
                guard sqlite3_step(s) == SQLITE_DONE else { throw failure() }
            }
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
    }
    func candidates(needles: [String], sources: [String], cancelled: @escaping () -> Bool) throws -> [ContentRecord] {
        var result = [ContentRecord]()
        try visitCandidates(needles: needles, sources: sources, cancelled: cancelled) { result.append($0); return true }
        return result
    }
    func visitCandidates(needles: [String], sources: [String], cancelled: @escaping () -> Bool, visit: (ContentRecord) -> Bool) throws {
        guard !sources.isEmpty, !cancelled() else { return }
        let reader = try ContentDatabase(url: fileURL, readOnly: true)
        try reader.readCandidates(needles: needles, sources: sources, cancelled: cancelled, visit: visit)
    }
    private func readCandidates(needles: [String], sources: [String], cancelled: @escaping () -> Bool, visit: (ContentRecord) -> Bool) throws {
        let cancellation = SQLCancellation(cancelled)
        sqlite3_progress_handler(db, 1000, { context in
            guard let context else { return 0 }
            return Unmanaged<SQLCancellation>.fromOpaque(context).takeUnretainedValue().check() ? 1 : 0
        }, Unmanaged.passUnretained(cancellation).toOpaque())
        defer { sqlite3_progress_handler(db, 0, nil, nil); withExtendedLifetime(cancellation) {} }
        // LIKE on FTS5's trigram table accelerates substrings of three or more characters.
        // instr handles literal % and _ without turning user input into wildcard syntax.
        let folded = Array(Set(needles.map(Self.folded))).sorted()
        // Trigram MATCH cannot represent one- or two-character terms. Keep literal
        // substring retrieval for the entire OR query in that case, so mixed Chinese
        // short terms never disappear. All MATCH terms are quoted data, not FTS syntax.
        let ranked = !folded.isEmpty && folded.allSatisfy { $0.unicodeScalars.count >= 3 && $0.utf8.count < 32_000 && !$0.contains("\0") }
        let clauses = folded.map { $0.contains("%") || $0.contains("_") ? "instr(f.fold,?)>0" : "f.fold LIKE ?" }
        let values = ranked ? [folded.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " OR ")]
            : zip(folded, clauses).map { $1.hasPrefix("instr") ? $0 : "%" + $0 + "%" }
        let predicate = ranked ? "text_search MATCH ?" : (clauses.isEmpty ? "d.text<>''" : clauses.joined(separator: " OR "))
        let placeholders = sources.map { _ in "?" }.joined(separator: ",")
        let s = try statement("""
        SELECT d.source,d.path,d.fingerprint,d.text,d.category,d.note,d.mtime,d.size,\(ranked ? "f.rank" : "NULL")
        FROM text_search f JOIN documents d ON d.rowid=f.rowid
        WHERE d.source IN (\(placeholders)) AND (\(predicate))
        \(ranked ? "ORDER BY f.rank" : "")
        """, sources + values)
        defer { sqlite3_finalize(s) }
        while !cancelled(), sqlite3_step(s) == SQLITE_ROW {
            var row = ContentRecord(source: string(s, 0), path: string(s, 1), fingerprint: string(s, 2),
                                    text: string(s, 3), category: string(s, 4), note: string(s, 5),
                                    mtime: UInt32(clamping: sqlite3_column_int64(s, 6)), size: UInt64(clamping: sqlite3_column_int64(s, 7)))
            if ranked { row.lexicalScore = -sqlite3_column_double(s, 8) }
            if !visit(row) { break }
        }
    }
    func statistics() throws -> (indexed: Int, skipped: Int) {
        lock.lock(); defer { lock.unlock() }
        let s = try statement("SELECT sum(text<>''),sum(note<>'') FROM documents"); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { throw failure() }
        return (Int(sqlite3_column_int64(s, 0)), Int(sqlite3_column_int64(s, 1)))
    }
    func record(source: String, path: String) throws -> ContentRecord? {
        lock.lock(); defer { lock.unlock() }
        let s = try statement("SELECT source,path,fingerprint,text,category,note,mtime,size,segments FROM documents WHERE source=? AND path=?", [source, path])
        defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { return nil }
        return ContentRecord(source: string(s, 0), path: string(s, 1), fingerprint: string(s, 2), text: string(s, 3),
                             category: string(s, 4), note: string(s, 5), mtime: UInt32(clamping: sqlite3_column_int64(s, 6)), size: UInt64(clamping: sqlite3_column_int64(s, 7)),
                             segments: (try? JSONDecoder().decode([ContentTextSegment].self, from: Data(string(s, 8).utf8))) ?? [])
    }
    func diagnostics(limit: Int = 100) throws -> [(source: String, path: String, note: String)] {
        lock.lock(); defer { lock.unlock() }
        let s = try statement("SELECT source,path,note FROM documents WHERE note<>'' ORDER BY category='skipped' DESC,path LIMIT ?", [String(max(1, min(limit, 1000)))])
        defer { sqlite3_finalize(s) }
        var rows: [(source: String, path: String, note: String)] = []
        while sqlite3_step(s) == SQLITE_ROW { rows.append((string(s, 0), string(s, 1), string(s, 2))) }
        return rows
    }
    /// Retain usable cached text while marking incomplete records for the next extraction pass.
    func retryIncomplete() throws {
        lock.lock(); defer { lock.unlock() }
        try exec("UPDATE documents SET fingerprint='retry:' || fingerprint WHERE note<>'' AND fingerprint NOT LIKE 'retry:%'")
    }
    func clear() throws {
        lock.lock(); defer { lock.unlock() }
        try exec("DELETE FROM documents; DELETE FROM text_search; PRAGMA wal_checkpoint(TRUNCATE); VACUUM;")
    }
}

private final class SQLCancellation {
    let check: () -> Bool
    init(_ check: @escaping () -> Bool) { self.check = check }
}
