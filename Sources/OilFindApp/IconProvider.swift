import AppKit
import ImageIO
import UniformTypeIdentifiers
import OilFindCore

/// Main-thread cache, bounded background image/Launch Services work. Stale cell
/// requests are discarded before touching the filesystem, not just at delivery.
final class IconProvider {
    private struct Waiter {
        let isRelevant: () -> Bool
        let completion: (NSImage) -> Void
    }
    private let paths = NSCache<NSString, NSImage>()
    private let types = NSCache<NSString, NSImage>()
    private var pending: [String: [Waiter]] = [:]
    private let queue = OperationQueue()
    private let pixelSize: Int
    private let resolveType: (String, UTType?) -> NSImage
    private(set) var discardedRequests = 0
    private(set) var paused = false
    func setPaused(_ value: Bool) {
        precondition(Thread.isMainThread)
        paused = value; queue.isSuspended = value
    }
    var isIdle: Bool { pending.isEmpty }
    init(pixelSize: Int = 64, resolveType: @escaping (String, UTType?) -> NSImage = { key, type in
        NSWorkspace.shared.icon(for: type ?? UTType(filenameExtension: key) ?? .data)
    }) {
        self.pixelSize = pixelSize; self.resolveType = resolveType
        paths.countLimit = 500; paths.totalCostLimit = 24 * 1024 * 1024; types.countLimit = 128
        queue.maxConcurrentOperationCount = 2; queue.qualityOfService = .utility
    }
    deinit { queue.cancelAllOperations() }
    private func request(_ key: String, relevant: @escaping () -> Bool, completion: @escaping (NSImage) -> Void,
                         load: @escaping () -> NSImage?) {
        let waiter = Waiter(isRelevant: relevant, completion: completion)
        if pending[key] != nil {
            pending[key]!.removeAll { !$0.isRelevant() }
            pending[key]!.append(waiter); return
        }
        pending[key] = [waiter]
        let pixels = pixelSize
        queue.addOperation { [weak self] in
            let needed = DispatchQueue.main.sync { [weak self] () -> Bool in
                guard let self else { return false }
                self.pending[key]?.removeAll { !$0.isRelevant() }
                if self.pending[key]?.isEmpty != false {
                    self.pending.removeValue(forKey: key); self.discardedRequests += 1; return false
                }
                return true
            }
            guard needed else { return }
            let image = autoreleasepool { load().map { key.hasPrefix("thumbnail:") ? $0 : Self.displaySized($0, pixels: pixels) } }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let callbacks = self.pending.removeValue(forKey: key) ?? []
                guard let image else { return }
                let cache = key.hasPrefix("type:") ? self.types : self.paths
                cache.setObject(image, forKey: key as NSString, cost: key.hasPrefix("thumbnail:") ? 64 * 64 * 4 : pixels * pixels * 4)
                if !self.paused {
                    for callback in callbacks where callback.isRelevant() { callback.completion(image) }
                }
            }
        }
    }
    private static func displaySized(_ image: NSImage, pixels: Int) -> NSImage {
        let dimension = CGFloat(pixels)
        var proposed = NSRect(x: 0, y: 0, width: dimension, height: dimension)
        guard let source = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        let scale = min(dimension / CGFloat(source.width), dimension / CGFloat(source.height))
        let w = CGFloat(source.width) * scale, h = CGFloat(source.height) * scale
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: (dimension - w) / 2, y: (dimension - h) / 2, width: w, height: h))
        guard let cg = context.makeImage() else { return image }
        return NSImage(cgImage: cg, size: NSSize(width: 32, height: 32))
    }
    func thumbnail(path: String, modified: Date, isRelevant: @escaping () -> Bool = { true }, completion: @escaping (NSImage) -> Void) {
        precondition(Thread.isMainThread)
        let key = "thumbnail:" + path + String(modified.timeIntervalSince1970)
        if let cached = paths.object(forKey: key as NSString) { completion(cached); return }
        guard !paused else { return }
        request(key, relevant: isRelevant, completion: completion) {
            let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
            guard let cg = source.flatMap({ CGImageSourceCreateThumbnailAtIndex($0, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 64, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) }) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
    }
    func icon(name: String, path: String, flags: UInt8, kind: UInt8, resolveFileIcon: Bool = true,
              isRelevant: @escaping () -> Bool = { true }, completion: @escaping (NSImage) -> Void) -> NSImage {
        precondition(Thread.isMainThread)
        let directory = flags & SiftFlag.dir != 0, package = flags & SiftFlag.package != 0
        let key: String, type: UTType?
        if kind == 2 { key = "/application"; type = .application }
        else if package { key = "/package"; type = .package }
        else if directory { key = "/folder"; type = .folder }
        else { key = (name as NSString).pathExtension.lowercased(); type = nil }
        let fileKey = "file:" + path, typeKey = "type:" + key
        let specific = resolveFileIcon && (directory || package || kind == 2)
        if specific, let image = paths.object(forKey: fileKey as NSString) { return image }
        let generic = types.object(forKey: typeKey as NSString)
        if generic == nil && !paused {
            let resolver = resolveType
            request(typeKey, relevant: isRelevant, completion: { [weak self] image in
                if !specific || self?.paths.object(forKey: fileKey as NSString) == nil { completion(image) }
            }) { resolver(key, type) }
        }
        if specific && !paused { request(fileKey, relevant: isRelevant, completion: completion) { NSWorkspace.shared.icon(forFile: path) } }
        return generic ?? Theme.symbol(kind == 2 ? "app" : directory ? "folder" : "doc", size: 32, weight: .regular)
    }
}
