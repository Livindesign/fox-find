import AppKit
import SwiftUI
import Combine
import OilFindCore
import OilFindApp

public final class LocalFindExtension: ApplicationExtension {
    let settings: ContentSettings
    private let database: ContentDatabase?
    private var engine: ContentEngine?
    private var provider: ContentSearch?
    private var semanticEngine: SemanticEngine?
    private let semanticModels: SemanticModels
    private weak var catalog: ExternalDriveCatalogReading?
    private var subscription: AnyCancellable?
    private var timer: Timer?
    private var offlineManagers = [String: IndexManager]()
    private var offlineInfo = [String: ExternalDriveInfo]()
    private var previousFolders: [String]
    public var onSearchSourcesChange: (() -> Void)?
    public var onSettingsMenuItemChange: (() -> Void)?
    private var showSettings: (() -> Void)?
    public convenience init() {
        #if DEBUG
        if let directory = ProcessInfo.processInfo.environment["LOCALFIND_TEST_PROFILE"] {
            self.init(dataDirectory: URL(fileURLWithPath: directory), defaults: UserDefaults(suiteName: "app.localfind.demo")!)
            return
        }
        #endif
        self.init(dataDirectory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Local Find"), defaults: .standard)
    }
    init(dataDirectory: URL, defaults: UserDefaults) {
        let settings = ContentSettings(defaults: defaults); self.settings = settings; previousFolders = settings.folders
        semanticModels = SemanticModels(directory: dataDirectory.appendingPathComponent("SemanticModels"))
        let url = dataDirectory.appendingPathComponent("content.sqlite")
        do {
            let db = try ContentDatabase(url: url); database = db
            let engine = ContentEngine(database: db, settings: settings); self.engine = engine
            provider = ContentSearch(database: db, settings: settings, engine: engine)
            DispatchQueue.global(qos: .utility).async {
                if let stats = try? db.statistics() {
                    DispatchQueue.main.async { settings.indexed = stats.indexed; settings.skipped = stats.skipped }
                }
            }
            engine.onResultsChange = { [weak self] in self?.onSearchSourcesChange?() }
            do {
                let semanticDB = try SemanticDatabase(url: dataDirectory.appendingPathComponent("semantic.sqlite"))
                let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/foxfind-semantic-worker")
                let sibling = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("foxfind-semantic-worker")
                let helper = FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : sibling
                let semantic = SemanticEngine(database: semanticDB, settings: settings, models: semanticModels, helper: helper)
                semanticEngine = semantic; provider?.semantic = SemanticSearch(database: semanticDB, engine: semantic)
                semantic.onResultsChange = { [weak self] in self?.onSearchSourcesChange?() }
                semanticModels.onReady = { [weak semantic] in semantic?.request() }
                semantic.refreshStats()
            } catch { settings.semanticError = error.localizedDescription }
        } catch { database = nil; settings.error = error.localizedDescription }
        settings.onChange = { [weak self] in
            guard let self else { return }
            let removed = self.previousFolders.contains { !self.settings.folders.contains($0) }
            self.previousFolders = self.settings.folders
            if removed { self.engine?.clear() }
            self.engine?.settingsChanged(); self.semanticEngine?.settingsChanged();
            if !self.settings.semanticEnabled || !self.settings.enabled { self.provider?.semantic?.close() }
            self.refreshOffline(); self.onSearchSourcesChange?()
        }
    }
    public var supplementarySearchProvider: SupplementarySearchProvider? { provider }
    public func attachExternalDrives(_ catalog: ExternalDriveCatalogReading) {
        self.catalog = catalog
        subscription = catalog.changes.sink { [weak self] in self?.refreshOffline() }
        refreshOffline()
    }
    public func start(chinese: Bool, showSettings: @escaping () -> Void) {
        settings.chinese = chinese; self.showSettings = showSettings
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.engine?.request(); self?.semanticEngine?.request() }
        refreshOffline()
    }
    public var settingsMenuItem: ApplicationMenuItem? {
        ApplicationMenuItem(title: settings.text("内容搜索设置…", "Content Search…")) { [weak self] in self?.showSettings?() }
    }
    public func stop() {
        timer?.invalidate(); timer = nil; engine?.stop(); semanticEngine?.stop(); provider?.semantic?.close(); semanticModels.cancel()
        for manager in offlineManagers.values { manager.stop() }
        offlineManagers.removeAll(); subscription = nil
    }
    public func languageDidChange(chinese: Bool) { settings.chinese = chinese; onSettingsMenuItemChange?() }
    public func handle(_ url: URL) {}
    public func searchSources() -> [SearchSource] {
        offlineManagers.keys.sorted().compactMap { id in
            guard let manager = offlineManagers[id], let store = manager.store, let info = offlineInfo[id] else { return nil }
            return SearchSource(id: id, displayName: info.name, isOnline: false, store: store)
        }
    }
    private func refreshOffline() {
        let desired = (catalog?.knownDrives ?? []).filter { settings.offline && $0.enabled && !$0.isConnected }
        let ids = Set(desired.map(\.id))
        for id in Array(offlineManagers.keys) where !ids.contains(id) {
            offlineManagers.removeValue(forKey: id)?.stop(); offlineInfo.removeValue(forKey: id)
        }
        for drive in desired {
            if offlineInfo[drive.id] == drive { continue }
            offlineManagers.removeValue(forKey: drive.id)?.stop()
            let config = IndexConfig(rootPath: drive.path, excludedNames: IndexConfig.standard().excludedNames)
            let manager = IndexManager(config: config, dbURL: drive.catalogURL, volumeUUID: drive.id)
            manager.onIndexChange = { [weak self] in self?.onSearchSourcesChange?() }
            offlineManagers[drive.id] = manager; offlineInfo[drive.id] = drive
            manager.startOffline()
        }
        onSearchSourcesChange?()
    }
    public func settingsSection(window: @escaping () -> NSWindow?) -> AnyView {
        AnyView(ContentSettingsView(model: settings, semanticModels: semanticModels, rebuildSemantic: { [weak self] in self?.semanticEngine?.clear() }, rebuild: { [weak self] in self?.engine?.clear() }, retry: { [weak self] in self?.engine?.retryIncomplete() }, diagnostics: { [weak self] completion in self?.engine?.loadDiagnostics(completion) }, window: window))
    }
}

