import AppKit
import FoxFindCore

enum UpdateState: Equatable {
    case idle, checking, available, downloading(Double), installing, latest, failed(UpdateFailure)
    var busy: Bool {
        switch self { case .checking, .downloading, .installing: return true; default: return false }
    }
    var installing: Bool {
        switch self { case .downloading, .installing: return true; default: return false }
    }
}

final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()
    static var current: UpdateVersion {
        UpdateVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.1",
                      build: Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "27") ?? 27)
            ?? UpdateVersion("0.0.1", build: 27)!
    }
    @Published private(set) var state: UpdateState = .idle
    @Published private(set) var manifest: UpdateManifest?
    @Published var automatic: Bool { didSet { if !snapshot { preferences.automatic = automatic; schedule() } } }
    var onChange: (() -> Void)?
    private let preferences: UpdatePreferences
    let runningVersion: UpdateVersion
    private let snapshot: Bool
    private var timer: Timer?
    private var windowController: UpdateWindowController?
    private var started = false
    private var readyToRelaunch = false
    private var checkTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private var publicKey: Data? { (Bundle.main.object(forInfoDictionaryKey: "FoxUpdatePublicKey") as? String).flatMap { Data(base64Encoded: $0) } }
    var preventsTermination: Bool { state.installing && !readyToRelaunch }
    var canCheck: Bool {
        !snapshot && !state.busy && Bundle.main.bundleURL.pathExtension == "app" && publicKey?.count == 32
    }
    init(snapshot: Bool = false, preferences: UpdatePreferences = UpdatePreferences(), current: UpdateVersion = UpdateManager.current) {
        self.snapshot = snapshot; self.preferences = preferences
        runningVersion = current
        automatic = snapshot ? true : preferences.automatic
    }
    func start() {
        guard !started, canCheck else { return }
        started = true
        let elapsed = preferences.lastCheck.map { Date().timeIntervalSince($0) } ?? 86_400
        schedule(delay: max(90, min(86_400, 86_400 - elapsed)))
    }
    func stop() { timer?.invalidate(); timer = nil; started = false; checkTask?.cancel(); checkTask = nil }
    private func schedule(delay: TimeInterval = 86_400) {
        timer?.invalidate(); timer = nil
        guard started, automatic else { return }
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.check(manual: false); self?.schedule()
        }
        timer?.tolerance = min(60, delay * 0.1)
    }
    func check(manual: Bool = true) {
        guard canCheck, let publicKey else { return }
        manifest = nil; setState(.checking)
        if manual { present() }
        preferences.lastCheck = Date()
        checkTask = Task.detached(priority: .utility) { [weak self] in
            do {
                let found = try await GitHubUpdateClient(publicKey: publicKey).check()
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if let found, self.preferences.shouldOffer(found, current: self.runningVersion, system: ProcessInfo.processInfo.operatingSystemVersion, manual: manual) {
                        self.manifest = found; self.setState(.available)
                    } else { self.manifest = nil; self.setState(manual ? .latest : .idle) }
                    self.checkTask = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.setState(manual ? .failed((error as? UpdateFailure) ?? .network) : .idle)
                    self?.checkTask = nil
                }
            }
        }
    }
    func present() {
        if windowController == nil { windowController = UpdateWindowController(model: self) }
        NSApp.activate(ignoringOtherApps: true)
        windowController?.present()
    }
    func dismiss() { windowController?.close() }
    func skip() {
        guard let manifest, !state.busy else { return }
        if !snapshot { preferences.skip(manifest) }
        self.manifest = nil; setState(.idle); dismiss()
    }
    func install() {
        guard canCheck, case .available = state, let manifest, let publicKey else { return }
        let application = Bundle.main.bundleURL, current = runningVersion
        setState(.downloading(0))
        let updateProgress: @MainActor @Sendable (Double) -> Void = { [weak self] fraction in
            guard let self, case .downloading = self.state else { return }
            self.setState(.downloading(fraction))
        }
        installTask = Task { @MainActor [weak self] in
            var archive: URL?
            defer { if let archive { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) } }
            do {
                let downloaded = try await GitHubUpdateClient(publicKey: publicKey).download(manifest) { fraction in
                    Task { @MainActor in updateProgress(fraction) }
                }
                archive = downloaded
                self?.setState(.installing)
                try await Task.detached(priority: .utility) {
                    let installer = UpdateInstaller(application: application, current: current, signature: FoxUpdateSignature())
                    let installation = try installer.install(archive: downloaded, manifest: manifest)
                    do { try UpdateRelauncher().startWaiting(for: ProcessInfo.processInfo.processIdentifier, installation: installation) }
                    catch { try installer.rollback(installation); throw UpdateFailure.other }
                }.value
                self?.readyToRelaunch = true
                Permissions.cancelRelaunch()
                NSApp.terminate(nil)
            } catch {
                self?.setState(.failed((error as? UpdateFailure) ?? .other)); self?.installTask = nil
            }
        }
    }

    func openWebsite() { NSWorkspace.shared.open(FoxUpdateTrust.releases) }
    func reportLaunchFailure(_ failure: UpdateFailure) { setState(.failed(failure)); present() }
    private func setState(_ value: UpdateState) { state = value; onChange?() }
    var menuTitle: String {
        switch state {
        case .downloading(let fraction): return L10n.text("update.downloading", Self.percent(fraction))
        case .installing: return L10n.text("update.installing")
        default: return manifest.map { L10n.text("update.menuAvailable", $0.version) } ?? L10n.text("update.check")
        }
    }
    static func percent(_ fraction: Double) -> String { "\(Int(fraction * 100))%" }
    #if DEBUG
    func prepareSnapshot(_ state: UpdateState, manifest: UpdateManifest?) { self.manifest = manifest; setState(state) }
    #endif
    deinit { timer?.invalidate(); checkTask?.cancel() }
}
