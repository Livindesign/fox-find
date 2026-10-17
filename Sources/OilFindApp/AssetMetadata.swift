import Foundation
import Darwin
import ImageIO
import AVFoundation
import UniformTypeIdentifiers

struct AssetMetadata: Equatable, Codable {
    var readable = true
    var width = 0, height = 0
    var duration: Double?
    var capturedAt: Date?
    var tags: [String] = []
    var caption: String {
        var parts: [String] = []
        if width > 0 && height > 0 { parts.append("\(width) × \(height)") }
        if let duration { parts.append(String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60)) }
        if !tags.isEmpty { parts.append(tags.joined(separator: " · ")) }
        return parts.joined(separator: "  ·  ")
    }
}

enum AssetFilter: String, CaseIterable, Codable {
    case all, landscape, portrait, square, large, shortVideo, longVideo
    var title: String { L10n.text("asset." + rawValue) }
    func matches(_ info: AssetMetadata) -> Bool {
        switch self {
        case .all: return true
        case .landscape: return info.width > info.height && info.height > 0 && info.duration == nil
        case .portrait: return info.height > info.width && info.width > 0 && info.duration == nil
        case .square: return info.width == info.height && info.width > 0 && info.duration == nil
        case .large: return max(info.width, info.height) >= 3840
        case .shortVideo: return info.duration.map { $0 > 0 && $0 <= 60 } ?? false
        case .longVideo: return info.duration.map { $0 > 60 } ?? false
        }
    }
}

// Only requested/visible files are inspected, off the search and main queues.
// Short-lived caching also picks up Finder tag edits that do not change mtime.
final class AssetMetadataReader {
    private struct Cached { let stamp: Date, info: AssetMetadata }
    private let lock = NSLock()
    private var cache: [String: Cached] = [:]
    private let cacheURL: URL?
    private lazy var disk = cacheURL.map(AssetMetadataCache.init)
    init(cacheURL: URL? = nil) { self.cacheURL = cacheURL }
    func offline(path: String, modified: Date, media: Bool) -> AssetMetadata? {
        lock.lock(); defer { lock.unlock() }
        let key = path + ":" + String(modified.timeIntervalSince1970) + ":" + String(media)
        return cache[key]?.info ?? disk?.read(path: path + (media ? "#media" : "#tags"), stamp: nil, prefix: String(modified.timeIntervalSince1970) + "|")
    }
    func captureCandidates(_ interval: DateInterval?, month: Int? = nil) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return disk?.captureCandidates(interval, month: month) ?? []
    }
    private static func finderTags(path: String) -> [String]? {
        let attribute = "com.apple.metadata:_kMDItemUserTags"
        let size = path.withCString { getxattr($0, attribute, nil, 0, 0, 0) }
        guard size > 0 && size <= 65536 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { bytes in path.withCString { getxattr($0, attribute, bytes.baseAddress, size, 0, 0) } }
        guard read == size, let values = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String] else { return nil }
        return values.map { value in
            // Finder stores an optional color index after the final newline.
            guard let newline = value.lastIndex(of: "\n"), let color = Int(value[value.index(after: newline)...]), (0...7).contains(color) else { return value }
            return String(value[..<newline])
        }.filter { !$0.isEmpty }
    }
    func read(path: String, modified: Date, media: Bool = true) -> AssetMetadata {
        let key = path + ":" + String(modified.timeIntervalSince1970) + ":" + String(media)
        lock.lock(); let cached = cache[key]; lock.unlock()
        if let cached, Date().timeIntervalSince(cached.stamp) < 20 { return cached.info }
        var statInfo = stat()
        guard lstat(path, &statInfo) == 0 else { return AssetMetadata(readable: false) }
        let stamp = String(modified.timeIntervalSince1970) + "|\(statInfo.st_dev):\(statInfo.st_ino):\(statInfo.st_size):\(statInfo.st_mtimespec.tv_sec):\(statInfo.st_mtimespec.tv_nsec):\(statInfo.st_ctimespec.tv_sec):\(statInfo.st_ctimespec.tv_nsec)#capture-v1:" + TimeZone.current.identifier
        let diskKey = path + (media ? "#media" : "#tags")
        lock.lock(); let persisted = disk?.read(path: diskKey, stamp: stamp); lock.unlock()
        if let persisted { lock.lock(); if cache.count >= 3000 { cache.removeAll(keepingCapacity: true) }; cache[key] = Cached(stamp: Date(), info: persisted); lock.unlock(); return persisted }
        let url = URL(fileURLWithPath: path)
        // URL tag/cloud resource values synchronously contact DesktopServices/FileProvider.
        // lstat and the Finder tag xattr avoid that unbounded IPC in the filtering queue.
        var info = AssetMetadata(tags: Self.finderTags(path: path) ?? [])
        let local = statInfo.st_flags & UInt32(SF_DATALESS) == 0
        if media && !local { info.readable = false }
        if media && local && statInfo.st_mode & S_IFMT == S_IFREG, let type = UTType(filenameExtension: url.pathExtension) {
            if type.conforms(to: .image), let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                info.width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
                info.height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
                let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
                if (5...8).contains(orientation) { swap(&info.width, &info.height) }
                info.capturedAt = Self.captureDate(properties)
            } else if type.conforms(to: .movie) {
                let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
                let ready = DispatchSemaphore(value: 0), box = VideoMetadataBox()
                let task = Task {
                    defer { ready.signal() }
                    guard let duration = try? await asset.load(.duration) else { return }
                    var value = AssetMetadata()
                    let seconds = CMTimeGetSeconds(duration)
                    if seconds.isFinite && seconds >= 0 && seconds < Double(Int.max) { value.duration = seconds }
                    if let track = try? await asset.loadTracks(withMediaType: .video).first,
                       let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
                        let display = size.applying(transform)
                        if display.width.isFinite && display.height.isFinite {
                            value.width = Int(abs(display.width)); value.height = Int(abs(display.height))
                        }
                    }
                    box.set(value)
                }
                if ready.wait(timeout: .now() + 1.5) == .success, let video = box.get() {
                    info.width = video.width; info.height = video.height; info.duration = video.duration
                } else { task.cancel(); asset.cancelLoading(); info.readable = false }
            }
            if type.conforms(to: .image) && (info.width <= 0 || info.height <= 0) { info.readable = false }
        }
        lock.lock()
        if cache.count >= 3000 { cache.removeAll(keepingCapacity: true) }
        cache[key] = Cached(stamp: Date(), info: info)
        if info.readable { disk?.put(path: diskKey, stamp: stamp, info: info) }
        lock.unlock()
        return info
    }
    /// DateTimeOriginal is capture time. File mtime and digitization time are not substitutes.
    static func captureDate(_ properties: [CFString: Any], localZone: TimeZone = .current) -> Date? {
        guard let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
              original.range(of: "^[0-9]{4}:[0-9]{2}:[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$", options: .regularExpression) != nil else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.isLenient = false
        formatter.timeZone = localZone; formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        if let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String {
            guard offset.range(of: "^[+-](?:0[0-9]|1[0-4]):[0-5][0-9]$", options: .regularExpression) != nil else { return nil }
            let pieces = offset.dropFirst().split(separator: ":").compactMap { Int($0) }
            guard pieces.count == 2, pieces[0] < 14 || pieces[1] == 0 else { return nil }
            formatter.timeZone = TimeZone(secondsFromGMT: (pieces[0] * 3600 + pieces[1] * 60) * (offset.first == "-" ? -1 : 1))
        }
        guard let date = formatter.date(from: original), formatter.string(from: date) == original else { return nil }
        return date
    }
}

