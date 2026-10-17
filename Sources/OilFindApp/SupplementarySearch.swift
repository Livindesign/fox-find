import AppKit
import OilFindCore

public enum SearchMode: String, Codable, CaseIterable { case combined, names, contents }

public struct ContentTextSegment: Codable, Equatable {
    public var offset: Int, length: Int, page: Int
    public init(offset: Int, length: Int, page: Int) { self.offset = offset; self.length = length; self.page = page }
}

public struct ExtractedTextPreview {
    public let path: String, text: String, note: String
    public let isOnline: Bool
    public let segments: [ContentTextSegment]
    public let sourceStamp: String?
    public let isCached: Bool
    public init(path: String, text: String, note: String, isOnline: Bool, segments: [ContentTextSegment] = [], sourceStamp: String? = nil, isCached: Bool = true) {
        self.path = path; self.text = text; self.note = note; self.isOnline = isOnline
        self.segments = segments; self.sourceStamp = sourceStamp
        self.isCached = isCached
    }
}

public enum TextPreviewOutcome {
    case ready(ExtractedTextPreview)
    case unavailable(String)
    case cancelled
}

/// Additional matches refer to entries in the captured source snapshot.
public struct SupplementaryHit {
    public let sourceID: String
    public let entryID: UInt32
    private let decoration: () -> (text: String, highlights: [NSRange])
    public var presentation: (text: String, highlights: [NSRange]) { decoration() }
    public var detail: String { decoration().text }
    public var highlights: [NSRange] { decoration().highlights }
    public let semanticScore: Float?
    public let lexicalScore: Double?
    public let matchedPage: Int?
    public let matchedStamp: String?
    public let thumbnail: Bool
    func samePresentation(as other: SupplementaryHit) -> Bool {
        guard sourceID == other.sourceID, entryID == other.entryID,
              thumbnail == other.thumbnail, semanticScore == other.semanticScore, lexicalScore == other.lexicalScore,
              matchedPage == other.matchedPage, matchedStamp == other.matchedStamp else { return false }
        let a = presentation, b = other.presentation
        return a.text == b.text && a.highlights == b.highlights
    }
    public init(sourceID: String, entryID: UInt32, detail: String, highlights: [NSRange] = [], thumbnail: Bool = false, semanticScore: Float? = nil, matchedPage: Int? = nil, matchedStamp: String? = nil, lexicalScore: Double? = nil) {
        self.matchedStamp = matchedStamp
        self.semanticScore = semanticScore; self.matchedPage = matchedPage; self.lexicalScore = lexicalScore
        self.sourceID = sourceID; self.entryID = entryID; self.decoration = { (detail, highlights) }; self.thumbnail = thumbnail
    }
    public init(sourceID: String, entryID: UInt32, thumbnail: Bool = false, presentation: @escaping () -> (text: String, highlights: [NSRange])) {
        semanticScore = nil; matchedPage = nil; matchedStamp = nil; lexicalScore = nil
        self.sourceID = sourceID; self.entryID = entryID; self.thumbnail = thumbnail; decoration = presentation
    }
}
public typealias SupplementaryFileFilter = (SearchSource, UInt32) -> Bool

/// Main-thread snapshot; no disk work in the search panel's status refresh.
public struct SupplementarySearchStatus: Equatable {
    public let title: String, message: String, actionTitle: String
    public let canSearch: Bool
    public let indexedFiles: Int
    public var summary = ""
    public var folders: [String] = []
    public init(title: String, message: String, actionTitle: String, canSearch: Bool = false, indexedFiles: Int = 0) {
        self.title = title; self.message = message; self.actionTitle = actionTitle
        self.canSearch = canSearch; self.indexedFiles = indexedFiles
    }
}

