import XCTest
import CryptoKit
@testable import OilFindCore

final class FoxUpdateTests: XCTestCase {
    private func payload(url: String = "https://github.com/Livindesign/fox-find/releases/download/v0.8.6/Fox-Find-0.8.6-macOS-arm64.zip", build: Int = 21) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": "0.8.6", "build": build, "url": url, "size": 10,
            "sha256": String(repeating: "a", count: 64), "minimumSystemVersion": "14.0", "published": "2026-10-17",
            "notes": ["zh": ["更新内容"], "en": ["Changes"]]])
    }
    private func signed(_ data: Data, key: Curve25519.Signing.PrivateKey) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["payload": data.base64EncodedString(), "signature": try key.signature(for: data).base64EncodedString()])
    }
    func testSignedReleaseAndTampering() throws {
        let key = Curve25519.Signing.PrivateKey(), data = try payload()
        let envelope = try signed(data, key: key)
        XCTAssertEqual(try FoxUpdateTrust.verify(envelope, publicKey: key.publicKey.rawRepresentation).build, 21)
        XCTAssertThrowsError(try FoxUpdateTrust.verify(envelope, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation))
        let tampered = try JSONSerialization.data(withJSONObject: ["payload": try payload(build: 99).base64EncodedString(), "signature": try key.signature(for: data).base64EncodedString()])
        XCTAssertThrowsError(try FoxUpdateTrust.verify(tampered, publicKey: key.publicKey.rawRepresentation))
        XCTAssertThrowsError(try FoxUpdateTrust.verify(data, publicKey: key.publicKey.rawRepresentation))
    }
    func testOnlyOwnRepositoryAndArchitectureAreEligible() throws {
        let key = Curve25519.Signing.PrivateKey()
        for url in ["https://github.com/other/fox-find/releases/download/v1/a-macOS-arm64.zip",
                    "https://github.com/Livindesign/fox-find/releases/download/v1/a-macOS-x86.zip",
                    "http://github.com/Livindesign/fox-find/releases/download/v1/a-macOS-arm64.zip",
                    "https://evil.example/Livindesign/fox-find/releases/download/v1/a-macOS-arm64.zip"] {
            XCTAssertThrowsError(try FoxUpdateTrust.verify(signed(payload(url: url), key: key), publicKey: key.publicKey.rawRepresentation))
        }
        XCTAssertTrue(FoxUpdateTrust.allowsRedirect(URL(string: "https://release-assets.githubusercontent.com/a?token=fixture")!))
        for url in ["http://github.com/a", "https://github.com.evil.test/a", "https://evil.test/a", "https://user:pass@github.com/a", "https://github.com:9999/a"] {
            XCTAssertFalse(FoxUpdateTrust.allowsRedirect(URL(string: url)!))
        }
    }
    func testSkipDoesNotHideNewBuildOfSameVersion() throws {
        let suite = "FoxUpdateTests." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = UpdatePreferences(defaults: defaults), first = try UpdateManifest.parse(payload())
        let second = try UpdateManifest.parse(payload(build: 22)), current = UpdateVersion("0.8.5", build: 20)!
        let system = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
        preferences.skip(first)
        XCTAssertFalse(preferences.shouldOffer(first, current: current, system: system, manual: false))
        XCTAssertTrue(preferences.shouldOffer(second, current: current, system: system, manual: false))
        XCTAssertTrue(preferences.shouldOffer(first, current: current, system: system, manual: true))
    }
    func testGitHubReleaseDownloadTransport() async throws {
        guard let path = ProcessInfo.processInfo.environment["FOX_TEST_GITHUB_TRANSPORT_MANIFEST"] else {
            throw XCTSkip("Optional real GitHub download; uses public release metadata, never installs")
        }
        let manifest = try UpdateManifest.parse(Data(contentsOf: URL(fileURLWithPath: path)))
        let archive = try await GitHubUpdateClient(publicKey: Data()).download(manifest) { _ in }
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        try SystemUpdateFiles().verifyArchive(archive, manifest: manifest)
    }
    func testPackagedInstallAndRollbackInIsolatedDirectory() throws {
        guard let archivePath = ProcessInfo.processInfo.environment["FOX_TEST_UPDATE_ARCHIVE"],
              let manifestPath = ProcessInfo.processInfo.environment["FOX_TEST_UPDATE_MANIFEST"],
              let publicKey = Data(base64Encoded: ProcessInfo.processInfo.environment["FOX_TEST_UPDATE_PUBLIC_KEY"] ?? "")
        else { throw XCTSkip("Requires a signed release archive; never touches /Applications") }
        let manifest = try FoxUpdateTrust.verify(Data(contentsOf: URL(fileURLWithPath: manifestPath)), publicKey: publicKey)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoxUpdateIntegration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Fox Find.app")
        try FileManager.default.createDirectory(at: target.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let oldInfo: [String: Any] = ["CFBundleIdentifier": "app.localfind.desktop", "CFBundleShortVersionString": "0.0.0", "CFBundleVersion": "0"]
        try PropertyListSerialization.data(fromPropertyList: oldInfo, format: .xml, options: 0).write(to: target.appendingPathComponent("Contents/Info.plist"))
        try Data("original".utf8).write(to: target.appendingPathComponent("original-marker"))
        let installer = UpdateInstaller(application: target, current: UpdateVersion("0.0.0", build: 0)!, signature: FoxUpdateSignature())
        let installation = try installer.install(archive: URL(fileURLWithPath: archivePath), manifest: manifest)
        XCTAssertEqual(try SystemUpdateFiles().version(of: target), manifest.release)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installation.backup.appendingPathComponent("original-marker").path))
        try installer.rollback(installation)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("original-marker")), "original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installation.workspace.path))
    }
}
