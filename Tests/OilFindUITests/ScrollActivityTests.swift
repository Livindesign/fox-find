import AppKit
import XCTest
@testable import OilFindApp

final class ScrollActivityTests: XCTestCase {
    func testLongScrollKeepsBackgroundIdleForListAndGridWithoutPerFrameCallbacks() throws {
        _ = NSApplication.shared
        let results = ResultsView(frame: .zero)
        let list = try XCTUnwrap(results.subviews.compactMap { $0 as? NSScrollView }.first)
        var now: TimeInterval = 100
        var reports = [TimeInterval]()
        results.interactionClock = { now }
        results.onInteractionActivity = { reports.append(now) }
        for viewport in [list, results.grid.scroll] {
            reports.removeAll()
            let start = now
            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: viewport)
            // Simulate 20 seconds at 100 Hz with no sleeping, files, models or rendering.
            for step in 1...2_000 {
                now = start + Double(step) / 100
                NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: viewport)
                XCTAssertLessThan(now - (reports.last ?? 0), 1.01)
            }
            XCTAssertGreaterThanOrEqual(reports.count, 20)
            XCTAssertLessThanOrEqual(reports.count, 21)
            now += 0.25
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: viewport)
            XCTAssertEqual(reports.last, now, "The idle delay must start after the gesture ends")
            let count = reports.count
            now += 10
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: viewport)
            XCTAssertEqual(reports.count, count, "Programmatic layout must not keep indexing paused")
        }
    }

    func testLegacyWheelEventsAlsoRenewActivity() throws {
        _ = NSApplication.shared
        let results = ResultsView(frame: .zero)
        var now: TimeInterval = 100
        var reports = [TimeInterval]()
        results.interactionClock = { now }
        results.onInteractionActivity = { reports.append(now) }
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                        wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0))
        let wheel = try XCTUnwrap(NSEvent(cgEvent: event))
        for step in 0...1_000 {
            now = 100 + Double(step) / 100
            results.grid.scroll.onScrollWheel?(wheel)
            XCTAssertLessThan(now - (reports.last ?? 0), 1.01)
        }
        XCTAssertGreaterThanOrEqual(reports.count, 10)
        XCTAssertLessThanOrEqual(reports.count, 11)
    }
}
