import AppKit
import OilFindCore
import QuickLookThumbnailing
import ImageIO

private final class AssetTile: FlippedView {
    let image = NSImageView(), name = Theme.label(12.5, .medium, .labelColor), detail = Theme.label(10.5, .regular, .secondaryLabelColor)
    let star = FavoriteStarButton(frame: .zero)
    let actions = ToolbarButton(symbol: "ellipsis")
    var selected = false { didSet { if selected != oldValue { needsDisplay = true } } }
    var onOpen: (() -> Void)?, menuProvider: (() -> NSMenu?)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.cornerRadius = 12
        image.imageScaling = .scaleProportionallyUpOrDown
        actions.iconOnly = true; actions.title = L10n.text("hint.actions")
        actions.toolTip = L10n.text("workspace.actions"); actions.setAccessibilityLabel(L10n.text("hint.actions"))
        actions.onPress = { [weak self] in
            guard let self else { return }
            self.menuProvider?()?.popUp(positioning: nil, at: NSPoint(x: 0, y: 30), in: self.actions)
        }
        [image, name, detail, star, actions].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        Theme.place(image, NSRect(x: 12, y: 12, width: bounds.width - 24, height: 104))
        Theme.place(name, NSRect(x: 12, y: 124, width: bounds.width - 24, height: 18))
        Theme.place(detail, NSRect(x: 12, y: 145, width: bounds.width - 24, height: 16))
        Theme.place(star, NSRect(x: 8, y: 8, width: 32, height: 32))
        Theme.place(actions, NSRect(x: bounds.width - 40, y: 8, width: 32, height: 32))
    }
    override var wantsUpdateLayer: Bool { true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (selected ? Theme.accent.withAlphaComponent(0.16) : NSColor.labelColor.withAlphaComponent(0.045)).cgColor
            layer?.borderColor = Theme.accent.withAlphaComponent(0.55).cgColor
            layer?.borderWidth = selected ? 1 : 0
        }
    }
    override func mouseDown(with event: NSEvent) { super.mouseDown(with: event); if event.clickCount == 2 { onOpen?() } }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}

private final class AssetGridItem: NSCollectionViewItem {
    var token = UUID()
    var preview: Operation?
    var metadataWork: Operation?
    var displayedItem: ResultItem?
    var imageItem: ResultItem?
    var hasThumbnail = false
    var displayedFavorite = false
    func cancelPreview() { token = UUID(); preview?.cancel(); preview = nil; metadataWork?.cancel(); metadataWork = nil; displayedItem = nil }
    var tile: AssetTile { view as! AssetTile }
    override func loadView() { view = AssetTile(frame: NSRect(x: 0, y: 0, width: 200, height: 174)) }
    override var isSelected: Bool { didSet { tile.selected = isSelected } }
    override func prepareForReuse() { super.prepareForReuse(); cancelPreview(); imageItem = nil; hasThumbnail = false; tile.image.image = nil }
}

private final class AssetCollection: NSCollectionView {
    override var acceptsFirstResponder: Bool { false }
}

