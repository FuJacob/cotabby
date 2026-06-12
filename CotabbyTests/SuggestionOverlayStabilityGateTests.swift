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

    private static func geometry(
        caretRect: CGRect = caretRect,
        inputFrameRect: CGRect? = inputFrame,
        focusChangeSequence: UInt64 = 7
    ) -> SuggestionOverlayGeometry {
        SuggestionOverlayGeometry(
            caretRect: caretRect,
            inputFrameRect: inputFrameRect,
            caretQuality: .exact,
            observedCharWidth: 8,
            isRightToLeft: false,
            focusChangeSequence: focusChangeSequence
        )
    }

    func test_hiddenOverlay_alwaysReRenders() {
        XCTAssertTrue(
            SuggestionOverlayStabilityGate.shouldRePresent(
                currentOverlay: .hidden(reason: "idle"),
                newText: "draft",
                newCaretRect: Self.caretRect,
                newInputFrameRect: Self.inputFrame,
                newFocusChangeSequence: 7
            )
        )
    }

    /// The exact scenario the gate exists for: text and field are identical, only the caret rect
    /// has drifted by a sub-pixel amount in the latest AX read. Holding the geometry is what
    /// prevents the post-accept jitter.
    func test_sameFieldSameTextSubPixelCaretDrift_holdsGeometry() {
        let current: OverlayState = .visible(text: "draft and send", geometry: Self.geometry(), mode: .inline)

        XCTAssertFalse(
            SuggestionOverlayStabilityGate.shouldRePresent(
                currentOverlay: current,
                newText: "draft and send",
                newCaretRect: Self.caretRect.offsetBy(dx: 0.4, dy: -0.3),
                newInputFrameRect: Self.inputFrame,
                newFocusChangeSequence: 7
            )
        )
    }

    func test_focusSessionChanged_reAnchors() {
        let current: OverlayState = .visible(
            text: "draft and send",
            geometry: Self.geometry(focusChangeSequence: 7),
            mode: .inline
        )

        XCTAssertTrue(
            SuggestionOverlayStabilityGate.shouldRePresent(
                currentOverlay: current,
                newText: "draft and send",
                newCaretRect: Self.caretRect,
                newInputFrameRect: Self.inputFrame,
                newFocusChangeSequence: 8
            )
        )
    }

    func test_displayedTextChanged_reAnchors() {
        let current: OverlayState = .visible(text: "draft and send", geometry: Self.geometry(), mode: .inline)

        XCTAssertTrue(
            SuggestionOverlayStabilityGate.shouldRePresent(
                currentOverlay: current,
                newText: "and send notes tomorrow",
                newCaretRect: Self.caretRect,
                newInputFrameRect: Self.inputFrame,
                newFocusChangeSequence: 7
            )
        )
    }

    /// A caret move within the tolerance (post-insertion AX noise, or an exact-advance residual) is
    /// held — this is the per-accept stillness the fix is for.
    func test_caretMoveWithinTolerance_holdsGeometry() {
        let current: OverlayState = .visible(text: "and send", geometry: Self.geometry(), mode: .inline)

        XCTAssertFalse(
            SuggestionOverlayStabilityGate.shouldRePresent(
                currentOverlay: current,
                newText: "and send",
                newCaretRect: Self.caretRect.offsetBy(dx: 3, dy: 0),
                newInputFrameRect: Self.inputFrame,
                newFocusChangeSequence: 7
            )
        )
    }

    /// A caret move beyond the tolerance (a genuine caret jump, or accumulated advance drift) must
    /// re-anchor so the ghost does not detach from the real caret.
    func test_caretMoveBeyondTolerance_reAnchors() {
        let current: OverlayState = .visible(text: "and send", geometry: Self.geometry(), mode: .inline)

        XCTAssertTrue(
            SuggestionOverlayStabilityGate.shouldRePresent(
                currentOverlay: current,
                newText: "and send",
                newCaretRect: Self.caretRect.offsetBy(dx: 10, dy: 0),
                newInputFrameRect: Self.inputFrame,
                newFocusChangeSequence: 7
            )
        )
    }

    /// Vertical caret drift beyond the tolerance also re-anchors (line change / scroll).
    func test_caretMovedVerticallyBeyondTolerance_reAnchors() {
        let current: OverlayState = .visible(text: "and send", geometry: Self.geometry(), mode: .inline)

        XCTAssertTrue(
            SuggestionOverlayStabilityGate.shouldRePresent(
                currentOverlay: current,
                newText: "and send",
                newCaretRect: Self.caretRect.offsetBy(dx: 0, dy: 10),
                newInputFrameRect: Self.inputFrame,
                newFocusChangeSequence: 7
            )
        )
    }

    /// Exactly at the caret tolerance: a 6pt drift is absorbed (strict `>` comparison).
    func test_caretMoveAtExactTolerance_holdsGeometry() {
        let current: OverlayState = .visible(text: "and send", geometry: Self.geometry(), mode: .inline)

        XCTAssertFalse(
            SuggestionOverlayStabilityGate.shouldRePresent(
                currentOverlay: current,
                newText: "and send",
                newCaretRect: Self.caretRect.offsetBy(dx: 6, dy: 0),
                newInputFrameRect: Self.inputFrame,
                newFocusChangeSequence: 7
            )
        )
    }

    /// Window-drag case: the field's screen frame moves by whole-pixel amounts. The gate must
    /// re-anchor or the overlay will lag behind the dragged window.
    func test_inputFrameMovedBeyondTolerance_reAnchors() {
        let movedFrame = Self.inputFrame.offsetBy(dx: 12, dy: 0)
        let current: OverlayState = .visible(text: "draft and send", geometry: Self.geometry(), mode: .inline)

        XCTAssertTrue(
            SuggestionOverlayStabilityGate.shouldRePresent(
                currentOverlay: current,
                newText: "draft and send",
                newCaretRect: Self.caretRect,
                newInputFrameRect: movedFrame,
                newFocusChangeSequence: 7
            )
        )
    }

    /// Sub-pixel noise inside the 1pt tolerance must be swallowed — this is the actual
    /// post-accept regression we are guarding against.
    func test_inputFrameSubPixelNoise_holdsGeometry() {
        let nudgedFrame = Self.inputFrame.offsetBy(dx: 0.4, dy: -0.3)
        let current: OverlayState = .visible(text: "draft and send", geometry: Self.geometry(), mode: .inline)

        XCTAssertFalse(
            SuggestionOverlayStabilityGate.shouldRePresent(
                currentOverlay: current,
                newText: "draft and send",
                newCaretRect: Self.caretRect,
                newInputFrameRect: nudgedFrame,
                newFocusChangeSequence: 7
            )
        )
    }

    func test_inputFrameAppearedOrDisappeared_reAnchors() {
        let visibleWithFrame: OverlayState = .visible(
            text: "draft and send",
            geometry: Self.geometry(inputFrameRect: Self.inputFrame),
            mode: .inline
        )
        let visibleWithoutFrame: OverlayState = .visible(
            text: "draft and send",
            geometry: Self.geometry(inputFrameRect: nil),
            mode: .inline
        )

        XCTAssertTrue(
            SuggestionOverlayStabilityGate.shouldRePresent(
                currentOverlay: visibleWithFrame,
                newText: "draft and send",
                newCaretRect: Self.caretRect,
                newInputFrameRect: nil,
                newFocusChangeSequence: 7
            )
        )
        XCTAssertTrue(
            SuggestionOverlayStabilityGate.shouldRePresent(
                currentOverlay: visibleWithoutFrame,
                newText: "draft and send",
                newCaretRect: Self.caretRect,
                newInputFrameRect: Self.inputFrame,
                newFocusChangeSequence: 7
            )
        )
    }

    /// Exactly at the 1pt boundary: drift of 1.0pt is absorbed (strict `>` comparison).
    /// Pins the contract so a future change to `>=` would flip a documented branch and fail here.
    func test_inputFrameAtExactTolerance_holdsGeometry() {
        let exactFrame = Self.inputFrame.offsetBy(dx: 1.0, dy: 0)
        let current: OverlayState = .visible(text: "draft and send", geometry: Self.geometry(), mode: .inline)

        XCTAssertFalse(
            SuggestionOverlayStabilityGate.shouldRePresent(
                currentOverlay: current,
                newText: "draft and send",
                newCaretRect: Self.caretRect,
                newInputFrameRect: exactFrame,
                newFocusChangeSequence: 7
            )
        )
    }

    func test_bothFramesNil_holdsGeometry() {
        let current: OverlayState = .visible(
            text: "draft and send",
            geometry: Self.geometry(inputFrameRect: nil),
            mode: .inline
        )

        XCTAssertFalse(
            SuggestionOverlayStabilityGate.shouldRePresent(
                currentOverlay: current,
                newText: "draft and send",
                newCaretRect: Self.caretRect,
                newInputFrameRect: nil,
                newFocusChangeSequence: 7
            )
        )
    }

    // MARK: - Post-insertion sync window

    func test_awaitingPostInsertionSync_holdsEvenAcrossAWordWidthOfCaretDrift() {
        // The +30ms refresh racing the host publish reads the PRE-insertion caret, a full accepted
        // word left of where the overlay correctly sits. The drift tolerance cannot tell that from
        // a genuine caret move; only the awaiting flag can, and it must win. This is the TextEdit
        // left-then-right accept jitter.
        let current: OverlayState = .visible(
            text: " again",
            geometry: Self.geometry(caretRect: CGRect(x: 180, y: 210, width: 2, height: 18)),
            mode: .inline
        )

        XCTAssertFalse(
            SuggestionOverlayStabilityGate.shouldRePresent(
                currentOverlay: current,
                newText: " again",
                newCaretRect: Self.caretRect,
                newInputFrameRect: Self.inputFrame,
                newFocusChangeSequence: 7,
                isAwaitingPostInsertionSync: true
            )
        )
    }

    func test_awaitingPostInsertionSync_stillReAnchorsOnFieldOrTextChange() {
        // The hold only covers stale geometry for the same field and text: a real field switch or
        // a text change mid-window must keep re-anchoring.
        let current: OverlayState = .visible(
            text: " again",
            geometry: Self.geometry(),
            mode: .inline
        )

        XCTAssertTrue(
            SuggestionOverlayStabilityGate.shouldRePresent(
                currentOverlay: current,
                newText: " again",
                newCaretRect: Self.caretRect,
                newInputFrameRect: Self.inputFrame,
                newFocusChangeSequence: 8,
                isAwaitingPostInsertionSync: true
            )
        )
        XCTAssertTrue(
            SuggestionOverlayStabilityGate.shouldRePresent(
                currentOverlay: current,
                newText: " different tail",
                newCaretRect: Self.caretRect,
                newInputFrameRect: Self.inputFrame,
                newFocusChangeSequence: 7,
                isAwaitingPostInsertionSync: true
            )
        )
    }

    func test_syncCleared_wordWidthDriftReAnchorsAgain() {
        // Once the host publishes (the sentinel clears), the same drift must re-anchor: that is
        // the legitimate settle onto the real caret.
        let current: OverlayState = .visible(
            text: " again",
            geometry: Self.geometry(caretRect: CGRect(x: 180, y: 210, width: 2, height: 18)),
            mode: .inline
        )

        XCTAssertTrue(
            SuggestionOverlayStabilityGate.shouldRePresent(
                currentOverlay: current,
                newText: " again",
                newCaretRect: Self.caretRect,
                newInputFrameRect: Self.inputFrame,
                newFocusChangeSequence: 7,
                isAwaitingPostInsertionSync: false
            )
        )
    }
}
