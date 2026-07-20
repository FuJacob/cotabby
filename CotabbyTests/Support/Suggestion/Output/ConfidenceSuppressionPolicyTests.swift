import XCTest
@testable import Cotabby

/// Pure-function tests for confidence-based suppression.
final class ConfidenceSuppressionPolicyTests: XCTestCase {

    func test_disabledFloor_neverSuppresses() {
        // The default floor (-infinity) means suppression is off, even for very low confidence.
        XCTAssertFalse(
            ConfidenceSuppressionPolicy.shouldSuppress(averageLogprob: -50.0, floor: -.infinity)
        )
    }

    func test_belowFloor_suppresses() {
        XCTAssertTrue(
            ConfidenceSuppressionPolicy.shouldSuppress(averageLogprob: -3.0, floor: -2.0)
        )
    }

    func test_aboveFloor_doesNotSuppress() {
        XCTAssertFalse(
            ConfidenceSuppressionPolicy.shouldSuppress(averageLogprob: -1.0, floor: -2.0)
        )
    }

    func test_atFloor_doesNotSuppress() {
        XCTAssertFalse(
            ConfidenceSuppressionPolicy.shouldSuppress(averageLogprob: -2.0, floor: -2.0)
        )
    }
}