public protocol SupplementarySearchProvider: AnyObject {
    var semanticStatus: SupplementarySearchStatus? { get }
    func contentStatus(in folder: String?) -> SupplementarySearchStatus?
    var isEnabled: Bool { get }
    var supportsSimilarity: Bool { get }
    func prepareSemantic(_ query: Query, options: SearchOptions, sources: [SearchSource], accepts: @escaping SupplementaryFileFilter, isCancelled: @escaping () -> Bool) -> (() -> [SupplementaryHit])?
    func prepareSimilarity(path: String, query: Query, options: SearchOptions, sources: [SearchSource], accepts: @escaping SupplementaryFileFilter, isCancelled: @escaping () -> Bool) -> () -> [SupplementaryHit]
    func prepareSemantic(_ query: Query, options: SearchOptions, sources: [SearchSource], isCancelled: @escaping () -> Bool) -> (() -> [SupplementaryHit])?
    func prepareSimilarity(path: String, query: Query, options: SearchOptions, sources: [SearchSource], isCancelled: @escaping () -> Bool) -> () -> [SupplementaryHit]
    /// Called on the main thread; returned work runs concurrently with the name search.
    func prepareSearch(_ query: Query, options: SearchOptions, sources: [SearchSource], isCancelled: @escaping () -> Bool) -> () -> [SupplementaryHit]
    func prepareSearch(_ query: Query, options: SearchOptions, sources: [SearchSource], contentOnly: Bool, isCancelled: @escaping () -> Bool) -> () -> [SupplementaryHit]
    func preparePreview(source: SearchSource, entryID: UInt32) -> () -> ExtractedTextPreview?
    /// Explicit user action; may extract the selected local file without background indexing.
    func preparePreview(source: SearchSource, entryID: UInt32, isCancelled: @escaping () -> Bool) -> () -> TextPreviewOutcome
    func prepareDiagnosis(path: String, sources: [SearchSource]) -> () -> String
    func sourcesDidChange(_ sources: [SearchSource])
    func userActivity(visible: Bool, typing: Bool)
}
public extension SupplementarySearchProvider {
    func prepareSemantic(_ query: Query, options: SearchOptions, sources: [SearchSource], accepts: @escaping SupplementaryFileFilter, isCancelled: @escaping () -> Bool) -> (() -> [SupplementaryHit])? {
        prepareSemantic(query, options: options, sources: sources, isCancelled: isCancelled)
    }
    func prepareSimilarity(path: String, query: Query, options: SearchOptions, sources: [SearchSource], accepts: @escaping SupplementaryFileFilter, isCancelled: @escaping () -> Bool) -> () -> [SupplementaryHit] {
        prepareSimilarity(path: path, query: query, options: options, sources: sources, isCancelled: isCancelled)
    }
    var semanticStatus: SupplementarySearchStatus? { nil }
    func contentStatus(in folder: String?) -> SupplementarySearchStatus? { semanticStatus }
    var supportsSimilarity: Bool { false }
    func prepareSemantic(_ query: Query, options: SearchOptions, sources: [SearchSource], isCancelled: @escaping () -> Bool) -> (() -> [SupplementaryHit])? { nil }
    func prepareSimilarity(path: String, query: Query, options: SearchOptions, sources: [SearchSource], isCancelled: @escaping () -> Bool) -> () -> [SupplementaryHit] { { [] } }
    func prepareDiagnosis(path: String, sources: [SearchSource]) -> () -> String { { "" } }
    func prepareSearch(_ query: Query, options: SearchOptions, sources: [SearchSource], contentOnly: Bool, isCancelled: @escaping () -> Bool) -> () -> [SupplementaryHit] {
        prepareSearch(query, options: options, sources: sources, isCancelled: isCancelled)
    }
    func preparePreview(source: SearchSource, entryID: UInt32) -> () -> ExtractedTextPreview? { { nil } }
    func preparePreview(source: SearchSource, entryID: UInt32, isCancelled: @escaping () -> Bool) -> () -> TextPreviewOutcome {
        let cached = preparePreview(source: source, entryID: entryID)
        return {
            guard !isCancelled() else { return .cancelled }
            guard let value = cached(), !value.text.isEmpty else { return .unavailable(L10n.text("workspace.previewUnavailable")) }
            return .ready(value)
        }
    }
}
