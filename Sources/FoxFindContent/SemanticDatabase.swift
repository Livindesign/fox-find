import Foundation
import SQLite3
import Accelerate
import FoxFindSemanticCore

struct SemanticFile {
    let source: String, path: String, stamp: String
    let mtime: UInt32, size: UInt64
}
struct SemanticPiece {
    let ordinal: Int, page: Int, text: String, image: Bool, vector: [Float]
}
struct SemanticMatch {
    let file: SemanticFile, page: Int, text: String, image: Bool, score: Float
}
struct SemanticProgress { let cursor: Int, done: Bool, note: String }

/// Read connections have their own WAL snapshot. Ranking streams one vector at a time.
final class SemanticDatabase {
    static let version = "gemma2-\(ModelFiles.revision)-llama-v1-768-photo140-imageio2048-chunk800-v1"
    let url: URL
    private let writer: SemanticSQL
    private let lock = NSLock()
    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        writer = try SemanticSQL(url: url, write: true)
        try writer.exec("""
        PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;
        CREATE TABLE IF NOT EXISTS files(id INTEGER PRIMARY KEY,source TEXT NOT NULL,path TEXT NOT NULL,stamp TEXT NOT NULL,
          mtime INTEGER,size INTEGER,model TEXT NOT NULL,cursor INTEGER DEFAULT 0,done INTEGER DEFAULT 0,note TEXT DEFAULT '',UNIQUE(source,path));
        CREATE TABLE IF NOT EXISTS pieces(file INTEGER REFERENCES files(id) ON DELETE CASCADE,ordinal INTEGER,page INTEGER,text TEXT,image INTEGER,vector BLOB,PRIMARY KEY(file,ordinal));
        """)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func progress(_ file: SemanticFile) throws -> SemanticProgress? {
        let db = try SemanticSQL(url: url)
        return try db.query("SELECT cursor,done,note FROM files WHERE source=? AND path=? AND stamp=? AND model=?", [file.source,file.path,file.stamp,Self.version]) { s in
            SemanticProgress(cursor: Int(sqlite3_column_int(s,0)), done: sqlite3_column_int(s,1) != 0, note: db.string(s,2))
        }.first
    }
    /// Resume a matching fingerprint, otherwise atomically discard stale segments.
    func prepare(_ f: SemanticFile) throws {
        lock.lock(); defer { lock.unlock() }
        try writer.transaction {
            try writer.exec("DELETE FROM files WHERE source=? AND path=? AND (stamp<>? OR model<>?)", [f.source,f.path,f.stamp,Self.version])
            try writer.exec("INSERT OR IGNORE INTO files(source,path,stamp,mtime,size,model) VALUES(?,?,?,?,?,?)", [f.source,f.path,f.stamp,String(f.mtime),String(f.size),Self.version])
        }
    }
    func append(_ pieces: [SemanticPiece], to f: SemanticFile, cursor: Int, done: Bool, note: String = "") throws {
        lock.lock(); defer { lock.unlock() }
        try writer.transaction {
            let ids = try writer.query("SELECT id FROM files WHERE source=? AND path=? AND stamp=? AND model=?", [f.source,f.path,f.stamp,Self.version]) { sqlite3_column_int64($0,0) }
            guard let id = ids.first else { throw SemanticError.unavailable("File changed while indexing") }
            for piece in pieces {
                guard piece.vector.count == 768, piece.vector.allSatisfy(\.isFinite) else { throw SemanticError.invalidResponse }
                let s = try writer.statement("INSERT OR REPLACE INTO pieces(file,ordinal,page,text,image,vector) VALUES(?,?,?,?,?,?)", [String(id),String(piece.ordinal),String(piece.page),String(piece.text.prefix(400)),piece.image ? "1" : "0"])
                defer { sqlite3_finalize(s) }
                _ = piece.vector.withUnsafeBytes { sqlite3_bind_blob(s,6,$0.baseAddress,Int32($0.count),writer.transient) }
                guard sqlite3_step(s) == SQLITE_DONE else { throw writer.failure() }
            }
            try writer.exec("UPDATE files SET cursor=?,done=?,note=? WHERE id=?", [String(cursor),done ? "1" : "0",note,String(id)])
        }
    }
    func purge(folders: [String], sources: Set<String>? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        let files = try writer.query("SELECT id,path,source FROM files") { (sqlite3_column_int64($0,0),writer.string($0,1),writer.string($0,2)) }
        try writer.transaction {
            for (id,path,source) in files where !folders.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) || (sources != nil && !sources!.contains(source)) {
                try writer.exec("DELETE FROM files WHERE id=?", [String(id)])
            }
        }
    }
    func removeMissing(source: String, paths: Set<String>) throws {
        lock.lock(); defer { lock.unlock() }
        let rows = try writer.query("SELECT id,path FROM files WHERE source=?", [source]) { (sqlite3_column_int64($0,0),writer.string($0,1)) }
        try writer.transaction {
            for (id,path) in rows where !paths.contains(path) { try writer.exec("DELETE FROM files WHERE id=?", [String(id)]) }
        }
    }
    func remove(_ file: SemanticFile) throws {
        lock.lock(); defer { lock.unlock() }; try writer.exec("DELETE FROM files WHERE source=? AND path=?",[file.source,file.path])
    }
    func stats() throws -> (files: Int, pieces: Int, incomplete: Int) {
        let db = try SemanticSQL(url: url)
        return try db.query("SELECT (SELECT count(*) FROM files WHERE model=?),(SELECT count(*) FROM pieces JOIN files ON files.id=pieces.file WHERE model=?),(SELECT count(*) FROM files WHERE model=? AND (done=0 OR note<>''))", [Self.version,Self.version,Self.version]) {
            (Int(sqlite3_column_int($0,0)),Int(sqlite3_column_int($0,1)),Int(sqlite3_column_int($0,2)))
        }.first ?? (0,0,0)
    }
    func clear() throws { lock.lock(); defer { lock.unlock() }; try writer.exec("DELETE FROM files") }
    func search(vector: [Float], imagesOnly: Bool = false, limit: Int = 80,
                cancelled: () -> Bool, qualifies: (SemanticMatch) -> Bool = { _ in true }, accepts: (SemanticFile) -> Bool) throws -> [SemanticMatch] {
        guard vector.count == 768, vector.allSatisfy(\.isFinite), limit > 0 else { return [] }
        let db = try SemanticSQL(url: url)
        let s = try db.statement("SELECT f.id,f.source,f.path,f.stamp,f.mtime,f.size,p.page,p.text,p.image,p.vector FROM files f JOIN pieces p ON p.file=f.id WHERE f.model=?" + (imagesOnly ? " AND p.image=1 AND p.page=0" : "") + " ORDER BY f.id,p.ordinal", [Self.version])
        defer { sqlite3_finalize(s) }
        var best = [SemanticMatch](), lastID: Int64 = -1, allowed = false, file: SemanticFile?
        var current: SemanticMatch?, row = SQLITE_ROW
        func retain() {
            guard let current else { return }
            if best.count < limit || current.score > best.last!.score {
                guard qualifies(current) else { return }
                best.append(current); best.sort { $0.score == $1.score ? $0.file.path < $1.file.path : $0.score > $1.score }
                if best.count > limit { best.removeLast() }
            }
        }
        var floats = [Float](repeating: 0, count: 768)
        while !cancelled() {
            row = sqlite3_step(s); if row != SQLITE_ROW { break }
            let id = sqlite3_column_int64(s,0)
            if id != lastID {
                retain(); current = nil; lastID = id
                let f = SemanticFile(source: db.string(s,1),path: db.string(s,2),stamp: db.string(s,3),mtime: UInt32(clamping: sqlite3_column_int64(s,4)),size: UInt64(clamping: sqlite3_column_int64(s,5)))
                file = f; allowed = accepts(f)
            }
            guard allowed, let file, sqlite3_column_bytes(s,9) == 768 * 4, let pointer = sqlite3_column_blob(s,9) else { continue }
            floats.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(start: pointer,count: 768 * 4)) }
            var score: Float = 0
            vDSP_dotpr(vector,1,floats,1,&score,768)
            let image = sqlite3_column_int(s,8) != 0
            let threshold: Float = imagesOnly ? 0.75 : (image ? 0.60 : 0.65)
            guard score.isFinite, score >= threshold, score > (current?.score ?? -1) else { continue }
            current = SemanticMatch(file: file,page: Int(sqlite3_column_int(s,6)),text: db.string(s,7),image: sqlite3_column_int(s,8) != 0,score: score)
        }
        if cancelled() { return [] }
        guard row == SQLITE_DONE else { throw db.failure() }
        retain(); return best
    }
}

