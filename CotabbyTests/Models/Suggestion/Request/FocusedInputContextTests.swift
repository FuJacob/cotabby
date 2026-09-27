import CoreGraphics
import XCTest
@testable import Cotabby

/// Tests for the two identity keys a `FocusedInputContext` derives. They deliberately answer
/// different questions: the field key must survive a self-resizing composer (so ghost-font
/// stabilization does not jitter), while the session key must change on navigation even when the
/// host reuses the same AX element (so prediction memory cannot leak across conversations).
final class FocusedInputContextTests: XCTestCase {
    func test_focusedInputIdentityKey_survivesTextFrameAndSequenceChangesButNotAFieldSwitch() {
        let base = CotabbyTestFixtures.focusedInputContext(elementIdentifier: "composer")
        let grown = CotabbyTestFixtures.focusedInputContext(
            elementIdentifier: "composer",
            inputFrameRect: CGRect(x: 0, y: 0, width: 240, height: 64),
            precedingText: "Hello there, this wrapped onto a second line",
            focusChangeSequence: 9
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

        // Same AX element, so the geometry key is shared...
        XCTAssertEqual(chatA.focusedInputIdentityKey, chatB.focusedInputIdentityKey)
        // ...but a different conversation must not reuse prediction memory.
        XCTAssertNotEqual(chatA.suggestionSessionIdentityKey, chatB.suggestionSessionIdentityKey)
        // Typing inside one conversation is still the same session.
        XCTAssertEqual(chatA.suggestionSessionIdentityKey, chatAAfterTyping.suggestionSessionIdentityKey)
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
}
