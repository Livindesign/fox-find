import AppKit

enum AITopicActions {
    static func desktopURL(_ topic: AITopic) -> URL? {
        if topic.provider == .codex { return topic.codexURL }
        if topic.provider == .workbuddy { return topic.workbuddyURL }
        guard topic.provider == .claude else { return nil }
        // The desktop's local session IDs are distinct from CLI UUIDs.
        guard topic.desktopID.range(of: "^local_[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil else { return nil }
        // This route opens the local session directly, including archived sessions.
        var url = URLComponents(); url.scheme = "claude"; url.host = "claude.ai"; url.path = "/epitaxy/" + topic.desktopID
        return url.url
    }
    static func copyResume(_ topic: AITopic) {
        guard !topic.resumeCommand.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(topic.resumeCommand, forType: .string)
    }
    enum OpenResult { case dispatched, unavailable, failed }

    // Prefer the running client, rather than letting an arbitrary URL handler (or
    // an old backup of the same app) receive the conversation URL.
    static func applicationURL(_ provider: AITopicProvider,
                               running: (String) -> [URL] = { NSRunningApplication.runningApplications(withBundleIdentifier: $0).compactMap(\.bundleURL) },
                               installed: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }) -> URL? {
        guard let id = AITopicInstallation.bundleIdentifiers[provider] else { return nil }
        return (running(id) + [installed(id)].compactMap { $0 }).first { url in
            let path = url.resolvingSymlinksInPath()
            return path.isFileURL && path.pathExtension == "app" &&
                !path.pathComponents.contains(where: { $0.hasPrefix(".") }) &&
                Bundle(url: path)?.bundleIdentifier == id && FileManager.default.fileExists(atPath: path.path)
        }
    }

    static func open(_ topic: AITopic, completion: @escaping (OpenResult) -> Void) {
        guard let url = desktopURL(topic), let application = applicationURL(topic.provider) else {
            completion(.unavailable); return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.open([url], withApplicationAt: application, configuration: configuration) { app, error in
            DispatchQueue.main.async {
                // LaunchServices confirms dispatch, not navigation inside the client.
                completion(app != nil && error == nil ? .dispatched : .failed)
            }
        }
    }
}

final class AITopicIcons {
    private var images: [AITopicProvider: NSImage] = [:]
    static func bundledImage(_ provider: AITopicProvider, directories: [URL]? = nil) -> NSImage? {
        // SwiftPM's generated accessor misses Contents/Resources in a packaged macOS app.
        // Resolve both installed and SwiftPM layouts without its fatal build-path fallback.
        let locations = directories ?? [Bundle.main.resourceURL, Bundle.main.bundleURL,
                                       Bundle(for: AITopicIcons.self).bundleURL.deletingLastPathComponent()].compactMap { $0 }
        for directory in locations {
            let url = directory.appendingPathComponent("FoxFind_OilFindApp.bundle")
            if let bundle = Bundle(url: url),
               let imageURL = bundle.url(forResource: provider.rawValue, withExtension: "png", subdirectory: "TopicIcons"),
               let image = NSImage(contentsOf: imageURL) { return image }
        }
        return nil
    }
    func image(_ provider: AITopicProvider) -> NSImage {
        if let image = images[provider] { return image }
        let identifier = AITopicInstallation.bundleIdentifiers[provider]!
        let image: NSImage
        if provider != .codex, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            image = NSWorkspace.shared.icon(forFile: app.path)
        } else if let asset = Self.bundledImage(provider) {
            image = asset
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            image = NSWorkspace.shared.icon(forFile: app.path)
        } else { image = NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: provider.name)! }
        images[provider] = image; return image
    }
}
