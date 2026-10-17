import Foundation
import CryptoKit
import Security

/// A signed release manifest binds the version, archive hash and repository URL.
/// Ad-hoc app signatures alone cannot authenticate a new release.
public enum FoxUpdateTrust {
    public static let feed = URL(string: "https://github.com/Livindesign/fox-find/releases/latest/download/fox-find-update.json")!
    public static let releases = URL(string: "https://github.com/Livindesign/fox-find/releases")!
    public static func allowsRedirect(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
            && ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(url.host ?? "")
    }
    public static func verify(_ data: Data, publicKey: Data) throws -> UpdateManifest {
        struct Envelope: Decodable { let payload: Data; let signature: Data }
        guard data.count <= 131_072, let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(envelope.signature, for: envelope.payload) else { throw UpdateFailure.signature }
        let manifest = try UpdateManifest.parse(envelope.payload)
        guard manifest.size <= 268_435_456, manifest.url.host == "github.com", allowsRedirect(manifest.url),
              manifest.url.query == nil,
              manifest.url.path.hasPrefix("/Livindesign/fox-find/releases/download/"),
              manifest.url.pathComponents.count == 7, manifest.url.lastPathComponent.hasSuffix("-macOS-arm64.zip")
        else { throw UpdateFailure.integrity }
        return manifest
    }
}

private class GitHubRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(FoxUpdateTrust.allowsRedirect) == true ? request : nil)
    }
}

public final class GitHubUpdateClient {
    private let key: Data
    public init(publicKey: Data) { key = publicKey }
    private func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 600
        config.httpAdditionalHeaders = ["User-Agent": "FoxFind-Updater", "Accept": "application/octet-stream"]
        return config
    }
    public func check() async throws -> UpdateManifest? {
        let session = URLSession(configuration: configuration(), delegate: GitHubRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(from: FoxUpdateTrust.feed)
            let code = (response as? HTTPURLResponse)?.statusCode
            if code == 404 { return nil } // No stable release/feed has been published yet.
            guard code == 200 else { throw UpdateFailure.network }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 131_072 else { throw UpdateFailure.integrity }
                data.append(byte)
            }
            return try FoxUpdateTrust.verify(data, publicKey: key)
        } catch let failure as UpdateFailure { throw failure }
        catch { throw UpdateFailure.network }
    }
    public func download(_ manifest: UpdateManifest, progress: @escaping (Double) -> Void) async throws -> URL {
        guard FoxUpdateTrust.allowsRedirect(manifest.url), manifest.url.host == "github.com" else { throw UpdateFailure.integrity }
        return try await withCheckedThrowingContinuation { continuation in
            let delegate = GitHubArchiveDownload(size: manifest.size, progress: progress) { continuation.resume(with: $0) }
            let session = URLSession(configuration: configuration(), delegate: delegate, delegateQueue: nil)
            session.downloadTask(with: manifest.url).resume()
        }
    }
}

private final class GitHubArchiveDownload: GitHubRedirects, URLSessionDownloadDelegate {
    let size: Int64
    let progress: (Double) -> Void
    var completion: ((Result<URL, Error>) -> Void)?
    var lastPercent = -1
    var oversized = false
    init(size: Int64, progress: @escaping (Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        self.size = size; self.progress = progress; self.completion = completion
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > size { oversized = true; downloadTask.cancel(); return }
        let percent = Int(Double(totalBytesWritten) / Double(size) * 100)
        if percent != lastPercent { lastPercent = percent; progress(Double(percent) / 100) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else { finish(session, .failure(UpdateFailure.network)); return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("foxfind-download-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let target = folder.appendingPathComponent("update.zip")
            try FileManager.default.moveItem(at: location, to: target)
            finish(session, .success(target))
        } catch { try? FileManager.default.removeItem(at: folder); finish(session, .failure(UpdateFailure.other)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil { finish(session, .failure(oversized ? UpdateFailure.integrity : UpdateFailure.network)) }
    }
    private func finish(_ session: URLSession, _ result: Result<URL, Error>) {
        let callback = completion; completion = nil; callback?(result); session.finishTasksAndInvalidate()
    }
}

/// Called only after a manifest authenticated with the embedded release key and
/// a matching archive hash. Strict code validation also covers nested helpers.
public struct FoxUpdateSignature: UpdateSignatureValidating {
    public init() {}
    public func validate(_ app: URL) throws {
        _ = try SystemUpdateFiles().version(of: app)
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), nil) == errSecSuccess
        else { throw UpdateFailure.signature }
    }
}
