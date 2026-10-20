import AppKit
import XCTest
@testable import FoxFindApp
@testable import FoxFindCore

final class NaturalCombinationTests: XCTestCase {
    private let zone = TimeZone(identifier: "Asia/Shanghai")!
    private let now = ISO8601DateFormatter().date(from: "2026-10-17T12:00:00+08:00")!
    private func plan(_ input: String) throws -> NaturalSearchPlan {
        try XCTUnwrap(NaturalSearch.parse(input, home: "/demo", now: now, timeZone: zone), input)
    }
    func testInclusiveSizesRangesTypesAndDescription() throws {
        let values = [("不超过10MB的图片", "size:<=10mb"), ("不少于1.5GB的视频", "size:>=1.5gb"), ("小于1TB的压缩包", "size:<1tb"), ("1到10MB的PDF", "size:1mb..10mb"), ("500KB到2MB的文档", "size:500kb..2mb"), ("图片大小等于0B", "size:0b")]
        for (input, token) in values {
            let p = try plan(input)
            XCTAssertTrue(p.conditions.contains { $0.token == token }, p.query)
            XCTAssertTrue(p.filtersOnly, p.query); XCTAssertNil(p.warning, input)
            XCTAssertTrue(Query.parse(p.query).diagnostics.isEmpty)
        }
        for input in ["图片不超过1.5MB", "不超过1.5MB的图片", "图片1.5MB以内", "1.5MB以下的图片"] {
            let p = try plan(input)
            XCTAssertTrue(p.conditions.contains { $0.token == "size:<=1.5mb" }, input)
            XCTAssertTrue(p.filtersOnly, p.query); XCTAssertNil(p.warning, input)
        }
        XCTAssertEqual(try plan("视频1.5GB以上").query, "size:>=1.5gb kind:video")
        for input in ["图片或视频", "图片和视频", "图片、视频", "图片或者视频"] {
            let p = try plan(input)
            XCTAssertEqual(p.query, "kind:image|kind:video"); XCTAssertTrue(p.filtersOnly)
        }
        XCTAssertEqual(try plan("电子表格").query, "ext:xls;xlsx;csv;numbers;ods")
        XCTAssertEqual(try plan("大于10MB的PDF，不要合同").query, "!合同 size:>10mb ext:pdf")
        XCTAssertEqual(try plan("不要红色的照片").query, "!红色 kind:image")
        XCTAssertEqual(try plan("不要图片或视频").query, "!kind:image !kind:video")
        XCTAssertEqual(try plan("应用设计文档").query, "应用设计 kind:doc")
        XCTAssertEqual(try plan("图片处理应用").query, "图片处理 kind:app")
        XCTAssertNil(NaturalSearch.unresolvedConstraint("水晶拍摄如何布光"))
        XCTAssertNotNil(try plan("8月之前的图片").warning)
        XCTAssertNotNil(try plan("10到1MB图片").warning)
        let description = try plan("在下载目录里，7月白色背景的微信图片，不超过2MB")
        XCTAssertEqual(description.folder, "/demo/Downloads")
        XCTAssertTrue(description.query.contains("白色背景")); XCTAssertTrue(description.query.contains("dm:month7"))
        XCTAssertFalse(description.filtersOnly); XCTAssertNil(description.warning)
        XCTAssertEqual(try plan("横向的图片").refinement.media, .landscape)
        XCTAssertEqual(try plan("标签为作品的图片").refinement.tag, "作品")
    }
    func testDateRangesUnionsAndUnresolvedConditionsKeepKnownType() throws {
        for input in ["7月至8月图片", "七月到八月的照片", "7月和8月的图片"] {
            let p = try plan(input)
            XCTAssertTrue(p.query.contains("dm:month7|dm:month8"), p.query)
            XCTAssertTrue(p.filtersOnly); XCTAssertNil(p.warning)
        }
        XCTAssertEqual(try plan("11月至2月图片").query, "dm:month11|dm:month12|dm:month1|dm:month2 kind:image")
        XCTAssertEqual(try plan("2025年12月至2026年2月图片").query, "dm:2025-12-01..2026-02-28 kind:image")
        XCTAssertEqual(try plan("2024年2月至3月图片").query, "dm:2024-02-01..2024-03-31 kind:image")
        for input in ["昨天下载的图片", "8月保存的图片", "13月图片", "2026年2月30日图片", "7月至8月拍摄的图片", "7月1日和8月2日拍摄的照片"] {
            let p = try plan(input)
            XCTAssertTrue(p.query.contains("kind:image"), input)
            XCTAssertNotNil(p.warning, input)
            XCTAssertFalse(p.refinement.hasCaptureFilter, input)
            XCTAssertFalse(p.query.contains("dm:"), input)
        }
        for input in ["report.pdf", "八月图片.jpg", "\"八月的图片\"", "/demo/不要合同.pdf", "kind:image !ext:jpg", "P202601092289", "八月图片*", "图片|视频", "!图片"] {
            XCTAssertNil(NaturalSearch.parse(input), input)
        }
    }
    func testActualIndexedResultsForCombinedConditionsAndUIChips() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoxCombination-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rows = [("WeChat Images/山海.jpg", 1000, "2024-07-12"), ("WeChat Images/海边.png", 3000, "2026-08-12"), ("WeChat Images/红色海边.jpg", 1000, "2026-07-12"), ("WeChat Images/海边.mp4", 1000, "2026-07-12"), ("Camera/海边.jpg", 1000, "2026-07-12"), ("WeChat Images/合同.pdf", 1000, "2026-07-12"), ("WeChat Images/报告.pdf", 1500, "2026-07-12"), ("Notes/search-intent.md", 1000, "2026-07-12")]
        for (name, size, day) in rows {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 32, count: size).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: ISO8601DateFormatter().date(from: day + "T12:00:00+08:00")!], ofItemAtPath: url.path)
        }
        let config = IndexConfig(rootPath: root.path)
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        store.write { store.buildHash() }
        let suite = "FoxCombination-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let c = SearchViewController(snapshot: true, preferences: defaults)
        _ = c.view; c.view.frame = NSRect(x: 0, y: 0, width: 960, height: 650)
        c.additionalSources = { [SearchSource(id: "fixture", displayName: "Demo", isOnline: true, store: store)] }
        func finish() {
            let end = Date().addingTimeInterval(3)
            while c.searchInFlight && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
            XCTAssertFalse(c.searchInFlight)
        }
        func paths() -> Set<String> {
            Set((0..<(c.results.result?.count ?? 0)).compactMap { c.results.item(at: $0)?.path.replacingOccurrences(of: root.path + "/", with: "") })
        }
        let cases: [(String, Set<String>)] = [
            ("7月微信图片", ["WeChat Images/山海.jpg", "WeChat Images/红色海边.jpg"]),
            ("7月微信图片，不要红色", ["WeChat Images/山海.jpg"]),
            ("7月微信图片或视频，不超过2KB", ["WeChat Images/山海.jpg", "WeChat Images/红色海边.jpg", "WeChat Images/海边.mp4"]),
            ("八月微信图片", ["WeChat Images/海边.png"]),
            ("图片大小1到2KB", ["WeChat Images/山海.jpg", "WeChat Images/红色海边.jpg", "Camera/海边.jpg"]),
            ("PDF不要合同", ["WeChat Images/报告.pdf"]),
            ("图片，不要微信", ["Camera/海边.jpg"]),
            ("2026年7月微信图片", ["WeChat Images/红色海边.jpg"])
        ]
        var timings: [Double] = []
        for mode in [SearchMode.combined, .contents, .names] {
            c.toolsBar.mode = mode
            for (input, expected) in cases {
                let start = Date(); c.searchField.text = input; c.searchField.onChange?(); finish()
                timings.append(Date().timeIntervalSince(start) * 1000)
                XCTAssertEqual(paths(), expected, "\(mode) \(input) \(c.naturalPlan?.query ?? "nil")")
                XCTAssertFalse(c.footer.warning, c.footer.text)
                XCTAssertNil(c.results.result?.refinementChecked)
            }
        }
        timings.sort(); print("NATURAL_COMBINATIONS count=\(timings.count) p95_ms=\(timings[Int(Double(timings.count)*0.95)]) max_ms=\(timings.last!)")
        c.searchField.text = "7月微信图片或视频，不超过2KB"; c.searchField.onChange?(); finish()
        XCTAssertTrue(c.contextBar.conditions.contains { $0.id == "token:kind:image|kind:video" })
        c.removeSearchCondition("token:" + NaturalQueryRules.wechat.joined(separator: "|")); finish()
        XCTAssertTrue(paths().contains("Camera/海边.jpg"))
        c.clearSearchConditions(); finish()
        XCTAssertTrue(paths().contains("Notes/search-intent.md"))
        c.searchField.text = "昨天下载的图片"; c.searchField.onChange?(); finish()
        XCTAssertTrue(c.footer.warning)
        c.materializeNaturalQuery(); finish(); XCTAssertTrue(c.footer.warning)
        c.searchField.text = "7月微信图片"; c.searchField.onChange?(); finish(); XCTAssertFalse(c.footer.warning)
        c.searchField.text = ""; c.searchField.onChange?()
    }
}
