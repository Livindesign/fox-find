import Foundation
import OilFindCore

struct SavedSearch: Codable, Equatable {
    var query: String
    var mode: SearchMode = .combined
    var folder: String?
    var kind: UInt8?
    var sort = "relevance"
    var ascending = false
    var assetFilter: AssetFilter?
    var finderTag: String?
    var minWidth: Int?
    var minHeight: Int?
    var captured: DateInterval?
    var options: SearchOptions {
        let key: SortKey = sort == "name" ? .name : sort == "modified" ? .modified : sort == "size" ? .size : .relevance
        return SearchOptions(sort: key, ascending: ascending, kind: kind)
    }
    var title: String {
        let body = query.isEmpty ? (L10n.chinese ? "最近文件" : "Recent files") : query
        let scope = folder.map { " · " + URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        let modeName = mode == .contents ? (L10n.chinese ? "内容" : "Contents") : mode == .names ? (L10n.chinese ? "文件名" : "Names") : (L10n.chinese ? "综合" : "All")
        let type = kind.map { " · " + Query.kindNames[Int($0) - 1] } ?? ""
        return String(body.prefix(70)) + scope + type + " · " + modeName + (assetFilter.map { " · " + $0.title } ?? "") + (finderTag.map { " · #" + $0 } ?? "")
    }
}

final class SearchLibrary {
    private let defaults: UserDefaults
    private(set) var favorites: [SavedSearch]
    private(set) var history: [SavedSearch]
    init(defaults: UserDefaults) {
        self.defaults = defaults
        func load(_ key: String) -> [SavedSearch] {
            guard let data = defaults.data(forKey: key), let rows = try? JSONDecoder().decode([SavedSearch].self, from: data) else { return [] }
            return rows.filter { $0.kind == nil || (1...8).contains(Int($0.kind!)) }
        }
        favorites = Array(load("search.favorites").prefix(50)); history = Array(load("search.history").prefix(20))
    }
    func toggleFavorite(_ value: SavedSearch) {
        if let i = favorites.firstIndex(of: value) { favorites.remove(at: i) }
        else { favorites.insert(value, at: 0); favorites = Array(favorites.prefix(50)) }
        persist()
    }
    func record(_ value: SavedSearch) {
        guard !value.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        history.removeAll { $0 == value }; history.insert(value, at: 0)
        history = Array(history.prefix(20)); persist()
    }
    func clearHistory() { history = []; persist() }
    private func persist() {
        if let data = try? JSONEncoder().encode(favorites) { defaults.set(data, forKey: "search.favorites") }
        if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: "search.history") }
    }
}

enum SearchExport {
    static func csv(_ rows: [[String]]) -> String {
        "\u{feff}" + rows.map { $0.map(cell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }
    static func cell(_ value: String) -> String {
        // A result filename must not become a spreadsheet formula when opened in Excel.
        let first = value.trimmingCharacters(in: .whitespacesAndNewlines).first
        let safe = first.map { "=+-@".contains($0) } == true ? "'" + value : value
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
