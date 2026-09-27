import XCTest
@testable import Cotabby

/// Tests for the overlay fade-in gate: the fade plays only on a genuine appearance, and the user
/// toggle and the system Reduce Motion preference each veto it. These three inputs are exactly the
/// distinctions that, if wrong, would either flicker stable ghost text on every keystroke or animate
/// when the user asked for no motion.
final class SuggestionFadeInPolicyTests: XCTestCase {
    func test_fadesInOnlyOnAGenuineAppearanceWithTheToggleOnAndMotionAllowed() {
        // Every one of the eight combinations is listed so no single veto can silently stop
        // mattering. The reasons name which rule decides each row.
        let cases: [(enabled: Bool, wasVisible: Bool, reduceMotion: Bool, fades: Bool, reason: String)] = [
            (true, false, false, true, "first paint with the toggle on"),
            // A reposition / streamed extension / word-by-word advance re-enters the show path while
            // the panel stays on screen; restarting the ramp there is the flicker the gate prevents.
            (true, true, false, false, "update to an overlay already on screen"),
            // Reduce Motion is an accessibility need that overrides the cosmetic toggle.
            (true, false, true, false, "Reduce Motion vetoes the first paint"),
            (true, true, true, false, "Reduce Motion and already visible"),
            // Disabled wins regardless of visibility: the user opted into instant ghost text.
            (false, false, false, false, "toggle off on first paint"),
            (false, true, false, false, "toggle off while visible"),
            (false, false, true, false, "toggle off and Reduce Motion"),
            (false, true, true, false, "every veto at once")
        ]

        for row in cases {
            XCTAssertEqual(
                SuggestionFadeInPolicy.shouldFadeIn(
                    isEnabled: row.enabled,
                    overlayWasVisible: row.wasVisible,
                    reduceMotionEnabled: row.reduceMotion
                ),
                row.fades,
                row.reason
            )
        }
    }
}
