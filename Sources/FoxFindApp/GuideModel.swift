import AppKit
import Combine
import FoxFindCore

/// Aggregate content-index state only. No file enumeration, extracted text or model work.
public struct ContentGuideStatus: Equatable {
    public var enabled: Bool, paused: Bool, running: Bool, hasError: Bool
    public var folders: Int, indexed: Int, completed: Int, total: Int, skipped: Int
    public init(enabled: Bool = true, paused: Bool = false, running: Bool = false, hasError: Bool = false,
                folders: Int = 0, indexed: Int = 0, completed: Int = 0, total: Int = 0, skipped: Int = 0) {
        self.enabled = enabled; self.paused = paused; self.running = running; self.hasError = hasError
        self.folders = folders; self.indexed = indexed; self.completed = completed; self.total = total; self.skipped = skipped
    }
    public var searchable: Bool { enabled && folders > 0 && indexed > 0 }
}

final class GuideModel: ObservableObject {
    static let storageKey = "guide.v1.step"
    static let dismissedKey = "guide.v1.automaticDismissed"
    @Published private(set) var progress: GuideProgress
    @Published private(set) var content = ContentGuideStatus()
    @Published private(set) var hasResult = false
    @Published private(set) var canPreview = false
    @Published private(set) var browsedPage: Int?
    private(set) var navigationDirection = 1
    var cardStep: GuideProgress.Step { browsedPage.map { [.search, .result, .contentOffer][$0 - 1] } ?? step }
    var cardNumber: Int { cardStep.number }
    func navigate(_ direction: Int) {
        let page = max(1, min(3, cardNumber + direction))
        guard page != cardNumber else { return }
        navigationDirection = direction; browsedPage = page; onChange?()
    }
    func returnToLiveStep() { /* Focusing search must not turn the guide page. */ }
    private let defaults: UserDefaults
    private var contentSubscription: AnyCancellable?
    var onChange: (() -> Void)?
    var onPrimary: (() -> Void)?
    var step: GuideProgress.Step { progress.step }
    var active: Bool { step.isActive }
    var cardHeight: CGFloat {
        switch cardStep {
        case .search, .result, .contentOffer, .success: return 320
        default: return 360
        }
    }

