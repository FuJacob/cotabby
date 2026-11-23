import CoreGraphics
import XCTest
@testable import Cotabby

/// The overlay's presented/held bookkeeping, driven as pure transitions. A plain string stands in
/// for the controller's inline session: the lifecycle only decides when one exists.
@MainActor
final class OverlayPresentationLifecycleTests: XCTestCase {
    private typealias Lifecycle = OverlayPresentationLifecycle<String>

    private var geometry: SuggestionOverlayGeometry { CotabbyTestFixtures.overlayGeometry() }
    private var advancedGeometry: SuggestionOverlayGeometry {
        geometry.withCaretRect(CGRect(x: 60, y: 20, width: 2, height: 18))
    }

    private func inlineLifecycle() -> Lifecycle {
        var lifecycle = Lifecycle()
        lifecycle.beginShow()
        lifecycle.presentInline("session", text: "hello world", geometry: geometry)
        return lifecycle
    }

    func test_startsHiddenWithNothingHeld() {
        let lifecycle = Lifecycle()

        XCTAssertEqual(lifecycle.state, .hidden(reason: "Overlay idle."))
        XCTAssertNil(lifecycle.heldText)
        XCTAssertNil(lifecycle.inlineSession)
        XCTAssertFalse(lifecycle.isPanelTakenDownForCapture)
    }

    // MARK: - Presentations

    func test_anInlinePresentationCarriesItsSession() {
        let lifecycle = inlineLifecycle()

        XCTAssertEqual(lifecycle.state, .visible(text: "hello world", geometry: geometry, mode: .inline))
        XCTAssertEqual(lifecycle.inlineSession, "session")
    }

    func test_theCardReplacesAnInlineGhostAndItsSession() {
        var lifecycle = inlineLifecycle()
        lifecycle.beginShow()
        lifecycle.presentMirror(text: "card", geometry: geometry, reason: .caretMidLine)

        XCTAssertEqual(lifecycle.state, .visible(text: "card", geometry: geometry, mode: .mirror(reason: .caretMidLine)))
        XCTAssertNil(lifecycle.inlineSession, "a session exists only while an inline ghost is presented")
    }

    func test_hidingDropsTheSessionAndRecordsWhy() {
        var lifecycle = inlineLifecycle()
        lifecycle.hide(reason: "typed past it")

        XCTAssertEqual(lifecycle.state, .hidden(reason: "typed past it"))
        XCTAssertNil(lifecycle.inlineSession)
    }

    // MARK: - Redraws and advances of the inline ghost

    func test_replacingTheSessionLeavesWhatTheCoordinatorWasTold() {
        var lifecycle = inlineLifecycle()

        XCTAssertTrue(lifecycle.replaceInlineSession("recalibrated"))
        XCTAssertEqual(lifecycle.inlineSession, "recalibrated")
        XCTAssertEqual(lifecycle.state, .visible(text: "hello world", geometry: geometry, mode: .inline))
    }

    func test_advancingMovesTheSessionAndThePublishedTextTogether() {
        var lifecycle = inlineLifecycle()

        XCTAssertTrue(lifecycle.advanceInline(to: "advanced", remainingText: " world", geometry: advancedGeometry))
        XCTAssertEqual(lifecycle.inlineSession, "advanced")
        XCTAssertEqual(lifecycle.state, .visible(text: " world", geometry: advancedGeometry, mode: .inline))
    }

    func test_aSessionCannotBeReplacedOrAdvancedUnlessAnInlineGhostIsPresented() {
        var hidden = Lifecycle()
        XCTAssertFalse(hidden.replaceInlineSession("late"))
        XCTAssertFalse(hidden.advanceInline(to: "late", remainingText: "x", geometry: geometry))
        XCTAssertEqual(hidden.state, .hidden(reason: "Overlay idle."))

        var card = Lifecycle()
        card.beginShow()
        card.presentMirror(text: "card", geometry: geometry, reason: .userPreference)
        XCTAssertFalse(card.replaceInlineSession("late"), "a calibration that lands after the card took over changes nothing")
        XCTAssertFalse(card.advanceInline(to: "late", remainingText: "x", geometry: geometry))
        XCTAssertNil(card.inlineSession)
        XCTAssertEqual(card.state, .visible(text: "card", geometry: geometry, mode: .mirror(reason: .userPreference)))
    }

