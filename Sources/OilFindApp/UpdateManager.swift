import AppKit
import OilFindCore

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
        UpdateVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3.0",
                      build: Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "7") ?? 7)
            ?? UpdateVersion("1.3.0", build: 7)!
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
    var preventsTermination: Bool { state.installing && !readyToRelaunch }
    var canCheck: Bool {
        #if DEBUG
        return false
        #else
        return false
        #endif
    }
    init(snapshot: Bool = false, preferences: UpdatePreferences = UpdatePreferences(), current: UpdateVersion = UpdateManager.current) {
        self.snapshot = snapshot; self.preferences = preferences
        runningVersion = current
        automatic = snapshot ? true : preferences.automatic
    }
    func start() {}
    func stop() { timer?.invalidate(); timer = nil; started = false }
    private func schedule(delay: TimeInterval = 86_400) {
        timer?.invalidate(); timer = nil
        guard started, automatic else { return }
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.check(manual: false); self?.schedule()
        }
    }
    func check(manual: Bool = true) {}
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
    func install() {}
    func openWebsite() {}
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
    deinit { timer?.invalidate() }
}
