import CoreGraphics
import XCTest
@testable import Cotabby

/// Tests for the post-accept overlay-stability gate.
///
/// The bug this gate fixes: after every Tab accept, AX returns slightly drifted `caretRect` /
/// `observedCharWidth` values for the same underlying field state. The +30ms post-insertion
/// reconcile used to call `presentOverlay` with those drifted values, producing a visible
/// one-frame "shift left and down then snap back". The gate stops the reconcile from
/// re-rendering when the field, text, and on-screen field bounds have not materially moved,
/// while still allowing legitimate context changes (window drag, field switch, text change)
/// to re-anchor the overlay.
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
                newInputFrameRect: Self.inputFrame,
                newFocusChangeSequence: 7
            )
        )
    }

    /// The exact scenario the gate exists for: text and field are identical, only the caret rect
    /// has drifted by a sub-pixel amount in the latest AX read. Holding the geometry is what
    /// prevents the post-accept jitter.
    func test_sameFieldSameTextStableFrame_holdsGeometry() {
        let current: OverlayState = .visible(text: "draft and send", geometry: Self.geometry())

        XCTAssertFalse(
            SuggestionOverlayStabilityGate.shouldRePresent(
                currentOverlay: current,
                newText: "draft and send",
                newInputFrameRect: Self.inputFrame,
                newFocusChangeSequence: 7
            )
        )
    }

    func test_focusSessionChanged_reAnchors() {
        let current: OverlayState = .visible(
            text: "draft and send",
            geometry: Self.geometry(focusChangeSequence: 7)
        )

        XCTAssertTrue(
            SuggestionOverlayStabilityGate.shouldRePresent(
                currentOverlay: current,
                newText: "draft and send",
                newInputFrameRect: Self.inputFrame,
                newFocusChangeSequence: 8
            )
        )
    }

    func test_displayedTextChanged_reAnchors() {
        let current: OverlayState = .visible(text: "draft and send", geometry: Self.geometry())

        XCTAssertTrue(
            SuggestionOverlayStabilityGate.shouldRePresent(
                currentOverlay: current,
                newText: "and send notes tomorrow",
                newInputFrameRect: Self.inputFrame,
                newFocusChangeSequence: 7
            )
        )
    }

    /// Window-drag case: the field's screen frame moves by whole-pixel amounts. The gate must
    /// re-anchor or the overlay will lag behind the dragged window.
    func test_inputFrameMovedBeyondTolerance_reAnchors() {
        let movedFrame = Self.inputFrame.offsetBy(dx: 12, dy: 0)
        let current: OverlayState = .visible(text: "draft and send", geometry: Self.geometry())

        XCTAssertTrue(
            SuggestionOverlayStabilityGate.shouldRePresent(
                currentOverlay: current,
                newText: "draft and send",
                newInputFrameRect: movedFrame,
                newFocusChangeSequence: 7
            )
        )
    }

    /// Sub-pixel noise inside the 1pt tolerance must be swallowed — this is the actual
    /// post-accept regression we are guarding against.
    func test_inputFrameSubPixelNoise_holdsGeometry() {
        let nudgedFrame = Self.inputFrame.offsetBy(dx: 0.4, dy: -0.3)
        let current: OverlayState = .visible(text: "draft and send", geometry: Self.geometry())

        XCTAssertFalse(
            SuggestionOverlayStabilityGate.shouldRePresent(
                currentOverlay: current,
                newText: "draft and send",
                newInputFrameRect: nudgedFrame,
                newFocusChangeSequence: 7
            )
        )
    }

    func test_inputFrameAppearedOrDisappeared_reAnchors() {
        let visibleWithFrame: OverlayState = .visible(
            text: "draft and send",
            geometry: Self.geometry(inputFrameRect: Self.inputFrame)
        )
        let visibleWithoutFrame: OverlayState = .visible(
            text: "draft and send",
            geometry: Self.geometry(inputFrameRect: nil)
        )

        XCTAssertTrue(
            SuggestionOverlayStabilityGate.shouldRePresent(
                currentOverlay: visibleWithFrame,
                newText: "draft and send",
                newInputFrameRect: nil,
                newFocusChangeSequence: 7
            )
        )
        XCTAssertTrue(
            SuggestionOverlayStabilityGate.shouldRePresent(
                currentOverlay: visibleWithoutFrame,
                newText: "draft and send",
                newInputFrameRect: Self.inputFrame,
                newFocusChangeSequence: 7
            )
        )
    }

    func test_bothFramesNil_holdsGeometry() {
        let current: OverlayState = .visible(
            text: "draft and send",
            geometry: Self.geometry(inputFrameRect: nil)
        )

        XCTAssertFalse(
            SuggestionOverlayStabilityGate.shouldRePresent(
                currentOverlay: current,
                newText: "draft and send",
                newInputFrameRect: nil,
                newFocusChangeSequence: 7
            )
        )
    }
}
