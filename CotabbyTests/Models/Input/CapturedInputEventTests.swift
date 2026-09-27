import XCTest
@testable import Cotabby

/// Tests for the semantic input-event vocabulary's scheduling policy: which event kinds start a new
/// prediction and which clear the visible suggestion. The coordinator branches on these two flags
/// for every keystroke, so each kind is pinned explicitly.
final class CapturedInputEventTests: XCTestCase {
    func test_everyKind_mapsToItsSchedulingAndClearingPolicy() {
        let expectations: [(kind: CapturedInputEvent.Kind, schedules: Bool, clears: Bool)] = [
            (.acceptance, false, false),
            (.fullAcceptance, false, false),
            (.textMutation, true, true),
            (.navigation, false, true),
            (.shortcutMutation, true, true),
            (.dismissal, false, true),
            (.other, false, false)
        ]

        for expectation in expectations {
            let event = CotabbyTestFixtures.inputEvent(kind: expectation.kind)
            XCTAssertEqual(event.shouldSchedulePrediction, expectation.schedules, "\(expectation.kind) scheduling")
            XCTAssertEqual(event.shouldClearSuggestion, expectation.clears, "\(expectation.kind) clearing")
        }
    }
}
