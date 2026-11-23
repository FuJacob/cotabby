import CoreGraphics
import Foundation
import XCTest
@testable import Cotabby

/// Locks the acceptance-preparation guards in `SuggestionInteractionState` that the coordinator
/// suites cannot reach: each one is the difference between Tab inserting text and Tab leaking
/// through to the host as a focus-moving keystroke. Also covers the field-change and reset rules
/// the coordinator uses to discard work for a conversation the user already left.
@MainActor
final class SuggestionInteractionStateAcceptanceGuardTests: XCTestCase {
    private func makeState() -> SuggestionInteractionState {
        TestLifetime.retain(SuggestionInteractionState())
    }

    private func visibleOverlay(text: String, for snapshot: FocusedInputSnapshot) -> OverlayState {
        .visible(
            text: text,
            geometry: CotabbyTestFixtures.overlayGeometry(caretRect: snapshot.caretRect),
            mode: .inline
        )
    }

    func test_prepareAcceptance_withoutASessionPassesTheKeyThrough() {
        let state = makeState()
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot()

        let preparation = state.prepareAcceptance(
            from: snapshot,
            overlayState: visibleOverlay(text: " world", for: snapshot),
            granularity: .word,
            autoAcceptTrailingPunctuation: true
        )

        guard case let .invalid(reason) = preparation else {
            return XCTFail("Expected invalid preparation")
        }
        XCTAssertTrue(reason.contains("no valid suggestion"))
    }

    func test_prepareAcceptance_selectedTextPassesTheKeyThrough() {
        let state = makeState()
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello")
        _ = state.startSession(
            fullText: " world",
            liveContext: FocusedInputContext(snapshot: snapshot, generation: 1),
            latency: 0.05
        )

        let selectedSnapshot = CotabbyTestFixtures.focusedInputSnapshot(
            precedingText: "Hello",
            selection: NSRange(location: 0, length: 3)
        )
        let preparation = state.prepareAcceptance(
            from: selectedSnapshot,
            overlayState: visibleOverlay(text: " world", for: selectedSnapshot),
            granularity: .word,
            autoAcceptTrailingPunctuation: true
        )

        guard case let .invalid(reason) = preparation else {
            return XCTFail("Expected invalid preparation")
        }
        XCTAssertTrue(reason.contains("selected"))
    }

    func test_prepareAcceptance_processChangePassesTheKeyThrough() {
        let state = makeState()
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello")
        _ = state.startSession(
            fullText: " world",
            liveContext: FocusedInputContext(snapshot: snapshot, generation: 1),
            latency: 0.05
        )

        // The same text in a different app must never be accepted into: the session belongs to
        // the original process.
        let otherApp = CotabbyTestFixtures.focusedInputSnapshot(
            processIdentifier: 999,
            precedingText: "Hello"
        )
        let preparation = state.prepareFullAcceptance(
            from: otherApp,
            overlayState: visibleOverlay(text: " world", for: otherApp)
        )

        guard case let .invalid(reason) = preparation else {
            return XCTFail("Expected invalid preparation")
        }
        XCTAssertTrue(reason.contains("focused field changed"))
    }

    func test_prepareFullAcceptance_returnsTheEntireRemainingTail() {
        let state = makeState()
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello")
        _ = state.startSession(
            fullText: " world again",
            liveContext: FocusedInputContext(snapshot: snapshot, generation: 1),
            latency: 0.05
        )

        let preparation = state.prepareFullAcceptance(
            from: snapshot,
            overlayState: visibleOverlay(text: " world again", for: snapshot)
        )

        guard case let .ready(_, _, chunk) = preparation else {
            return XCTFail("Expected ready preparation")
        }
        XCTAssertEqual(chunk, " world again")
    }

    func test_reconcileActiveSession_withoutASessionReturnsNil() {
        let state = makeState()
        XCTAssertNil(state.reconcileActiveSession(with: CotabbyTestFixtures.focusedInputSnapshot()))
    }

