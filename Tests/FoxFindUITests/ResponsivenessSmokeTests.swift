import AppKit
import QuartzCore
import XCTest
import FoxFindCore
@testable import FoxFindApp

/// A small, opt-in compositor check. No user files, models or thumbnail generation.
final class ResponsivenessSmokeTests: XCTestCase {
    func testBoundedListGridInteraction() throws {
        guard ProcessInfo.processInfo.environment["FOX_UI_SMOKE"] == "1" else { throw XCTSkip("Opt-in small UI check") }
        _ = NSApplication.shared
        let count = 512, names = [""] + (1..<512).map { "Demo document \($0).txt" }
        var b = ScanBuffer()
        b.ids = (0..<count).map(UInt32.init); b.parents = Array(repeating: 0, count: count)
        b.sizes = Array(repeating: 4096, count: count); b.mtimes = Array(repeating: 1_700_000_000, count: count)
        b.flags = [1] + Array(repeating: 0, count: count - 1)
        b.depths = [0] + Array(repeating: 1, count: count - 1)
        b.kinds = [1] + Array(repeating: 3, count: count - 1)
        b.nameLens = names.map { UInt32($0.utf8.count) }; b.nameBytes = Array(names.joined().utf8)
        let store = IndexStore(scan: ScanOutput(buffers: [b], count: count, homeIndex: .max, elapsed: 0, finishedAt: 0), config: IndexConfig(rootPath: "/FoxFindDemo"))
        let sources = [SearchSource(id: "demo", displayName: "Demo", isOnline: false, store: store)]
        let found = try XCTUnwrap(MultiSearcher.search(.parse("Demo"), options: .init(), in: sources))
        let surface = PanelSurface(snapshot: false)
        surface.frame = NSRect(x: 0, y: 0, width: 960, height: 650)
        let results = ResultsView(frame: NSRect(x: 16, y: 20, width: 928, height: 610))
        surface.addSubview(results)
        let window = NSWindow(contentRect: surface.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = surface
        window.isOpaque = false; window.backgroundColor = .clear
        window.title = "Fox Find small synthetic interaction check"
        defer { window.orderOut(nil); window.close() }
        window.orderFront(nil); results.show(SearchPresentation(found))
        surface.layoutSubtreeIfNeeded(); surface.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        var samples = [Double]()
        for i in 0..<12 {
            let start = CACurrentMediaTime()
            results.gridMode = i % 2 == 0
            results.restoreScroll(NSPoint(x: 0, y: CGFloat(i * 40)))
            surface.layoutSubtreeIfNeeded(); surface.displayIfNeeded(); CATransaction.flush()
            samples.append((CACurrentMediaTime() - start) * 1000)
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        }
        samples.sort()
        print("FOX_UI_SMOKE files=511 interactions=12 p95_ms=\(samples[11]) max_ms=\(samples.last!)")
        XCTAssertLessThan(samples.last!, 250, "Small native view changes must not block for a quarter second")
    }
}
