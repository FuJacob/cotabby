import CoreGraphics
import XCTest
@testable import Cotabby

final class CaptureWindowSelectorTests: XCTestCase {
    private let caret = CGPoint(x: 300, y: 300)

    func test_picksTheFrontMostWindowUnderTheCaret() {
        // Two cascaded TextEdit documents, both reported active, the background one listed first:
        // capturing it put another document's text in the prompt and read as navigation.
        let background = CaptureWindowSelector.Candidate(id: 11, frame: CGRect(x: 0, y: 0, width: 603, height: 505), isActive: true)
        let focused = CaptureWindowSelector.Candidate(id: 22, frame: CGRect(x: 20, y: 20, width: 603, height: 505), isActive: true)
        let selected = CaptureWindowSelector.select([background, focused], caret: caret, frontToBack: [22, 11])
        XCTAssertEqual(selected, 22)
    }

    func test_aWindowUnderTheCaretBeatsAnActiveOneElsewhere() {
        let elsewhere = CaptureWindowSelector.Candidate(id: 1, frame: CGRect(x: 900, y: 0, width: 400, height: 400), isActive: true)
        let underCaret = CaptureWindowSelector.Candidate(id: 2, frame: CGRect(x: 0, y: 0, width: 600, height: 600), isActive: false)
        XCTAssertEqual(CaptureWindowSelector.select([elsewhere, underCaret], caret: caret, frontToBack: [1, 2]), 2)
    }

    func test_fallsBackToTheFrontMostActiveWindowWhenNoneContainsTheCaret() {
        let back = CaptureWindowSelector.Candidate(id: 1, frame: CGRect(x: 900, y: 0, width: 400, height: 400), isActive: true)
        let front = CaptureWindowSelector.Candidate(id: 2, frame: CGRect(x: 1400, y: 0, width: 400, height: 400), isActive: true)
        let inactive = CaptureWindowSelector.Candidate(id: 3, frame: CGRect(x: 2000, y: 0, width: 400, height: 400), isActive: false)
        XCTAssertEqual(CaptureWindowSelector.select([back, front, inactive], caret: caret, frontToBack: [3, 2, 1]), 2)
    }

    func test_keepsListOrderWhenTheWindowOrderIsUnknown() {
        let first = CaptureWindowSelector.Candidate(id: 1, frame: CGRect(x: 0, y: 0, width: 600, height: 600), isActive: true)
        let second = CaptureWindowSelector.Candidate(id: 2, frame: CGRect(x: 0, y: 0, width: 600, height: 600), isActive: true)
        XCTAssertEqual(CaptureWindowSelector.select([first, second], caret: caret, frontToBack: []), 1)
        XCTAssertNil(CaptureWindowSelector.select([], caret: caret, frontToBack: [1]))
    }
}
