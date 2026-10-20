import XCTest
@testable import FoxFindApp

final class AITopicImportGateTests: XCTestCase {
    func testStartupTypingAndSustainedScrollingDeferImportWithoutLosingCancellation() throws {
        var time: TimeInterval = 100
        let gate = AITopicImportGate(now: { time })
        gate.userActivity()
        XCTAssertNil(gate.ticket()); XCTAssertEqual(gate.delay, 8)
        time += 8
        let old = try XCTUnwrap(gate.ticket())
        XCTAssertTrue(gate.permits(old))
        for _ in 0..<12 {
            gate.userActivity(); time += 1
            XCTAssertFalse(gate.permits(old)); XCTAssertNil(gate.ticket())
        }
        time += 8
        XCTAssertFalse(gate.permits(old), "A cancelled import cannot become current after the grace period")
        XCTAssertTrue(gate.permits(try XCTUnwrap(gate.ticket())))
    }
    func testMemoryPressureCancelsImportAndRecoveryWaitsForQuietPeriod() throws {
        var time: TimeInterval = 100
        let gate = AITopicImportGate(now: { time })
        let token = try XCTUnwrap(gate.ticket())
        gate.memoryPressure(true); time += 100
        XCTAssertFalse(gate.permits(token)); XCTAssertNil(gate.ticket())
        gate.memoryPressure(false)
        XCTAssertEqual(gate.delay, 8); XCTAssertNil(gate.ticket())
        time += 8
        XCTAssertNotNil(gate.ticket()); XCTAssertFalse(gate.permits(token))
    }
}