    func test_matchingSpaceAndLetterSurviveStaleAXUntilTypedPrefixPublishes() throws {
        let state = makeState()
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello")
        let session = state.startSession(fullText: " world again",
                                        liveContext: FocusedInputContext(snapshot: snapshot, generation: 1), latency: 0)
        let spaced = try XCTUnwrap(state.advanceIfTypedCharactersMatch(" ", expectedSession: session))
        _ = state.advanceIfTypedCharactersMatch("w", expectedSession: spaced)

        for stalePrefix in ["Hello", "Hello "] {
            let result = state.reconcileActiveSession(
                with: CotabbyTestFixtures.focusedInputSnapshot(precedingText: stalePrefix)
            )
            guard case let .valid(_, kept, _) = result else {
                return XCTFail("A not-yet-published matching key should retain the continuation")
            }
            XCTAssertEqual(kept.remainingText, "orld again")
            XCTAssertTrue(state.isAwaitingPostInsertionSync)
            XCTAssertEqual(state.publicationLag, .awaitingTypedInput(0..<2), "Typing must not open synthetic-insertion tolerance")
        }

        guard case let .valid(_, published, _) = state.reconcileActiveSession(
            with: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello w")
        ) else { return XCTFail("Published matching input must reconcile") }
        XCTAssertEqual(published.remainingText, "orld again")
        XCTAssertFalse(state.isAwaitingPostInsertionSync)

        guard case .invalid = state.reconcileActiveSession(with: snapshot) else {
            return XCTFail("After publication, deleting the typed prefix must invalidate the session")
        }
    }

    func test_acceptanceAfterMatchingTypedSpaceUsesTailWhileAXStillLags() {
        let state = makeState()
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello")
        let session = state.startSession(fullText: " world again",
                                        liveContext: FocusedInputContext(snapshot: snapshot, generation: 1), latency: 0)
        _ = state.advanceIfTypedCharactersMatch(" ", expectedSession: session)

        guard case let .ready(_, prepared, chunk) = state.prepareAcceptance(
            from: snapshot, overlayState: visibleOverlay(text: "world again", for: snapshot), granularity: .word
        ) else { return XCTFail("A rapid Tab should still accept after the matching space") }
        XCTAssertEqual(prepared.remainingText, "world again")
        XCTAssertEqual(chunk, "world")
    }

    func test_secondTabBeforeAXPublishAcceptsTheHeldTailWhileOverlayShowsThePreviousOne() throws {
        // Rapid Tab regression: after the first accept, AX still shows the pre-insertion text and
        // the overlay's published state still shows the pre-accept tail, because the controller is
        // holding the next present. The held text must authorize the second Tab.
        let state = makeState()
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello")
        let context = FocusedInputContext(snapshot: snapshot, generation: 1)
        let session = state.startSession(fullText: " world again", liveContext: context, latency: 0)
        _ = state.commitAcceptedChunk(" world", liveContext: context, session: session)
        let stalePublishedOverlay = visibleOverlay(text: " world again", for: snapshot)

        guard case .invalid = state.prepareAcceptance(
            from: snapshot, overlayState: stalePublishedOverlay, granularity: .word
        ) else { return XCTFail("Without a held present, a mismatched visible ghost is stale UI") }

        guard case let .ready(_, prepared, chunk) = state.prepareAcceptance(
            from: snapshot,
            overlayState: stalePublishedOverlay,
            heldPresentationText: " again",
            granularity: .word
        ) else { return XCTFail("The held tail must accept before AX publishes the first insertion") }
        XCTAssertEqual(prepared.consumedCharacterCount, 6)
        XCTAssertEqual(chunk, " again")
        XCTAssertTrue(state.isAwaitingPostInsertionSync, "The first insertion's publication is still owed")
    }