private struct ContentSettingsView: View {
    @ObservedObject var model: ContentSettings
    @ObservedObject var semanticModels: SemanticModels
    let rebuildSemantic: () -> Void
    let rebuild: () -> Void
    let retry: () -> Void
    let diagnostics: (@escaping ([ContentIssue]) -> Void) -> Void
    let window: () -> NSWindow?
    @State private var confirmClear = false
    @State private var showIssues = false
    @State private var issues = [ContentIssue]()
    @State private var loadingIssues = false
    var body: some View {
        Section(model.text("Fox Find · 内容搜索", "Fox Find · Content Search")) {
            Toggle(model.text("启用内容搜索", "Enable content search"), isOn: $model.enabled)
            Text(model.text("选择文件夹后，会在后台识别图片和文档。文件内容和索引均留在这台 Mac。", "Choose folders to index images and documents in the background. Files and indexes stay on this Mac."))
                .font(.footnote).foregroundStyle(.secondary)
            Toggle(model.text("识别图片文字 / 扫描版 PDF", "Recognize image text / scanned PDFs"), isOn: $model.images)
            Toggle(model.text("识别图片场景和物体", "Recognize image scenes and objects"), isOn: $model.labels)
            Text(model.text("场景标签以英文为主，常见类别附中文词。", "Scene labels are mainly English, with Chinese aliases for common categories."))
                .font(.footnote).foregroundStyle(.secondary)
            Toggle(model.text("搜索文档内容", "Search document contents"), isOn: $model.documents)
            Text("PDF · DOCX · XLSX · PPTX · ODT/ODS/ODP · RTF/DOC · TXT/Markdown/Code")
                .font(.footnote).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(model.text("内容索引文件夹", "Content folders")).fontWeight(.medium)
                    Spacer()
                    Menu(model.text("常用文件夹", "Common Folders")) {
                        ForEach(["Desktop", "Documents", "Downloads", "Pictures"], id: \.self) { name in
                            Button(folderName(name)) {
                                let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(name)
                                model.folders = ExcludedFolders.adding([url.path], to: model.folders)
                            }
                        }
                    }
                    Button(model.text("添加文件夹…", "Add Folder…"), action: chooseFolder)
                }
                if model.folders.isEmpty {
                    Text(model.text("尚未选择：目前只能按文件名查找。添加素材所在文件夹后，自动识别图片和文档内容。", "None selected. Indexing begins after adding a folder; filename search is always available."))
                        .foregroundStyle(.secondary).font(.footnote)
                }
                ForEach(model.folders, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder")
                        Text(path).font(.footnote).lineLimit(2).textSelection(.enabled)
                        Spacer()
                        Button { model.folders.removeAll { $0 == path } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help(model.text("移除文件夹并重建内容缓存", "Remove folder and rebuild content cache"))
                    }
                }
            }
            HStack {
                Image(systemName: model.running ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                Text(model.running ? model.text("正在处理", "Indexing") + " \(model.completed)/\(model.total)" :
                    (!model.enabled ? model.text("内容搜索已关闭", "Content search disabled") : model.paused ? model.text("索引已暂停，缓存仍可搜索", "Indexing paused; cache searchable") : model.folders.isEmpty ? model.text("请选择内容文件夹", "Choose content folders") : model.text("等待文件变化", "Watching for changes")))
                Spacer()
                Text(model.text("已索引 \(model.indexed) 项", "\(model.indexed) indexed")).monospacedDigit()
            }.font(.footnote)
            Button(model.paused ? model.text("继续内容索引", "Resume Content Indexing") : model.text("暂停内容索引", "Pause Content Indexing")) { model.paused.toggle() }
                .disabled(!model.enabled || model.folders.isEmpty)
            if model.running {
                ProgressView(value: Double(min(model.completed, model.total)), total: Double(max(1, model.total)))
                Text(model.currentFile).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if model.skipped > 0 {
                Text(model.text("\(model.skipped) 项无可用文字、读取失败或达到处理上限。", "\(model.skipped) items have no text, failed extraction, or reached a processing limit."))
                    .font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Button(model.text("查看处理详情…", "View Details…")) {
                        showIssues = true; loadingIssues = true
                        diagnostics { issues = $0; loadingIssues = false }
                    }
                    Button(model.text("重试未完整处理的文件", "Retry Incomplete Files"), action: retry)
                        .disabled(model.paused || !model.enabled)
                }
            }
            if !model.error.isEmpty { Text(model.error).foregroundStyle(.red).font(.footnote).textSelection(.enabled) }
            Button(model.text("清空内容缓存…", "Clear Content Cache…")) { confirmClear = true }
                .confirmationDialog(model.text("清空后，已启用的文件夹会重新建立索引。原文件不受影响。", "Enabled folders will be reindexed. Original files are unaffected."), isPresented: $confirmClear) {
                    Button(model.text("清空缓存", "Clear Cache"), role: .destructive, action: rebuild)
                }
            Text(model.text("上限：64 MB/文件、20 万字、PDF 前 200 页（扫描页最多 20 页）。未下载的云端文件跳过；沿用文件名索引的排除规则。", "Limits: 64 MB/file, 200k characters, first 200 PDF pages (up to 20 scanned pages). Undownloaded cloud files and filename-index exclusions are skipped."))
                .font(.caption).foregroundStyle(.secondary)
            SemanticSettingsSection(model: model, models: semanticModels, rebuild: rebuildSemantic, chooseFolder: chooseFolder)
            Toggle(model.text("拔出磁盘后保留目录搜索", "Search saved catalogs after disconnecting drives"), isOn: $model.offline)
            Text(model.text("磁盘连接时先建立目录；内容需包含在所选文件夹中。离线结果会标明磁盘，重新连接后可打开。", "First index the drive while connected. Content must be inside selected folders. Offline results identify their drive; reconnect to open files."))
                .font(.footnote).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showIssues) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(model.text("内容索引处理详情", "Content Index Details")).font(.title2).bold()
                    Spacer(); Button(model.text("完成", "Done")) { showIssues = false }
                }
                Text(model.text("最多显示 100 项；达到上限的文件仍保留可用内容。", "Shows up to 100 items. Files at a processing limit retain available content.")).font(.footnote).foregroundStyle(.secondary)
                if loadingIssues { ProgressView() }
                List(issues) { issue in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(issue.path).font(.system(size: 12)).textSelection(.enabled)
                        Text(issue.reason(chinese: model.chinese)).font(.footnote).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
            }.padding(20).frame(width: 680, height: 440)
        }
    }
    private func folderName(_ name: String) -> String {
        model.chinese ? (["Desktop": "桌面", "Documents": "文稿", "Downloads": "下载", "Pictures": "图片"][name] ?? name) : name
    }
    private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.prompt = model.text("添加", "Add")
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK { model.folders = ExcludedFolders.adding(panel.urls.map { $0.resolvingSymlinksInPath().path }, to: model.folders) }
        }
        if let window = window() { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
}
