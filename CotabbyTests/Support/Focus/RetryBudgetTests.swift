import XCTest
@testable import Cotabby

final class RetryBudgetTests: XCTestCase {
    func test_budgetAllowsExactlyItsMaximumNumberOfAttempts() {
        var budget = RetryBudget(maximumAttempts: 3)

        for _ in 0..<3 {
            XCTAssertTrue(budget.hasAttemptsLeft)
            budget.spend()
        }

        XCTAssertFalse(budget.hasAttemptsLeft)
        XCTAssertEqual(budget.attempts, 3)
    }

    func test_aBudgetOfZeroNeverAllowsAnAttempt() {
        XCTAssertFalse(RetryBudget(maximumAttempts: 0).hasAttemptsLeft)
    }

    func test_pacingAllowsTheFirstAttemptImmediately() {
        let pacing = RetryPacing(interval: 0.25)

        XCTAssertTrue(pacing.allowsAttempt(at: Date(timeIntervalSinceReferenceDate: 0)))
    }

    /// The window is half-open: exactly one interval later is allowed again.
    func test_pacingHoldsFurtherAttemptsForOneInterval() {
        let start = Date(timeIntervalSinceReferenceDate: 100)
        var pacing = RetryPacing(interval: 0.25)
        pacing.recordAttempt(at: start)

        XCTAssertFalse(pacing.allowsAttempt(at: start))
        XCTAssertFalse(pacing.allowsAttempt(at: start.addingTimeInterval(0.24)))
        XCTAssertTrue(pacing.allowsAttempt(at: start.addingTimeInterval(0.25)))
    }

    func test_pacingMeasuresFromTheMostRecentAttempt() {
        let start = Date(timeIntervalSinceReferenceDate: 100)
        var pacing = RetryPacing(interval: 0.25)
        pacing.recordAttempt(at: start)
        pacing.recordAttempt(at: start.addingTimeInterval(0.25))

        XCTAssertFalse(pacing.allowsAttempt(at: start.addingTimeInterval(0.4)))
        XCTAssertTrue(pacing.allowsAttempt(at: start.addingTimeInterval(0.5)))
    }
}
