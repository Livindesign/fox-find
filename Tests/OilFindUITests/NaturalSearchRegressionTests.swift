import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import OilFindApp
@testable import OilFindCore

private final class NaturalProbe: SupplementarySearchProvider {
    var isEnabled = true
    var semanticQueries = [String](), contentQueries = [String]()
    func sourcesDidChange(_ sources: [SearchSource]) {}
    func userActivity(visible: Bool, typing: Bool) {}
    func prepareSearch(_ query: Query, options: SearchOptions, sources: [SearchSource], isCancelled: @escaping () -> Bool) -> () -> [SupplementaryHit] {
        contentQueries.append(query.raw); return { [] }
    }
    func prepareSemantic(_ query: Query, options: SearchOptions, sources: [SearchSource], isCancelled: @escaping () -> Bool) -> (() -> [SupplementaryHit])? {
        semanticQueries.append(query.raw); return { [] }
    }
}

final class NaturalSearchRegressionTests: XCTestCase {
    private let zone = TimeZone(secondsFromGMT: 8 * 3600)!
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private var now: Date { date("2026-10-17T12:00:00+08:00") }
    private func plan(_ text: String) -> NaturalSearchPlan? { NaturalSearch.parse(text, home: "/fixture", now: now, timeZone: zone) }

    func testMonthAndDayPhrasesResolveToExactCalendarBoundaries() throws {
        for text in ["7月拍摄的照片", "七月拍的相片", "7月份拍摄图片", "拍摄于7月的照片", "搜索7月拍摄的照片", "帮我找7月拍的照片"] {
            let p = try XCTUnwrap(plan(text), text)
            XCTAssertEqual(p.refinement.captureMonth, 7); XCTAssertNil(p.refinement.captured)
            XCTAssertEqual(p.query, "kind:image"); XCTAssertTrue(p.filtersOnly)
        }
        for text in ["今年7月拍摄的图片", "2026年7月拍下的照片"] {
            let p = try XCTUnwrap(plan(text), text)
            XCTAssertEqual(p.query, "kind:image", text); XCTAssertTrue(p.filtersOnly, text)
            XCTAssertEqual(p.refinement.captured, DateInterval(start: date("2026-07-01T00:00:00+08:00"), end: date("2026-08-01T00:00:00+08:00")), text)
        }
        let lastYear = try XCTUnwrap(plan("去年七月拍摄的照片"))
        XCTAssertEqual(lastYear.refinement.captured?.start, date("2025-07-01T00:00:00+08:00"))
        XCTAssertEqual(plan("2024年2月29日拍摄的照片")?.refinement.captured, DateInterval(start: date("2024-02-29T00:00:00+08:00"), end: date("2024-03-01T00:00:00+08:00")))
        XCTAssertEqual(plan("下载文件夹7月拍摄的红色照片")?.folder, "/fixture/Downloads")
        XCTAssertEqual(plan("下载目录7月拍摄的红色照片")?.query, "红色 kind:image")
        XCTAssertEqual(plan("下载目录7月拍摄的红色照片")?.filtersOnly, false)
        let january = NaturalSearch.parse("12月拍摄的照片", now: date("2026-01-05T00:00:00+08:00"), timeZone: zone)
        XCTAssertNil(january?.refinement.captured); XCTAssertEqual(january?.refinement.captureMonth, 12)
    }
    func testRelativeCalendarPeriodsAndTimeZones() throws {
        let expected = [
            ("上个月拍摄的照片", "2026-09-01T00:00:00+08:00", "2026-10-01T00:00:00+08:00"),
            ("本月拍摄的图片", "2026-10-01T00:00:00+08:00", "2026-11-01T00:00:00+08:00"),
            ("今年拍摄的照片", "2026-01-01T00:00:00+08:00", "2027-01-01T00:00:00+08:00"),
            ("去年拍的照片", "2025-01-01T00:00:00+08:00", "2026-01-01T00:00:00+08:00"),
            ("前天拍摄的图片", "2026-10-15T00:00:00+08:00", "2026-10-16T00:00:00+08:00"),
            ("上周拍摄的照片", "2026-10-05T00:00:00+08:00", "2026-10-12T00:00:00+08:00"),
            ("近2周拍摄的照片", "2026-10-03T12:00:00+08:00", "2026-10-17T12:00:00+08:00"),
            ("最近3个月拍的照片", "2026-07-17T12:00:00+08:00", "2026-10-17T12:00:00+08:00")
        ]
        for (query, start, end) in expected {
            XCTAssertEqual(try XCTUnwrap(plan(query), query).refinement.captured, DateInterval(start: date(start), end: date(end)), query)
        }
        let la = TimeZone(identifier: "America/Los_Angeles")!
        let dst = try XCTUnwrap(NaturalSearch.parse("2026年3月8日拍摄的照片", now: now, timeZone: la)?.refinement.captured)
        XCTAssertEqual(dst.duration, 23 * 3600)
    }
    func testTypeIsIndependentAndLiteralNamesStayLiteral() throws {
        for (query, expected) in [("红色的照片", "红色 kind:image"), ("蓝天和山丘的图片", "蓝天和山丘 kind:image"), ("水晶相片", "水晶 kind:image"), ("合同PDF", "合同 ext:pdf"), ("照片", "kind:image")] {
            XCTAssertEqual(plan(query)?.query, expected, query)
        }
        for query in ["report.pdf", "今天的报告.pdf", "拍摄计划.docx", "photo.jpg", "kind:image", "\"红色照片\"", "invoice123"] { XCTAssertNil(plan(query), query) }
        for query in ["13月拍摄的照片", "0月拍摄的照片", "2026年2月30日拍摄的图片", "最近0天拍摄的图片", "最近9999天拍摄的图片", "7月至8月拍摄的照片", "7月1日和8月2日拍摄的照片", "不是7月拍摄的照片", "不要红色的照片", "昨天下载的PDF", "7月的照片", "不超过10MB的图片", "不超过1.5MB的照片", "不大于10MB的照片"] {
            XCTAssertNil(plan(query), query)
            XCTAssertNotNil(NaturalSearch.unresolvedConstraint(query), query)
        }
    }
    func testRealEXIFSearchNeverReturnsDocumentsWrongMonthsOrUnknownDates() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoxNatural-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        // Misleading filenames/mtime must not replace DateTimeOriginal.
        for (name, capture) in [("photo-A.jpg", "\(year):07:15 12:00:00"), ("7月拍摄.jpg", "\(year):08:01 00:00:00"), ("unknown.jpg", ""), ("prior-year.jpg", "\(year-1):07:15 12:00:00")] {
            let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            let url = root.appendingPathComponent(name)
            let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
            let exif: [CFString: Any] = capture.isEmpty ? [:] : [kCGImagePropertyExifDateTimeOriginal: capture, kCGImagePropertyExifOffsetTimeOriginal: "+08:00"]
            CGImageDestinationAddImage(dest, try XCTUnwrap(context.makeImage()), [kCGImagePropertyExifDictionary: exif] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
        }
        try "7月拍摄的照片 红色".write(to: root.appendingPathComponent("directions.json"), atomically: true, encoding: .utf8)
        let config = IndexConfig(rootPath: root.path)
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        store.write { store.buildHash() }
        let suite = "FoxNatural-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let c = SearchViewController(snapshot: true, preferences: defaults), provider = NaturalProbe()
        _ = c.view
        c.additionalSources = { [SearchSource(id: "fixture", displayName: "Fixture", isOnline: true, store: store)] }
        c.supplementaryProvider = provider
        func finish() {
            let end = Date().addingTimeInterval(4)
            while c.searchInFlight && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
            XCTAssertFalse(c.searchInFlight)
        }
        for mode in [SearchMode.combined, .contents, .names] {
            c.toolsBar.mode = mode; c.searchField.text = "7月拍摄的照片"; c.startSearch(); finish()
            XCTAssertEqual(c.results.result?.count, 2, "\(mode)")
            let result = try XCTUnwrap(c.results.result)
            XCTAssertEqual(Set((0..<result.count).compactMap { result.row($0).map { $0.source.store.name($0.id) } }), ["photo-A.jpg", "prior-year.jpg"])
            XCTAssertEqual(c.results.result?.refinementUnknown, 1)
            XCTAssertTrue(c.contextBar.conditions.contains { $0.id == "captured" && ($0.title.contains("所有年份") || $0.title.contains("All years")) })
            XCTAssertTrue(provider.semanticQueries.isEmpty); XCTAssertTrue(provider.contentQueries.isEmpty)
        }
        c.searchField.text = "\(year)年7月拍摄的照片"; c.startSearch(); finish()
        XCTAssertEqual(c.results.result?.count, 1); XCTAssertEqual(c.results.selectedItem?.name, "photo-A.jpg")
        c.searchField.text = "7月拍摄的照片"; c.startSearch(); finish()
        c.removeSearchCondition("captured"); finish()
        XCTAssertNil(c.toolsBar.refinement.captureMonth); XCTAssertFalse(c.contextBar.conditions.contains { $0.id == "captured" })
        XCTAssertEqual(c.results.result?.count, 4)
        c.searchField.text = ""; c.startSearch()
        c.toolsBar.mode = .combined; c.searchField.text = "7月拍摄的红色照片"; c.startSearch(); finish()
        XCTAssertEqual(provider.semanticQueries, ["红色 kind:image"])
        c.searchField.text = "13月拍摄的照片"; c.startSearch(); finish()
        XCTAssertEqual(provider.semanticQueries.count, 1, "Unparsed constraints must never launch approximate search")
        XCTAssertTrue(c.footer.warning)
        c.searchField.text = ""; c.startSearch(); XCTAssertNil(c.results.result)
    }
    func testParsingBudget() {
        let samples = ["7月拍摄的照片", "下载文件夹最近7天拍摄的红色照片", "上个月拍摄的图片", "蓝天白云的图片", "13月拍摄的照片"]
        for input in samples { _ = plan(input) }
        var times = [Double]()
        for _ in 0..<100 {
            for input in samples {
                let start = Date(); _ = plan(input); times.append(Date().timeIntervalSince(start) * 1000)
            }
        }
        times.sort(); print("NATURAL_PARSE count=\(times.count) p95_ms=\(times[Int(Double(times.count) * 0.95)]) max_ms=\(times.last!)")
        XCTAssertLessThan(times[Int(Double(times.count) * 0.95)], 10)
    }
}
