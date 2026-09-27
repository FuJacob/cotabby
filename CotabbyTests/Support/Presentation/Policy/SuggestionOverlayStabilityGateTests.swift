import CoreGraphics
import XCTest
@testable import Cotabby

/// Tests for the post-accept overlay-stability gate.
///
/// The bug this gate fixes: after every Tab accept, AX returns slightly drifted `caretRect` /
/// `observedCharWidth` values for the same underlying field state. The +30ms post-insertion
/// reconcile used to call `presentOverlay` with those drifted values, producing a visible
/// one-frame "shift left and down then snap back". The gate stops the reconcile from
/// re-rendering when the field, text, caret, and on-screen field bounds have not materially moved,
/// while still allowing legitimate context changes (window drag, field switch, text change, a real
/// caret move, or accumulated advance drift) to re-anchor the overlay.
final class SuggestionOverlayStabilityGateTests: XCTestCase {
    private static let inputFrame = CGRect(x: 100, y: 200, width: 400, height: 32)
    private static let caretRect = CGRect(x: 140, y: 210, width: 2, height: 18)
    /// A held anchor a word (180pt) right of `caretRect`, as after an exact-width advance.
    private static let advancedCaret = CGRect(x: 320, y: 210, width: 2, height: 18)

    /// The overlay currently on screen: text " again" in focus session 7 unless stated otherwise.
    private static func visible(
        _ text: String = " again",
        caretRect: CGRect = caretRect,
        inputFrameRect: CGRect? = inputFrame,
        caretQuality: CaretGeometryQuality = .exact,
        isRightToLeft: Bool = false,
        mode: CompletionRenderMode = .inline
    ) -> OverlayState {
        .visible(
            text: text,
            geometry: SuggestionOverlayGeometry(
                caretRect: caretRect,
                inputFrameRect: inputFrameRect,
                caretQuality: caretQuality,
                observedCharWidth: 8,
                isRightToLeft: isRightToLeft,
                focusChangeSequence: 7
            ),
            mode: mode
        )
    }

    /// The fresh reconcile tick; by default identical to `visible()`'s field, text, and geometry.
    private static func shouldRePresent(
        _ current: OverlayState,
        text: String = " again",
        caretRect: CGRect = caretRect,
        inputFrameRect: CGRect? = inputFrame,
        focusChangeSequence: UInt64 = 7,
        isAwaitingPostInsertionSync: Bool = false,
        millisecondsSinceLastAcceptance: Int? = nil
    ) -> Bool {
        SuggestionOverlayStabilityGate.shouldRePresent(
            currentOverlay: current,
            newText: text,
            newCaretRect: caretRect,
            newInputFrameRect: inputFrameRect,
            newFocusChangeSequence: focusChangeSequence,
            isAwaitingPostInsertionSync: isAwaitingPostInsertionSync,
            millisecondsSinceLastAcceptance: millisecondsSinceLastAcceptance
        )
    }

    // MARK: - Context changes

    func test_hiddenOverlay_alwaysReRenders() {
        XCTAssertTrue(Self.shouldRePresent(.hidden(reason: "idle")))
    }

    func test_identicalTick_holdsGeometryInEveryRenderMode() {
        // Render mode is not part of the decision: a card is held exactly like an inline ghost.
        XCTAssertFalse(Self.shouldRePresent(Self.visible()))
        XCTAssertFalse(Self.shouldRePresent(Self.visible(mode: .mirror(reason: .userPreference))))
    }

    func test_focusSessionOrDisplayedTextChanged_reAnchors() {
        XCTAssertTrue(Self.shouldRePresent(Self.visible(), focusChangeSequence: 8))
        XCTAssertTrue(Self.shouldRePresent(Self.visible(), text: " and send notes tomorrow"))
    }

    // MARK: - Caret drift

    /// Drift within the 6pt tolerance (post-insertion AX noise, an exact-advance residual) is held;
    /// beyond it on either axis (a genuine caret jump, a line change, accumulated advance drift)
    /// the overlay re-anchors. The comparison is strict, so exactly 6pt is still absorbed.
    func test_caretDrift_holdsWithinToleranceAndReAnchorsBeyondIt() {
        let cases: [(dx: CGFloat, dy: CGFloat, reAnchors: Bool)] = [
            (0.4, -0.3, false),
            (3, 0, false),
            (6, 0, false),
            (0, 6, false),
            (-6, -6, false),
            (10, 0, true),
            (-10, 0, true),
            (0, 10, true),
            (0, -10, true)
        ]

        for (dx, dy, reAnchors) in cases {
            XCTAssertEqual(
                Self.shouldRePresent(Self.visible(), caretRect: Self.caretRect.offsetBy(dx: dx, dy: dy)),
                reAnchors,
                "dx: \(dx), dy: \(dy)"
            )
        }
    }

