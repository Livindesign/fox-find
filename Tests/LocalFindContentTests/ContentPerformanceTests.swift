import XCTest
import Darwin
import OilFindCore
@testable import LocalFindContent

final class ContentPerformanceTests: XCTestCase {
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
    private func source(count: Int) -> SearchSource {
        var buffer = ScanBuffer()
        buffer.ids = (0..<count).map(UInt32.init)
        buffer.parents = Array(repeating: 0, count: count)
        buffer.sizes = Array(repeating: 1024, count: count)
        buffer.mtimes = Array(repeating: 1_700_000_000, count: count)
        buffer.flags = Array(repeating: 0, count: count); buffer.flags[0] = 1
        buffer.depths = Array(repeating: 1, count: count)
        buffer.kinds = Array(repeating: 4, count: count); buffer.kinds[0] = 1
        for i in 0..<count {
            let name = i == 0 ? "" : "Fixture Photo \(i).jpg"
            buffer.nameLens.append(UInt32(name.utf8.count)); buffer.nameBytes.append(contentsOf: name.utf8)
        }
        let store = IndexStore(scan: ScanOutput(buffers: [buffer], count: count, homeIndex: .max, elapsed: 0, finishedAt: 0), config: IndexConfig(rootPath: "/FoxPerformanceCatalog"))
        return SearchSource(id: "fixture", displayName: "Fixture", isOnline: true, store: store)
    }
    func testCandidateScanMemoryAndLatency() throws {
        guard ProcessInfo.processInfo.environment["FOX_CONTENT_PERF"] == "1" else { throw XCTSkip("Opt-in synthetic candidate-scan benchmark") }
        let count = Int(ProcessInfo.processInfo.environment["FOX_CONTENT_COUNT"] ?? "100000") ?? 100000
        let source = source(count: count), done = expectation(description: "candidate scan")
        DispatchQueue.global(qos: .utility).async {
            autoreleasepool {
                let before = self.footprint(), start = CFAbsoluteTimeGetCurrent()
                var peak = before
                let candidates = ContentEngine.candidates(source, folders: ["/Fixture/Downloads", "/Fixture/Documents", "/Fixture/Pictures", "/Fixture/Projects"], options: .init(), cancelled: {
                    peak = max(peak, self.footprint()); return false
                })
                peak = max(peak, self.footprint())
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                let growth = Double(peak - min(peak, before)) / 1048576
                print("FOX_CONTENT_SCAN count=\(count) elapsed_ms=\(elapsed) peak_growth_mb=\(growth) matches=\(candidates.count)")
                XCTAssertTrue(candidates.isEmpty)
                XCTAssertLessThan(growth, 128, "Candidate scanning must drain temporary Foundation objects")
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 120)
    }
    func testCandidateScopeAndCancellation() {
        let source = source(count: 10000)
        XCTAssertEqual(ContentEngine.candidates(source, folders: ["/FoxPerformanceCatalog/../FoxPerformanceCatalog/"], options: .init(), cancelled: { false }).count, 9999)
        XCTAssertTrue(ContentEngine.candidates(source, folders: ["/FoxPerformance"], options: .init(), cancelled: { false }).isEmpty)
        XCTAssertTrue(ContentEngine.candidates(source, folders: ["/"], options: .init(), cancelled: { true }).isEmpty)
    }
    func testBackgroundCandidateScanYieldsIndexToWriters() throws {
        guard ProcessInfo.processInfo.environment["FOX_CONTENT_PERF"] == "1" else { throw XCTSkip("Opt-in candidate contention benchmark") }
        let source = source(count: 300000), token = ContentCancellation()
        let started = DispatchSemaphore(value: 0), done = expectation(description: "cancelled scan")
        DispatchQueue.global(qos: .utility).async {
            var signalled = false
            _ = ContentEngine.candidates(source, folders: ["/Outside"], options: .init(), cancelled: {
                if !signalled { signalled = true; started.signal() }
                return token.cancelled
            })
            done.fulfill()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        var waits: [Double] = []
        for _ in 0..<100 {
            let start = CFAbsoluteTimeGetCurrent()
            source.store.write { }
            waits.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            Thread.sleep(forTimeInterval: 0.001)
        }
        token.cancel(); wait(for: [done], timeout: 2)
        waits.sort()
        print("FOX_CONTENT_CONTENTION writer_p95_ms=\(waits[95]) writer_max_ms=\(waits.last!)")
        XCTAssertLessThan(waits.last!, 100, "Background candidate traversal must not monopolize the index lock")
    }
}
