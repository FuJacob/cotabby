import CoreGraphics
import XCTest
@testable import tabby

/// Tests for the pure state-machine rules behind partial acceptance.
///
/// This is the highest-risk autocomplete logic because it decides whether a live editor change is
/// still consistent with the active ghost-text tail or whether Tabby must invalidate the session.
final class SuggestionSessionReconcilerTests: XCTestCase {
    func test_advanceIfTypedCharactersMatch_advancesMatchingDirectText() {
        let session = TabbyTestFixtures.activeSession(fullText: " world again")

        let advanced = SuggestionSessionReconciler.advanceIfTypedCharactersMatch(
            " world",
            session: session
        )

        XCTAssertEqual(advanced?.acceptedText, " world")
        XCTAssertEqual(advanced?.remainingText, " again")
    }

    func test_advanceIfTypedCharactersMatch_returnsNilForDivergentText() {
        let session = TabbyTestFixtures.activeSession(fullText: " world again")

        let advanced = SuggestionSessionReconciler.advanceIfTypedCharactersMatch(
            " there",
            session: session
        )

        XCTAssertNil(advanced)
    }

    func test_advanceIfTypedCharactersMatch_returnsNilForControlCharacters() {
        let session = TabbyTestFixtures.activeSession(fullText: " world again")

        let advanced = SuggestionSessionReconciler.advanceIfTypedCharactersMatch(
            "\n",
            session: session
        )

        XCTAssertNil(advanced)
    }

