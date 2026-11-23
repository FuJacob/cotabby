import AppKit
import XCTest
@testable import Cotabby

/// Drives a real `OverlayController` through show, hold, advance and hide. No calibrator is
/// injected and every geometry is one Accessibility placed exactly, so nothing here captures the
/// screen: the presentations are applied synchronously and can be asserted on directly.
@MainActor
final class OverlayControllerLifecycleTests: XCTestCase {
    private var settings: SuggestionSettingsModel!
    private var overlay: OverlayController!
    private var publishedStates: [OverlayState] = []

    override func setUp() {
        super.setUp()
        settings = SuggestionSettingsModel(configuration: .standard, userDefaults: IsolatedUserDefaults.make())
        overlay = OverlayController(suggestionSettings: settings)
        publishedStates = []
        overlay.onStateChange = { [weak self] state in
            self?.publishedStates.append(state)
        }
    }

    override func tearDown() {
        // Takes the panel off screen before the controller is released.
        overlay.hide(reason: "test finished")
        overlay = nil
        settings = nil
        super.tearDown()
    }

    /// A native field's exact caret at the end of its line, well inside any screen.
    private func nativeGeometry(isCaretAtEndOfLine: Bool = true) -> SuggestionOverlayGeometry {
        SuggestionOverlayGeometry(
            caretRect: CGRect(x: 200, y: 300, width: 2, height: 18),
            inputFrameRect: CGRect(x: 100, y: 290, width: 600, height: 40),
            caretQuality: .exact,
            isCaretAtEndOfLine: isCaretAtEndOfLine,
            observedCharWidth: nil,
            isRightToLeft: false,
            focusedInputIdentityKey: 1
        )
    }

    /// A web field that has published "hello" on its line while its caret still sits at the line's
    /// left edge (`CaretLagPolicy`).
    private func laggingWebGeometry() -> SuggestionOverlayGeometry {
        SuggestionOverlayGeometry(
            caretRect: CGRect(x: 200, y: 300, width: 2, height: 18),
            inputFrameRect: CGRect(x: 100, y: 290, width: 600, height: 40),
            caretQuality: .exact,
            observedCharWidth: nil,
            isRightToLeft: false,
            focusedInputIdentityKey: 2,
            hostTextMetrics: HostTextMetrics(lineRect: CGRect(x: 200, y: 300, width: 400, height: 18)),
            isWebContentField: true,
            lineTextBeforeCaret: "hello"
        )
    }

    private func assertInline(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .visible(let shown, _, let mode) = overlay.state else {
            return XCTFail("expected a visible overlay, got \(overlay.state)", file: file, line: line)
        }
        XCTAssertEqual(shown, text, file: file, line: line)
        XCTAssertEqual(mode, .inline, file: file, line: line)
    }

    // MARK: - Show and hide

    func test_anExactEndOfLineCaretPresentsInline() {
        overlay.showSuggestion("hello world", geometry: nativeGeometry())

        assertInline("hello world")
        XCTAssertNil(overlay.heldPresentationText)
        XCTAssertEqual(publishedStates.count, 1)
        XCTAssertEqual(publishedStates.last, overlay.state)
    }

    func test_anEmptySuggestionHides() {
        overlay.showSuggestion("hello world", geometry: nativeGeometry())
        overlay.showSuggestion("", geometry: nativeGeometry())

        XCTAssertEqual(overlay.state, .hidden(reason: "Overlay not shown because the suggestion was empty."))
        XCTAssertEqual(publishedStates.count, 2)
    }

    func test_hidingRecordsTheReason() {
        overlay.showSuggestion("hello world", geometry: nativeGeometry())
        overlay.hide(reason: "focus left the field")

        XCTAssertEqual(overlay.state, .hidden(reason: "focus left the field"))
        XCTAssertEqual(publishedStates.last, overlay.state)
    }

    // MARK: - Mode fallbacks

    func test_alwaysPopupPresentsTheCard() {
        settings.setMirrorPreference(.alwaysMirror)
        let geometry = nativeGeometry()
        overlay.showSuggestion("hello world", geometry: geometry)

        XCTAssertEqual(overlay.state, .visible(text: "hello world", geometry: geometry, mode: .mirror(reason: .userPreference)))
    }

