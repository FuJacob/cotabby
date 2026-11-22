@testable import Cotabby
import XCTest

final class DoubleTapAcceptanceStateTests: XCTestCase {
    private let session = DoubleTapAcceptanceState.SessionToken(generation: 7, fullText: " world and more")

    func test_secondPressWithinWindowOnSameSession_isDoubleTap() {
        var state = DoubleTapAcceptanceState()
        state.recordWordAccept(of: session, at: 10.0)

        XCTAssertTrue(state.consumeDoubleTap(of: session, at: 10.2))
    }

    func test_secondPressAfterWindow_isNotDoubleTap() {
        var state = DoubleTapAcceptanceState()
        state.recordWordAccept(of: session, at: 10.0)

        XCTAssertFalse(state.consumeDoubleTap(of: session, at: 10.0 + DoubleTapAcceptanceState.window + 0.01))
    }

    func test_pressOnDifferentSession_isNotDoubleTap() {
        var state = DoubleTapAcceptanceState()
        state.recordWordAccept(of: session, at: 10.0)
        let regenerated = DoubleTapAcceptanceState.SessionToken(generation: 8, fullText: " world and more")

        XCTAssertFalse(state.consumeDoubleTap(of: regenerated, at: 10.1))
    }

    func test_firstPressWithoutRecordedAccept_isNotDoubleTap() {
        var state = DoubleTapAcceptanceState()

        XCTAssertFalse(state.consumeDoubleTap(of: session, at: 10.0))
    }

    func test_consumingEndsThePair_soATripleTapIsNotASecondDoubleTap() {
        var state = DoubleTapAcceptanceState()
        state.recordWordAccept(of: session, at: 10.0)

        XCTAssertTrue(state.consumeDoubleTap(of: session, at: 10.1))
        XCTAssertFalse(state.consumeDoubleTap(of: session, at: 10.2))
    }

    func test_missedDoubleTapAlsoClearsThePendingPress() {
        var state = DoubleTapAcceptanceState()
        state.recordWordAccept(of: session, at: 10.0)

        XCTAssertFalse(state.consumeDoubleTap(of: session, at: 11.0))
        XCTAssertFalse(state.hasPendingPress)
    }

    func test_resetCancelsThePendingPress() {
        var state = DoubleTapAcceptanceState()
        state.recordWordAccept(of: session, at: 10.0)

        state.reset()

        XCTAssertFalse(state.consumeDoubleTap(of: session, at: 10.1))
    }

    func test_clockGoingBackwards_isNotDoubleTap() {
        var state = DoubleTapAcceptanceState()
        state.recordWordAccept(of: session, at: 10.0)

        XCTAssertFalse(state.consumeDoubleTap(of: session, at: 9.9))
    }
}
