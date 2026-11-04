import CoreGraphics
import XCTest
@testable import Ghostype

/// Tests for the two identity keys a `FocusedInputContext` derives. They deliberately answer
/// scoped to a writing session: both survive self-resizing and typing, and both change when a
/// recycled AX node belongs to a newly focused field or conversation. Measurements and prediction
/// memory must not leak across those sessions.
final class FocusedInputContextTests: XCTestCase {
    func test_focusedInputIdentityKey_survivesGrowthWithinTheSameSession() {
        let base = CotabbyTestFixtures.focusedInputContext(elementIdentifier: "composer")
        let grown = CotabbyTestFixtures.focusedInputContext(
            elementIdentifier: "composer",
            inputFrameRect: CGRect(x: 0, y: 0, width: 240, height: 64),
            precedingText: "Hello there, this wrapped onto a second line",
            focusChangeSequence: 1
        )

        XCTAssertEqual(base.focusedInputIdentityKey, grown.focusedInputIdentityKey)
        XCTAssertNotEqual(
            base.focusedInputIdentityKey,
            CotabbyTestFixtures.focusedInputContext(elementIdentifier: "other-field").focusedInputIdentityKey
        )
        XCTAssertNotEqual(
            base.focusedInputIdentityKey,
            CotabbyTestFixtures.focusedInputContext(processIdentifier: 999, elementIdentifier: "composer")
                .focusedInputIdentityKey
        )
    }

    func test_suggestionSessionIdentityKey_changesOnNavigationWithinTheSameField() {
        let chatA = CotabbyTestFixtures.focusedInputContext(
            elementIdentifier: "composer",
            focusedURLString: "https://chat.example.com/c/a"
        )
        let chatB = CotabbyTestFixtures.focusedInputContext(
            elementIdentifier: "composer",
            focusedURLString: "https://chat.example.com/c/b"
        )
        let chatAAfterTyping = CotabbyTestFixtures.focusedInputContext(
            elementIdentifier: "composer",
            precedingText: "Hello again",
            focusedURLString: "https://chat.example.com/c/a"
        )

        // Reusing the same AX node on a different page must not reuse font or baseline measurements.
        XCTAssertNotEqual(chatA.focusedInputIdentityKey, chatB.focusedInputIdentityKey)
        // A different conversation must not reuse prediction memory either.
        XCTAssertNotEqual(chatA.suggestionSessionIdentityKey, chatB.suggestionSessionIdentityKey)
        // Typing inside one conversation is still the same session.
        XCTAssertEqual(chatA.suggestionSessionIdentityKey, chatAAfterTyping.suggestionSessionIdentityKey)
    }

    func test_titleOnlyChangePreservesPresentationMeasurements() {
        let first = CotabbyTestFixtures.focusedInputContext(windowTitle: "Inbox (1)")
        let next = CotabbyTestFixtures.focusedInputContext(windowTitle: "Inbox (2)")
        XCTAssertEqual(first.focusedInputIdentityKey, next.focusedInputIdentityKey)
    }

    /// Hosts show a placeholder only while the field is empty. Its disappearance on the first typed
    /// characters must not read as a new writing session (FocusTracker's sequence carries a real
    /// placeholder change), or prediction memory and screen context reset on every first keystroke.
    func test_sessionIdentity_survivesThePlaceholderHidingOnceTextIsTyped() {
        let empty = CotabbyTestFixtures.focusedInputContext(
            elementIdentifier: "composer", precedingText: "", fieldPlaceholder: "Type / for commands."
        )
        let typed = CotabbyTestFixtures.focusedInputContext(
            elementIdentifier: "composer", precedingText: "df", fieldPlaceholder: nil
        )

        XCTAssertEqual(empty.sessionIdentity, typed.sessionIdentity)
        XCTAssertEqual(empty.suggestionSessionIdentityKey, typed.suggestionSessionIdentityKey)
    }

    func test_sessionIdentity_matchesTheSnapshotItWasBuiltFrom() {
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(
            focusChangeSequence: 5,
            focusedURLString: "https://mail.example.com",
            windowTitle: "Inbox",
            fieldPlaceholder: "Reply"
        )

        let context = FocusedInputContext(snapshot: snapshot, generation: 2)

        XCTAssertEqual(context.sessionIdentity, snapshot.sessionIdentity)
        XCTAssertEqual(context.generation, 2)
    }
    func test_newSessionOnRecycledElementDiscardsPresentationIdentity() {
        let first = CotabbyTestFixtures.focusedInputContext(elementIdentifier: "recycled", focusChangeSequence: 1)
        let second = CotabbyTestFixtures.focusedInputContext(elementIdentifier: "recycled", focusChangeSequence: 2)
        XCTAssertNotEqual(first.focusedInputIdentityKey, second.focusedInputIdentityKey)
    }

}
