import Foundation

struct ProjectFolder: Codable, Equatable {
    let path: String
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}
final class ProjectFolders {
    private let defaults: UserDefaults
    private(set) var folders: [ProjectFolder]
    init(defaults: UserDefaults) {
        self.defaults = defaults
        folders = defaults.data(forKey: "search.projects").flatMap { try? JSONDecoder().decode([ProjectFolder].self, from: $0) } ?? []
    }
    func add(_ path: String) {
        let item = ProjectFolder(path: URL(fileURLWithPath: path).standardizedFileURL.path)
        guard !folders.contains(item) else { return }
        folders.append(item); persist()
    }
    func remove(_ path: String) { folders.removeAll { $0.path == path }; persist() }
    private func persist() { if let data = try? JSONEncoder().encode(folders) { defaults.set(data, forKey: "search.projects") } }
}

