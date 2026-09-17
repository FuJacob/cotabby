import XCTest
@testable import Cotabby

final class SuggestionPresentationTimingTests: XCTestCase {
    private let field = FocusedInputIdentity(elementIdentifier: "field", focusChangeSequence: 1)

    func testLatestInputWinsAndOnlyFirstPresentationIsMeasured() {
        var timing = SuggestionPresentationTiming()
        timing.begin(identity: field, kind: "textMutation", at: 1)
        timing.begin(identity: field, kind: "acceptance", at: 2)
        let result = timing.presented(identity: field, at: 2.25)
        XCTAssertEqual(result?.inputKind, "acceptance")
        XCTAssertEqual(result?.milliseconds, 250)
        XCTAssertNil(timing.presented(identity: field, at: 3))
    }

    func testDifferentFocusRetiresMeasurement() {
        var timing = SuggestionPresentationTiming()
        timing.begin(identity: field, kind: "textMutation", at: 1)
        let nextFocus = FocusedInputIdentity(elementIdentifier: "field", focusChangeSequence: 2)
        XCTAssertNil(timing.presented(identity: nextFocus, at: 2))
        XCTAssertNil(timing.presented(identity: field, at: 3))
    }

    func testClearAndInvalidClockDoNotReportLatency() {
        var timing = SuggestionPresentationTiming()
        timing.begin(identity: field, kind: "textMutation", at: 2)
        XCTAssertNil(timing.presented(identity: field, at: 1))
        timing.begin(identity: field, kind: "textMutation", at: 2)
        timing.clear()
        XCTAssertNil(timing.presented(identity: field, at: 3))
    }

    func testNonFiniteTimestampsRetireMeasurement() {
        var timing = SuggestionPresentationTiming()
        timing.begin(identity: field, kind: "textMutation", at: .infinity)
        XCTAssertNil(timing.presented(identity: field, at: 3))
        timing.begin(identity: field, kind: "textMutation", at: 1)
        XCTAssertNil(timing.presented(identity: field, at: .infinity))
        XCTAssertNil(timing.presented(identity: field, at: 3))
    }
}
