import CoreGraphics
import XCTest
@testable import Cotabby

/// Tests for the focused-context generation buffer.
///
/// `ContextBuffer` is a small type, but it protects a major async invariant: old model results
/// must not be applied after the user changes fields or text.
final class ContextBufferTests: XCTestCase {
    /// App-hosted macOS tests have shown deallocation crashes for short-lived main-actor objects.
    /// Retaining these helpers for the process lifetime mirrors the existing settings-model tests.
    private static var retainedBuffers: [ContextBuffer] = []

    func test_materialize_assignsFirstGenerationAndStoresCurrentContext() {
        runOnMainActor {
            let buffer = makeBuffer()
            let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello")

            let context = buffer.materialize(from: snapshot)

            XCTAssertEqual(context.generation, 1)
            XCTAssertEqual(buffer.currentContext, context)
        }
    }

    func test_materialize_keepsGenerationForIdenticalProcessAndContent() {
        runOnMainActor {
            let buffer = makeBuffer()
            let first = buffer.materialize(
                from: CotabbyTestFixtures.focusedInputSnapshot(
                    processIdentifier: 123,
                    elementIdentifier: "field-a",
                    precedingText: "Hello"
                )
            )
            let second = buffer.materialize(
                from: CotabbyTestFixtures.focusedInputSnapshot(
                    processIdentifier: 123,
                    elementIdentifier: "field-b",
                    precedingText: "Hello"
                )
            )

            XCTAssertEqual(second.generation, first.generation)
        }
    }

