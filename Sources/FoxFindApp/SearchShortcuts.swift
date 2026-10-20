import Foundation

struct SearchShortcut: Codable, Equatable {
    var id = UUID().uuidString
    var name: String
    var destination: String
    var keyword = ""
    var origin = "manual"
    var url: URL? { Self.validURL(destination.replacingOccurrences(of: "{query}", with: "example")) }
    static func validURL(_ text: String) -> URL? {
        if text.hasPrefix("/") || text.hasPrefix("~/") { return URL(fileURLWithPath: (text as NSString).expandingTildeInPath).standardizedFileURL }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "file" { return url.host == nil || url.host == "" || url.host == "localhost" ? url : nil }
        guard ["https", "http"].contains(scheme), url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return url
    }
    func resolved(for query: String) -> URL? {
        guard destination.contains("{query}") else { return url }
        let parts = query.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard parts.count == 2, LauncherApplication.normalize(String(parts[0])) == LauncherApplication.normalize(keyword), !keyword.isEmpty else { return nil }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encoded = String(parts[1]).addingPercentEncoding(withAllowedCharacters: safe) else { return nil }
        return Self.validURL(destination.replacingOccurrences(of: "{query}", with: encoded))
    }
    func score(_ query: String) -> Int? {
        let q = LauncherApplication.normalize(query), name = LauncherApplication.normalize(name), alias = LauncherApplication.normalize(keyword)
        guard !q.isEmpty else { return nil }
        if destination.contains("{query}") { return resolved(for: query) != nil ? 0 : nil }
        if q == alias || q == name { return 0 }
        if name.hasPrefix(q) || (!alias.isEmpty && alias.hasPrefix(q)) { return 10 }
        return q.count >= 2 && name.contains(q) ? 20 : nil
    }
}

final class SearchShortcuts {
    private let defaults: UserDefaults
    private(set) var items: [SearchShortcut]
    private var index: [(item: SearchShortcut, name: String, alias: String)] = []
    static let limit = 5000
    init(defaults: UserDefaults) {
        self.defaults = defaults
        items = defaults.data(forKey: "search.shortcuts").flatMap { try? JSONDecoder().decode([SearchShortcut].self, from: $0) } ?? []
        items = Array(items.filter { $0.url != nil && !$0.name.isEmpty }.prefix(Self.limit))
        rebuildIndex()
    }
    @discardableResult func save(_ item: SearchShortcut) -> Bool {
        guard !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, item.url != nil,
              !item.destination.contains("{query}") || (!item.keyword.isEmpty && !item.keyword.contains(where: \.isWhitespace)) else { return false }
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
        else { guard items.count < Self.limit else { return false }; items.append(item) }
        persist(); return true
    }
    func remove(_ id: String) { items.removeAll { $0.id == id }; persist() }
    @discardableResult func merge(_ incoming: [SearchShortcut]) -> Int {
        var known = Set(items.map(\.destination)), added = 0
        for item in incoming where items.count < Self.limit && item.url != nil && !item.name.isEmpty {
            if known.insert(item.destination).inserted { items.append(item); added += 1 }
        }
        persist(); return added
    }
    func matches(_ query: String, limit: Int = 3) -> [SearchShortcut] {
        var ranked: [(item: SearchShortcut, score: Int)] = []
        let q = LauncherApplication.normalize(query)
        guard !q.isEmpty, q.utf8.count <= 2048 else { return [] }
        for entry in index {
            if entry.item.destination.contains("{query}") {
                if !entry.alias.isEmpty, q.hasPrefix(entry.alias + " ") { ranked.append((entry.item, 0)) }
            } else if q == entry.alias || q == entry.name { ranked.append((entry.item, 0)) }
            else if entry.name.hasPrefix(q) || (!entry.alias.isEmpty && entry.alias.hasPrefix(q)) { ranked.append((entry.item, 10)) }
            else if q.count >= 2 && entry.name.contains(q) { ranked.append((entry.item, 20)) }
        }
        ranked.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            if lhs.item.name != rhs.item.name { return lhs.item.name < rhs.item.name }
            return lhs.item.id < rhs.item.id
        }
        return ranked.prefix(limit).map { $0.item }
    }
    private func rebuildIndex() { index = items.map { ($0, LauncherApplication.normalize($0.name), LauncherApplication.normalize($0.keyword)) } }
    private func persist() { rebuildIndex(); if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: "search.shortcuts") } }
}