struct AssetRefinement: Equatable {
    var media: AssetFilter = .all
    var tag: String = ""
    var minWidth: Int? = nil
    var minHeight: Int? = nil
    var captured: DateInterval? = nil
    var captureMonth: Int? = nil
    var hasCaptureFilter: Bool { captured != nil || captureMonth != nil }
    var active: Bool { media != .all || !tag.isEmpty || needsMedia }
    var needsMedia: Bool { media != .all || minWidth != nil || minHeight != nil || hasCaptureFilter }
    var captureDescription: String {
        if let captureMonth { return L10n.local("拍摄时间：所有年份的 \(captureMonth) 月", "Captured in month \(captureMonth) · All years") }
        guard let captured else { return "" }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return L10n.text("workspace.capturedRange", formatter.string(from: captured.start), formatter.string(from: captured.end))
    }
    func hasRequiredMetadata(_ info: AssetMetadata) -> Bool { info.readable && (!hasCaptureFilter || info.capturedAt != nil) }
    func matches(_ info: AssetMetadata) -> Bool {
        media.matches(info) && (tag.isEmpty || info.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }) &&
            (minWidth == nil || info.width >= minWidth!) && (minHeight == nil || info.height >= minHeight!) &&
            (captured == nil || info.capturedAt.map { $0 >= captured!.start && $0 < captured!.end } == true) &&
            (captureMonth == nil || info.capturedAt.map { Calendar(identifier: .gregorian).component(.month, from: $0) == captureMonth } == true)
    }
}

private final class VideoMetadataBox {
    private let lock = NSLock()
    private var value: AssetMetadata?
    func set(_ value: AssetMetadata) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> AssetMetadata? { lock.lock(); defer { lock.unlock() }; return value }
}
