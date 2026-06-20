import XCTest
@testable import Cotabby

/// Tests for the overlay fade-in gate: the fade plays only on a genuine appearance, and the user
/// toggle and the system Reduce Motion preference each veto it. These three inputs are exactly the
/// distinctions that, if wrong, would either flicker stable ghost text on every keystroke or animate
/// when the user asked for no motion.
final class SuggestionFadeInPolicyTests: XCTestCase {
    func test_fadesIn_onAppearanceWhenEnabledAndMotionAllowed() {
        XCTAssertTrue(
            SuggestionFadeInPolicy.shouldFadeIn(
                isEnabled: true,
                overlayWasVisible: false,
                reduceMotionEnabled: false
            )
        )
    }

    func test_doesNotFade_whenOverlayWasAlreadyVisible() {
        // A reposition / streamed extension / word-by-word advance re-enters the show path while the
        // panel stays on screen; restarting the ramp here is the flicker the gate exists to prevent.
        XCTAssertFalse(
            SuggestionFadeInPolicy.shouldFadeIn(
                isEnabled: true,
                overlayWasVisible: true,
                reduceMotionEnabled: false
            )
        )
    }

    func test_doesNotFade_whenDisabled() {
        // Disabled wins regardless of visibility: the user opted into instant ghost text.
        XCTAssertFalse(
            SuggestionFadeInPolicy.shouldFadeIn(
                isEnabled: false,
                overlayWasVisible: false,
                reduceMotionEnabled: false
            )
        )
        XCTAssertFalse(
            SuggestionFadeInPolicy.shouldFadeIn(
                isEnabled: false,
                overlayWasVisible: true,
                reduceMotionEnabled: false
            )
        )
    }

    func test_doesNotFade_whenReduceMotionOn_evenIfEnabled() {
        // Reduce Motion is an accessibility need that overrides the cosmetic toggle.
        XCTAssertFalse(
            SuggestionFadeInPolicy.shouldFadeIn(
                isEnabled: true,
                overlayWasVisible: false,
                reduceMotionEnabled: true
            )
        )
    }

    func test_vetoesCompose_disabledAndReduceMotionAndVisibleAllSuppress() {
        // Exhaust the remaining corners so no single veto silently stops mattering.
        for isEnabled in [true, false] {
            for wasVisible in [true, false] {
                for reduceMotion in [true, false] {
                    let expected = isEnabled && !wasVisible && !reduceMotion
                    XCTAssertEqual(
                        SuggestionFadeInPolicy.shouldFadeIn(
                            isEnabled: isEnabled,
                            overlayWasVisible: wasVisible,
                            reduceMotionEnabled: reduceMotion
                        ),
                        expected,
                        "enabled=\(isEnabled) wasVisible=\(wasVisible) reduceMotion=\(reduceMotion)"
                    )
                }
            }
        }
    }
}