    func test_matchingTypingAfterTabPreservesOutstandingInsertionPublication() throws {
        let state = makeState()
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello")
        let context = FocusedInputContext(snapshot: snapshot, generation: 1)
        let session = state.startSession(fullText: " world again", liveContext: context, latency: 0)
        _ = state.commitAcceptedChunk(" world", liveContext: context, session: session)
        let afterAccept = try XCTUnwrap(state.activeSession)
        _ = state.advanceIfTypedCharactersMatch(" ", expectedSession: afterAccept)

        XCTAssertEqual(state.publicationLag, .awaitingSyntheticInsert(consumedCount: 7))
        guard case let .valid(_, kept, _) = state.reconcileActiveSession(with: snapshot) else {
            return XCTFail("Typing ahead must not retire a still-pending Tab insertion")
        }
        XCTAssertEqual(kept.remainingText, "again")

        _ = state.reconcileActiveSession(with: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello world "))
        XCTAssertFalse(state.isAwaitingPostInsertionSync)
    }

    func test_clearSuggestionRetiresPendingTypedInput() {
        let state = makeState()
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello")
        let session = state.startSession(fullText: " world again",
                                        liveContext: FocusedInputContext(snapshot: snapshot, generation: 1), latency: 0)
        _ = state.advanceIfTypedCharactersMatch(" ", expectedSession: session)
        XCTAssertTrue(state.isAwaitingPostInsertionSync)

        state.clearSuggestion()

        XCTAssertNil(state.activeSession)
        XCTAssertFalse(state.isAwaitingPostInsertionSync)
    }

    func test_fullAcceptanceOfWordEndingRevealsBufferedPhraseWithoutExhaustingSession() {
        let state = makeState()
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Build a flux")
        let context = FocusedInputContext(snapshot: snapshot, generation: 1)
        _ = state.startSession(
            fullText: "beam for the device",
            initialVisibleCharacterCount: 4,
            liveContext: context,
            latency: 0.05
        )

        guard case let .ready(_, session, chunk) = state.prepareFullAcceptance(
            from: snapshot, overlayState: visibleOverlay(text: "beam", for: snapshot)
        ) else { return XCTFail("The visible word ending should be acceptable") }
        XCTAssertEqual(chunk, "beam", "Full accept must never include the hidden following words")

        guard case let .advanced(advanced, _) = state.commitAcceptedChunk(
            chunk, liveContext: context, session: session
        ) else { return XCTFail("The buffered phrase should stay ready after the word ending is accepted") }
        XCTAssertEqual(advanced.remainingText, " for the device")
        XCTAssertEqual(state.publicationLag, .awaitingSyntheticInsert(consumedCount: 4))

        // A second Tab may arrive before AX publishes the first insertion. The existing sentinel
        // must continue to protect the newly revealed phrase without a second model request.
        guard case let .ready(_, _, nextChunk) = state.prepareAcceptance(
            from: snapshot, overlayState: visibleOverlay(text: " for the device", for: snapshot), granularity: .word
        ) else { return XCTFail("The following word should be immediately acceptable") }
        XCTAssertEqual(nextChunk, " for")
    }

    func test_phraseAndFullAcceptanceStayWithinOneWordPresentation() {
        for useFullAcceptance in [false, true] {
            let state = makeState()
            let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello")
            _ = state.startSession(
                fullText: " world again.",
                showFollowingWords: false,
                liveContext: FocusedInputContext(snapshot: snapshot, generation: 1),
                latency: 0
            )
            let overlay = visibleOverlay(text: " world", for: snapshot)
            let preparation = useFullAcceptance
                ? state.prepareFullAcceptance(from: snapshot, overlayState: overlay)
                : state.prepareAcceptance(from: snapshot, overlayState: overlay, granularity: .phrase)

            guard case let .ready(_, _, chunk) = preparation else { return XCTFail("Expected a visible word") }
            XCTAssertEqual(chunk, " world")
        }
    }

    func test_typedWordEndingRevealsPhraseWhileAXStillShowsTheOriginalPrefix() throws {
        let state = makeState()
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Build a flux")
        let session = state.startSession(
            fullText: "beam for the device",
            initialVisibleCharacterCount: 4,
            liveContext: FocusedInputContext(snapshot: snapshot, generation: 1),
            latency: 0
        )
        _ = try XCTUnwrap(state.advanceIfTypedCharactersMatch("beam", expectedSession: session))

        guard case let .valid(_, kept, _) = state.reconcileActiveSession(with: snapshot) else {
            return XCTFail("Unpublished matching typing must preserve the following phrase")
        }
        XCTAssertEqual(kept.remainingText, " for the device")
        XCTAssertEqual(state.publicationLag, .awaitingTypedInput(0..<4))
    }

    func test_acceptanceCannotCrossIntoAnUnseenWordRevealedByTheLatestAXSnapshot() {
        let state = makeState()
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Build a flux")
        _ = state.startSession(
            fullText: "beam for the device",
            initialVisibleCharacterCount: 4,
            liveContext: FocusedInputContext(snapshot: snapshot, generation: 1),
            latency: 0
        )
        let publishedTyping = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Build a fluxbeam")

        guard case .invalid = state.prepareFullAcceptance(
            from: publishedTyping, overlayState: visibleOverlay(text: "beam", for: snapshot)
        ) else { return XCTFail("An old word-ending ghost cannot authorize inserting the unseen phrase") }
    }

    func test_predictionExtensionPreservesPendingTypedPublication() throws {
        let state = makeState()
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello")
        let session = state.startSession(
            fullText: " world", showFollowingWords: false,
            liveContext: FocusedInputContext(snapshot: snapshot, generation: 1), latency: 0
        )
        let typed = try XCTUnwrap(state.advanceIfTypedCharactersMatch(" w", expectedSession: session))
        let extended = try XCTUnwrap(state.extendPrediction(fullText: " world again", expectedSession: typed))

        XCTAssertEqual(extended.remainingText, "orld")
        XCTAssertEqual(extended.predictedRemainingText, "orld again")
        XCTAssertTrue(state.isAwaitingPostInsertionSync)
        guard case let .valid(_, kept, _) = state.reconcileActiveSession(with: snapshot) else {
            return XCTFail("Extending a prediction must not discard outstanding typed-input tolerance")
        }
        XCTAssertEqual(kept, extended)
    }

    func test_predictionExtensionPreservesPendingInsertionPublication() throws {
        let state = makeState()
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello")
        let context = FocusedInputContext(snapshot: snapshot, generation: 1)
        let session = state.startSession(fullText: " world again", liveContext: context, latency: 0)
        _ = state.commitAcceptedChunk(" world", liveContext: context, session: session)
        let accepted = try XCTUnwrap(state.activeSession)

        let extended = try XCTUnwrap(state.extendPrediction(
            fullText: " world again today", expectedSession: accepted
        ))

        XCTAssertEqual(extended.remainingText, " again today")
        XCTAssertEqual(state.publicationLag, .awaitingSyntheticInsert(consumedCount: 6))
        guard case let .valid(_, kept, _) = state.reconcileActiveSession(with: snapshot) else {
            return XCTFail("Extending a prediction must preserve pending Tab insertion")
        }
        XCTAssertEqual(kept, extended)
    }

    // MARK: - Field identity and reset

    func test_hasFocusedElementChanged_isFalseBeforeAnyContextOrSession() {
        XCTAssertFalse(makeState().hasFocusedElementChanged(comparedTo: CotabbyTestFixtures.focusedInputSnapshot()))
    }

    func test_hasFocusedElementChanged_tracksSessionIdentityNotAXWrapperChurn() {
        let state = makeState()
        // The field's title was readable when the context was materialized, so a *different* title
        // later is a conversation switch (a nil one would only be an unreadable poll).
        _ = state.materializeContext(from: CotabbyTestFixtures.focusedInputSnapshot(windowTitle: "This chat"))

        let cases: [(FocusedInputSnapshot, Bool, String)] = [
            (CotabbyTestFixtures.focusedInputSnapshot(windowTitle: "This chat"), false, "same field"),
            (CotabbyTestFixtures.focusedInputSnapshot(elementIdentifier: "new-wrapper"), false, "wrapper refresh"),
            (CotabbyTestFixtures.focusedInputSnapshot(focusChangeSequence: 2), true, "real focus change"),
            (CotabbyTestFixtures.focusedInputSnapshot(windowTitle: "Other chat"), true, "reused composer, new chat")
        ]
        for (snapshot, expected, label) in cases {
            XCTAssertEqual(state.hasFocusedElementChanged(comparedTo: snapshot), expected, label)
        }
    }

    /// A poll whose title or URL read timed out (nil) is the same field; only a different known
    /// value is a conversation switch. Reading nil as a switch tore the session down mid-accept.
    func test_hasFocusedElementChanged_ignoresSurfaceFactsThatFailedToRead() {
        let state = makeState()
        _ = state.materializeContext(from: CotabbyTestFixtures.focusedInputSnapshot(
            focusedURLString: "https://chat.example/one", windowTitle: "Chat one"
        ))

        XCTAssertFalse(state.hasFocusedElementChanged(comparedTo: CotabbyTestFixtures.focusedInputSnapshot(
            focusedURLString: "https://chat.example/one", windowTitle: nil
        )), "title read timed out")
        XCTAssertFalse(state.hasFocusedElementChanged(comparedTo: CotabbyTestFixtures.focusedInputSnapshot()),
                       "every surface read timed out")
        // With a URL known, the title is not an identity fact; the URL is.
        XCTAssertTrue(state.hasFocusedElementChanged(comparedTo: CotabbyTestFixtures.focusedInputSnapshot(
            focusedURLString: "https://chat.example/two", windowTitle: "Chat one"
        )), "a different known URL is still a switch")
    }

    /// A session started from a context that never went through the buffer still anchors the
    /// comparison, so a stale session cannot be kept alive just because no snapshot was buffered.
    func test_hasFocusedElementChanged_fallsBackToTheSessionBaseContext() {
        let state = makeState()
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot()
        _ = state.startSession(
            fullText: " world",
            liveContext: FocusedInputContext(snapshot: snapshot, generation: 1),
            latency: 0
        )
        XCTAssertNil(state.currentContext)

        XCTAssertFalse(state.hasFocusedElementChanged(comparedTo: snapshot))
        XCTAssertTrue(state.hasFocusedElementChanged(
            comparedTo: CotabbyTestFixtures.focusedInputSnapshot(focusChangeSequence: 2)
        ))
    }

    func test_resetAllDropsSessionContextAndSentinelsAndAdvancesTheGeneration() throws {
        let state = makeState()
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello")
        let context = state.materializeContext(from: snapshot)
        let session = state.startSession(fullText: " world again", liveContext: context, latency: 0)
        _ = try XCTUnwrap(state.advanceIfTypedCharactersMatch(" ", expectedSession: session))
        XCTAssertTrue(state.isAwaitingPostInsertionSync)

        state.resetAll()

        XCTAssertNil(state.activeSession)
        XCTAssertNil(state.currentContext)
        XCTAssertFalse(state.isAwaitingPostInsertionSync)
        // Identical text after a reset is still a new generation, so pre-reset results are stale.
        XCTAssertGreaterThan(state.materializeContext(from: snapshot).generation, context.generation)
    }

    func test_extendPredictionWithoutAnActiveSessionIsRejected() {
        let state = makeState()
        let orphan = CotabbyTestFixtures.activeSession(fullText: " world")

        XCTAssertNil(state.extendPrediction(fullText: " world again", expectedSession: orphan))
        XCTAssertNil(state.activeSession)
    }

    func test_predictionExtensionRejectsRevisionsAndAnOutdatedExpectedSession() throws {
        let state = makeState()
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello")
        let session = state.startSession(
            fullText: " world", liveContext: FocusedInputContext(snapshot: snapshot, generation: 1), latency: 0
        )
        XCTAssertNil(state.extendPrediction(fullText: " there", expectedSession: session))
        _ = try XCTUnwrap(state.advanceIfTypedCharactersMatch(" ", expectedSession: session))

        XCTAssertNil(state.extendPrediction(fullText: " world again", expectedSession: session))
        XCTAssertEqual(state.activeSession?.fullText, " world")
    }
}

/// Tests for the storage wrapper around active suggestion session state.
///
/// The coordinator owns the user-facing state machine, while this helper owns the mutable details:
/// current context, active tail, and the AX-lag sentinel after Tab insertion.
final class SuggestionInteractionStateTests: XCTestCase {
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
            XCTAssertEqual(state.publicationLag, .settled)
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
            XCTAssertEqual(state.publicationLag, .awaitingSyntheticInsert(consumedCount: 6))
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
            XCTAssertEqual(state.publicationLag, .settled)
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
            XCTAssertEqual(advancement?.advancedBy, 6)
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

