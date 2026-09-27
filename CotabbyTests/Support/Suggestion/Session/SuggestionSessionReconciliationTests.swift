import XCTest
@testable import Cotabby

/// Live-AX reconciliation of an active session: which field/text changes invalidate it, which
/// consumed-prefix changes advance it, and how the post-insertion and typed-input lag sentinels
/// tolerate a host that has not published yet without excusing unrelated edits.
final class SuggestionSessionReconciliationTests: XCTestCase {
    func test_identicalTextInAnotherConversationRejectsEvenDuringInsertionLag() {
        let session = CotabbyTestFixtures.activeSession()
        let targets = [
            CotabbyTestFixtures.focusedInputContext(focusChangeSequence: 2),
            CotabbyTestFixtures.focusedInputContext(windowTitle: "Other chat"),
            CotabbyTestFixtures.focusedInputContext(focusedURLString: "https://chat.example/two")
        ]
        for target in targets {
            assertInvalid(SuggestionSessionReconciler.reconcile(
                session: session, with: target, pendingInsertionConsumedCount: session.consumedCharacterCount
            ), reason: "Overlay hidden because the focused field changed.")
        }
    }

    func test_wrapperChurnInsideSessionStillAcceptsSuggestion() {
        let session = CotabbyTestFixtures.activeSession()
        let target = CotabbyTestFixtures.focusedInputContext(elementIdentifier: "refreshed-wrapper")
        guard case .valid = SuggestionSessionReconciler.reconcile(
            session: session, with: target, pendingInsertionConsumedCount: nil
        ) else { return XCTFail("AX wrapper churn must not discard an otherwise matching suggestion") }
    }

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
        XCTAssertEqual(advancement, SuggestionSessionAdvancement(
            stage: "session-reconciled",
            message: "The live field state consumed 6 additional suggestion characters.",
            exhaustionStage: "session-exhausted",
            exhaustionMessage: "The live field state fully consumed the active suggestion."
        ))
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

    func test_pendingTypedInputNeverToleratesUnrelatedEditsOrAnEarlierPublishedPrefix() {
        let session = CotabbyTestFixtures.activeSession(fullText: " world again", consumedCharacterCount: 7,
                                                       basePrecedingText: "Hello", baseTrailingText: " tail")
        let invalidContexts = [
            CotabbyTestFixtures.focusedInputContext(precedingText: "Hello world", trailingText: " changed"),
            CotabbyTestFixtures.focusedInputContext(precedingText: "Goodbye", trailingText: " tail"),
            CotabbyTestFixtures.focusedInputContext(precedingText: "Hello there", trailingText: " tail"),
            CotabbyTestFixtures.focusedInputContext(precedingText: "Hello", trailingText: " tail"),
            CotabbyTestFixtures.focusedInputContext(precedingText: "Hello world", trailingText: " tail", focusChangeSequence: 2),
            CotabbyTestFixtures.focusedInputContext(precedingText: "Hello world", trailingText: " tail",
                                                    selection: NSRange(location: 11, length: 1))
        ]

        for context in invalidContexts {
            let result = SuggestionSessionReconciler.reconcile(
                session: session, with: context, pendingInsertionConsumedCount: nil,
                pendingTypedConsumedRange: 6..<7
            )
            guard case .invalid = result else {
                return XCTFail("Typed-input lag must not excuse a changed field or text: \(context.precedingText)")
            }
        }
    }

    func test_reconcile_reportsExhaustionWhenOnlyWhitespaceRemains() {
        // A whitespace-only tail counts as exhausted, so the coordinator can retire the ghost
        // instead of rendering a trailing "ghost space".
        let session = CotabbyTestFixtures.activeSession(fullText: " world ", basePrecedingText: "Hello")
        let liveContext = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello world")

        guard case let .valid(reconciledSession, advancement, _) = SuggestionSessionReconciler.reconcile(
            session: session, with: liveContext, pendingInsertionConsumedCount: nil
        ) else { return XCTFail("Expected typing through the suggestion to stay valid") }

        XCTAssertTrue(reconciledSession.isExhausted)
        XCTAssertEqual(advancement, SuggestionSessionAdvancement(
            stage: "session-exhausted",
            message: "The live field state caught up with the fully consumed suggestion.",
            exhaustionStage: "session-exhausted",
            exhaustionMessage: "The live field state fully consumed the active suggestion."
        ))
    }

