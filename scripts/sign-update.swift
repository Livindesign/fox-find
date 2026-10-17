// The release private key lives outside the repository. Never upload it.
import Foundation
import CryptoKit

let arguments = CommandLine.arguments
let keyURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Fox Find Release/ed25519.key")
if arguments.count == 2 && arguments[1] == "--initialize" {
    if !FileManager.default.fileExists(atPath: keyURL.path) {
        try FileManager.default.createDirectory(at: keyURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let key = Curve25519.Signing.PrivateKey()
        try key.rawRepresentation.write(to: keyURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
    }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: keyURL))
    print(key.publicKey.rawRepresentation.base64EncodedString())
    exit(0)
}
guard arguments.count == 6 else { fatalError("Usage: sign-update.swift archive.zip Info.plist release-tag notes.json output.json") }
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: keyURL))
let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: arguments[2])), format: nil) as! [String: Any]
guard info["FoxUpdatePublicKey"] as? String == key.publicKey.rawRepresentation.base64EncodedString() else { fatalError("Release key does not match app public key") }
let archive = URL(fileURLWithPath: arguments[1])
let tag = arguments[3]
guard tag.range(of: #"^v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil else { fatalError("Invalid release tag") }
let bytes = try Data(contentsOf: archive, options: .mappedIfSafe)
let notes = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: arguments[4])))
let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withFullDate]
let payload: [String: Any] = ["version": info["CFBundleShortVersionString"]!, "build": Int(info["CFBundleVersion"] as! String)!,
    "url": "https://github.com/Livindesign/fox-find/releases/download/\(tag)/\(archive.lastPathComponent)",
    "size": bytes.count, "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
    "minimumSystemVersion": info["LSMinimumSystemVersion"]!, "published": formatter.string(from: Date()), "notes": notes]
let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
let envelope = ["payload": data.base64EncodedString(), "signature": try key.signature(for: data).base64EncodedString()]
try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]).write(to: URL(fileURLWithPath: arguments[5]), options: .atomic)
print("Signed update manifest: " + arguments[5])
