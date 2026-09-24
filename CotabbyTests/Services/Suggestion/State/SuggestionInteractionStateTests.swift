import Foundation
import XCTest
@testable import Cotabby

/// Locks the acceptance-preparation guards in `SuggestionInteractionState` that the coordinator
/// suites cannot reach: each one is the difference between Tab inserting text and Tab leaking
/// through to the host as a focus-moving keystroke.
@MainActor
final class SuggestionInteractionStateAcceptanceGuardTests: XCTestCase {
    /// Production @MainActor class instances are quarantined against the back-deploy deinit shim.
    private static var retained: [AnyObject] = []

    private func makeState() -> SuggestionInteractionState {
        let state = SuggestionInteractionState()
        Self.retained.append(state)
        return state
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
            XCTAssertNil(state.pendingInsertionConsumedCount, "Typing must not open synthetic-insertion tolerance")
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

    func test_matchingTypingAfterTabPreservesOutstandingInsertionPublication() throws {
        let state = makeState()
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello")
        let context = FocusedInputContext(snapshot: snapshot, generation: 1)
        let session = state.startSession(fullText: " world again", liveContext: context, latency: 0)
        _ = state.commitAcceptedChunk(" world", liveContext: context, session: session)
        let afterAccept = try XCTUnwrap(state.activeSession)
        _ = state.advanceIfTypedCharactersMatch(" ", expectedSession: afterAccept)

        XCTAssertEqual(state.pendingInsertionConsumedCount, 7)
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
}