    init(defaults: UserDefaults = .standard, returningUser: Bool) {
        self.defaults = defaults
        let saved = defaults.bool(forKey: Self.dismissedKey) ? "dismissed" : defaults.string(forKey: Self.storageKey)
        progress = GuideProgress(saved: saved, returningUser: returningUser)
        if [.search, .result, .contentOffer].contains(progress.step) { browsedPage = progress.step.number }
        defaults.set(progress.step.rawValue, forKey: Self.storageKey)
    }
    func send(_ event: GuideProgress.Event) {
        // Manual replay is session-only after dismissal; it never re-enables startup tips.
        if case .dismiss = event { defaults.set(true, forKey: Self.dismissedKey) }
        var next = progress; next.send(event)
        guard next != progress else { return }
        if case .replay = event { hasResult = false; canPreview = false }
        progress = next
        // Product progress and the page the user is reading are separate. Typing,
        // results and opening an action must never turn the explanation page.
        switch event {
        case .start, .replay: browsedPage = 1
        case .results, .useResult, .contentMatch: break
        default: browsedPage = nil
        }
        defaults.set(step.rawValue, forKey: Self.storageKey)
        if !active { contentSubscription = nil }
        onChange?()
    }
    func observeContent(_ appExtension: ApplicationExtension?) {
        guard active, let appExtension else { return }
        if let status = appExtension.contentGuideStatus { updateContent(status) }
        contentSubscription = appExtension.contentGuideUpdates.sink { [weak self] in self?.updateContent($0) }
    }
    func updateContent(_ status: ContentGuideStatus) {
        guard content != status else { return }
        content = status
        if [.contentSetup, .contentSearch].contains(cardStep) { onChange?() }
    }
    func resultsChanged(available: Bool, previewable: Bool, contentMatch: Bool = false) {
        guard active else { return }
        let changed = hasResult != available || canPreview != previewable
        let previous = step
        if hasResult != available { hasResult = available }
        if canPreview != previewable { canPreview = previewable }
        if available { send(.results) }
        if available && contentMatch { send(.contentMatch) }
        if changed && step == previous { onChange?() }
    }
    func dismiss() { send(.dismiss) }
    func localize() { objectWillChange.send(); onChange?() }
    var title: String {
        switch cardStep {
        case .search: return L10n.local("从你记得的名字开始", "Start with a name")
        case .result: return L10n.local("更多操作，顺手就有", "More actions, close at hand")
        case .contentOffer: return L10n.local("只记得里面的文字？", "Remember the words inside?")
        case .contentSetup:
            if content.folders == 0 { return L10n.local("先选一个文件夹", "Start with one folder") }
            if !content.searchable && (!content.enabled || content.paused) { return L10n.local("让内容搜索准备好", "Get content search ready") }
            if content.searchable { return L10n.local("已经可以搜一搜了", "Ready for a first search") }
            if content.hasError { return L10n.local("还有一步需要处理", "One thing to check") }
            if content.running { return L10n.local("正在读懂你的文件", "Reading your files") }
            return L10n.local("还没有可搜索的文字", "No searchable text yet")
        case .contentSearch: return content.searchable ? L10n.local("试试文件里的关键词", "Try a few words from a file") : L10n.local("内容还在准备中", "Content is not ready yet")
        case .success: return L10n.local("以后，想起什么就搜什么", "A few words. Your file.")
        default: return ""
        }
    }
    var message: String {
        switch cardStep {
        case .search: return L10n.local("输入应用名或文件名的一部分。用左右箭头查看说明，随时可以自己试试。", "Type an app name or part of a filename. Use the arrows to explore the tips at your own pace.")
        case .result:
            return L10n.local("打开、收藏和定位，都在这里。选中结果后按 ⌘K，也可以右键查看。", "Open, favorite and reveal files, all here. Select a result and press ⌘K, or right-click it.")
        case .contentOffer: return L10n.local("选一个文件夹，就能搜索 PDF、文档和图片里的文字。识别在这台 Mac 上完成。", "Choose a folder to search words in PDFs, documents and images. Recognition stays on this Mac.")
        case .contentSetup:
            if content.folders == 0 { return L10n.local("建议从下载或一个小文件夹开始。出现系统读取提示时，允许你选择的目录即可。", "Start with Downloads or a small folder. Allow access to the folder you choose when macOS asks.") }
            if !content.searchable && (!content.enabled || content.paused) { return L10n.local("启用并继续索引后，会在后台识别你选择的文件夹。文件名搜索始终可用。", "Enable and resume indexing to read your chosen folders in the background. Filename search remains available.") }
            if content.searchable { return L10n.local("已识别的内容可以立即搜索，无需等全部完成。试试某份文档或截图中确定出现的词。", "Search indexed content now, without waiting for every file. Try words you know appear in a document or screenshot.") }
            if content.hasError { return L10n.local("下方设置里有处理详情。检查目录读取权限、文件是否已下载，然后重试；也可以换个文件夹。", "Check the details below, folder access and whether files are downloaded. Retry or choose another folder.") }
            if content.running { return L10n.local("首次识别需要一点时间。你可以先返回搜索文件名；有文字可搜时，这里会提示。", "First indexing takes a little time. You can search filenames meanwhile; this card will show when text is ready.") }
            return L10n.local("选择包含文字的 PDF、文档或截图所在的文件夹。无可用文字或无法读取的文件，可在下方查看详情。", "Choose a folder containing text documents, PDFs or screenshots. See details below for unreadable files or files with no text.")
        case .contentSearch: return content.searchable ? L10n.local("现在按文件内容匹配。输入你确定在文档或截图里出现过的词；描述画面需要另行启用语义搜索。", "Matching file contents now. Type words you know are in a document or screenshot. Describing an image needs optional semantic search.") : L10n.local("你可以返回设置查看进度、继续索引或选择其他文件夹。也可以先用文件名搜索。", "Return to settings to check progress, resume indexing or choose another folder. Filename search is available meanwhile.")
        case .success: return L10n.local("你已经找到文件里的文字。回车打开，⌘Y 预览；以后也可以在菜单栏重新查看使用引导。", "You found words inside a file. Return opens it; ⌘Y previews it. Replay this guide from the menu bar anytime.")
        default: return ""
        }
    }
    var primaryTitle: String? {
        switch cardStep {
        case .search: return L10n.local("试着搜索", "Try a search")
        case .result: return L10n.local("查看操作", "Show actions")
        case .contentOffer: return L10n.local("试试内容搜索", "Try content search")
        case .contentSetup:
            if content.folders == 0 { return L10n.local("选择文件夹…", "Choose a folder…") }
            if !content.searchable && (!content.enabled || content.paused) { return L10n.local("启用并继续索引", "Enable and resume") }
            if content.searchable { return L10n.local("去搜关键词", "Search its words") }
            return L10n.local("选择其他文件夹…", "Choose another folder…")
        case .contentSearch: return L10n.local("查看内容设置", "Content settings")
        case .success: return L10n.local("开始使用", "You’re all set")
        default: return nil
        }
    }
    var primaryEnabled: Bool { cardStep != .result || hasResult }
    var statusText: String? {
        guard step == .contentSetup || step == .contentSearch, content.folders > 0 else { return nil }
        if content.searchable { return L10n.local("已索引 \(content.indexed) 项 · 可搜索", "\(content.indexed) indexed · searchable") }
        if content.running { return content.total > 0 ? L10n.local("正在处理 \(content.completed) / \(content.total)", "Processing \(content.completed) / \(content.total)") : L10n.local("正在检查所选文件夹", "Checking selected folders") }
        return L10n.local("已索引 \(content.indexed) 项", "\(content.indexed) indexed")
    }
}
