import XCTest
@testable import Cotabby

/// Focused coverage for one responsibility of `SuggestionSessionReconciler`.
final class SuggestionSessionReconciliationTests: XCTestCase {
    func test_reconcile_validWhenLiveContextStillMatchesBaseContext() {
        let session = CotabbyTestFixtures.activeSession(
            fullText: " world again",
            basePrecedingText: "Hello",
            baseTrailingText: " tail"
        )
        let liveContext = CotabbyTestFixtures.focusedInputContext(
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
        let session = CotabbyTestFixtures.activeSession(processIdentifier: 123)
        let liveContext = CotabbyTestFixtures.focusedInputContext(processIdentifier: 456)

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
        let session = CotabbyTestFixtures.activeSession()
        let liveContext = CotabbyTestFixtures.focusedInputContext(
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
        let session = CotabbyTestFixtures.activeSession(
            fullText: " world again",
            basePrecedingText: "Hello",
            baseTrailingText: " tail"
        )
        let liveContext = CotabbyTestFixtures.focusedInputContext(
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
        let session = CotabbyTestFixtures.activeSession(
            fullText: " world again",
            consumedCharacterCount: 6,
            basePrecedingText: "Hello",
            baseTrailingText: " tail"
        )
        let liveContext = CotabbyTestFixtures.focusedInputContext(
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
        let session = CotabbyTestFixtures.activeSession(
            fullText: " world again",
            basePrecedingText: "Hello"
        )
        let liveContext = CotabbyTestFixtures.focusedInputContext(precedingText: "Goodbye")

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
        let session = CotabbyTestFixtures.activeSession(
            fullText: " world again",
            basePrecedingText: "Hello"
        )
        let liveContext = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello there")

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
        let session = CotabbyTestFixtures.activeSession(
            fullText: " world again",
            basePrecedingText: "Hello"
        )
        let liveContext = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello world")

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

    func test_reconcile_invalidWhenSuggestionPartiallyUndoneOutsideInsertionSyncWindow() {
        // The session has consumed " worl" (5 chars) but the live field only shows " wo": the user
        // deleted part of the accepted text, so the session must die.
        let session = CotabbyTestFixtures.activeSession(
            fullText: " world again",
            consumedCharacterCount: 5,
            basePrecedingText: "Hello"
        )
        let liveContext = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello wo")

        let reconciliation = SuggestionSessionReconciler.reconcile(
            session: session,
            with: liveContext,
            pendingInsertionConsumedCount: nil
        )

        assertInvalid(
            reconciliation,
            reason: "Overlay hidden because the active suggestion was partially undone."
        )
    }

    func test_reconcile_toleratesShorterConsumedSuffixRightAfterAcceptedInsertion() {
        // Same field state as the undo case, but we just Tab-inserted up to 5 consumed characters
        // (the sentinel matches): AX simply has not published the full insert yet, so the session
        // must survive untouched for one more cycle.
        let session = CotabbyTestFixtures.activeSession(
            fullText: " world again",
            consumedCharacterCount: 5,
            basePrecedingText: "Hello"
        )
        let liveContext = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello wo")

        let reconciliation = SuggestionSessionReconciler.reconcile(
            session: session,
            with: liveContext,
            pendingInsertionConsumedCount: 5
        )

        guard case let .valid(reconciledSession, advancement, nextPending) = reconciliation else {
            XCTFail("Expected post-insertion AX lag to be tolerated")
            return
        }
        XCTAssertEqual(reconciledSession.acceptedText, session.acceptedText)
        XCTAssertEqual(reconciledSession.remainingText, session.remainingText)
        XCTAssertNil(advancement)
        XCTAssertEqual(nextPending, 5)
    }

    func test_reconcile_toleratesPrefixAnchorRaceRightAfterAcceptedInsertion() {
        // Inverse Chromium race: trailing text already stable, but the prefix still reflects the
        // pre-insertion snapshot. With the sentinel armed the session waits instead of dying.
        let session = CotabbyTestFixtures.activeSession(
            fullText: " world again",
            consumedCharacterCount: 6,
            basePrecedingText: "Hello"
        )
        let liveContext = CotabbyTestFixtures.focusedInputContext(precedingText: "Goodbye")

        let reconciliation = SuggestionSessionReconciler.reconcile(
            session: session,
            with: liveContext,
            pendingInsertionConsumedCount: 6
        )

        guard case let .valid(reconciledSession, advancement, nextPending) = reconciliation else {
            XCTFail("Expected prefix-anchor race to be tolerated during the insertion sync window")
            return
        }
        XCTAssertEqual(reconciledSession.remainingText, session.remainingText)
        XCTAssertNil(advancement)
        XCTAssertEqual(nextPending, 6)
    }

    func test_reconcile_toleratesConsumedSuffixDivergenceRightAfterAcceptedInsertion() {
        // The preceding text grew with characters that do not match the suggestion: outside the
        // sync window that is invalidating, but right after Tab it is just stale AX content.
        let session = CotabbyTestFixtures.activeSession(
            fullText: " world again",
            consumedCharacterCount: 6,
            basePrecedingText: "Hello"
        )
        let liveContext = CotabbyTestFixtures.focusedInputContext(precedingText: "Helloxyz")

        let reconciliation = SuggestionSessionReconciler.reconcile(
            session: session,
            with: liveContext,
            pendingInsertionConsumedCount: 6
        )

        guard case let .valid(reconciledSession, advancement, nextPending) = reconciliation else {
            XCTFail("Expected consumed-suffix divergence to be tolerated during the insertion sync window")
            return
        }
        XCTAssertEqual(reconciledSession.remainingText, session.remainingText)
        XCTAssertNil(advancement)
        XCTAssertEqual(nextPending, 6)
    }

    func test_reconcile_clearsPendingInsertionSentinelWhenAXCatchesUp() {
        let session = CotabbyTestFixtures.activeSession(
            fullText: " world again",
            consumedCharacterCount: 6,
            basePrecedingText: "Hello"
        )
        let liveContext = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello world")

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
