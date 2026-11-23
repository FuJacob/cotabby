import CoreGraphics
import XCTest
@testable import Cotabby

/// Tests for the value that holds one open macro capture.
@MainActor
final class MacroCaptureSessionTests: XCTestCase {
    private func makeSession() -> MacroCaptureSession {
        MacroCaptureSession(focusChangeSequence: 9, caretRect: CGRect(x: 1, y: 2, width: 3, height: 4))
    }

    func test_newSession_hasAnEmptyQueryAndNoResult() {
        let session = makeSession()

        XCTAssertEqual(session.focusChangeSequence, 9)
        XCTAssertEqual(session.query, "")
        XCTAssertNil(session.result)
        XCTAssertEqual(session.typedRunUTF16Count, 1, "only the `/` sigil has been typed")
    }

    func test_setResult_replacesQueryAndResultTogether() {
        var session = makeSession()
        let four = MacroResult(previewText: "= 4", insertionText: "4")

        session.setResult(four, for: "2+2=")
        XCTAssertEqual(session.query, "2+2=")
        XCTAssertEqual(session.result, four)

        // Backspacing to an incomplete expression must drop the result rather than keep a stale one.
        session.setResult(nil, for: "2+")
        XCTAssertEqual(session.query, "2+")
        XCTAssertNil(session.result)
    }

    func test_typedRunUTF16Count_isTheSigilPlusTheQueryInUTF16Units() {
        var session = makeSession()

        session.setResult(nil, for: "10km->mi")
        XCTAssertEqual(session.typedRunUTF16Count, 9)

        // "é" as a single precomposed scalar is one UTF-16 unit; an astral scalar is two.
        session.setResult(nil, for: "é")
        XCTAssertEqual(session.typedRunUTF16Count, 2)
        session.setResult(nil, for: "𝟙")
        XCTAssertEqual(session.typedRunUTF16Count, 3)
    }
}
