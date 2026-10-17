import AppKit
import XCTest
import OilFindCore
@testable import OilFindApp

final class SearchPerformanceTests: XCTestCase {
    func testExistingIndexRenderingBudget() throws {
        guard let path = ProcessInfo.processInfo.environment["FOXFIND_PERF_DB"] else { throw XCTSkip("Opt-in read-only existing-index check") }
        _ = NSApplication.shared
        let store = try XCTUnwrap(IndexStore.load(from: path))
        var metrics: [String: Double] = ["index_entries": Double(store.count)]
        var presented: SearchPresentation?
        for query in ["ext:jpg", "ext:pdf", "ext:txt", "ext:png"] {
            let start = CFAbsoluteTimeGetCurrent()
            let result = try XCTUnwrap(Searcher.search(.parse(query), options: .init(sort: .name, ascending: true), in: store))
            metrics[query + "_search_ms"] = (CFAbsoluteTimeGetCurrent() - start) * 1000
            metrics[query + "_matches"] = Double(result.total)
            if presented == nil { presented = SearchPresentation(result) }
        }
        let view = ResultsView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.close() }
        for grid in [false, true] {
            view.gridMode = grid; view.show(try XCTUnwrap(presented)); view.layoutSubtreeIfNeeded()
            let container: NSView = grid ? view.grid : view
            let scroll = try XCTUnwrap(container.subviews.compactMap { $0 as? NSScrollView }.first)
            var samples: [Double] = []
            for step in 0..<100 {
                let start = CFAbsoluteTimeGetCurrent()
                scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(step % 40) * 100))
                scroll.reflectScrolledClipView(scroll.contentView)
                view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
                samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            }
            samples.sort(); metrics[(grid ? "grid" : "list") + "_scroll_p95_ms"] = samples[95]
            XCTAssertLessThan(samples[95], 16.7, "AppKit update exceeds 60 Hz frame budget")
        }
        let data = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
        print("FOX_LARGE_INDEX_PERF " + String(decoding: data, as: UTF8.self))
    }
    func testRepeatableRenderingBenchmark() throws {
        guard ProcessInfo.processInfo.environment["FOXFIND_PERF"] == "1" else { throw XCTSkip("Opt-in rendering benchmark") }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoxPerf-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<1000 { try Data("Search performance fixture".utf8).write(to: root.appendingPathComponent(String(format: "result%04d.txt", i))) }
        let config = IndexConfig(rootPath: root.path)
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        let found = SearchPresentation(try XCTUnwrap(Searcher.search(.parse("result"), options: .init(sort: .name, ascending: true), in: store)))
        let view = ResultsView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.close() }
        var metrics: [String: Double] = [:]
        let now = Date(), calendar = Calendar(identifier: .gregorian)
        var start = CFAbsoluteTimeGetCurrent()
        for i in 0..<2000 { _ = Presentation.dateText(now.addingTimeInterval(-Double(i) * 86400), now: now, calendar: calendar, chinese: true) }
        metrics["date_2000_ms"] = (CFAbsoluteTimeGetCurrent() - start) * 1000
        for gridMode in [false, true] {
            view.gridMode = gridMode; view.show(found); view.layoutSubtreeIfNeeded()
            let container: NSView = gridMode ? view.grid : view
            let scroll = try XCTUnwrap(container.subviews.compactMap { $0 as? NSScrollView }.first)
            var samples: [Double] = []
            for i in 0..<100 {
                start = CFAbsoluteTimeGetCurrent()
                scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(i % 40) * 100))
                scroll.reflectScrolledClipView(scroll.contentView)
                view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
                samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                RunLoop.current.run(until: Date().addingTimeInterval(0.001))
            }
            samples.sort()
            let prefix = gridMode ? "grid" : "list"
            var refreshed: [Double] = []
            for i in 0..<100 {
                start = CFAbsoluteTimeGetCurrent()
                scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(i % 40) * 100))
                scroll.reflectScrolledClipView(scroll.contentView)
                view.refresh(found)
                view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
                refreshed.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                RunLoop.current.run(until: Date().addingTimeInterval(0.001))
            }
            refreshed.sort()
            metrics[prefix + "_scroll_with_refresh_p95_ms"] = refreshed[95]
            metrics[prefix + "_scroll_p50_ms"] = samples[50]
            metrics[prefix + "_scroll_p95_ms"] = samples[95]
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            start = CFAbsoluteTimeGetCurrent()
            for _ in 0..<100 { view.refresh(found); view.layoutSubtreeIfNeeded() }
            metrics[prefix + "_unchanged_refresh_100_ms"] = (CFAbsoluteTimeGetCurrent() - start) * 1000
        }
        let data = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
        print("FOX_PERF " + String(decoding: data, as: UTF8.self))
    }
}
