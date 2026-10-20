import Foundation

struct LauncherApplication: Equatable {
    let path: String, name: String, bundleID: String
    let searchNames: [String]
    private let searchWords: [String]
    init(path: String, name: String, bundleID: String, aliases: [String] = []) {
        self.path = path; self.name = name; self.bundleID = bundleID
        var names = [name, URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent] + aliases
        for name in names {
            if name.unicodeScalars.contains(where: { (0x3400...0x9fff).contains($0.value) }),
               let latin = name.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false) {
                names.append(latin.replacingOccurrences(of: " ", with: ""))
                names.append(latin.split(separator: " ").compactMap(\.first).map(String.init).joined())
            }
        }
        searchNames = Array(Set(names.map(Self.normalize))).sorted()
        searchWords = Array(Set(searchNames.filter { $0.contains(" ") }.flatMap { $0.split(separator: " ").map(String.init) })).sorted()
    }
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    func score(_ query: String) -> Int? {
        var best = Int.max
        let substring = query.utf8.count >= 2
        for name in searchNames {
            if name == query { return 0 }
            if name.hasPrefix(query) { best = min(best, 10) }
            else if substring && name.contains(query) { best = min(best, 30) }
        }
        if best > 20 && searchWords.contains(where: { $0.hasPrefix(query) }) { best = 20 }
        return best == Int.max ? nil : best
    }
}

/// Main-thread snapshots; discovery and plist/name decoding stay off the typing path.
final class ApplicationCatalog {
    private(set) var applications: [LauncherApplication] = []
    private let queue = DispatchQueue(label: "app.localfind.desktop.applications", qos: .utility)
    private var refreshing = false
    private var refreshedAt = Date.distantPast
    var onChange: (() -> Void)?
    func replace(_ applications: [LauncherApplication]) { self.applications = applications; refreshedAt = Date(); onChange?() }
    func refreshIfNeeded() {
        guard !refreshing, Date().timeIntervalSince(refreshedAt) > 30 else { return }
        refreshing = true
        queue.async { [weak self] in
            let applications = Self.discover()
            DispatchQueue.main.async {
                guard let self else { return }
                self.applications = applications; self.refreshedAt = Date(); self.refreshing = false; self.onChange?()
            }
        }
    }
    func matches(_ text: String, limit: Int = 3) -> [LauncherApplication] {
        let query = LauncherApplication.normalize(text)
        guard !query.isEmpty, query.count <= 100,
              query.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: ".-_+&")).contains($0) }) else { return [] }
        return applications.compactMap { app in app.score(query).map { (app, $0) } }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                let order = lhs.0.name.localizedStandardCompare(rhs.0.name)
                return order == .orderedSame ? lhs.0.path < rhs.0.path : order == .orderedAscending
            }.prefix(limit).map(\.0)
    }
    static func discover(roots: [URL]? = nil) -> [LauncherApplication] {
        let fm = FileManager.default
        let folders = roots ?? [URL(fileURLWithPath: "/Applications"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"), URL(fileURLWithPath: "/System/Applications"), URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications")]
        var paths = Set<String>(), found: [LauncherApplication] = []
        func inspect(_ url: URL) {
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard paths.insert(canonical).inserted,
                  let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  (info["CFBundlePackageType"] as? String) == "APPL",
                  !isTrue(info["LSBackgroundOnly"]),
                  let executable = info["CFBundleExecutable"] as? String,
                  fm.isExecutableFile(atPath: url.appendingPathComponent("Contents/MacOS/" + executable).path) else { return }
            let bundleID = info["CFBundleIdentifier"] as? String ?? url.path
            let name = (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? url.deletingPathExtension().lastPathComponent
            var aliases = [info["CFBundleDisplayName"] as? String, info["CFBundleName"] as? String].compactMap { $0 }
            // Include both English and Chinese display names independently of the current OS language.
            for locale in ["en", "zh_CN", "zh-Hans", "zh_TW", "zh-Hant"] {
                let file = url.appendingPathComponent("Contents/Resources/" + locale + ".lproj/InfoPlist.strings")
                if let data = try? Data(contentsOf: file), let names = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                    aliases += [names["CFBundleDisplayName"] as? String, names["CFBundleName"] as? String].compactMap { $0 }
                }
            }
            let tableURL = url.appendingPathComponent("Contents/Resources/InfoPlist.loctable")
            if let data = try? Data(contentsOf: tableURL), let table = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                for locale in ["en", "en_US", "zh_CN", "zh-Hans", "zh_TW", "zh-Hant"] {
                    if let names = table[locale] as? [String: Any] {
                        aliases += [names["CFBundleDisplayName"] as? String, names["CFBundleName"] as? String].compactMap { $0 }
                    }
                }
            }
            found.append(.init(path: url.path, name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name, bundleID: bundleID, aliases: aliases))
        }
        for root in folders {
            // Some system app links (including Safari) are hidden from recursive enumeration.
            for url in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension.lowercased() == "app" && !url.lastPathComponent.hasPrefix(".") { inspect(url) }
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let url = enumerator.nextObject() as? URL {
                if url.pathExtension.lowercased() == "app" { inspect(url); enumerator.skipDescendants() }
                else if enumerator.level >= 3 { enumerator.skipDescendants() }
            }
        }
        if roots == nil { inspect(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")) }
        return found.sorted { $0.path < $1.path }
    }
    private static func isTrue(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String { return ["1", "true", "yes"].contains(text.lowercased()) }
        return false
    }
}