    func test_materialize_incrementsGenerationWhenContentChanges() {
        runOnMainActor {
            let buffer = makeBuffer()
            let first = buffer.materialize(from: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello"))
            let second = buffer.materialize(from: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello!"))

            XCTAssertEqual(second.generation, first.generation + 1)
        }
    }

    func test_materialize_incrementsGenerationWhenProcessChanges() {
        runOnMainActor {
            let buffer = makeBuffer()
            let first = buffer.materialize(
                from: CotabbyTestFixtures.focusedInputSnapshot(processIdentifier: 123)
            )
            let second = buffer.materialize(
                from: CotabbyTestFixtures.focusedInputSnapshot(processIdentifier: 456)
            )

            XCTAssertEqual(second.generation, first.generation + 1)
        }
    }

    func test_clearDropsCurrentContextAndAdvancesFutureGeneration() {
        runOnMainActor {
            let buffer = makeBuffer()
            let first = buffer.materialize(from: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello"))

            buffer.clear()

            XCTAssertNil(buffer.currentContext)
            let second = buffer.materialize(from: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello"))
            XCTAssertGreaterThan(second.generation, first.generation)
        }
    }

    @MainActor
    private func makeBuffer() -> ContextBuffer {
        let buffer = ContextBuffer()
        Self.retainedBuffers.append(buffer)
        return buffer
    }
}

/// Tests for the storage wrapper around active suggestion session state.
///
/// The coordinator owns the user-facing state machine, while this helper owns the mutable details:
/// current context, active tail, and the AX-lag sentinel after Tab insertion.
final class SuggestionInteractionStateTests: XCTestCase {
    private static var retainedStates: [SuggestionInteractionState] = []

    func test_startSessionStoresActiveSessionAndClearsPendingInsertionSentinel() {
        runOnMainActor {
            let state = makeState()
            let context = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello")

            let session = state.startSession(
                fullText: " world",
                liveContext: context,
                latency: 0.2
            )

            XCTAssertEqual(state.activeSession, session)
            XCTAssertNil(state.pendingInsertionConsumedCount)
            XCTAssertFalse(state.isAwaitingPostInsertionSync)
        }
    }

    func test_prepareAcceptance_returnsReadyForVisibleMatchingOverlay() {
        runOnMainActor {
            let state = makeState()
            let context = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello")
            _ = state.startSession(fullText: " world again", liveContext: context, latency: 0.1)
            let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello")

            let preparation = state.prepareAcceptance(
                from: snapshot,
                overlayState: .visible(
                    text: " world again",
                    geometry: CotabbyTestFixtures.overlayGeometry(caretRect: context.caretRect),
                    mode: .inline
                ),
                granularity: .word
            )

            guard case let .ready(liveContext, session, acceptedChunk) = preparation else {
                XCTFail("Expected acceptance to be ready")
                return
            }
            XCTAssertEqual(liveContext.precedingText, "Hello")
            XCTAssertEqual(session.remainingText, " world again")
            XCTAssertEqual(acceptedChunk, " world")
        }
    }

    func test_prepareAcceptance_rejectsVisibleOverlayTextMismatch() {
        runOnMainActor {
            let state = makeState()
            let context = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello")
            _ = state.startSession(fullText: " world again", liveContext: context, latency: 0.1)

            let preparation = state.prepareAcceptance(
                from: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello"),
                overlayState: .visible(
                    text: " different",
                    geometry: CotabbyTestFixtures.overlayGeometry(caretRect: context.caretRect),
                    mode: .inline
                ),
                granularity: .word
            )

            guard case let .invalid(reason) = preparation else {
                XCTFail("Expected overlay mismatch to reject acceptance")
                return
            }
            XCTAssertEqual(
                reason,
                "Key passed through because no visible ghost text matched the ready suggestion."
            )
        }
    }

    func test_prepareAcceptance_allowsHiddenOverlayWhenProcessStillMatches() {
        runOnMainActor {
            let state = makeState()
            let context = CotabbyTestFixtures.focusedInputContext(
                processIdentifier: 123,
                precedingText: "Hello"
            )
            _ = state.startSession(fullText: " world again", liveContext: context, latency: 0.1)

            let preparation = state.prepareAcceptance(
                from: CotabbyTestFixtures.focusedInputSnapshot(
                    processIdentifier: 123,
                    precedingText: "Different live text"
                ),
                overlayState: .hidden(reason: "waiting for caret sync"),
                granularity: .word
            )

            guard case let .ready(_, _, acceptedChunk) = preparation else {
                XCTFail("Expected hidden overlay to allow acceptance during sync")
                return
            }
            XCTAssertEqual(acceptedChunk, " world")
        }
    }

    func test_prepareAcceptance_phraseGranularityAcceptsThroughSentenceTerminator() {
        runOnMainActor {
            let state = makeState()
            let context = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello")
            _ = state.startSession(fullText: " hello world. next", liveContext: context, latency: 0.1)
            let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello")

            let preparation = state.prepareAcceptance(
                from: snapshot,
                overlayState: .visible(
                    text: " hello world. next",
                    geometry: CotabbyTestFixtures.overlayGeometry(caretRect: context.caretRect),
                    mode: .inline
                ),
                granularity: .phrase
            )

            guard case let .ready(_, session, acceptedChunk) = preparation else {
                XCTFail("Expected phrase acceptance to be ready")
                return
            }
            // Phrase mode must delegate to nextAcceptancePhrase: the accepted chunk spans every word
            // up to the sentence terminator, not just the first word a .word accept would take.
            XCTAssertEqual(session.remainingText, " hello world. next")
            XCTAssertEqual(acceptedChunk, " hello world.")
            XCTAssertEqual(SuggestionSessionReconciler.nextAcceptanceChunk(from: session.remainingText), " hello")
        }
    }

    func test_commitAcceptedChunkAdvancesSessionAndSetsPendingInsertionSentinel() {
        runOnMainActor {
            let state = makeState()
            let context = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello", generation: 7)
            let session = state.startSession(fullText: " world again", liveContext: context, latency: 0.1)

            let progress = state.commitAcceptedChunk(
                " world",
                liveContext: context,
                session: session
            )

            guard case let .advanced(advancedSession, generation) = progress else {
                XCTFail("Expected partial acceptance to keep the session alive")
                return
            }
            XCTAssertEqual(generation, 7)
            XCTAssertEqual(advancedSession.acceptedText, " world")
            XCTAssertEqual(advancedSession.remainingText, " again")
            XCTAssertEqual(state.activeSession, advancedSession)
            XCTAssertEqual(state.pendingInsertionConsumedCount, 6)
            XCTAssertTrue(state.isAwaitingPostInsertionSync)
        }
    }

    func test_commitAcceptedChunkClearsSessionWhenTailIsExhausted() {
        runOnMainActor {
            let state = makeState()
            let context = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello", generation: 4)
            let session = state.startSession(fullText: " world", liveContext: context, latency: 0.1)

            let progress = state.commitAcceptedChunk(
                " world",
                liveContext: context,
                session: session
            )

            guard case let .exhausted(generation) = progress else {
                XCTFail("Expected final chunk to exhaust the session")
                return
            }
            XCTAssertEqual(generation, 4)
            XCTAssertNil(state.activeSession)
            XCTAssertNil(state.pendingInsertionConsumedCount)
        }
    }

    func test_reconcileActiveSessionStoresAdvancedSession() {
        runOnMainActor {
            let state = makeState()
            let context = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello")
            _ = state.startSession(fullText: " world again", liveContext: context, latency: 0.1)

            let reconciliation = state.reconcileActiveSession(
                with: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello world")
            )

            guard case let .valid(_, session, advancement) = reconciliation else {
                XCTFail("Expected live consumed text to advance stored session")
                return
            }
            XCTAssertEqual(session.remainingText, " again")
            XCTAssertEqual(state.activeSession?.remainingText, " again")
            XCTAssertEqual(advancement?.actionSummary, "Suggestion tail advanced from live editor state.")
        }
    }

    func test_advanceIfTypedCharactersMatchRequiresExpectedStoredSession() {
        runOnMainActor {
            let state = makeState()
            let context = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello")
            let storedSession = state.startSession(fullText: " world again", liveContext: context, latency: 0.1)
            let differentExpectedSession = storedSession.advancing(by: 1)

            XCTAssertNil(
                state.advanceIfTypedCharactersMatch(
                    " world",
                    expectedSession: differentExpectedSession
                )
            )

            let advanced = state.advanceIfTypedCharactersMatch(
                " world",
                expectedSession: storedSession
            )
            XCTAssertEqual(advanced?.remainingText, " again")
            XCTAssertEqual(state.activeSession?.remainingText, " again")
        }
    }

    @MainActor
    private func makeState() -> SuggestionInteractionState {
        let state = SuggestionInteractionState()
        Self.retainedStates.append(state)
        return state
    }
}

/// Tests for async work identity and cancellation.
///
/// The controller gives the coordinator "latest request wins" semantics. That is the protection
/// against older debounce or generation tasks writing stale results after the user keeps typing.
final class SuggestionWorkControllerTests: XCTestCase {
    private var retainedControllers: [SuggestionWorkController] = []

    override func tearDown() {
        runOnMainActor {
            retainedControllers.forEach { $0.cancelAll() }
            retainedControllers.removeAll()
        }
        super.tearDown()
    }

    func test_replaceDebouncedWorkRunsOnlyLatestOperation() {
        let operationRan = expectation(description: "latest debounce runs")
        let recorder = runOnMainActor { WorkRecorder() }
        var firstID: UInt64 = 0
        var secondID: UInt64 = 0

        runOnMainActor {
            let controller = makeController()
            firstID = controller.replaceDebouncedWork(delayMilliseconds: 20) { workID in
                recorder.record(workID)
            }
            secondID = controller.replaceDebouncedWork(delayMilliseconds: 1) { workID in
                recorder.record(workID)
                operationRan.fulfill()
            }
        }

        wait(for: [operationRan], timeout: 1.0)

        runOnMainActor {
            XCTAssertEqual(firstID, 1)
            XCTAssertEqual(secondID, 2)
            XCTAssertEqual(recorder.workIDs, [2])
        }
    }

    func test_cancelAllPreventsPendingDebouncedOperation() {
        let operationRan = expectation(description: "cancelled debounce should not run")
        operationRan.isInverted = true
        var currentWorkID: UInt64 = 0

        runOnMainActor {
            let controller = makeController()
            _ = controller.replaceDebouncedWork(delayMilliseconds: 1) { _ in
                operationRan.fulfill()
            }
            controller.cancelAll()
            currentWorkID = controller.currentWorkID
        }

        wait(for: [operationRan], timeout: 0.1)
        XCTAssertEqual(currentWorkID, 2)
    }

    func test_replaceGenerationWorkRunsForCurrentWorkID() {
        let generationRan = expectation(description: "current generation runs")

        runOnMainActor {
            let controller = makeController()
            let workID = controller.replaceDebouncedWork(delayMilliseconds: 1_000) { _ in }
            controller.replaceGenerationWork(for: workID) {
                generationRan.fulfill()
            }
        }

        wait(for: [generationRan], timeout: 1.0)
    }

    func test_replaceGenerationWorkRejectsStaleWorkID() {
        let generationRan = expectation(description: "stale generation should not run")
        generationRan.isInverted = true

        runOnMainActor {
            let controller = makeController()
            let staleWorkID = controller.replaceDebouncedWork(delayMilliseconds: 1_000) { _ in }
            controller.cancelAll()
            controller.replaceGenerationWork(for: staleWorkID) {
                generationRan.fulfill()
            }
        }

        wait(for: [generationRan], timeout: 0.1)
    }

    @MainActor
    private func makeController() -> SuggestionWorkController {
        let controller = SuggestionWorkController()
        retainedControllers.append(controller)
        return controller
    }
}

/// Tests for the small adapter between coordinator intent and overlay-controller calls.
final class SuggestionOverlayPresenterTests: XCTestCase {
    func test_presentEmptyTextHidesOverlay() {
        runOnMainActor {
            let overlayController = FakeOverlayController()
            let presenter = SuggestionOverlayPresenter(overlayController: overlayController)

            let message = presenter.present(
                text: "   ",
                geometry: CotabbyTestFixtures.overlayGeometry(caretRect: .zero),
                previousState: overlayController.state
            )

            XCTAssertEqual(message, "Overlay hidden because the suggestion text was empty.")
            XCTAssertEqual(overlayController.hideReasons, ["Overlay hidden because the suggestion text was empty."])
            XCTAssertEqual(overlayController.showCallCount, 0)
        }
    }

    func test_presentNewTextShowsOverlayAndReturnsDisplayedMessage() {
        runOnMainActor {
            let overlayController = FakeOverlayController()
            let presenter = SuggestionOverlayPresenter(overlayController: overlayController)
            let caretRect = CGRect(x: 10, y: 20, width: 2, height: 18)

            let message = presenter.present(
                text: " world",
                geometry: CotabbyTestFixtures.overlayGeometry(caretRect: caretRect),
                previousState: overlayController.state
            )

            XCTAssertEqual(message, "Displayed ghost text near the caret.")
            XCTAssertEqual(overlayController.lastShownText, " world")
            XCTAssertEqual(overlayController.lastShownCaretRect, caretRect)
            XCTAssertEqual(overlayController.showCallCount, 1)
        }
    }

    func test_presentIdenticalVisibleStateDoesNotCallOverlayAgain() {
        runOnMainActor {
            let caretRect = CGRect(x: 10, y: 20, width: 2, height: 18)
            let geometry = CotabbyTestFixtures.overlayGeometry(caretRect: caretRect)
            let overlayController = FakeOverlayController(
                initialState: .visible(text: " world", geometry: geometry, mode: .inline)
            )
            let presenter = SuggestionOverlayPresenter(overlayController: overlayController)

            let message = presenter.present(
                text: " world",
                geometry: geometry,
                previousState: overlayController.state
            )

            XCTAssertNil(message)
            XCTAssertEqual(overlayController.showCallCount, 0)
        }
    }

    func test_presentSameTextAtNewCaretReturnsMovedMessage() {
        runOnMainActor {
            let previousRect = CGRect(x: 10, y: 20, width: 2, height: 18)
            let nextRect = CGRect(x: 30, y: 20, width: 2, height: 18)
            let overlayController = FakeOverlayController()
            let presenter = SuggestionOverlayPresenter(overlayController: overlayController)

            let message = presenter.present(
                text: " world",
                geometry: CotabbyTestFixtures.overlayGeometry(caretRect: nextRect),
                previousState: .visible(
                    text: " world",
                    geometry: CotabbyTestFixtures.overlayGeometry(caretRect: previousRect),
                    mode: .inline
                )
            )

            XCTAssertEqual(message, "Moved ghost text to the latest caret position.")
        }
    }

    func test_presentSameTextAndCaretWithNewQualityReturnsStylingMessage() {
        runOnMainActor {
            let caretRect = CGRect(x: 10, y: 20, width: 2, height: 18)
            let overlayController = FakeOverlayController()
            let presenter = SuggestionOverlayPresenter(overlayController: overlayController)

            let message = presenter.present(
                text: " world",
                geometry: CotabbyTestFixtures.overlayGeometry(
                    caretRect: caretRect,
                    caretQuality: .derived
                ),
                previousState: .visible(
                    text: " world",
                    geometry: CotabbyTestFixtures.overlayGeometry(caretRect: caretRect),
                    mode: .inline
                )
            )

            XCTAssertEqual(message, "Updated ghost text styling for the latest caret quality.")
        }
    }

    func test_hideForwardsReasonToOverlayController() {
        runOnMainActor {
            let overlayController = FakeOverlayController()
            let presenter = SuggestionOverlayPresenter(overlayController: overlayController)

            let message = presenter.hide(reason: "Overlay hidden for test.")

            XCTAssertEqual(message, "Overlay hidden for test.")
            XCTAssertEqual(overlayController.hideReasons, ["Overlay hidden for test."])
        }
    }
}

final class SuggestionCaretPredictionTests: XCTestCase {
    func test_predictedCaretRectUsesObservedCharacterWidthForTrustedGeometry() {
        runOnMainActor {
            let oldRect = CGRect(x: 10, y: 20, width: 2, height: 18)

            let predicted = SuggestionCoordinator.predictedCaretRect(
                after: "abcd",
                oldCaretRect: oldRect,
                caretQuality: .exact,
                observedCharWidth: 7
            )

            XCTAssertEqual(predicted.origin.x, 38)
            XCTAssertEqual(predicted.origin.y, oldRect.origin.y)
            XCTAssertEqual(predicted.size, oldRect.size)
        }
    }

    func test_predictedCaretRectStillMovesForwardForEstimatedGeometry() {
        runOnMainActor {
            let oldRect = CGRect(x: 10, y: 20, width: 2, height: 18)

            let predicted = SuggestionCoordinator.predictedCaretRect(
                after: "abcd",
                oldCaretRect: oldRect,
                caretQuality: .estimated,
                observedCharWidth: 7
            )

            XCTAssertGreaterThan(predicted.origin.x, oldRect.origin.x)
            XCTAssertEqual(predicted.origin.y, oldRect.origin.y)
        }
    }
}

@MainActor
private final class FakeOverlayController: SuggestionOverlayControlling {
    var state: OverlayState
    var onStateChange: ((OverlayState) -> Void)?

    private(set) var showCallCount = 0
    private(set) var lastShownText: String?
    private(set) var lastShownCaretRect: CGRect?
    private(set) var lastShownGeometry: SuggestionOverlayGeometry?
    private(set) var hideReasons: [String] = []

    init(initialState: OverlayState = .hidden(reason: "Overlay idle.")) {
        state = initialState
    }

    func showSuggestion(
        _ text: String,
        geometry: SuggestionOverlayGeometry
    ) {
        showCallCount += 1
        lastShownText = text
        lastShownCaretRect = geometry.caretRect
        lastShownGeometry = geometry
        // The fake does not run the production policy; it just records the call. Defaulting to
        // inline keeps existing tests unchanged. Mirror-aware tests inject explicit state via
        // `initialState:`.
        state = .visible(text: text, geometry: geometry, mode: .inline)
        onStateChange?(state)
    }

    func hide(reason: String) {
        hideReasons.append(reason)
        state = .hidden(reason: reason)
        onStateChange?(state)
    }
}

@MainActor
private final class WorkRecorder {
    private(set) var workIDs: [UInt64] = []

    func record(_ workID: UInt64) {
        workIDs.append(workID)
    }
}

private func runOnMainActor<Result>(
    _ body: @MainActor () throws -> Result
) rethrows -> Result {
    if Thread.isMainThread {
        return try MainActor.assumeIsolated(body)
    }

    return try DispatchQueue.main.sync {
        try MainActor.assumeIsolated(body)
    }
}
