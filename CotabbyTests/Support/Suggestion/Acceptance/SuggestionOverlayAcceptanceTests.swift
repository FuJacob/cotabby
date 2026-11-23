import XCTest
@testable import Cotabby

/// Overlay-facing acceptance rules: Tab is allowed only for the ghost text actually on screen (or
/// while the overlay is briefly hidden), and hide reasons map input kinds to user-visible messages.
final class SuggestionOverlayAcceptanceTests: XCTestCase {
    func test_overlayAllowsAcceptance_trueWhenOverlayHidden() {
        XCTAssertTrue(
            SuggestionSessionReconciler.overlayAllowsAcceptance(
                of: " world",
                overlayState: .hidden(reason: "waiting for AX")
            )
        )
    }

    func test_overlayAllowsAcceptance_trueOnlyWhenVisibleTextMatches() {
        let caretRect = CGRect(x: 10, y: 20, width: 2, height: 18)

        XCTAssertTrue(
            SuggestionSessionReconciler.overlayAllowsAcceptance(
                of: " world",
                overlayState: .visible(
                    text: " world",
                    geometry: CotabbyTestFixtures.overlayGeometry(caretRect: caretRect),
                    mode: .inline
                )
            )
        )
        XCTAssertFalse(
            SuggestionSessionReconciler.overlayAllowsAcceptance(
                of: " world",
                overlayState: .visible(
                    text: " there",
                    geometry: CotabbyTestFixtures.overlayGeometry(caretRect: caretRect),
                    mode: .inline
                )
            )
        )
    }

    func test_overlayAllowsAcceptance_heldPresentationAuthorizesItsOwnTextOnly() {
        // The controller is holding the next present, so the published state still shows the
        // tail from before the last accept.
        let previousTail = OverlayState.visible(
            text: " hello world",
            geometry: CotabbyTestFixtures.overlayGeometry(),
            mode: .inline
        )

        XCTAssertTrue(
            SuggestionSessionReconciler.overlayAllowsAcceptance(
                of: " world", overlayState: previousTail, heldPresentationText: " world"
            )
        )
        XCTAssertFalse(
            SuggestionSessionReconciler.overlayAllowsAcceptance(
                of: " world", overlayState: previousTail, heldPresentationText: " there"
            ),
            "A held present for different text does not make a mismatched ghost acceptable"
        )
        XCTAssertFalse(
            SuggestionSessionReconciler.overlayAllowsAcceptance(
                of: " world", overlayState: previousTail, heldPresentationText: nil
            )
        )
    }

    func test_overlayHideReason_mapsSemanticInputEventsToUserVisibleReasons() {
        XCTAssertEqual(
            SuggestionSessionReconciler.overlayHideReason(
                for: CotabbyTestFixtures.inputEvent(kind: .textMutation)
            ),
            "Overlay hidden because typing invalidated the current suggestion."
        )
        XCTAssertEqual(
            SuggestionSessionReconciler.overlayHideReason(
                for: CotabbyTestFixtures.inputEvent(kind: .navigation)
            ),
            "Overlay hidden because caret navigation invalidated the current suggestion."
        )
        XCTAssertEqual(
            SuggestionSessionReconciler.overlayHideReason(
                for: CotabbyTestFixtures.inputEvent(kind: .dismissal)
            ),
            "Overlay hidden because a dismissal key was pressed."
        )
    }

    func test_overlayHideReason_acceptanceAndOtherEventsUseTheGenericReason() {
        // Acceptance-driven hides are expected behavior, not invalidation, so they get the plain
        // message; shortcut mutations read as typing.
        for kind in [CapturedInputEvent.Kind.acceptance, .fullAcceptance, .other] {
            XCTAssertEqual(
                SuggestionSessionReconciler.overlayHideReason(
                    for: CotabbyTestFixtures.inputEvent(kind: kind)
                ),
                "Overlay hidden."
            )
        }
        XCTAssertEqual(
            SuggestionSessionReconciler.overlayHideReason(
                for: CotabbyTestFixtures.inputEvent(kind: .shortcutMutation)
            ),
            "Overlay hidden because typing invalidated the current suggestion."
        )
    }

