import XCTest
@testable import Cotabby

/// Focused coverage for one responsibility of `SuggestionSessionReconciler`.
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
}
