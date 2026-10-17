import AppKit
import SwiftUI
import OilFindCore

private struct UpdateGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> PanelSurface { PanelSurface(snapshot: false) }
    func updateNSView(_ nsView: PanelSurface, context: Context) {}
}

private struct UpdateActionStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 16).frame(height: 36)
            .foregroundStyle(primary ? Color(nsColor: AppearancePreferences.foreground(on: Theme.accent)) : .primary)
            .background(primary ? Color(nsColor: Theme.accent) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct UpdateView: View {
    @ObservedObject var model: UpdateManager
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                if let logo = FunctionalIcons.art("fox-original") {
                    Image(nsImage: logo).resizable().frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fox Find").font(.system(size: 16, weight: .semibold))
                    Text(L10n.local("软件更新", "Software Update")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if !model.state.installing {
                    Button(action: model.dismiss) {
                        Image(nsImage: Theme.symbol("xmark", size: 12, weight: .medium)).resizable().scaledToFit()
                            .frame(width: 12, height: 12).frame(width: 28, height: 28)
                            .background(Color.primary.opacity(0.05), in: Circle())
                    }.buttonStyle(.plain).accessibilityLabel(L10n.local("关闭更新窗口", "Close update window"))
                }
            }
            Text(title).font(.system(size: 23, weight: .semibold)).tracking(-0.4)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 26)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            if let manifest = model.manifest, !isChecking {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array((L10n.chinese ? manifest.notes.zh : manifest.notes.en).enumerated()), id: \.offset) { _, note in
                            HStack(alignment: .top, spacing: 10) {
                                Circle().fill(Color(nsColor: Theme.accent).opacity(0.7)).frame(width: 4, height: 4).padding(.top, 6)
                                Text(note).font(.system(size: 12)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }.frame(height: notesHeight).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12)).padding(.top, 20)
            }
            if case .failed(let reason) = model.state {
                Text(L10n.text("update.reason." + reason.rawValue)).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 14)
            }
            Spacer(minLength: 24)
            if model.state.installing {
                VStack(alignment: .leading, spacing: 10) {
                    if case .downloading(let fraction) = model.state {
                        HStack { Text(L10n.local("正在下载", "Downloading")); Spacer(); Text(UpdateManager.percent(fraction)).monospacedDigit() }
                        ProgressView(value: fraction)
                    } else {
                        HStack(spacing: 10) { ProgressView().controlSize(.small); Text(L10n.local("正在校验并安装…", "Verifying and installing…")) }
                    }
                    Text(L10n.local("完成后将自动重启 Fox Find。", "Fox Find will restart when the update is ready.")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else if case .available = model.state {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(L10n.local("自动更新", "Automatic updates"), isOn: $model.automatic)
                            .toggleStyle(.checkbox).font(.system(size: 12)).accessibilityIdentifier("update.automatic")
                        Text(L10n.local("每天检查，安装前由你确认", "Check daily. Ask before installing."))
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                }.padding(.bottom, 18)
                HStack {
                    Button(L10n.text("update.skip"), action: model.skip).buttonStyle(UpdateActionStyle())
                        .accessibilityIdentifier("update.skip")
                    Spacer()
                    Button(L10n.text("update.install"), action: model.install).buttonStyle(UpdateActionStyle(primary: true))
                        .keyboardShortcut(.defaultAction).accessibilityIdentifier("update.install")
                }
            } else {
                HStack {
                    if isChecking { ProgressView().controlSize(.small) }
                    Spacer()
                    if case .failed = model.state {
                        Button(L10n.local("关闭", "Close"), action: model.dismiss).buttonStyle(UpdateActionStyle()).keyboardShortcut(.cancelAction)
                        Button(L10n.text("update.openWebsite"), action: model.openWebsite).buttonStyle(UpdateActionStyle(primary: true)).keyboardShortcut(.defaultAction)
                    } else {
                        Button(isChecking ? L10n.local("关闭", "Close") : L10n.local("我知道了", "Got it"), action: model.dismiss)
                            .buttonStyle(UpdateActionStyle(primary: true)).keyboardShortcut(.defaultAction).accessibilityIdentifier("update.dismiss")
                    }
                }
            }
        }.font(.system(size: 12)).padding(28).frame(width: 440, height: contentHeight)
            .background(UpdateGlass()).clipShape(RoundedRectangle(cornerRadius: 22))
            .animation(.easeOut(duration: reducedMotion ? 0 : 0.18), value: section)
    }
    private var isChecking: Bool { model.state == .checking || model.state == .idle }
    private var section: Int {
        switch model.state { case .idle, .checking: return 0; case .latest: return 1; case .available: return 2; case .downloading, .installing: return 3; case .failed: return 4 }
    }
    private var title: String {
        switch model.state {
        case .latest: return L10n.text("update.latest.title")
        case .available: return L10n.local("新版本，准备好了", "A fresh update is ready")
        case .downloading, .installing: return L10n.local("正在更新 Fox Find", "Updating Fox Find")
        case .failed: return L10n.local("这次更新未能完成", "The update couldn’t finish")
        default: return L10n.local("看看有没有新版本", "Checking for something new")
        }
    }
    private var subtitle: String {
        if isChecking { return L10n.local("正在从 GitHub 获取最新版本信息…", "Fetching the latest release from GitHub…") }
        if let manifest = model.manifest { return "\(model.runningVersion.version.text) → \(manifest.version) · " + L10n.local("更新内容", "What’s new") }
        if case .failed = model.state { return L10n.local("你可以稍后重新检查，或前往 GitHub 下载。", "Check again later, or download from GitHub.") }
        return L10n.text("update.latest.body", model.runningVersion.version.text)
    }
    private var notesHeight: CGFloat {
        let notes = model.manifest.map { L10n.chinese ? $0.notes.zh : $0.notes.en } ?? []
        let height = notes.reduce(CGFloat(0)) { result, note in
            let text = NSAttributedString(string: note, attributes: [.font: NSFont.systemFont(ofSize: 12)])
            let measured = text.boundingRect(with: NSSize(width: 338, height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height
            return result + ceil(measured) + 6
        } + CGFloat(max(0, notes.count - 1)) * 12 + 32
        return min(224, max(72, height))
    }
    private var contentHeight: CGFloat {
        if isChecking || model.state == .latest { return 270 }
        if case .failed = model.state { return model.manifest == nil ? 324 : notesHeight + 318 }
        return notesHeight + 316
    }
}

private final class UpdatePanel: NSPanel {
    var onDismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onDismiss?() }
}

final class UpdateWindowController: NSWindowController, NSWindowDelegate {
    private let model: UpdateManager
    private var languageObserver: NSObjectProtocol?
    init(model: UpdateManager) {
        self.model = model
        let window = UpdatePanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 270), styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = L10n.text("update.check"); window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.onDismiss = { [weak model] in if model?.state.installing == false { model?.dismiss() } }
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: UpdateView(model: model)); window.delegate = self
        languageObserver = NotificationCenter.default.addObserver(forName: L10n.changed, object: nil, queue: .main) { [weak self] _ in
            self?.window?.title = L10n.text("update.check")
            self?.model.objectWillChange.send()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present() { window?.center(); window?.makeKeyAndOrderFront(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.state.installing }
    deinit { if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) } }
}