    func test_typedThroughAdvanceSurvivesTheHostsAccessibilityLag() {
        // The key event advances the session before the host publishes the character. A poll that
        // still shows the old text must not kill the session (it read as "partially undone" in the
        // Claude composer); the one that carries the character clears the sentinel.
        runOnMainActor {
            let state = makeState()
            let context = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello")
            let storedSession = state.startSession(fullText: " world again", liveContext: context, latency: 0.1)
            XCTAssertNotNil(state.advanceIfTypedCharactersMatch(" wor", expectedSession: storedSession))
            XCTAssertTrue(state.isAwaitingPostInsertionSync)

            let lagging = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello w")
            guard case .valid(_, let survived, _)? = state.reconcileActiveSession(with: lagging) else {
                return XCTFail("A snapshot behind the typed characters must be tolerated")
            }
            XCTAssertEqual(survived.remainingText, "ld again")
            XCTAssertTrue(state.isAwaitingPostInsertionSync)

            let caughtUp = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello wor")
            guard case .valid(_, let current, _)? = state.reconcileActiveSession(with: caughtUp) else {
                return XCTFail("The published text matches the session")
            }
            XCTAssertEqual(current.remainingText, "ld again")
            XCTAssertFalse(state.isAwaitingPostInsertionSync, "AX caught up: the sentinel clears")
        }
    }

    func test_typingThroughTheWholeSuggestionArmsNoSentinel() {
        runOnMainActor {
            let state = makeState()
            let context = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello")
            let storedSession = state.startSession(fullText: " world", liveContext: context, latency: 0.1)
            let exhausted = state.advanceIfTypedCharactersMatch(" world", expectedSession: storedSession)
            XCTAssertEqual(exhausted?.isExhausted, true)
            XCTAssertFalse(state.isAwaitingPostInsertionSync)
        }
    }

    @MainActor
    private func makeState() -> SuggestionInteractionState {
        TestLifetime.retain(SuggestionInteractionState())
    }
}