final class AssetGridView: FlippedView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    let collection: NSCollectionView = AssetCollection()
    let scroll = ResultScrollView()
    private let flow = AssetGridLayout()
    private let metadata = AssetMetadataReader(), work = OperationQueue(), imageWork = OperationQueue(), metadataWork = OperationQueue()
    private let icons = IconProvider(pixelSize: 256)
    private let thumbnails = NSCache<NSString, NSImage>()
    private(set) var reloadCount = 0
    private var generation = 0
    private var scrolling = false
    func setScrolling(_ value: Bool) {
        guard scrolling != value else { return }
        scrolling = value
        icons.setPaused(value)
        if value { suspendPreviews() }
        else if !isHidden { refreshVisibleItems() }
    }
    var count = 0
    var item: ((Int) -> ResultItem?)?, isFavorite: ((ResultItem) -> Bool)?
    var onSelect: ((Int) -> Void)?, onFavorite: ((ResultItem) -> Void)?
    var onOpen: (() -> Void)?, onMenu: ((Int) -> NSMenu?)?, onDragging: ((Bool) -> Void)?
    var columns: Int { max(1, Int((scroll.contentView.bounds.width - 22) / 206)) }
    override init(frame: NSRect) {
        super.init(frame: frame)
        work.maxConcurrentOperationCount = 2; work.qualityOfService = .utility; thumbnails.countLimit = 250; thumbnails.totalCostLimit = 48 * 1024 * 1024
        imageWork.maxConcurrentOperationCount = 2; imageWork.qualityOfService = .userInitiated
        metadataWork.maxConcurrentOperationCount = 1; metadataWork.qualityOfService = .utility
        collection.autoresizingMask = [.width]
        collection.collectionViewLayout = flow; collection.backgroundColors = [.clear]; collection.isSelectable = true
        collection.register(AssetGridItem.self, forItemWithIdentifier: .init("asset")); collection.dataSource = self; collection.delegate = self
        collection.setDraggingSourceOperationMask(.copy, forLocal: false)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.documentView = collection; addSubview(scroll)
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(fitColumns), name: NSView.frameDidChangeNotification, object: scroll.contentView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }
    override func layout() {
        super.layout()
        if scroll.frame != bounds { scroll.frame = bounds }
        fitColumns()
    }
    @objc private func fitColumns() {
        // A legacy scroller reduces the viewport after content is laid out.
        // Recompute against that viewport so four tiles do not wrap to three.
        let width = scroll.contentView.bounds.width
        guard width > 33 else { return }
        let size = NSSize(width: max(1, floor((width - 33 - CGFloat(columns - 1) * 10) / CGFloat(columns))), height: 174)
        if flow.itemSize != size || flow.columns != columns { flow.itemSize = size; flow.columns = columns; flow.invalidateLayout() }
        if collection.frame.width != width { collection.setFrameSize(NSSize(width: width, height: collection.frame.height)) }
    }
    func reload(count: Int, selection: Int) {
        reloadCount += 1; generation += 1; suspendPreviews(); self.count = count; collection.reloadData(); select(selection, reveal: false)
    }
    func refreshVisibleItems() {
        for indexPath in collection.indexPathsForVisibleItems() {
            guard let cell = collection.item(at: indexPath) as? AssetGridItem, let file = item?(indexPath.item) else { continue }
            configure(cell, file: file, at: indexPath)
        }
    }
    func suspendPreviews() {
        work.cancelAllOperations(); imageWork.cancelAllOperations(); metadataWork.cancelAllOperations()
        for case let cell as AssetGridItem in collection.visibleItems() { cell.cancelPreview() }
    }
    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
        (item as? AssetGridItem)?.cancelPreview()
    }
    func resetScroll() { scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView) }
    func select(_ row: Int, reveal: Bool) {
        guard row >= 0 && row < count else { collection.selectionIndexPaths = []; return }
        let path = IndexPath(item: row, section: 0)
        if collection.selectionIndexPaths != [path] { collection.selectionIndexPaths = [path] }
        if reveal, let attributes = flow.layoutAttributesForItem(at: path) {
            // Reveal the exact fixed-grid rect, including items far outside
            // the collection's currently prepared region.
            collection.scrollToVisible(attributes.frame)
        }
    }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: .init("asset"), for: indexPath) as! AssetGridItem
        if let file = item?(indexPath.item) { configure(cell, file: file, at: indexPath) }
        return cell
    }
    private func configure(_ cell: AssetGridItem, file: ResultItem, at indexPath: IndexPath) {
        let favorite = isFavorite?(file) ?? false
        if cell.displayedItem?.sameDisplay(as: file) == true, cell.displayedFavorite == favorite { return }
        // Cancelling work during a gesture must not discard an already loaded image.
        let keepImage = cell.imageItem.map { $0.path == file.path && $0.modified == file.modified && $0.size == file.size && $0.source.isOnline == file.source.isOnline && $0.flags == file.flags && $0.kind == file.kind } ?? false
        cell.imageItem = file
        if !keepImage { cell.hasThumbnail = false }
        cell.displayedItem = file; cell.displayedFavorite = favorite
        let token = UUID(); cell.token = token; let currentGeneration = generation
        let semanticCaption = file.detail?.semanticScore == nil ? "" : L10n.text("semantic.match") + (file.detail?.matchedPage.map { " · " + L10n.text("workspace.page", String($0)) } ?? "")
        let directory = file.flags & SiftFlag.dir != 0 && file.flags & SiftFlag.package == 0
        let caption = file.kind == 2 ? L10n.text("meta.app") : directory ? L10n.text("meta.folder") : Presentation.sizeText(file.size)
        cell.tile.name.stringValue = file.name; cell.tile.detail.stringValue = file.source.isOnline ? caption : L10n.text("source.offline")
        if !semanticCaption.isEmpty { cell.tile.detail.stringValue = semanticCaption }
        cell.tile.toolTip = (file.detail?.detail).map { $0 + "\n" + file.path } ?? file.path; cell.tile.setAccessibilityLabel(file.name)
        cell.tile.star.isFavorite = favorite
        cell.tile.star.onPress = { [weak self] in self?.onSelect?(indexPath.item); self?.onFavorite?(file) }
        cell.tile.onOpen = { [weak self] in self?.onSelect?(indexPath.item); self?.onOpen?() }
        cell.tile.menuProvider = { [weak self] in
            guard let self, let current = self.item?(indexPath.item), current.path == file.path,
                  current.source.store === file.source.store else { return nil }
            self.onSelect?(indexPath.item); return self.onMenu?(indexPath.item)
        }
        cell.preview?.cancel(); cell.preview = nil
        cell.metadataWork?.cancel(); cell.metadataWork = nil
        let cacheKey = file.path + ":" + String(file.modified.timeIntervalSince1970) + ":" + String(file.size)
        let cached = file.source.isOnline ? thumbnails.object(forKey: cacheKey as NSString) : nil
        if let cached { cell.hasThumbnail = true; cell.tile.image.image = cached }
        if !cell.hasThumbnail {
            // Use the same full-color file/type icons as list results. Quick Look
            // is an enhancement; unsupported or unavailable previews retain this icon.
            cell.tile.image.image = icons.icon(name: file.name, path: file.path, flags: file.flags, kind: file.kind,
                resolveFileIcon: file.source.isOnline, isRelevant: { [weak cell] in cell?.token == token && cell?.hasThumbnail == false }) { [weak cell] image in
                guard let cell, cell.token == token, !cell.hasThumbnail else { return }; cell.tile.image.image = image
            }
        }
        // Keep cached images while moving; resume expensive previews once settled.
        if scrolling { cell.displayedItem = nil; return }
        guard file.source.isOnline, file.kind != 2, !directory else { return }
        // Metadata (especially video duration and Finder tags) must not delay an image.
        let details = BlockOperation(), reader = metadata
        details.addExecutionBlock { [weak self, weak cell, weak details] in
            guard details?.isCancelled == false else { return }
            let info = reader.read(path: file.path, modified: file.modified)
            DispatchQueue.main.async {
                guard let self, self.generation == currentGeneration, let cell, cell.token == token else { return }
                cell.tile.detail.stringValue = semanticCaption.isEmpty ? (info.caption.isEmpty ? caption : info.caption) : semanticCaption
                cell.tile.detail.toolTip = info.caption
            }
        }
        cell.metadataWork = details; metadataWork.addOperation(details)
        guard !cell.hasThumbnail else { return }
        let receive: (NSImage?) -> Void = { [weak self, weak cell] image in
            guard let self, let image else { return }
            let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            self.thumbnails.setObject(image, forKey: cacheKey as NSString, cost: (cg?.bytesPerRow ?? 1360) * (cg?.height ?? 208))
            guard self.generation == currentGeneration, let cell, cell.token == token else { return }
            cell.hasThumbnail = true; cell.tile.image.image = image
        }
        let quickLook: () -> Void = { [weak self, weak cell] in
            guard let self, let cell, cell.token == token, !self.scrolling else { return }
            let operation = AssetPreviewOperation(file: file, completion: receive)
            cell.preview = operation; self.work.addOperation(operation)
        }
        if file.kind == 4 {
            // ImageIO downsamples off-main; a slow document preview cannot block
            // the visible photos. Unsupported image formats still get Quick Look.
            let operation = AssetPreviewOperation(file: file, directImage: true) { image in
                if let image { receive(image) } else { quickLook() }
            }
            cell.preview = operation; imageWork.addOperation(operation)
        } else { quickLook() }
    }
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { if let row = indexPaths.first?.item { onSelect?(row) } }
    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard let file = item?(indexPath.item), file.source.isOnline else { return nil }; return NSURL(fileURLWithPath: file.path)
    }
    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) { onDragging?(true) }
    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) { onDragging?(false) }
}