    func test_reconcile_countsConsumedTextInUserCharactersNotUTF16Units() {
        let session = CotabbyTestFixtures.activeSession(fullText: " 🐈 cat", basePrecedingText: "Hello")
        let liveContext = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello 🐈")

        guard case let .valid(reconciledSession, advancement, _) = SuggestionSessionReconciler.reconcile(
            session: session, with: liveContext, pendingInsertionConsumedCount: nil
        ) else { return XCTFail("Expected the typed emoji to advance the session") }

        XCTAssertEqual(reconciledSession.consumedCharacterCount, 2)
        XCTAssertEqual(reconciledSession.remainingText, " cat")
        XCTAssertEqual(advancement?.message, "The live field state consumed 2 additional suggestion characters.")
    }

    func test_reconcile_clearsSentinelAndAdvancesWhenAXPublishesBeyondTheInsertedChunk() {
        // The user kept typing matching characters after Tab and AX published both at once.
        let session = CotabbyTestFixtures.activeSession(
            fullText: " world again", consumedCharacterCount: 6, basePrecedingText: "Hello"
        )
        let liveContext = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello world ag")

        guard case let .valid(reconciledSession, advancement, nextPending) = SuggestionSessionReconciler.reconcile(
            session: session, with: liveContext, pendingInsertionConsumedCount: 6
        ) else { return XCTFail("Expected matching typed-ahead text to stay valid") }

        XCTAssertEqual(reconciledSession.remainingText, "ain")
        XCTAssertEqual(advancement?.stage, "session-reconciled")
        XCTAssertEqual(advancement?.message, "The live field state consumed 3 additional suggestion characters.")
        XCTAssertNil(nextPending)
    }

    func test_reconcile_staleSentinelForAnEarlierChunkDoesNotExcuseAnUndo() {
        // The sentinel only protects the chunk it was armed for. After a later accept moved the
        // session to 6 consumed characters, a sentinel of 3 must not hide a real deletion.
        let session = CotabbyTestFixtures.activeSession(
            fullText: " world again", consumedCharacterCount: 6, basePrecedingText: "Hello"
        )
        let liveContext = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello wo")

        assertInvalid(
            SuggestionSessionReconciler.reconcile(
                session: session, with: liveContext, pendingInsertionConsumedCount: 3
            ),
            reason: "Overlay hidden because the active suggestion was partially undone."
        )
    }

    func test_reconcile_trailingTextRaceIsOnlyToleratedWhileThePrefixAnchorHolds() {
        let session = CotabbyTestFixtures.activeSession(
            fullText: " world again", consumedCharacterCount: 6,
            basePrecedingText: "Hello", baseTrailingText: " tail"
        )
        let liveContext = CotabbyTestFixtures.focusedInputContext(precedingText: "Goodbye", trailingText: " changed")

        assertInvalid(
            SuggestionSessionReconciler.reconcile(
                session: session, with: liveContext, pendingInsertionConsumedCount: 6
            ),
            reason: "Overlay hidden because text after the caret changed."
        )
    }

    func test_pendingTypedInputToleratesTheUnpublishedKeystrokesOnly() {
        // The tap saw " " (the 7th character) before the host published it; the live prefix still
        // shows 6 consumed characters, which the typed range 6..<7 explicitly covers.
        let session = CotabbyTestFixtures.activeSession(fullText: " world again", consumedCharacterCount: 7,
                                                       basePrecedingText: "Hello", baseTrailingText: " tail")
        let lagging = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello world", trailingText: " tail")

        XCTAssertEqual(
            SuggestionSessionReconciler.reconcile(
                session: session, with: lagging, pendingInsertionConsumedCount: nil,
                pendingTypedConsumedRange: 6..<7
            ),
            .valid(session: session, advancement: nil, nextPendingInsertionConsumedCount: nil)
        )

        // A range that does not end at the session's consumed count describes different keystrokes.
        assertInvalid(
            SuggestionSessionReconciler.reconcile(
                session: session, with: lagging, pendingInsertionConsumedCount: nil,
                pendingTypedConsumedRange: 5..<6
            ),
            reason: "Overlay hidden because the active suggestion was partially undone."
        )
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
