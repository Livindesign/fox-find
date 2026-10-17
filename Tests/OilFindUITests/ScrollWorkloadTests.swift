import AppKit
import QuartzCore
import XCTest
import OilFindCore
@testable import OilFindApp

/// Opt-in, isolated workload: no user files, preferences, or posted input events.
final class ScrollWorkloadTests: XCTestCase {
    func testLargeResultScrollWorkload() throws {
        guard ProcessInfo.processInfo.environment["FOX_SCROLL_WORKLOAD"] == "1" else { throw XCTSkip("Opt-in large scroll workload") }
        _ = NSApplication.shared
        print("FOX_RESPONSIVE_SCROLLING \(ResultScrollView.isCompatibleWithResponsiveScrolling)")
        var buffer = ScanBuffer()
        let count = 300_000
        buffer.ids = (0..<count).map(UInt32.init); buffer.parents = Array(repeating: 0, count: count)
        buffer.sizes = Array(repeating: 1024, count: count); buffer.mtimes = Array(repeating: 1_700_000_000, count: count)
        buffer.flags = Array(repeating: 0, count: count); buffer.depths = Array(repeating: 1, count: count)
        buffer.kinds = Array(repeating: 3, count: count); buffer.flags[0] = 1; buffer.kinds[0] = 1
        for i in 0..<count {
            let name = i == 0 ? "" : i <= 1500 ? "Fixture Application \(i).app" : "Fixture Document \(i).txt"
            buffer.nameLens.append(UInt32(name.utf8.count)); buffer.nameBytes.append(contentsOf: name.utf8)
            if i > 0 && i <= 1500 { buffer.flags[i] = 3; buffer.kinds[i] = 2 }
        }
        let store = IndexStore(scan: ScanOutput(buffers: [buffer], count: count, homeIndex: .max, elapsed: 0, finishedAt: 0), config: IndexConfig(rootPath: "/FoxFindSyntheticScrollFixture"))
        for apps in [false, true] {
          let result = try XCTUnwrap(Searcher.search(.parse("Fixture"), options: .init(kind: apps ? 2 : nil), in: store))
          for grid in [false, true] {
            let surface = PanelSurface(snapshot: false)
            surface.frame = NSRect(x: 0, y: 0, width: 960, height: 650)
            let view = ResultsView(frame: NSRect(x: 16, y: 70, width: 928, height: 510))
            surface.addSubview(view)
            let window = NSWindow(contentRect: surface.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.isOpaque = false; window.backgroundColor = .clear
            window.contentView = surface; window.title = "Fox Find synthetic scrolling verification"
            window.setFrameOrigin(NSPoint(x: 60, y: 80)); window.orderFront(nil)
            let start = CACurrentMediaTime()
            view.gridMode = grid; view.show(result); surface.layoutSubtreeIfNeeded(); surface.displayIfNeeded()
            let initial = (CACurrentMediaTime() - start) * 1000
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let scroll = try XCTUnwrap((grid ? view.grid : view).subviews.compactMap { $0 as? ResultScrollView }.first)
            var work: [Double] = [], intervals: [Double] = [], previous = CACurrentMediaTime()
            for step in 0..<180 {
                let now = CACurrentMediaTime(); if step > 0 { intervals.append((now - previous) * 1000) }; previous = now
                // Deliver only to this fixture's scroll view, never the system event queue.
                let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0))
                scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: cg)))
                view.restoreScroll(NSPoint(x: 0, y: CGFloat(step) * 56))
                surface.layoutSubtreeIfNeeded(); surface.displayIfNeeded(); CATransaction.flush()
                work.append((CACurrentMediaTime() - now) * 1000)
                RunLoop.main.run(until: Date().addingTimeInterval(max(0.001, 1.0 / 120 - (CACurrentMediaTime() - now))))
            }
            work.sort(); intervals.sort()
            let label = (apps ? "apps" : "all") + (grid ? "_grid" : "_list")
            print("FOX_SCROLL_WORKLOAD \(label) count=\(result.items.count) initial_ms=\(initial) work_p95_ms=\(work[171]) work_max_ms=\(work.last!) interval_p95_ms=\(intervals[170]) stalls_25ms=\(intervals.filter { $0 > 25 }.count)")
            window.orderOut(nil); window.close()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
          }
        }
    }
}
