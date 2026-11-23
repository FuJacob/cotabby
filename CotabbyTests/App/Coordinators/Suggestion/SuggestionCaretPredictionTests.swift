import CoreGraphics
import XCTest
@testable import Cotabby

final class SuggestionCaretPredictionTests: XCTestCase {
    func test_predictedCaretRectUsesObservedCharacterWidthForTrustedGeometry() {
        runOnMainActor {
            let oldRect = CGRect(x: 10, y: 20, width: 2, height: 18)

            let predicted = PredictedCaretAdvance.caretRect(
                after: "abcd",
                oldCaretRect: oldRect,
                caretQuality: .exact,
                observedCharWidth: 7
            )

            XCTAssertEqual(predicted.origin.x, 38)
            XCTAssertEqual(predicted.origin.y, oldRect.origin.y)
            XCTAssertEqual(predicted.size, oldRect.size)
        }
    }

    func test_predictedCaretRectAppliesTheBiasedConservativeShiftForEstimatedGeometry() {
        runOnMainActor {
            let oldRect = CGRect(x: 10, y: 20, width: 2, height: 18)

            let predicted = PredictedCaretAdvance.caretRect(
                after: "abcd",
                oldCaretRect: oldRect,
                caretQuality: .estimated,
                observedCharWidth: 7
            )

            // Coarse AXFrame geometry scales the measured 28pt by 0.91 and the 1.5 upward bias
            // (38.22pt), which sits between the 21pt floor and the 78pt per-character cap.
            XCTAssertEqual(predicted.origin.x, 48.22, accuracy: 0.001)
            XCTAssertEqual(predicted.origin.y, oldRect.origin.y)
            XCTAssertEqual(predicted.size, oldRect.size)
        }
    }

    func test_predictedCaretRectFloorsTinyEstimatedShifts() {
        runOnMainActor {
            let predicted = PredictedCaretAdvance.caretRect(
                after: "a",
                oldCaretRect: CGRect(x: 10, y: 20, width: 2, height: 18),
                caretQuality: .estimated,
                observedCharWidth: 2
            )

            // 2pt * 0.91 * 1.5 is below the 14pt * 1.5 floor, so the floor wins.
            XCTAssertEqual(predicted.origin.x, 31, accuracy: 0.001)
        }
    }

    func test_predictedCaretRectShiftsLeftForRightToLeftText() {
        runOnMainActor {
            let predicted = PredictedCaretAdvance.caretRect(
                after: "abcd",
                oldCaretRect: CGRect(x: 100, y: 20, width: 2, height: 18),
                caretQuality: .exact,
                observedCharWidth: 7,
                isRightToLeft: true
            )

            XCTAssertEqual(predicted.origin.x, 72)
        }
    }
}
