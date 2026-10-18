import Foundation
import Darwin

final class WorkflowCancellation {
    private let lock = NSLock()
    private var stopped = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
}

enum WorkflowFailure: LocalizedError {
    case unavailable(String), unsupported(String), limit, cancelled, changed(String)
    var errorDescription: String? {
        switch self {
        case .unavailable(let path): return L10n.local("文件不在本机、已离线或无法读取：", "File is missing, offline, or unavailable locally: ") + URL(fileURLWithPath: path).lastPathComponent
        case .unsupported(let path): return L10n.local("导出副本暂不支持文件夹、应用包或链接：", "Copy export does not support folders, app bundles, or links: ") + URL(fileURLWithPath: path).lastPathComponent
        case .changed(let path): return L10n.local("文件在处理期间发生变化，请重试：", "File changed during processing. Try again: ") + URL(fileURLWithPath: path).lastPathComponent
        case .limit: return L10n.local("已达到本次处理上限，请减少文件数量或大小。", "This operation reached its limit. Reduce the number or size of files.")
        case .cancelled: return L10n.local("已取消，原文件未改动。", "Cancelled. Original files are unchanged.")
        }
    }
}

enum WorkflowFiles {
    struct Stamp: Equatable {
        let device: Int32, inode: UInt64, size: Int64, seconds: Int, nanos: Int
        init(_ info: stat) { device = info.st_dev; inode = info.st_ino; size = info.st_size; seconds = info.st_mtimespec.tv_sec; nanos = info.st_mtimespec.tv_nsec }
    }
    static let maximumFileBytes: Int64 = 100 * 1024 * 1024
    static let maximumExportBytes: Int64 = 500 * 1024 * 1024
    /// lstat avoids following links and opening cloud placeholders. Used only on utility queues.
    static func inspect(_ file: WorkFile, offline: Set<String> = [], regular: Bool = true) throws -> Stamp {
        guard !offline.contains(file.sourceID) else { throw WorkflowFailure.unavailable(file.path) }
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_flags & UInt32(SF_DATALESS) == 0,
              access(file.path, R_OK) == 0 else { throw WorkflowFailure.unavailable(file.path) }
        let kind = info.st_mode & S_IFMT
        guard kind == S_IFREG || (!regular && kind == S_IFDIR) else { throw WorkflowFailure.unsupported(file.path) }
        if regular && info.st_size > maximumFileBytes { throw WorkflowFailure.limit }
        return Stamp(info)
    }
    static func urls(_ files: [WorkFile], offline: Set<String>, cancelled: () -> Bool) throws -> [URL] {
        var urls = [URL]()
        for file in files {
            if cancelled() { throw WorkflowFailure.cancelled }
            _ = try inspect(file, offline: offline, regular: false)
            urls.append(URL(fileURLWithPath: file.path))
        }
        return urls
    }
    /// All-or-nothing in a newly created directory. Never overwrites an existing output
    /// and never moves originals. Stream in 1 MB chunks, with cancellation between chunks.
    static func export(_ files: [WorkFile], to parent: URL, offline: Set<String>, cancelled: () -> Bool) throws -> URL {
        guard !files.isEmpty, files.count <= WorkCollection.maximumItems else { throw WorkflowFailure.limit }
        let stamps = try files.map { file -> Stamp in
            if cancelled() { throw WorkflowFailure.cancelled }
            return try inspect(file, offline: offline)
        }
        guard stamps.reduce(Int64(0), { $0 + $1.size }) <= maximumExportBytes else { throw WorkflowFailure.limit }
        let root = parent.appendingPathComponent("Fox Find Collection-" + UUID().uuidString.prefix(8))
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        var committed = false
        defer { if !committed { try? fm.removeItem(at: root) } }
        var names = Set<String>()
        for (file, expected) in zip(files, stamps) {
            if cancelled() { throw WorkflowFailure.cancelled }
            let url = URL(fileURLWithPath: file.path)
            var name = url.lastPathComponent, suffix = 2
            while !names.insert(name.lowercased()).inserted {
                name = url.deletingPathExtension().lastPathComponent + " (\(suffix))" + (url.pathExtension.isEmpty ? "" : "." + url.pathExtension); suffix += 1
            }
            let target = root.appendingPathComponent(name)
            let descriptor = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { throw WorkflowFailure.unavailable(file.path) }
            let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? input.close() }
            var info = stat()
            guard fstat(descriptor, &info) == 0, Stamp(info) == expected else { throw WorkflowFailure.changed(file.path) }
            guard fm.createFile(atPath: target.path, contents: nil) else { throw WorkflowFailure.unavailable(target.path) }
            let output = try FileHandle(forWritingTo: target)
            defer { try? output.close() }
            var copied: Int64 = 0
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                if cancelled() { throw WorkflowFailure.cancelled }
                copied += Int64(chunk.count)
                guard copied <= expected.size else { throw WorkflowFailure.changed(file.path) }
                try output.write(contentsOf: chunk)
            }
            guard copied == expected.size, try inspect(file, offline: offline) == expected else { throw WorkflowFailure.changed(file.path) }
        }
        if cancelled() { throw WorkflowFailure.cancelled }
        committed = true; return root
    }
}
