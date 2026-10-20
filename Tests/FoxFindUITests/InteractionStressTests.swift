import AppKit
import Quartz
import QuartzCore
import ImageIO
import UniformTypeIdentifiers
import Darwin
import XCTest
import FoxFindCore
@testable import FoxFindApp

/// Native controls and real synthetic images; never posts system keyboard events.
final class InteractionStressTests: XCTestCase {
    private func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
    private func wait(_ condition: () -> Bool, timeout: Double = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        return condition()
    }
    private func key(_ code: UInt16, text: String = "", flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                        context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }
    func testSearchPreviewViewSwitchAndClearStress() throws {
        guard ProcessInfo.processInfo.environment["FOX_INTERACTION_STRESS"] == "1" else { throw XCTSkip("Opt-in native interaction workload") }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FoxInteractionFixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<12 {
            try autoreleasepool {
                let context = try XCTUnwrap(CGContext(data: nil, width: 4032, height: 3024, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
                context.setFillColor(NSColor(srgbRed: 0.2 + Double(i) / 20, green: 0.35, blue: 0.8, alpha: 1).cgColor)
                context.fill(CGRect(x: 0, y: 0, width: 4032, height: 3024))
                context.setFillColor(NSColor.white.cgColor); context.fillEllipse(in: CGRect(x: 1000, y: 800, width: 1600, height: 1600))
                let url = root.appendingPathComponent(String(format: "Photo-%02d.jpg", i))
                let output = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(output, try XCTUnwrap(context.makeImage()), nil)
                XCTAssertTrue(CGImageDestinationFinalize(output))
            }
        }
        let config = IndexConfig(rootPath: root.path)
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        let suite = "FoxInteractionStress-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let panel = SearchPanel(snapshot: true, preferences: defaults), c = panel.searchController
        c.additionalSources = { [SearchSource(id: "fixture", displayName: "Demo", isOnline: true, store: store)] }
        defer {
            c.quickLook.close(); c.inlinePreview.clear(); QLPreviewPanel.shared().close(); panel.close()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        panel.makeKeyAndOrderFront(nil)
        c.searchField.text = "Photo"; c.startSearch()
        XCTAssertTrue(wait { c.results.result?.count == 12 })
        XCTAssertTrue(c.handleKey(key(125)))
        let previewStart = CACurrentMediaTime()
        XCTAssertTrue(c.handleKey(key(49, text: " ")))
        XCTAssertTrue(wait { c.quickLook.isVisible })
        print("FOX_INTERACTION preview_window_open_ms=\((CACurrentMediaTime() - previewStart) * 1000)")
        let reloads = c.quickLook.reloadCount
        for _ in 0..<50 { c.quickLook.refresh() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        XCTAssertEqual(c.quickLook.reloadCount, reloads, "Unchanged content refresh must not restart Quick Look")
        for row in 2...10 { c.results.select(row) }
        XCTAssertTrue(wait { c.quickLook.displayedURL?.path == c.results.selectedItem?.path })
        XCTAssertEqual(c.quickLook.reloadCount, reloads + 1, "Rapid selections should load only the final image")
        // A changed file at the same path still needs fresh preview content.
        let previousRevision = c.quickLook.selectedRevision
        c.quickLook.selectedRevision = { QuickLook.Revision(size: 999, modified: Date(timeIntervalSince1970: 1)) }
        c.quickLook.refresh()
        XCTAssertTrue(wait { c.quickLook.reloadCount == reloads + 2 })
        c.quickLook.selectedRevision = previousRevision
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        if let directory = ProcessInfo.processInfo.environment["FOX_INTERACTION_CAPTURE"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(QLPreviewPanel.shared().windowNumber), directory + "/quick-look.png"]
            try capture.run(); capture.waitUntilExit()
            XCTAssertEqual(capture.terminationStatus, 0)
        }
        c.quickLook.close()
        c.setGridMode(false); c.view.needsLayout = true; c.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(c.inlinePreview.isHidden); XCTAssertNil(c.inlinePreview.loadedImagePath)
        var switches: [Double] = [], searches: [Double] = [], layouts: [Double] = []
        var warmFootprint: UInt64 = 0, peakFootprint: UInt64 = 0
        let cycles = max(40, Int(ProcessInfo.processInfo.environment["FOX_INTERACTION_CYCLES"] ?? "40") ?? 40)
        for i in 0..<cycles {
            autoreleasepool {
                var start = CACurrentMediaTime()
                c.setGridMode(i % 2 == 0)
                let modeEnd = CACurrentMediaTime()
                c.view.layoutSubtreeIfNeeded()
                let layoutEnd = CACurrentMediaTime()
                c.view.displayIfNeeded()
                let displayEnd = CACurrentMediaTime()
                CATransaction.flush()
                let switchTime = (CACurrentMediaTime() - start) * 1000
                switches.append(switchTime)
                if switchTime > 100 {
                    print("FOX_SWITCH_PHASE cycle=\(i) grid=\(i % 2 == 0) mode_ms=\((modeEnd - start) * 1000) layout_ms=\((layoutEnd - modeEnd) * 1000) display_ms=\((displayEnd - layoutEnd) * 1000) commit_ms=\(switchTime - (displayEnd - start) * 1000)")
                }
                start = CACurrentMediaTime()
                for _ in 0..<5 { c.view.needsLayout = true; c.view.layoutSubtreeIfNeeded() }
                layouts.append((CACurrentMediaTime() - start) * 1000)
                c.searchField.text = i % 2 == 0 ? "Photo-0" : "Photo"; start = CACurrentMediaTime(); c.startSearch()
                let expected = i % 2 == 0 ? 10 : 12
                XCTAssertTrue(wait { c.results.result?.query.raw == c.searchField.text && c.results.result?.count == expected })
                searches.append((CACurrentMediaTime() - start) * 1000)
                c.searchField.clear.performClick(nil)
                XCTAssertNil(c.results.result); XCTAssertNil(c.results.selectedItem)
                c.searchField.text = "Photo"; c.startSearch()
                XCTAssertTrue(wait { c.results.result?.count == 12 })
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            if i == 19 { warmFootprint = footprint(); peakFootprint = warmFootprint }
            if i >= 20 { peakFootprint = max(peakFootprint, footprint()) }
        }
        switches.sort(); searches.sort(); layouts.sort()
        let percentile = min(cycles - 1, Int(Double(cycles) * 0.95))
        print("FOX_INTERACTION cycles=\(cycles) switch_p95_ms=\(switches[percentile]) switch_max_ms=\(switches.last!) search_ready_p95_ms=\(searches[percentile]) layout5_p95_ms=\(layouts[percentile])")
        let growth = Double(peakFootprint - min(peakFootprint, warmFootprint)) / 1048576
        print("FOX_INTERACTION memory_warm_mb=\(Double(warmFootprint) / 1048576) memory_peak_mb=\(Double(peakFootprint) / 1048576) memory_growth_mb=\(growth)")
        XCTAssertLessThan(growth, 128, "Repeated view and preview changes must have bounded warm memory")
        XCTAssertLessThan(switches.last!, 250, "View changes must not block for a quarter second")
        XCTAssertLessThan(searches[percentile], 500, "Warm local search should not block behind previews")
    }
}
