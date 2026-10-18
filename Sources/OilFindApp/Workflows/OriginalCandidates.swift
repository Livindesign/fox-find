import Foundation
import ImageIO
import CryptoKit
import Darwin

/// Candidate evidence, never a claim that a file is the user's original.
enum OriginalCandidates {
    enum Evidence: Int { case identical, similar, relatedName }
    struct Candidate {
        let file: WorkFile, width: Int, height: Int, bytes: Int64, thumbnail: CGImage
        let evidence: Evidence
        var explanation: String {
            switch evidence {
            case .identical: return L10n.local("内容完全相同 · SHA-256 一致", "Identical bytes · SHA-256 verified")
            case .similar: return L10n.local("画面可能相似 · 请对照确认", "Possibly similar image · Compare to confirm")
            case .relatedName: return L10n.local("名称相关 · 未确认画面相同", "Related filename · Image match not confirmed")
            }
        }
    }
    struct Report {
        let reference: Fingerprint
        let matches: [Candidate]
        let checked: Int, skipped: Int
        let limited: Bool
    }
    struct Fingerprint {
        let width: Int, height: Int, hash: UInt64, spread: Int, color: [Int], thumbnail: CGImage
    }
    static let maximumCandidates = 64
    static let maximumVisited = 512
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "bmp", "gif", "webp", "avif"]

    /// Direct children only. No recursive scan, packages, links, or cloud downloads.
    static func folderCandidates(_ folder: URL, cancelled: () -> Bool) -> (files: [WorkFile], limited: Bool) {
        let began = Date()
        guard let iterator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants, .skipsHiddenFiles]) else { return ([], false) }
        var files = [WorkFile](), visited = 0
        for case let url as URL in iterator {
            if cancelled() || visited >= maximumVisited || files.count >= maximumCandidates || Date().timeIntervalSince(began) > 2 { return (files, true) }
            visited += 1
            if extensions.contains(url.pathExtension.lowercased()) { files.append(WorkFile(path: url.path)) }
        }
        return (files, false)
    }
    static func fingerprint(_ path: String) throws -> Fingerprint {
        _ = try WorkflowFiles.inspect(WorkFile(path: path))
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawWidth = props[kCGImagePropertyPixelWidth] as? Int, let rawHeight = props[kCGImagePropertyPixelHeight] as? Int,
              rawWidth > 0, rawHeight > 0, rawWidth <= 16000, rawHeight <= 16000,
              Int64(rawWidth) * Int64(rawHeight) <= 36_000_000,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 128,
                kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw WorkflowFailure.unavailable(path) }
        let rotated = [5, 6, 7, 8].contains(props[kCGImagePropertyOrientation] as? Int ?? 1)
        var pixels = [UInt8](repeating: 0, count: 9 * 8 * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 9, height: 8, bitsPerComponent: 8, bytesPerRow: 36,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium; context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: 9, height: 8)); return true
        }
        guard rendered else { throw WorkflowFailure.unavailable(path) }
        let gray = (0..<72).map { i in (Int(pixels[i * 4]) * 30 + Int(pixels[i * 4 + 1]) * 59 + Int(pixels[i * 4 + 2]) * 11) / 100 }
        var hash: UInt64 = 0
        for y in 0..<8 { for x in 0..<8 { if gray[y * 9 + x] > gray[y * 9 + x + 1] { hash |= UInt64(1) << (y * 8 + x) } } }
        let color = (0..<3).map { channel in (0..<72).reduce(0) { $0 + Int(pixels[$1 * 4 + channel]) } / 72 }
        return Fingerprint(width: rotated ? rawHeight : rawWidth, height: rotated ? rawWidth : rawHeight,
                           hash: hash, spread: (gray.max() ?? 0) - (gray.min() ?? 0), color: color, thumbnail: thumbnail)
    }
    static func visuallySimilar(_ a: Fingerprint, _ b: Fingerprint) -> Bool {
        let ratio = Double(a.width) / Double(a.height), other = Double(b.width) / Double(b.height)
        return a.spread >= 24 && b.spread >= 24 && abs(ratio - other) / ratio < 0.05 &&
            (a.hash ^ b.hash).nonzeroBitCount <= 8 && zip(a.color, b.color).allSatisfy { abs($0 - $1) < 40 }
    }
    static func nameStem(_ path: String) -> String {
        let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.lowercased()
        let stripped = stem.replacingOccurrences(of: #"(?:[ _-](?:copy|edited|export|small|large|original|final|副本|导出|原图)|\s*\(\d+\)|[ _-]\d+x\d+)+$"#, with: "", options: .regularExpression)
        return stripped
    }
    private static func digest(_ file: WorkFile, expected: WorkflowFiles.Stamp, budget: inout Int64, cancelled: () -> Bool) throws -> SHA256.Digest? {
        guard expected.size <= budget else { return nil }
        let descriptor = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw WorkflowFailure.unavailable(file.path) }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true); defer { try? input.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, WorkflowFiles.Stamp(info) == expected else { throw WorkflowFailure.changed(file.path) }
        var hash = SHA256(), bytes: Int64 = 0
        while let data = try input.read(upToCount: 1 << 20), !data.isEmpty {
            if cancelled() { throw WorkflowFailure.cancelled }
            bytes += Int64(data.count); budget -= Int64(data.count)
            guard bytes <= expected.size, budget >= 0 else { throw WorkflowFailure.changed(file.path) }
            hash.update(data: data)
        }
        guard bytes == expected.size, try WorkflowFiles.inspect(file) == expected else { throw WorkflowFailure.changed(file.path) }
        return hash.finalize()
    }
    static func compare(reference: WorkFile, candidates: [WorkFile], offline: Set<String> = [], cancelled: () -> Bool) throws -> Report {
        if cancelled() { throw WorkflowFailure.cancelled }
        let stamp = try WorkflowFiles.inspect(reference, offline: offline), referenceImage = try fingerprint(reference.path)
        let began = Date(), stem = nameStem(reference.path)
        var seen: Set<String> = [reference.path], checked = 0, skipped = 0, matches = [Candidate](), limited = false
        var budget: Int64 = 64 * 1024 * 1024, referenceDigest: SHA256.Digest?
        for file in candidates where seen.insert(file.path).inserted {
            if cancelled() { throw WorkflowFailure.cancelled }
            if checked + skipped >= maximumCandidates || Date().timeIntervalSince(began) > 5 { limited = true; break }
            do {
                try autoreleasepool {
                    let candidateStamp = try WorkflowFiles.inspect(file, offline: offline)
                    let item = try fingerprint(file.path)
                    guard try WorkflowFiles.inspect(file, offline: offline) == candidateStamp else { throw WorkflowFailure.changed(file.path) }
                    checked += 1
                    var evidence: Evidence?
                    if visuallySimilar(referenceImage, item) { evidence = .similar }
                    else if stem.count >= 3, nameStem(file.path) == stem { evidence = .relatedName }
                    // Equal sizes may be duplicates even for flat-color pictures. Hashing has its own byte budget.
                    if stamp.size == candidateStamp.size {
                        if referenceDigest == nil { referenceDigest = try digest(reference, expected: stamp, budget: &budget, cancelled: cancelled) }
                        if let referenceDigest, let hash = try digest(file, expected: candidateStamp, budget: &budget, cancelled: cancelled), hash == referenceDigest { evidence = .identical }
                    }
                    if let evidence { matches.append(Candidate(file: file, width: item.width, height: item.height, bytes: candidateStamp.size, thumbnail: item.thumbnail, evidence: evidence)) }
                }
            } catch WorkflowFailure.cancelled { throw WorkflowFailure.cancelled }
            catch { skipped += 1 }
        }
        guard try WorkflowFiles.inspect(reference, offline: offline) == stamp else { throw WorkflowFailure.changed(reference.path) }
        matches.sort { $0.evidence.rawValue != $1.evidence.rawValue ? $0.evidence.rawValue < $1.evidence.rawValue : $0.file.path < $1.file.path }
        return Report(reference: referenceImage, matches: matches, checked: checked, skipped: skipped, limited: limited)
    }
}
