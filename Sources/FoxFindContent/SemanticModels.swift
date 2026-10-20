import Foundation
import Combine
import FoxFindSemanticCore

/// Only verified weights are promoted from URLSession's temporary download to the model directory.
final class SemanticModels: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published var ready = false
    @Published var downloading = false
    @Published var progress: Double = 0
    @Published var error = ""
    let directory: URL
    var onReady: (() -> Void)?
    private var session: URLSession?, task: URLSessionDownloadTask?
    private var current = 0, generation = 0
    init(directory: URL) {
        self.directory = directory; super.init()
        verifyExisting()
    }
    func verifyExisting() {
        let directory = directory
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let valid = ModelFiles.all.allSatisfy { file in
                let path = directory.appendingPathComponent(file.name)
                return (try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(file.bytes) && (try? ModelFiles.sha256(of: path)) == file.sha256
            }
            DispatchQueue.main.async { self?.ready = valid; if valid { self?.onReady?() } }
        }
    }
    func download() {
        guard !downloading else { return }
        generation += 1; current = 0; downloading = true; error = ""; progress = 0
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 1800
        session = URLSession(configuration: config,delegate: self,delegateQueue: .main)
        next()
    }
    func cancel() {
        generation += 1; task?.cancel(); session?.invalidateAndCancel(); session = nil; task = nil; downloading = false
    }
    private func next() {
        guard downloading else { return }
        guard current < ModelFiles.all.count else {
            downloading = false; ready = true; progress = 1; session?.finishTasksAndInvalidate(); session = nil; onReady?(); return
        }
        task = session?.downloadTask(with: ModelFiles.all[current].url); task?.resume()
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard downloadTask === task else { return }
        let completed = ModelFiles.all.prefix(current).reduce(Int64(0)) { $0 + $1.bytes }
        progress = min(1, Double(completed + totalBytesWritten) / Double(ModelFiles.totalBytes))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard downloadTask === task, current < ModelFiles.all.count else { return }
        let file = ModelFiles.all[current], token = generation, directory = directory
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw SemanticError.unavailable("Model download failed") }
            try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true,attributes: [.posixPermissions:0o700])
            let temporary = directory.appendingPathComponent(UUID().uuidString + ".part")
            try FileManager.default.moveItem(at: location,to: temporary)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let valid = (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(file.bytes) && (try? ModelFiles.sha256(of: temporary)) == file.sha256
                DispatchQueue.main.async {
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    guard let self, token == self.generation else { return }
                    guard valid else { self.fail("Model checksum mismatch. Retry the download."); return }
                    do {
                        let target = directory.appendingPathComponent(file.name)
                        if FileManager.default.fileExists(atPath: target.path) { _ = try FileManager.default.replaceItemAt(target,withItemAt: temporary) }
                        else { try FileManager.default.moveItem(at: temporary,to: target) }
                        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:target.path)
                        self.current += 1; self.next()
                    } catch { self.fail(error.localizedDescription) }
                }
            }
        } catch { fail(error.localizedDescription) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task, let error, downloading else { return }; fail(error.localizedDescription)
    }
    private func fail(_ message: String) { error = message; cancel() }
}
