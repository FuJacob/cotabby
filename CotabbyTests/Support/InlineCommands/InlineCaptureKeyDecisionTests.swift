import XCTest
@testable import Cotabby

/// Tests for the observer-to-active-tap hand-off value: a verdict applies only to the key it was
/// recorded for.
@MainActor
final class InlineCaptureKeyDecisionTests: XCTestCase {
    func test_matchingKey_reportsConsumeOrPassThrough() {
        let key = InputMonitorKeyEvent(keyCode: 48)
        XCTAssertEqual(InlineCaptureKeyDecision(keyCode: 48, consume: true).tapDecision(for: key), .consume)
        XCTAssertEqual(InlineCaptureKeyDecision(keyCode: 48, consume: false).tapDecision(for: key), .passThrough)
    }

    func test_differentKey_hasNoVerdict() {
        let decision = InlineCaptureKeyDecision(keyCode: 48, consume: true)
        XCTAssertNil(decision.tapDecision(for: InputMonitorKeyEvent(keyCode: 53)))
    }
}