    // MARK: - Painted head of a truncated ghost

    private func visible(_ text: String) -> OverlayState {
        .visible(text: text, geometry: CotabbyTestFixtures.overlayGeometry(), mode: .inline)
    }

    func test_shownHead_isNilWhenTheWholeGhostIsPaintedOrNothingIsVisible() {
        XCTAssertNil(SuggestionSessionReconciler.shownHead(
            of: " world again", overlayState: visible(" world again"), truncatedDisplayText: nil
        ))
        XCTAssertNil(SuggestionSessionReconciler.shownHead(
            of: " world again", overlayState: .hidden(reason: "held"), truncatedDisplayText: " world"
        ))
    }

    func test_shownHead_isThePaintedHeadWhenTheTailIsTheVisibleText() {
        XCTAssertEqual(
            SuggestionSessionReconciler.shownHead(
                of: " world again and more", overlayState: visible(" world again and more"),
                truncatedDisplayText: " world again"
            ),
            " world again"
        )
    }

    func test_shownHead_isRebasedOntoATailThatHasConsumedPartOfTheVisibleText() {
        // An accept advanced the session while the overlay still holds its next present, or the
        // user typed through letters before the ghost slid.
        XCTAssertEqual(
            SuggestionSessionReconciler.shownHead(
                of: " again and more", overlayState: visible(" world again and more"),
                truncatedDisplayText: " world again"
            ),
            " again"
        )
    }

    func test_shownHead_isEmptyOnceTheWholePaintedHeadIsConsumed() {
        XCTAssertEqual(
            SuggestionSessionReconciler.shownHead(
                of: " and more", overlayState: visible(" world again and more"),
                truncatedDisplayText: " world again"
            ),
            ""
        )
    }

    func test_shownHead_keepsThePaintedHeadForAHeldPresentThatExtendsTheVisibleText() {
        XCTAssertEqual(
            SuggestionSessionReconciler.shownHead(
                of: " world again and more", overlayState: visible(" world again and"),
                truncatedDisplayText: " world"
            ),
            " world"
        )
    }

    func test_shownHead_isEmptyForATailThatIsNotPartOfTheVisibleGhost() {
        XCTAssertEqual(
            SuggestionSessionReconciler.shownHead(
                of: " something new", overlayState: visible(" world again"), truncatedDisplayText: " world"
            ),
            ""
        )
    }

    func test_shownHead_imposesNoLimitWhenTheHeadDoesNotDescribeTheVisibleText() {
        XCTAssertNil(SuggestionSessionReconciler.shownHead(
            of: " world again", overlayState: visible(" world again"), truncatedDisplayText: " there"
        ))
    }

    func test_acceptanceChunk_isCutBackToTheShownHead() {
        XCTAssertEqual(
            SuggestionSessionReconciler.acceptanceChunk(" world again and more", limitedTo: " world again"),
            " world again"
        )
    }

    func test_acceptanceChunk_insideTheShownHeadIsUnchanged() {
        XCTAssertEqual(SuggestionSessionReconciler.acceptanceChunk(" world", limitedTo: " world again"), " world")
        XCTAssertEqual(SuggestionSessionReconciler.acceptanceChunk(" world again", limitedTo: " world again"), " world again")
        XCTAssertEqual(SuggestionSessionReconciler.acceptanceChunk(" world again", limitedTo: nil), " world again")
    }

    func test_acceptanceChunk_isEmptyWhenNothingWasShownOrTheHeadDisagrees() {
        XCTAssertEqual(SuggestionSessionReconciler.acceptanceChunk(" and", limitedTo: ""), "")
        XCTAssertEqual(SuggestionSessionReconciler.acceptanceChunk(" world again", limitedTo: " there"), "")
    }
}
