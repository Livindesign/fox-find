import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
import OilFindCore
@testable import OilFindApp

final class GridIconTests: XCTestCase {
    private func fixture(_ body: (URL, IndexStore) throws -> Void) throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoxGridIcons-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var buffer = ScanBuffer()
        buffer.ids = [0]; buffer.parents = [0]; buffer.sizes = [0]; buffer.mtimes = [0]
        buffer.flags = [1]; buffer.depths = [0]; buffer.kinds = [1]; buffer.nameLens = [0]
        let store = IndexStore(scan: ScanOutput(buffers: [buffer], count: 1, homeIndex: .max, elapsed: 0, finishedAt: 0), config: IndexConfig(rootPath: root.path))
        try body(root, store)
    }
    private func file(_ name: String, root: URL, store: IndexStore, online: Bool = true, folder: Bool = false) -> ResultItem {
        ResultItem(detail: nil, id: 0, source: SearchSource(id: "fixture", displayName: "Fixture", isOnline: online, store: store), name: name, parentPath: root.path, path: root.appendingPathComponent(name).path, size: 100, modified: Date(timeIntervalSince1970: 1), flags: folder ? SiftFlag.dir : 0, kind: folder ? 1 : ["png", "jpg"].contains(root.appendingPathComponent(name).pathExtension) ? 4 : 3)
    }
    private func pixels(_ image: NSImage?) -> Data? {
        guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
    private func wait(_ condition: () -> Bool, timeout: TimeInterval = 4) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return condition()
    }
    func testMissingPreviewsAndOfflineFilesKeepTheSameTypeIconsAsLists() throws {
        try fixture { root, store in
            for online in [true, false] {
                let files = ["Budget.xlsx", "Moodboard.png", "Plan.pdf", "Deck.pptx", "Guidelines.docx", "Resources"].enumerated().map {
                    file($0.element, root: root, store: store, online: online, folder: $0.offset == 5)
                }
                let grid = AssetGridView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
                grid.item = { files[$0] }; grid.reload(count: files.count, selection: 0); grid.layoutSubtreeIfNeeded()
                let cells = files.indices.map { grid.collectionView(grid.collection, itemForRepresentedObjectAt: IndexPath(item: $0, section: 0)) }
                let images = try cells.map { try XCTUnwrap($0.view.subviews.compactMap { $0 as? NSImageView }.first) }
                // List resolution, rendered at the grid's high-resolution icon size.
                let listIcons = IconProvider(pixelSize: 256)
                var expected: [Int: NSImage] = [:]
                for (i, file) in files.enumerated() {
                    expected[i] = listIcons.icon(name: file.name, path: file.path, flags: file.flags, kind: file.kind, resolveFileIcon: online) { expected[i] = $0 }
                }
                XCTAssertTrue(wait { listIcons.isIdle && files.indices.allSatisfy { pixels(images[$0].image) == pixels(expected[$0]) } }, "Grid must retain real type icons when Quick Look cannot provide a thumbnail")
                for image in images { XCTAssertFalse(try XCTUnwrap(image.image).isTemplate) }
                XCTAssertTrue(cells[5].view.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == L10n.text(online ? "meta.folder" : "source.offline") })
            }
        }
    }
    func testImageThumbnailSurvivesScrollingAndFavoriteRefresh() throws {
        try fixture { root, store in
            let item = file("Preview.png", root: root, store: store)
            let context = try XCTUnwrap(CGContext(data: nil, width: 160, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor(srgbRed: 0.9, green: 0.1, blue: 0.3, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 160, height: 100))
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(URL(fileURLWithPath: item.path) as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
            let grid = AssetGridView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
            let window = NSWindow(contentRect: grid.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = grid
            defer { window.close() }
            var favorite = false
            grid.item = { _ in item }; grid.isFavorite = { _ in favorite }
            grid.reload(count: 1, selection: 0); grid.layoutSubtreeIfNeeded()
            let cell = try XCTUnwrap(grid.collection.item(at: IndexPath(item: 0, section: 0)))
            let image = try XCTUnwrap(cell.view.subviews.compactMap { $0 as? NSImageView }.first)
            XCTAssertTrue(wait({
                guard let cg = image.image?.cgImage(forProposedRect: nil, context: nil, hints: nil), let color = NSBitmapImageRep(cgImage: cg).colorAt(x: cg.width / 2, y: cg.height / 2)?.usingColorSpace(.sRGB) else { return false }
                return color.redComponent > 0.8 && color.greenComponent < 0.25
            }), "Real image preview must replace the type icon")
            let preview = try XCTUnwrap(pixels(image.image))
            for _ in 0..<3 {
                grid.setScrolling(true); grid.setScrolling(false)
                favorite.toggle(); grid.refreshVisibleItems()
                XCTAssertEqual(pixels(image.image), preview, "Reconfiguration must not flash back to a placeholder or file icon")
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            XCTAssertEqual(pixels(image.image), preview, "Late icon completions must not replace a thumbnail")
        }
    }
    func testVisibleImageThumbnailLatency() throws {
        guard ProcessInfo.processInfo.environment["FOX_THUMBNAIL_WORKLOAD"] == "1" else { throw XCTSkip("Opt-in thumbnail latency workload") }
        try fixture { root, store in
            let files = (0..<12).map { file("Photo-\($0).jpg", root: root, store: store) }
            for (i, item) in files.enumerated() {
                let context = try XCTUnwrap(CGContext(data: nil, width: 4032, height: 3024, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
                let colors = [NSColor(srgbRed: 0.5 + Double(i) / 25, green: 0.1, blue: 0.3, alpha: 1).cgColor, NSColor.blue.cgColor]
                let gradient = try XCTUnwrap(CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]))
                context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 4032, y: 3024), options: [])
                let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(URL(fileURLWithPath: item.path) as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary); XCTAssertTrue(CGImageDestinationFinalize(destination))
            }
            let grid = AssetGridView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            let window = NSWindow(contentRect: grid.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = grid; defer { window.close() }
            grid.item = { files[$0] }; grid.setScrolling(true)
            grid.reload(count: files.count, selection: 0); grid.layoutSubtreeIfNeeded()
            let cells = try files.indices.map { try XCTUnwrap(grid.collection.item(at: IndexPath(item: $0, section: 0))) }
            let images = try cells.map { try XCTUnwrap($0.view.subviews.compactMap { $0 as? NSImageView }.first) }
            let start = CFAbsoluteTimeGetCurrent(); grid.setScrolling(false)
            var elapsed: [Int: Double] = [:]
            XCTAssertTrue(wait({
                for (i, image) in images.enumerated() where elapsed[i] == nil {
                    if let cg = image.image?.cgImage(forProposedRect: nil, context: nil, hints: nil), Double(cg.width) / Double(cg.height) > 1.3 { elapsed[i] = (CFAbsoluteTimeGetCurrent() - start) * 1000 }
                }
                return elapsed.count == files.count
            }, timeout: 15))
            let samples = elapsed.values.sorted()
            if samples.count == files.count { print("FOX_THUMBNAIL_WORKLOAD files=12 pixels=4032x3024 first_ms=\(samples[0]) p50_ms=\(samples[5]) last_ms=\(samples[11])") }
            let loaded = images.map { $0.image }
            let cachedStart = CFAbsoluteTimeGetCurrent()
            grid.setScrolling(true); grid.setScrolling(false)
            XCTAssertTrue(images.indices.allSatisfy { images[$0].image === loaded[$0] })
            print("FOX_THUMBNAIL_CACHED_REFRESH main_ms=\((CFAbsoluteTimeGetCurrent() - cachedStart) * 1000)")
        }
    }
}