    // MARK: - Holds

    /// A held presentation is not applied: the previous one stays exactly as it was, which is why
    /// the coordinator needs the held text to recognise its own in-flight present.
    func test_aHoldLeavesThePreviousPresentationInPlace() {
        var lifecycle = inlineLifecycle()
        lifecycle.beginShow()
        lifecycle.holdForCaretLag(text: "next")

        XCTAssertEqual(lifecycle.heldText, "next")
        XCTAssertEqual(lifecycle.state, .visible(text: "hello world", geometry: geometry, mode: .inline))
        XCTAssertEqual(lifecycle.inlineSession, "session")
        XCTAssertFalse(lifecycle.isPanelTakenDownForCapture, "a caret-lag hold leaves the ghost on screen")
    }

    func test_everyNewShowRetiresTheHold() {
        var lifecycle = Lifecycle()
        lifecycle.beginShow()
        lifecycle.holdForCaretLag(text: "first")
        lifecycle.beginShow()

        XCTAssertNil(lifecycle.heldText)
    }

    func test_hidingRetiresTheHold() {
        var lifecycle = Lifecycle()
        lifecycle.beginShow()
        _ = lifecycle.holdForPixelCapture(text: "held", panelTakenDown: true)
        lifecycle.hide(reason: "focus left")

        XCTAssertNil(lifecycle.heldText)
        XCTAssertFalse(lifecycle.isPanelTakenDownForCapture)
    }

    func test_aPixelReadLandsOnlyWhileItsHoldIsTheLatestRequest() {
        var lifecycle = Lifecycle()
        lifecycle.beginShow()
        let ticket = lifecycle.holdForPixelCapture(text: "held", panelTakenDown: false)
        XCTAssertTrue(lifecycle.isCurrent(ticket))
        XCTAssertEqual(lifecycle.heldText, "held")

        // The re-entered show that applies the read retires the hold it came from.
        lifecycle.beginShow()
        XCTAssertFalse(lifecycle.isCurrent(ticket))
    }

    func test_aNewerShowRetiresAnOlderPixelReadEvenIfItHoldsAgain() {
        var lifecycle = Lifecycle()
        lifecycle.beginShow()
        let older = lifecycle.holdForPixelCapture(text: "older", panelTakenDown: false)
        lifecycle.beginShow()
        let newer = lifecycle.holdForPixelCapture(text: "newer", panelTakenDown: false)

        XCTAssertFalse(lifecycle.isCurrent(older), "the older read must not resurrect stale text")
        XCTAssertTrue(lifecycle.isCurrent(newer))
        XCTAssertEqual(lifecycle.heldText, "newer")
    }

    func test_hidingDuringAPixelReadDropsTheLateAnswer() {
        var lifecycle = inlineLifecycle()
        lifecycle.beginShow()
        let ticket = lifecycle.holdForPixelCapture(text: "held", panelTakenDown: true)
        lifecycle.hide(reason: "escape")

        XCTAssertFalse(lifecycle.isCurrent(ticket))
        XCTAssertEqual(lifecycle.state, .hidden(reason: "escape"))
    }

    /// With the ghost ordered out for the read there is nothing on screen to slide, although the
    /// inline presentation it belongs to is still the one the coordinator knows about.
    func test_thePanelCountsAsTakenDownOnlyForACoveredPixelRead() {
        var covered = inlineLifecycle()
        covered.beginShow()
        _ = covered.holdForPixelCapture(text: "held", panelTakenDown: true)
        XCTAssertTrue(covered.isPanelTakenDownForCapture)
        XCTAssertEqual(covered.inlineSession, "session")

        var uncovered = inlineLifecycle()
        uncovered.beginShow()
        _ = uncovered.holdForPixelCapture(text: "held", panelTakenDown: false)
        XCTAssertFalse(uncovered.isPanelTakenDownForCapture)

        covered.beginShow()
        XCTAssertFalse(covered.isPanelTakenDownForCapture, "the show that puts the ghost back clears it")
    }

    func test_advancingDoesNotRetireAHold() {
        var lifecycle = inlineLifecycle()
        lifecycle.beginShow()
        lifecycle.holdForCaretLag(text: "next")
        lifecycle.advanceInline(to: "advanced", remainingText: " world", geometry: advancedGeometry)

        XCTAssertEqual(lifecycle.heldText, "next")
    }
}