enum BookmarkImport {
    enum Failure: Error { case tooLarge, unsupported }
    static func parse(_ data: Data, format: String) throws -> [SearchShortcut] {
        guard data.count <= 8 * 1024 * 1024 else { throw Failure.tooLarge }
        var items = [SearchShortcut]()
        func add(_ name: String?, _ destination: String?) {
            guard items.count < SearchShortcuts.limit, let name, let destination,
                  let url = SearchShortcut.validURL(destination), !url.isFileURL else { return }
            items.append(SearchShortcut(name: name.isEmpty ? (url.host ?? destination) : name, destination: url.absoluteString, origin: "bookmark"))
        }
        func visit(_ value: Any, depth: Int = 0) {
            guard depth < 64, items.count < SearchShortcuts.limit else { return }
            if let values = value as? [Any] { values.forEach { visit($0, depth: depth + 1) } }
            if let object = value as? [String: Any] {
                if let url = object["url"] as? String { add(object["name"] as? String, url) }
                else if let url = object["URLString"] as? String { add((object["URIDictionary"] as? [String: Any])?["title"] as? String, url) }
                for key in ["roots", "children", "Children", "bookmark_bar", "other", "synced"] {
                    if let child = object[key] { visit(child, depth: depth + 1) }
                }
            }
        }
        if ["html", "htm"].contains(format.lowercased()) {
            guard let text = String(data: data, encoding: .utf8),
                  let regex = try? NSRegularExpression(pattern: "<a\\b[^>]*?href\\s*=\\s*([\"'])(.*?)\\1[^>]*>(.*?)</a>", options: [.caseInsensitive, .dotMatchesLineSeparators]) else { throw Failure.unsupported }
            let ns = text as NSString
            regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, stop in
                guard let match else { return }
                add(decode(ns.substring(with: match.range(at: 3)).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)), decode(ns.substring(with: match.range(at: 2))))
                if items.count >= SearchShortcuts.limit { stop.pointee = true }
            }
        } else if let value = try? JSONSerialization.jsonObject(with: data) { visit(value) }
        else if let value = try? PropertyListSerialization.propertyList(from: data, format: nil) { visit(value) }
        else { throw Failure.unsupported }
        return items
    }
    private static func decode(_ input: String) -> String {
        var result = input
        for (entity, value) in [("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] { result = result.replacingOccurrences(of: entity, with: value) }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct SearchUse: Codable { var query: String, target: String; var count: Int; var date: Date }
final class SearchUsage {
    private let defaults: UserDefaults
    private(set) var entries: [SearchUse]
    init(defaults: UserDefaults) {
        self.defaults = defaults
        entries = defaults.data(forKey: "search.usage").flatMap { try? JSONDecoder().decode([SearchUse].self, from: $0) } ?? []
    }
    func record(query: String, target: String) {
        let query = LauncherApplication.normalize(query)
        guard !query.isEmpty, query.utf8.count <= 512 else { return }
        let previous = entries.first { $0.query == query && $0.target == target }
        entries.removeAll { $0.query == query && $0.target == target }
        entries.insert(SearchUse(query: query, target: target, count: min(1000, (previous?.count ?? 0) + 1), date: Date()), at: 0)
        entries = Array(entries.prefix(1000)); persist()
    }
    func scores(for query: String) -> [String: Int] {
        let query = LauncherApplication.normalize(query)
        return Dictionary(entries.filter { $0.query == query }.map { ($0.target, $0.count) }, uniquingKeysWith: max)
    }
    func clear() { entries = []; persist() }
    private func persist() { if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: "search.usage") } }
}
