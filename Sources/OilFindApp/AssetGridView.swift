import AppKit
import OilFindCore
import QuickLookThumbnailing

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
        image.frame = NSRect(x: 12, y: 12, width: bounds.width - 24, height: 104)
        name.frame = NSRect(x: 12, y: 124, width: bounds.width - 24, height: 18)
        detail.frame = NSRect(x: 12, y: 145, width: bounds.width - 24, height: 16)
        star.frame = NSRect(x: 8, y: 8, width: 32, height: 32)
        actions.frame = NSRect(x: bounds.width - 40, y: 8, width: 32, height: 32)
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
    var displayedItem: ResultItem?
    var displayedFavorite = false
    func cancelPreview() { token = UUID(); preview?.cancel(); preview = nil; displayedItem = nil }
    var tile: AssetTile { view as! AssetTile }
    override func loadView() { view = AssetTile(frame: NSRect(x: 0, y: 0, width: 200, height: 174)) }
    override var isSelected: Bool { didSet { tile.selected = isSelected } }
    override func prepareForReuse() { super.prepareForReuse(); cancelPreview(); displayedItem = nil; tile.image.image = nil }
}

private final class AssetCollection: NSCollectionView {
    override var acceptsFirstResponder: Bool { false }
}

final class AssetGridView: FlippedView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    let collection: NSCollectionView = AssetCollection()
    let scroll = ResultScrollView()
    private let flow = AssetGridLayout()
    private let metadata = AssetMetadataReader(), work = OperationQueue()
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
        super.layout(); scroll.frame = bounds; fitColumns()
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
        work.cancelAllOperations()
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
        let keepImage = cell.displayedItem.map { $0.path == file.path && $0.modified == file.modified && $0.size == file.size && $0.source.isOnline == file.source.isOnline } ?? false
        cell.displayedItem = file; cell.displayedFavorite = favorite
        let token = UUID(); cell.token = token; let currentGeneration = generation
        let semanticCaption = file.detail?.semanticScore == nil ? "" : L10n.text("semantic.match") + (file.detail?.matchedPage.map { " · " + L10n.text("workspace.page", String($0)) } ?? "")
        cell.tile.name.stringValue = file.name; cell.tile.detail.stringValue = file.source.isOnline ? (file.kind == 2 ? L10n.text("meta.app") : Presentation.sizeText(file.size)) : L10n.text("source.offline")
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
        if file.kind == 2 {
            cell.preview?.cancel()
            cell.tile.image.image = icons.icon(name: file.name, path: file.path, flags: file.flags, kind: file.kind,
                resolveFileIcon: file.source.isOnline, isRelevant: { [weak cell] in cell?.token == token }) { [weak cell] image in
                guard let cell, cell.token == token else { return }; cell.tile.image.image = image
            }
            if scrolling { cell.displayedItem = nil }
            return
        }
        if !keepImage { cell.tile.image.image = Theme.symbol(file.flags & 1 != 0 ? "folder" : "doc", size: 44, weight: .light) }
        cell.preview?.cancel()
        guard file.source.isOnline else { return }
        // Keep cached images while moving; resume expensive previews once settled.
        if scrolling { cell.displayedItem = nil; return }
        let cacheKey = file.path + ":" + String(file.modified.timeIntervalSince1970)
        let cached = thumbnails.object(forKey: cacheKey as NSString)
        if let cached { cell.tile.image.image = cached }
        let operation = AssetPreviewOperation(file: file, metadata: metadata, needsThumbnail: cached == nil) { [weak self, weak cell] info, image in
            guard let self, self.generation == currentGeneration, let cell, cell.token == token else { return }
            cell.tile.detail.stringValue = semanticCaption.isEmpty ? (info.caption.isEmpty ? Presentation.sizeText(file.size) : info.caption) : semanticCaption
            cell.tile.detail.toolTip = info.caption
            if let image {
                self.thumbnails.setObject(image, forKey: cacheKey as NSString, cost: 340 * 208 * 4)
                cell.tile.image.image = image
            }
        }
        cell.preview = operation; work.addOperation(operation)
    }
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { if let row = indexPaths.first?.item { onSelect?(row) } }
    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard let file = item?(indexPath.item), file.source.isOnline else { return nil }; return NSURL(fileURLWithPath: file.path)
    }
    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) { onDragging?(true) }
    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) { onDragging?(false) }
}

// The queue bounds the complete metadata + thumbnail pipeline, not only metadata reads.
// Cancellation also reaches Quick Look when cells leave the viewport or are reused.
private final class AssetPreviewOperation: Operation, @unchecked Sendable {
    private static let cancellationQueue = DispatchQueue(label: "app.localfind.desktop.preview-cancel", qos: .utility)
    private let file: ResultItem, metadata: AssetMetadataReader, needsThumbnail: Bool
    private let completion: (AssetMetadata, NSImage?) -> Void
    private let requestLock = NSLock()
    private let completionSignal = DispatchSemaphore(value: 0)
    private var request: QLThumbnailGenerator.Request?
    init(file: ResultItem, metadata: AssetMetadataReader, needsThumbnail: Bool, completion: @escaping (AssetMetadata, NSImage?) -> Void) {
        self.file = file; self.metadata = metadata; self.needsThumbnail = needsThumbnail; self.completion = completion
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
            guard !isCancelled, FileManager.default.fileExists(atPath: file.path) else { return }
            let info = metadata.read(path: file.path, modified: file.modified)
            guard !isCancelled else { return }
            let url = URL(fileURLWithPath: file.path)
            let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
            let local = values?.isUbiquitousItem != true || values?.ubiquitousItemDownloadingStatus == .current || values?.ubiquitousItemDownloadingStatus == .downloaded
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isCancelled else { return }; self.completion(info, nil)
            }
            guard needsThumbnail, local, !isCancelled else { return }
            let request = QLThumbnailGenerator.Request(fileAt: url, size: NSSize(width: 340, height: 208), scale: 1, representationTypes: .thumbnail)
            requestLock.lock(); self.request = request; requestLock.unlock()
            guard !isCancelled else { return }
            let ready = completionSignal
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
                defer { ready.signal() }
                DispatchQueue.main.async {
                    guard let self, !self.isCancelled, let representation else { return }
                    self.completion(info, representation.nsImage)
                }
            }
            if isCancelled { QLThumbnailGenerator.shared.cancel(request) }
            // A provider that fails to finish must not occupy a worker indefinitely.
            if ready.wait(timeout: .now() + 3) == .timedOut { cancel() }
            requestLock.lock(); self.request = nil; requestLock.unlock()
        }
    }
}
