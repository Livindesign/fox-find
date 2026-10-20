import AppKit
import Darwin

struct FileFavorite: Codable, Equatable {
    let sourceID: String
    var path: String
    let sourceName: String
    var bookmark: Data?
    var identity: String?
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var key: Key { Key(sourceID: sourceID, path: path) }
    struct Key: Hashable { let sourceID: String, path: String }
    init(sourceID: String, path: String, sourceName: String = "", bookmark: Data? = nil, identity: String? = nil) {
        self.sourceID = sourceID
        self.path = URL(fileURLWithPath: path).standardizedFileURL.path
        self.sourceName = sourceName; self.bookmark = bookmark; self.identity = identity
    }
}

// Persist a volume/source and full path, never the rebuildable index entry ID.
// A disconnected source does not remove its favorites or require disk access.
final class FileFavorites {
    private let defaults: UserDefaults
    private(set) var files: [FileFavorite]
    private var keys: Set<FileFavorite.Key>
    private var resolving = false, lastResolution = Date.distantPast
    private var invalid = Set<FileFavorite.Key>()
    private let queue = DispatchQueue(label: "app.localfind.desktop.favorites", qos: .utility)
    static func identity(of url: URL) -> String? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        let volume = (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) ?? String(info.st_dev)
        return volume + ":" + String(info.st_ino) + ":" + String(info.st_birthtimespec.tv_sec) + ":" + String(info.st_birthtimespec.tv_nsec)
    }
    static func tracked(_ value: FileFavorite) -> FileFavorite {
        var result = value; let url = URL(fileURLWithPath: value.path)
        guard let identity = identity(of: url) else { return result }
        result.bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        result.identity = identity; return result
    }
    private static func resolveIdentity(_ file: FileFavorite) -> URL? {
        guard let identity = file.identity, let inode = identity.split(separator: ":").dropFirst().first.flatMap({ UInt64($0) }) else { return nil }
        var parent = (file.path as NSString).deletingLastPathComponent, volume = statfs()
        while !parent.isEmpty {
            if statfs(parent, &volume) == 0 {
                var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                if fsgetpath(&bytes, bytes.count, &volume.f_fsid, inode) > 0 {
                    let url = URL(fileURLWithPath: String(cString: bytes))
                    if Self.identity(of: url) == identity { return url }
                }
                break
            }
            if parent == "/" { break }; parent = (parent as NSString).deletingLastPathComponent
        }
        return nil
    }
    private static func displayPath(_ url: URL, original: String) -> String {
        var parent = (original as NSString).deletingLastPathComponent
        while !parent.isEmpty && parent != "/" {
            let resolved = URL(fileURLWithPath: parent).resolvingSymlinksInPath().path
            if url.path.hasPrefix(resolved + "/") { return parent + String(url.path.dropFirst(resolved.count)) }
            parent = (parent as NSString).deletingLastPathComponent
        }
        return url.path
    }
    func reconcile(force: Bool = false, completion: @escaping (Bool) -> Void = { _ in }) {
        guard !resolving, force || Date().timeIntervalSince(lastResolution) > 3 else { return }
        resolving = true; lastResolution = Date(); let captured = files
        queue.async { [weak self] in
            var updated = [FileFavorite.Key: FileFavorite](), invalid = Set<FileFavorite.Key>()
            for file in captured {
                if let bookmark = file.bookmark {
                    var stale = false
                    let bookmarkURL = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
                    let validBookmark = bookmarkURL.flatMap { Self.identity(of: $0) == file.identity ? $0 : nil }
                    if let url = Self.resolveIdentity(file) ?? validBookmark {
                        var resolved = file
                        resolved.path = URL(fileURLWithPath: Self.displayPath(url, original: file.path)).standardizedFileURL.path
                        updated[file.key] = stale || resolved.path != file.path ? Self.tracked(resolved) : resolved
                    } else if let identity = Self.identity(of: URL(fileURLWithPath: file.path)), identity != file.identity { invalid.insert(file.key) }
                } else { updated[file.key] = Self.tracked(file) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.resolving = false
                let previous = self.files, previousInvalid = self.invalid
                self.files = self.files.map { current in
                    guard captured.contains(current) else { return current }
                    return updated[current.key] ?? current
                }
                self.keys = Set(self.files.map(\.key)); self.invalid = invalid
                let changed = previous != self.files || previousInvalid != invalid
                if previous != self.files { self.persist() }
                completion(changed)
            }
        }
    }
    init(defaults: UserDefaults) {
        self.defaults = defaults
        let decoded = defaults.data(forKey: "file.favorites").flatMap { try? JSONDecoder().decode([FileFavorite].self, from: $0) } ?? []
        var unique = Set<FileFavorite.Key>()
        files = decoded.filter { !$0.sourceID.isEmpty && $0.path.hasPrefix("/") }.map {
            FileFavorite(sourceID: $0.sourceID, path: $0.path, sourceName: $0.sourceName, bookmark: $0.bookmark, identity: $0.identity)
        }.filter { unique.insert($0.key).inserted }
        keys = unique
    }
    func contains(sourceID: String, path: String) -> Bool { let key = FileFavorite(sourceID: sourceID, path: path).key; return keys.contains(key) && !invalid.contains(key) }
    @discardableResult func toggle(_ value: FileFavorite) -> Bool {
        if keys.contains(value.key) { remove(value); return false }
        files.insert(value, at: 0); keys.insert(value.key); persist(); return true
    }
    func remove(_ value: FileFavorite) {
        files.removeAll { $0.key == value.key }; keys.remove(value.key); persist()
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(files) { defaults.set(data, forKey: "file.favorites") }
    }
}

final class FavoriteStarButton: NSButton {
    private let symbol = NSImageView()
    private var tracking: NSTrackingArea?
    private var hovered = false
    var onPress: (() -> Void)?
    var isFavorite = false { didSet { refresh() } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false; setButtonType(.momentaryChange)
        target = self; action = #selector(pressed)
        symbol.imageAlignment = .alignCenter; symbol.imageScaling = .scaleProportionallyUpOrDown
        addSubview(symbol); refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func refresh() {
        symbol.image = Theme.symbol(isFavorite ? "star.fill" : "star", size: 13, weight: .medium)
        symbol.contentTintColor = isFavorite ? Theme.accentText(self) : .tertiaryLabelColor
        title = L10n.text(isFavorite ? "file.unfavorite" : "file.favorite")
        state = isFavorite ? .on : .off; setAccessibilityLabel(title); needsDisplay = true
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }
    override func layout() { super.layout(); symbol.frame = NSRect(x: bounds.midX - 8, y: bounds.midY - 8, width: 16, height: 16) }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func draw(_ dirtyRect: NSRect) {
        if hovered || cell?.isHighlighted == true {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    @objc private func pressed() { onPress?() }
}
