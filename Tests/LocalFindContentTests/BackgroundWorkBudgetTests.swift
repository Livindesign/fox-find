import XCTest
@testable import LocalFindContent

final class BackgroundWorkBudgetTests: XCTestCase {
    func testBackgroundJobsShareOneLaneAndWrongCompletionCannotReleaseIt() {
        let budget = BackgroundWorkBudget(), ocr = ContentCancellation(), model = ContentCancellation()
        XCTAssertTrue(budget.beginBackground(ocr))
        XCTAssertFalse(budget.beginBackground(model))
        budget.endBackground(model)
        XCTAssertFalse(budget.beginBackground(model))
        budget.endBackground(ocr)
        XCTAssertTrue(budget.beginBackground(model))
        budget.endBackground(model)
    }

    func testContinuousActivityExtendsQuietPeriod() {
        var time: TimeInterval = 100
        let budget = BackgroundWorkBudget(clock: { time }), token = ContentCancellation()
        XCTAssertTrue(budget.beginBackground(token))
        budget.userActivity()
        XCTAssertTrue(token.cancelled)
        budget.endBackground(token)
        for step in 1...20 {
            time = 100 + Double(step)
            budget.userActivity()
            XCTAssertFalse(budget.beginBackground(ContentCancellation()))
        }
        time = 127.99
        XCTAssertFalse(budget.beginBackground(ContentCancellation()))
        time = 128
        let next = ContentCancellation()
        XCTAssertTrue(budget.beginBackground(next))
        budget.endBackground(next)
    }

    func testMemoryPressureCancelsBackgroundAndRejectsNewModelWork() throws {
        var time: TimeInterval = 100
        let budget = BackgroundWorkBudget(clock: { time }), token = ContentCancellation()
        var released = false
        budget.onMemoryPressure = { released = true }
        XCTAssertTrue(budget.beginBackground(token))
        budget.setMemoryPressure(true)
        XCTAssertTrue(token.cancelled); XCTAssertTrue(released)
        budget.endBackground(token)
        XCTAssertFalse(budget.beginBackground(ContentCancellation()))
        XCTAssertThrowsError(try budget.withForeground(cancelled: { false }) { XCTFail("Must not launch a model") })
        budget.setMemoryPressure(false)
        XCTAssertFalse(budget.beginBackground(ContentCancellation()))
        time += 8
        let next = ContentCancellation()
        XCTAssertTrue(budget.beginBackground(next))
        budget.endBackground(next)
        XCTAssertEqual(try budget.withForeground(cancelled: { false }) { 42 }, 42)
    }

    func testForegroundCancelsBackgroundAndWaitsForWorkerRelease() {
        let budget = BackgroundWorkBudget(), token = ContentCancellation()
        XCTAssertTrue(budget.beginBackground(token))
        let finished = expectation(description: "foreground completed")
        DispatchQueue.global(qos: .utility).async {
            defer { finished.fulfill() }
            do {
                try budget.withForeground(cancelled: { false }) {
                    XCTAssertFalse(budget.beginBackground(ContentCancellation()))
                }
            } catch { XCTFail("Unexpected error: \(error)") }
        }
        let deadline = Date().addingTimeInterval(0.5)
        while !token.cancelled && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
        XCTAssertTrue(token.cancelled)
        budget.endBackground(token)
        wait(for: [finished], timeout: 1)
        XCTAssertFalse(budget.beginBackground(ContentCancellation()), "Foreground work gets an idle grace period")
    }

    func testCancelledForegroundDoesNotReleaseAnActiveBackgroundOwner() {
        let budget = BackgroundWorkBudget(), token = ContentCancellation()
        XCTAssertTrue(budget.beginBackground(token))
        XCTAssertThrowsError(try budget.withForeground(cancelled: { true }) { XCTFail("Cancelled work must not run") })
        XCTAssertTrue(token.cancelled)
        XCTAssertFalse(budget.beginBackground(ContentCancellation()))
        budget.endBackground(token)
    }
}
