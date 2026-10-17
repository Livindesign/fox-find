import AppKit
import Quartz
import PDFKit
import ImageIO

/// A single on-demand native preview. Selection changes coalesce before Quick Look loads.
final class InlinePreview: FlippedView {
    private let name = Theme.label(12, .medium, .labelColor)
    private let path = Theme.label(10.5, .regular, .secondaryLabelColor)
    private let page = Theme.label(10.5, .regular, .secondaryLabelColor)
    private let unavailable = Theme.label(12, .regular, .secondaryLabelColor)
    private let icon = NSImageView()
    let actions = ToolbarButton(symbol: "ellipsis")
    let openPage = ToolbarButton()
    private let imagePreview = NSImageView()
    private let imageCache = NSCache<NSString, NSImage>()
    private(set) var loadedImagePath: String?
    private var preview: QLPreviewView?
    private var pdf: PDFView?
    private let documentQueue: OperationQueue = {
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .userInitiated
        return queue
    }()
    private(set) var loadedPDFPath: String?
    private var pending: DispatchWorkItem?
    private var displayedItem: ResultItem?
    private var displayedLanguage = L10n.chinese
    private var representedPath: String?
    private var stamp: Date?
    private var generation = 0
    private let icons = IconProvider()
    var onActions: (() -> Void)?, onOpenPage: (() -> Void)?
    var allowsLoading = true
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.cornerRadius = 14; layer?.masksToBounds = true
        icon.imageScaling = .scaleProportionallyUpOrDown
        imagePreview.imageScaling = .scaleProportionallyUpOrDown; imagePreview.isHidden = true
        imageCache.totalCostLimit = 24 * 1024 * 1024; imageCache.countLimit = 8
        actions.iconOnly = true; actions.title = L10n.text("hint.actions"); actions.setAccessibilityLabel(actions.title)
        actions.onPress = { [weak self] in self?.onActions?() }
        openPage.title = L10n.local("查看这一页 ↗", "View this page ↗")
        openPage.onPress = { [weak self] in self?.onOpenPage?() }
        unavailable.alignment = .center
        [imagePreview, icon, name, path, page, openPage, actions, unavailable].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { pending?.cancel(); documentQueue.cancelAllOperations(); preview?.close() }
    func show(_ item: ResultItem?) {
        guard let item else { clear(); return }
        guard displayedItem?.sameDisplay(as: item) != true || displayedLanguage != L10n.chinese else { return }
        displayedItem = item; displayedLanguage = L10n.chinese
        let changed = representedPath != item.path || stamp != item.modified
        representedPath = item.path; stamp = item.modified
        name.stringValue = item.name; path.stringValue = item.parentPath; path.toolTip = item.path
        let pageNumber = item.detail?.matchedPage
        page.stringValue = pageNumber.map { L10n.local("相关内容在第 \($0) 页", "Related content on page \($0)") } ?? ""
        page.isHidden = pageNumber == nil; openPage.isHidden = pageNumber == nil
        openPage.title = L10n.local("查看这一页 ↗", "View this page ↗")
        guard changed else {
            if let document = pdf?.document, let pageNumber, let target = document.page(at: pageNumber - 1), pdf?.currentPage !== target { pdf?.go(to: target) }
            return
        }
        generation += 1; let token = generation
        pending?.cancel(); documentQueue.cancelAllOperations()
        icon.image = icons.icon(name: item.name, path: item.path, flags: item.flags, kind: item.kind, resolveFileIcon: item.source.isOnline, isRelevant: { [weak self] in self?.generation == token }) { [weak self] image in
            guard let self, self.generation == token else { return }; self.icon.image = image
        }
        // Remove stale preview immediately, but never clear or reload the search results.
        if preview?.previewItem != nil { preview?.previewItem = nil }; preview?.isHidden = true
        imagePreview.image = nil; imagePreview.isHidden = true; loadedImagePath = nil
        pdf?.document = nil; pdf?.isHidden = true; loadedPDFPath = nil
        unavailable.isHidden = item.source.isOnline
        unavailable.stringValue = L10n.local("连接磁盘后可预览", "Reconnect the drive to preview")
        guard item.source.isOnline, allowsLoading else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token, !self.isHidden else { return }
            if item.kind == 4 { self.loadImage(item.path, modified: item.modified, token: token); return }
            if URL(fileURLWithPath: item.path).pathExtension.lowercased() == "pdf" {
                self.loadPDF(item.path, page: pageNumber, token: token); return
            }
            if self.preview == nil {
                let view = QLPreviewView(frame: self.previewFrame, style: .normal)!
                // This view owns teardown. Auto-close plus deinit.close() asserts in Quick Look.
                view.shouldCloseWithWindow = false
                self.preview = view; self.addSubview(view, positioned: .below, relativeTo: self.name)
            }
            self.preview?.previewItem = URL(fileURLWithPath: item.path) as NSURL
            self.preview?.isHidden = false
            self.needsLayout = true
        }
        pending = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }
    private func loadImage(_ file: String, modified: Date, token: Int) {
        let key = (file + "|" + String(modified.timeIntervalSince1970)) as NSString
        if let cached = imageCache.object(forKey: key) {
            imagePreview.image = cached; imagePreview.isHidden = false; loadedImagePath = file; return
        }
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard operation?.isCancelled == false else { return }
            let image: NSImage? = autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: file) as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1280,
                        kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
            guard operation?.isCancelled == false else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token, !self.isHidden else { return }
                if let image {
                    self.imageCache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height) * 4)
                    self.imagePreview.image = image; self.imagePreview.isHidden = false; self.loadedImagePath = file
                } else {
                    self.unavailable.stringValue = L10n.local("无法预览此图片，可按回车打开", "Cannot preview this image. Press Return to open.")
                    self.unavailable.isHidden = false
                }
            }
        }
        documentQueue.addOperation(operation)
    }
    private var previewFrame: NSRect {
        let foot: CGFloat = openPage.isHidden ? 8 : 36
        return NSRect(x: 8, y: 54, width: max(1, bounds.width - 16), height: max(1, bounds.height - 54 - foot))
    }
    private func loadPDF(_ file: String, page: Int?, token: Int) {
        unavailable.stringValue = L10n.local("正在准备预览…", "Preparing preview…"); unavailable.isHidden = false
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard operation?.isCancelled == false else { return }
            let document = PDFDocument(url: URL(fileURLWithPath: file))
            guard operation?.isCancelled == false else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token, !self.isHidden else { return }
                guard let document, !document.isLocked, document.pageCount > 0 else {
                    self.unavailable.stringValue = L10n.local("无法预览此 PDF，可按回车打开", "Cannot preview this PDF. Press Return to open."); return
                }
                if self.pdf == nil {
                    let view = PDFView(frame: .zero)
                    view.autoScales = true; view.displayMode = .singlePage; view.displaysPageBreaks = false
                    view.backgroundColor = .clear
                    self.pdf = view; self.addSubview(view, positioned: .below, relativeTo: self.name)
                }
                self.pdf?.document = document; self.pdf?.isHidden = false
                if let target = document.page(at: max(0, min(document.pageCount - 1, (page ?? 1) - 1))) { self.pdf?.go(to: target) }
                self.loadedPDFPath = file; self.unavailable.isHidden = true; self.needsLayout = true
            }
        }
        documentQueue.addOperation(operation)
    }
    func clear() {
        guard representedPath != nil || pending != nil || loadedPDFPath != nil else { return }
        pending?.cancel(); documentQueue.cancelAllOperations(); generation += 1; representedPath = nil; stamp = nil
        pending = nil; displayedItem = nil
        if preview?.previewItem != nil { preview?.previewItem = nil }
        pdf?.document = nil; loadedPDFPath = nil
        imagePreview.image = nil; imagePreview.isHidden = true; loadedImagePath = nil
    }
    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 12, y: 10, width: 27, height: 31)
        name.frame = NSRect(x: 48, y: 9, width: bounds.width - 100, height: 18)
        path.frame = NSRect(x: 48, y: 29, width: bounds.width - 70, height: 15)
        actions.frame = NSRect(x: bounds.width - 42, y: 9, width: 30, height: 30)
        preview?.frame = previewFrame; pdf?.frame = previewFrame; imagePreview.frame = previewFrame
        unavailable.frame = NSRect(x: 14, y: bounds.midY, width: bounds.width - 28, height: 20)
        page.frame = NSRect(x: 12, y: bounds.height - 28, width: max(0, bounds.width - 150), height: 16)
        openPage.frame = NSRect(x: bounds.width - 128, y: bounds.height - 36, width: 116, height: 32)
    }
}