    func test_nextAcceptanceChunk_includesLeadingWhitespaceAndNextVisibleToken() {
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptanceChunk(from: "  world again"),
            "  world"
        )
    }

    func test_nextAcceptanceChunk_returnsSingleTokenWhenNoLeadingWhitespace() {
        XCTAssertEqual(
            SuggestionSessionReconciler.nextAcceptanceChunk(from: "world again"),
            "world"
        )
    }

    func test_nextAcceptanceChunk_returnsEmptyForEmptyTail() {
        XCTAssertEqual(SuggestionSessionReconciler.nextAcceptanceChunk(from: ""), "")
    }

    func test_acceptedWordCount_countsOnlyTokensWithAlphanumerics() {
        let count = SuggestionSessionReconciler.acceptedWordCount(
            in: "hello, !!! world 123 --"
        )

        XCTAssertEqual(count, 3)
    }

    func test_overlayAllowsAcceptance_trueWhenOverlayHidden() {
        XCTAssertTrue(
            SuggestionSessionReconciler.overlayAllowsAcceptance(
                of: " world",
                overlayState: .hidden(reason: "waiting for AX")
            )
        )
    }

    func test_overlayAllowsAcceptance_trueOnlyWhenVisibleTextMatches() {
        let caretRect = CGRect(x: 10, y: 20, width: 2, height: 18)

        XCTAssertTrue(
            SuggestionSessionReconciler.overlayAllowsAcceptance(
                of: " world",
                overlayState: .visible(
                    text: " world",
                    geometry: TabbyTestFixtures.overlayGeometry(caretRect: caretRect)
                )
            )
        )
        XCTAssertFalse(
            SuggestionSessionReconciler.overlayAllowsAcceptance(
                of: " world",
                overlayState: .visible(
                    text: " there",
                    geometry: TabbyTestFixtures.overlayGeometry(caretRect: caretRect)
                )
            )
        )
    }

    func test_overlayHideReason_mapsSemanticInputEventsToUserVisibleReasons() {
        XCTAssertEqual(
            SuggestionSessionReconciler.overlayHideReason(
                for: TabbyTestFixtures.inputEvent(kind: .textMutation)
            ),
            "Overlay hidden because typing invalidated the current suggestion."
        )
        XCTAssertEqual(
            SuggestionSessionReconciler.overlayHideReason(
                for: TabbyTestFixtures.inputEvent(kind: .navigation)
            ),
            "Overlay hidden because caret navigation invalidated the current suggestion."
        )
        XCTAssertEqual(
            SuggestionSessionReconciler.overlayHideReason(
                for: TabbyTestFixtures.inputEvent(kind: .dismissal)
            ),
            "Overlay hidden because a dismissal key was pressed."
        )
    }

    func test_reconcile_validWhenLiveContextStillMatchesBaseContext() {
        let session = TabbyTestFixtures.activeSession(
            fullText: " world again",
            basePrecedingText: "Hello",
            baseTrailingText: " tail"
        )
        let liveContext = TabbyTestFixtures.focusedInputContext(
            precedingText: "Hello",
            trailingText: " tail"
        )

        let reconciliation = SuggestionSessionReconciler.reconcile(
            session: session,
            with: liveContext,
            pendingInsertionConsumedCount: nil
        )

        guard case let .valid(reconciledSession, advancement, nextPending) = reconciliation else {
            XCTFail("Expected valid reconciliation")
            return
        }
        XCTAssertEqual(reconciledSession.acceptedText, session.acceptedText)
        XCTAssertEqual(reconciledSession.remainingText, session.remainingText)
        XCTAssertNil(advancement)
        XCTAssertNil(nextPending)
    }

    func test_reconcile_invalidWhenProcessChanges() {
        let session = TabbyTestFixtures.activeSession(processIdentifier: 123)
        let liveContext = TabbyTestFixtures.focusedInputContext(processIdentifier: 456)

        let reconciliation = SuggestionSessionReconciler.reconcile(
            session: session,
            with: liveContext,
            pendingInsertionConsumedCount: nil
        )

        assertInvalid(
            reconciliation,
            reason: "Overlay hidden because the focused field changed."
        )
    }

    func test_reconcile_invalidWhenTextIsSelected() {
        let session = TabbyTestFixtures.activeSession()
        let liveContext = TabbyTestFixtures.focusedInputContext(
            selection: NSRange(location: 1, length: 2)
        )

        let reconciliation = SuggestionSessionReconciler.reconcile(
            session: session,
            with: liveContext,
            pendingInsertionConsumedCount: nil
        )

        assertInvalid(reconciliation, reason: "Overlay hidden because text is selected.")
    }

    func test_reconcile_invalidWhenTrailingTextChangesOutsideInsertionSyncWindow() {
        let session = TabbyTestFixtures.activeSession(
            fullText: " world again",
            basePrecedingText: "Hello",
            baseTrailingText: " tail"
        )
        let liveContext = TabbyTestFixtures.focusedInputContext(
            precedingText: "Hello",
            trailingText: " changed"
        )

        let reconciliation = SuggestionSessionReconciler.reconcile(
            session: session,
            with: liveContext,
            pendingInsertionConsumedCount: nil
        )

        assertInvalid(
            reconciliation,
            reason: "Overlay hidden because text after the caret changed."
        )
    }

    func test_reconcile_toleratesTrailingTextRaceAfterAcceptedInsertion() {
        let session = TabbyTestFixtures.activeSession(
            fullText: " world again",
            consumedCharacterCount: 6,
            basePrecedingText: "Hello",
            baseTrailingText: " tail"
        )
        let liveContext = TabbyTestFixtures.focusedInputContext(
            precedingText: "Hello",
            trailingText: " changed"
        )

        let reconciliation = SuggestionSessionReconciler.reconcile(
            session: session,
            with: liveContext,
            pendingInsertionConsumedCount: 6
        )

        guard case let .valid(reconciledSession, advancement, nextPending) = reconciliation else {
            XCTFail("Expected transient insertion lag to be tolerated")
            return
        }
        XCTAssertEqual(reconciledSession.acceptedText, session.acceptedText)
        XCTAssertEqual(reconciledSession.remainingText, session.remainingText)
        XCTAssertNil(advancement)
        XCTAssertEqual(nextPending, 6)
    }

    func test_reconcile_invalidWhenPrefixAnchorChangesOutsideInsertionSyncWindow() {
        let session = TabbyTestFixtures.activeSession(
            fullText: " world again",
            basePrecedingText: "Hello"
        )
        let liveContext = TabbyTestFixtures.focusedInputContext(precedingText: "Goodbye")

        let reconciliation = SuggestionSessionReconciler.reconcile(
            session: session,
            with: liveContext,
            pendingInsertionConsumedCount: nil
        )

        assertInvalid(
            reconciliation,
            reason: "Overlay hidden because text before the caret no longer matches the suggestion anchor."
        )
    }

    func test_reconcile_invalidWhenConsumedSuffixDivergesFromSuggestion() {
        let session = TabbyTestFixtures.activeSession(
            fullText: " world again",
            basePrecedingText: "Hello"
        )
        let liveContext = TabbyTestFixtures.focusedInputContext(precedingText: "Hello there")

        let reconciliation = SuggestionSessionReconciler.reconcile(
            session: session,
            with: liveContext,
            pendingInsertionConsumedCount: nil
        )

        assertInvalid(
            reconciliation,
            reason: "Overlay hidden because typed text diverged from the active suggestion."
        )
    }

    func test_reconcile_advancesSessionWhenLiveTextConsumedSuggestionPrefix() {
        let session = TabbyTestFixtures.activeSession(
            fullText: " world again",
            basePrecedingText: "Hello"
        )
        let liveContext = TabbyTestFixtures.focusedInputContext(precedingText: "Hello world")

        let reconciliation = SuggestionSessionReconciler.reconcile(
            session: session,
            with: liveContext,
            pendingInsertionConsumedCount: nil
        )

        guard case let .valid(reconciledSession, advancement, nextPending) = reconciliation else {
            XCTFail("Expected consumed suggestion text to advance the session")
            return
        }
        XCTAssertEqual(reconciledSession.acceptedText, " world")
        XCTAssertEqual(reconciledSession.remainingText, " again")
        XCTAssertEqual(advancement?.stage, "session-reconciled")
        XCTAssertNil(nextPending)
    }

    func test_reconcile_clearsPendingInsertionSentinelWhenAXCatchesUp() {
        let session = TabbyTestFixtures.activeSession(
            fullText: " world again",
            consumedCharacterCount: 6,
            basePrecedingText: "Hello"
        )
        let liveContext = TabbyTestFixtures.focusedInputContext(precedingText: "Hello world")

        let reconciliation = SuggestionSessionReconciler.reconcile(
            session: session,
            with: liveContext,
            pendingInsertionConsumedCount: 6
        )

        guard case let .valid(_, _, nextPending) = reconciliation else {
            XCTFail("Expected caught-up AX state to remain valid")
            return
        }
        XCTAssertNil(nextPending)
    }

    private func assertInvalid(
        _ reconciliation: SuggestionSessionReconciliation,
        reason expectedReason: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .invalid(reason) = reconciliation else {
            XCTFail("Expected invalid reconciliation", file: file, line: line)
            return
        }

        XCTAssertEqual(reason, expectedReason, file: file, line: line)
    }
}