    /// An explicit inline preference keeps the policy's inline pick for a mid-line caret; the
    /// controller itself then declines to paint over the host's text and shows the card.
    func test_anInlinePinDeclinesToPaintOverTextAfterTheCaret() {
        settings.setMirrorPreference(.alwaysInline)
        let geometry = nativeGeometry(isCaretAtEndOfLine: false)
        overlay.showSuggestion("hello world", geometry: geometry)

        XCTAssertEqual(overlay.state, .visible(text: "hello world", geometry: geometry, mode: .mirror(reason: .caretMidLine)))
    }

    // MARK: - Advancing the inline ghost

    func test_advancingPastAnInsertedPrefixKeepsTheGhostAndMovesItsCaret() throws {
        let geometry = nativeGeometry()
        overlay.showSuggestion("hello world", geometry: geometry)

        XCTAssertTrue(overlay.advanceInline(to: " world", insertedText: "hello"))

        guard case .visible(let text, let advanced, let mode) = overlay.state else {
            return XCTFail("expected a visible overlay, got \(overlay.state)")
        }
        XCTAssertEqual(text, " world")
        XCTAssertEqual(mode, .inline)
        XCTAssertGreaterThan(advanced.caretRect.minX, geometry.caretRect.minX, "the published caret follows the consumed prefix")
        XCTAssertEqual(publishedStates.count, 2)

        // The same session keeps accounting for what has landed.
        XCTAssertTrue(overlay.advanceInline(to: "world", insertedText: " "))
        assertInline("world")
    }

    func test_anAdvanceTheSessionCannotAccountForIsRefused() {
        overlay.showSuggestion("hello world", geometry: nativeGeometry())
        let shown = overlay.state

        XCTAssertFalse(overlay.advanceInline(to: " world", insertedText: "jello"), "the inserted text is not the ghost's prefix")
        XCTAssertFalse(overlay.advanceInline(to: " there", insertedText: "hello"), "the remainder is not the ghost's")
        XCTAssertFalse(overlay.advanceInline(to: "hello world", insertedText: ""), "nothing landed")
        XCTAssertFalse(overlay.advanceInline(to: "", insertedText: "hello world"), "nothing would remain to draw")
        XCTAssertEqual(overlay.state, shown)
        XCTAssertEqual(publishedStates.count, 1)
    }

    func test_onlyAnInlineGhostCanBeAdvanced() {
        XCTAssertFalse(overlay.advanceInline(to: " world", insertedText: "hello"), "nothing is presented")

        settings.setMirrorPreference(.alwaysMirror)
        overlay.showSuggestion("hello world", geometry: nativeGeometry())
        XCTAssertFalse(overlay.advanceInline(to: " world", insertedText: "hello"), "the card is not slid")

        overlay.hide(reason: "done")
        XCTAssertFalse(overlay.advanceInline(to: " world", insertedText: "hello"), "a hidden ghost has no session")
    }

    // MARK: - Held presentations

    /// A caret the host has not moved for text it already published is not presented at: the show
    /// is held, the previous presentation stays as it was, and nothing is published.
    func test_aLaggingCaretHoldsThePresentationWithoutChangingState() {
        overlay.showSuggestion("hello world", geometry: nativeGeometry())
        let shown = overlay.state

        overlay.showSuggestion(" there", geometry: laggingWebGeometry())

        XCTAssertEqual(overlay.heldPresentationText, " there")
        XCTAssertEqual(overlay.state, shown)
        XCTAssertEqual(publishedStates.count, 1)
    }

    func test_hidingClearsAHeldPresentation() {
        overlay.showSuggestion(" there", geometry: laggingWebGeometry())
        XCTAssertEqual(overlay.heldPresentationText, " there")
        XCTAssertEqual(overlay.state, .hidden(reason: "Overlay idle."))

        overlay.hide(reason: "typed on")

        XCTAssertNil(overlay.heldPresentationText)
        XCTAssertEqual(overlay.state, .hidden(reason: "typed on"))
    }

    func test_aShowThatIsAppliedReplacesAHeldOne() {
        overlay.showSuggestion(" there", geometry: laggingWebGeometry())
        overlay.showSuggestion("hello world", geometry: nativeGeometry())

        XCTAssertNil(overlay.heldPresentationText)
        assertInline("hello world")
    }
}
