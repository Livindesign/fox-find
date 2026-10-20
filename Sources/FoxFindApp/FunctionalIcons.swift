import AppKit
import ImageIO

/// The product's own vector glyphs; file results continue to use IconProvider.
enum FunctionalIcons {
    private static let resources: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("FoxFind_FoxFindApp.bundle"), let bundled = Bundle(url: url) { return bundled }
        return Bundle.module
    }()
    private static var cache: [String: NSImage] = [:]
    private static let aliases = [
        "folder": "face-folder", "folder.fill": "face-folder", "doc": "face-document",
        "doc.text": "face-document", "photo": "face-image", "app": "face-applications",
        "magnifyingglass": "search", "text.magnifyingglass": "search",
        "xmark": "x", "xmark.circle.fill": "x", "gearshape": "settings",
        "list.bullet": "list", "square.grid.2x2": "grid", "ellipsis": "more",
        "star": "star", "slider.horizontal.3": "filter", "chevron.down": "chevron",
        "sidebar.right": "preview", "arrow.up.right.square": "open"
    ]
    static func image(_ name: String) -> NSImage? {
        let key = aliases[name] ?? name
        if let image = cache[key] { return image }
        guard let url = resources.url(forResource: key, withExtension: "svg", subdirectory: "Icons"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true; cache[key] = image
        return image
    }
    static func art(_ name: String) -> NSImage? {
        let key = "art-" + name
        if let image = cache[key] { return image }
        guard let url = resources.url(forResource: name, withExtension: "png", subdirectory: "Guide"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: name == "fox-original" ? 64 : 640,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: bitmap, size: NSSize(width: bitmap.width, height: bitmap.height))
        cache[key] = image; return image
    }
}