// Independently bounded image and Quick Look queues; both honor cell cancellation.
private final class AssetPreviewOperation: Operation, @unchecked Sendable {
    private static let cancellationQueue = DispatchQueue(label: "app.localfind.desktop.preview-cancel", qos: .utility)
    private let file: ResultItem, directImage: Bool
    private let completion: (NSImage?) -> Void
    private let requestLock = NSLock()
    private let completionSignal = DispatchSemaphore(value: 0)
    private var request: QLThumbnailGenerator.Request?
    init(file: ResultItem, directImage: Bool = false, completion: @escaping (NSImage?) -> Void) {
        self.file = file; self.directImage = directImage; self.completion = completion
    }
    override func cancel() {
        guard !isCancelled else { return }
        super.cancel()
        requestLock.lock(); let request = self.request; requestLock.unlock()
        // Cancellation may contact the preview service; keep that IPC off the scrolling thread too.
        if let request { Self.cancellationQueue.async { QLThumbnailGenerator.shared.cancel(request) } }
        completionSignal.signal()
    }
    override func main() {
        autoreleasepool {
            guard !isCancelled else { return }
            var info = stat()
            // No FileProvider/URL resource-value IPC or cloud download for previews.
            guard lstat(file.path, &info) == 0, info.st_flags & UInt32(SF_DATALESS) == 0 else { return }
            let url = URL(fileURLWithPath: file.path)
            if directImage {
                let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
                let cg = source.flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 416,
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary) }
                let image = cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                DispatchQueue.main.async { if !self.isCancelled { self.completion(image) } }
                return
            }
            guard !isCancelled else { return }
            let request = QLThumbnailGenerator.Request(fileAt: url, size: NSSize(width: 340, height: 208), scale: 1, representationTypes: .thumbnail)
            requestLock.lock(); self.request = request; requestLock.unlock()
            guard !isCancelled else { return }
            let ready = completionSignal
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
                defer { ready.signal() }
                DispatchQueue.main.async {
                    guard let self, !self.isCancelled, let representation else { return }
                    self.completion(representation.nsImage)
                }
            }
            if isCancelled { QLThumbnailGenerator.shared.cancel(request) }
            // A provider that fails to finish must not occupy a worker indefinitely.
            if ready.wait(timeout: .now() + 3) == .timedOut { cancel() }
            requestLock.lock(); self.request = nil; requestLock.unlock()
        }
    }
}