    // MARK: - Input frame movement

    /// Window drags and resizes move the field's screen frame by whole points and must re-anchor;
    /// sub-pixel read noise inside the strict 1pt tolerance (mixed Retina setups) must be held.
    func test_inputFrameChange_holdsWithinToleranceAndReAnchorsBeyondIt() {
        let frame = Self.inputFrame
        let cases: [(label: String, newFrame: CGRect, reAnchors: Bool)] = [
            ("sub-pixel noise", frame.offsetBy(dx: 0.4, dy: -0.3), false),
            ("exactly 1pt", frame.offsetBy(dx: 1, dy: 0), false),
            ("horizontal drag", frame.offsetBy(dx: 12, dy: 0), true),
            ("vertical drag", frame.offsetBy(dx: 0, dy: -12), true),
            ("wider", CGRect(x: frame.minX, y: frame.minY, width: frame.width + 2, height: frame.height), true),
            ("shorter", CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height - 2), true)
        ]

        for (label, newFrame, reAnchors) in cases {
            XCTAssertEqual(Self.shouldRePresent(Self.visible(), inputFrameRect: newFrame), reAnchors, label)
        }
    }

    func test_inputFrameAppearingOrDisappearing_reAnchorsButBothMissingHolds() {
        XCTAssertTrue(Self.shouldRePresent(Self.visible(), inputFrameRect: nil))
        XCTAssertTrue(Self.shouldRePresent(Self.visible(inputFrameRect: nil)))
        XCTAssertFalse(Self.shouldRePresent(Self.visible(inputFrameRect: nil), inputFrameRect: nil))
    }

    // MARK: - Post-insertion sync window

    func test_awaitingPostInsertionSync_holdsEvenAcrossAWordWidthOfCaretDrift() {
        // The +30ms refresh racing the host publish reads the PRE-insertion caret, a full accepted
        // word left of where the overlay correctly sits. The drift tolerance cannot tell that from
        // a genuine caret move; only the awaiting flag can, and it must win. This is the TextEdit
        // left-then-right accept jitter. Once the sentinel clears, the same drift re-anchors: that
        // is the legitimate settle onto the real caret.
        let current = Self.visible(caretRect: CGRect(x: 180, y: 210, width: 2, height: 18))

        XCTAssertFalse(Self.shouldRePresent(current, isAwaitingPostInsertionSync: true))
        XCTAssertTrue(Self.shouldRePresent(current, isAwaitingPostInsertionSync: false))
    }

    func test_awaitingPostInsertionSync_stillReAnchorsOnFieldOrTextChange() {
        // The hold only covers stale geometry for the same field and text: a real field switch or
        // a text change mid-window must keep re-anchoring.
        XCTAssertTrue(Self.shouldRePresent(Self.visible(), focusChangeSequence: 8, isAwaitingPostInsertionSync: true))
        XCTAssertTrue(Self.shouldRePresent(Self.visible(), text: " different tail", isAwaitingPostInsertionSync: true))
    }

    func test_awaitingPostInsertionSync_holdsEvenWhenTheFrameMoved() {
        // Every geometric field of the snapshot is pre-insertion state, including the frame.
        XCTAssertFalse(Self.shouldRePresent(
            Self.visible(),
            inputFrameRect: Self.inputFrame.offsetBy(dx: 40, dy: 0),
            isAwaitingPostInsertionSync: true
        ))
    }

    // MARK: - Layout-estimated anchors (TextKit mirror hosts)

    func test_layoutEstimatedAnchor_ignoresRawCaretDrift() {
        // The held anchor came from the hidden text layout; fresh snapshots still carry the RAW
        // resolver caret (an AXFrame proportional guess), which routinely sits a word or more
        // away. Treating that gap as drift re-presented and re-estimated on every reconcile
        // tick, and around accepts it was the jerk-left-then-back: with text and field unchanged
        // the estimate cannot move, so the gate must hold.
        let current = Self.visible(caretRect: Self.advancedCaret, caretQuality: .layoutEstimated)

        XCTAssertFalse(Self.shouldRePresent(current))
        XCTAssertFalse(Self.shouldRePresent(current, caretRect: CGRect(x: 140, y: 400, width: 2, height: 18)))
    }

    func test_layoutEstimatedAnchor_stillReAnchorsOnFrameTextOrFieldChange() {
        // The estimate is a pure function of (text, field frame, style): when one of its real
        // inputs changes, or the field itself does, the re-anchor must still happen.
        let current = Self.visible(caretQuality: .layoutEstimated)

        XCTAssertTrue(
            Self.shouldRePresent(current, inputFrameRect: Self.inputFrame.offsetBy(dx: 40, dy: 0)),
            "A field-frame move re-positions the estimate and must re-anchor"
        )
        XCTAssertTrue(Self.shouldRePresent(current, text: " different"))
        XCTAssertTrue(Self.shouldRePresent(current, focusChangeSequence: 8))
    }

    // MARK: - Backward drift after an accept (stale child-run frames)

    func test_backwardDriftInsideTheAcceptWindow_holdsUpToAndIncludingTheBoundary() {
        // Child-run hosts publish the inserted value before their run frames reflow, so the
        // post-publish caret maps into pre-insert frames and lands a word LEFT of the overlay.
        // Re-anchoring there and snapping back on the fresh walk was the runs-aligned accept
        // jitter; within the post-accept window a same-line backward jump is always staleness.
        let current = Self.visible(caretRect: Self.advancedCaret)
        let window = SuggestionOverlayStabilityGate.backwardDriftHoldWindowMilliseconds

        XCTAssertEqual(window, 300)
        for elapsed in [0, 80, window] {
            XCTAssertFalse(Self.shouldRePresent(current, millisecondsSinceLastAcceptance: elapsed), "\(elapsed)ms")
        }
    }

    func test_backwardDriftOutsideTheAcceptWindow_reAnchors() {
        // The hold is a staleness shield, not a one-way ratchet: once geometry has had time to
        // catch up, a backward correction (e.g. settling a slide overshoot in a style-less host)
        // must still land.
        let current = Self.visible(caretRect: Self.advancedCaret)
        let window = SuggestionOverlayStabilityGate.backwardDriftHoldWindowMilliseconds

        XCTAssertTrue(Self.shouldRePresent(current, millisecondsSinceLastAcceptance: window + 1))
        XCTAssertTrue(Self.shouldRePresent(current, millisecondsSinceLastAcceptance: 800))
        XCTAssertTrue(
            Self.shouldRePresent(current, millisecondsSinceLastAcceptance: nil),
            "No recorded acceptance means no staleness shield"
        )
    }

    func test_forwardDriftInsideTheAcceptWindow_stillReAnchors() {
        // Forward jumps are the legitimate settles (the host published and the caret moved on);
        // the directional hold must not block them.
        XCTAssertTrue(Self.shouldRePresent(
            Self.visible(),
            caretRect: Self.caretRect.offsetBy(dx: 40, dy: 0),
            millisecondsSinceLastAcceptance: 80
        ))
    }

    func test_backwardDriftWithALineChange_reAnchors() {
        // A vertical move past tolerance is a real line change (wrap, scroll); direction on X no
        // longer marks it as stale.
        XCTAssertTrue(Self.shouldRePresent(
            Self.visible(caretRect: Self.advancedCaret),
            caretRect: CGRect(x: 140, y: 240, width: 2, height: 18),
            millisecondsSinceLastAcceptance: 80
        ))
    }

    func test_backwardDriftForRTL_isMirrored() {
        // In RTL the caret advances leftward, so "backward" staleness arrives as a RIGHTWARD jump.
        let current = Self.visible(isRightToLeft: true)

        XCTAssertFalse(
            Self.shouldRePresent(
                current,
                caretRect: Self.caretRect.offsetBy(dx: 60, dy: 0),
                millisecondsSinceLastAcceptance: 80
            ),
            "A rightward jump is against the RTL writing direction and must be held in the window"
        )
        XCTAssertTrue(
            Self.shouldRePresent(
                current,
                caretRect: Self.caretRect.offsetBy(dx: -60, dy: 0),
                millisecondsSinceLastAcceptance: 80
            ),
            "A leftward jump is the RTL forward direction and stays re-anchorable"
        )
    }
}
