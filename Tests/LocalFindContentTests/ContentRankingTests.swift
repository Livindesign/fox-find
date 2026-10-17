import XCTest
@testable import LocalFindContent

final class ContentRankingTests: XCTestCase {
    private func database() throws -> ContentDatabase {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fox-ranking-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try ContentDatabase(url: root.appendingPathComponent("index.sqlite"))
    }
    private func put(_ db: ContentDatabase, _ path: String, _ text: String, source: String = "demo") throws {
        try db.put(.init(source: source, path: path, fingerprint: "fixture", text: text, category: "document", note: "", mtime: 1, size: UInt64(text.utf8.count)))
    }
    func testRelevantPassageBeforeLongIncidentalMention() throws {
        let db = try database()
        // The incidental match deliberately comes first in storage order.
        for i in 0..<240 {
            try put(db, "/background-\(i).txt", String(repeating: "background materials and notes ", count: 40) + "产品拍摄布光")
        }
        try put(db, "/focused.txt", "产品拍摄布光：柔光箱放在主体侧后方，用白卡补光。")
        var elapsed = [Double](), first = ""
        for _ in 0..<21 {
            let start = DispatchTime.now().uptimeNanoseconds
            let results = try db.candidates(needles: ["产品拍摄布光"], sources: ["demo"], cancelled: { false })
            elapsed.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            first = results.first?.path ?? ""
            XCTAssertEqual(results.count, 241)
        }
        elapsed.removeFirst(); elapsed.sort()
        print("FOX_CONTENT_RANK rows=241 query_p95_ms=\(elapsed[18]) top=\(first)")
        XCTAssertEqual(first, "/focused.txt")
    }
    func testLiteralOperatorsShortChineseAndSourceScope() throws {
        let db = try database()
        try put(db, "/one.txt", "水晶 蓝色 100%_literal a\"b AND OR café abc-def 👨‍👩‍👧")
        try put(db, "/two.txt", "水晶摄影 quartz")
        try put(db, "/excluded.txt", "water 100%_literal", source: "excluded")
        for term in ["100%_literal", "a\"b", "AND", "OR", "cafe", "abc-def", "蓝色", "👨‍👩‍👧"] {
            XCTAssertEqual(try db.candidates(needles: [term], sources: ["demo"], cancelled: { false }).map(\.path), ["/one.txt"], term)
        }
        XCTAssertEqual(Set(try db.candidates(needles: ["水晶", "quartz"], sources: ["demo"], cancelled: { false }).map(\.path)), ["/one.txt", "/two.txt"])
        XCTAssertTrue(try db.candidates(needles: ["water"], sources: ["demo"], cancelled: { false }).isEmpty)
        XCTAssertTrue(try db.candidates(needles: ["water"], sources: ["excluded"], cancelled: { true }).isEmpty)
    }
    func testStopAfterFirstCandidateAndRewrittenContent() throws {
        let db = try database()
        try put(db, "/one.txt", "product lighting")
        try put(db, "/two.txt", "product lighting notes")
        var visited = 0
        try db.visitCandidates(needles: ["lighting"], sources: ["demo"], cancelled: { false }) { _ in visited += 1; return false }
        XCTAssertEqual(visited, 1)
        try put(db, "/one.txt", "new words")
        XCTAssertEqual(try db.candidates(needles: ["lighting"], sources: ["demo"], cancelled: { false }).map(\.path), ["/two.txt"])
        try db.remove(source: "demo", paths: ["/two.txt"])
        XCTAssertTrue(try db.candidates(needles: ["lighting"], sources: ["demo"], cancelled: { false }).isEmpty)
    }
    func testSnippetBoundsLargeDocumentAndKeepsUnicodeHighlight() {
        let text = String(repeating: "background\n\n", count: 90_000) + "蓝色水晶光线 👨‍👩‍👧 end"
        let start = DispatchTime.now().uptimeNanoseconds
        let snippet = ContentSearch.snippet(text, needles: ["蓝色水晶光线"])
        print("FOX_CONTENT_SNIPPET bytes=\(text.utf8.count) elapsed_ms=\(Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000)")
        XCTAssertLessThan(snippet.text.utf16.count, 240)
        XCTAssertTrue(snippet.text.contains("蓝色水晶光线"))
        XCTAssertEqual(snippet.highlights.count, 1)
        XCTAssertEqual((snippet.text as NSString).substring(with: snippet.highlights[0]), "蓝色水晶光线")
    }
}