private final class SemanticSQL {
    private var db: OpaquePointer?
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(url: URL, write: Bool = false) throws {
        guard sqlite3_open_v2(url.path,&db,(write ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY) | SQLITE_OPEN_FULLMUTEX,nil) == SQLITE_OK else { throw failure() }
        sqlite3_busy_timeout(db,500)
    }
    deinit { sqlite3_close(db) }
    func failure() -> Error { NSError(domain: "FoxFind.SemanticDB",code: Int(sqlite3_errcode(db)),userInfo: [NSLocalizedDescriptionKey:String(cString:sqlite3_errmsg(db))]) }
    func statement(_ sql: String,_ values: [String] = []) throws -> OpaquePointer {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&s,nil) == SQLITE_OK, let s else { throw failure() }
        for (i,v) in values.enumerated() { sqlite3_bind_text(s,Int32(i+1),v,-1,transient) }; return s
    }
    func exec(_ sql: String,_ values: [String] = []) throws {
        if values.isEmpty { guard sqlite3_exec(db,sql,nil,nil,nil) == SQLITE_OK else { throw failure() }; return }
        let s = try statement(sql,values); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw failure() }
    }
    func query<T>(_ sql: String,_ values: [String] = [],_ read: (OpaquePointer) -> T) throws -> [T] {
        let s = try statement(sql,values); defer { sqlite3_finalize(s) }; var result = [T]()
        while true { let rc = sqlite3_step(s); if rc == SQLITE_DONE { return result }; guard rc == SQLITE_ROW else { throw failure() }; result.append(read(s)) }
    }
    func string(_ s: OpaquePointer,_ c: Int32) -> String { sqlite3_column_text(s,c).map { String(cString:$0) } ?? "" }
    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE"); do { try body(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }
    }
}
