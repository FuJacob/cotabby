import CoreGraphics
import XCTest
@testable import Cotabby

/// Tests for what a `FocusedInputContext` derives from its snapshot. The two identity keys
/// deliberately answer different questions: the field key must survive a self-resizing composer (so
/// ghost-font stabilization does not jitter), while the session key must change on navigation even
/// when the host reuses the same AX element (so prediction memory cannot leak across
/// conversations). The layout facts decide how many rows a ghost may take and whether it may show.
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

    func test_focusedInputContext_contentSignatureMirrorsSnapshotAndTagsSecureFields() {
        let context = CotabbyTestFixtures.focusedInputContext(
            elementIdentifier: "field-a",
            precedingText: "Hello",
            trailingText: " tail",
            focusChangeSequence: 7
        )
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(
            elementIdentifier: "field-a",
            precedingText: "Hello",
            trailingText: " tail",
            focusChangeSequence: 7
        )

        XCTAssertEqual(context.contentSignature, "5::0::Hello:: tail::plain")
        // The context's fingerprint must stay interchangeable with the snapshot's so staleness
        // checks can compare across the debounce boundary.
        XCTAssertEqual(context.contentSignature, snapshot.contentSignature)

        let secure = CotabbyTestFixtures.focusedInputContext(isSecure: true)
        XCTAssertTrue(secure.contentSignature.hasSuffix("::secure"))
    }

    /// A text field or combo box lays its text out on one line (an HTML input, Chromium's address
    /// bar, an NSTextField): measured 2026-09-11, a long ghost's second row was drawn under a Chrome
    /// text input. A text area, or a web area standing in for an editor, may wrap.
    func test_focusedInputContext_textFieldsAndComboBoxesAreSingleLine() {
        func context(role: String) -> FocusedInputContext {
            FocusedInputContext(snapshot: CotabbyTestFixtures.focusedInputSnapshot(role: role), generation: 1)
        }
        XCTAssertTrue(context(role: "AXTextField").isSingleLineField)
        XCTAssertTrue(context(role: "AXComboBox").isSingleLineField)
        XCTAssertFalse(context(role: "AXTextArea").isSingleLineField)
        XCTAssertFalse(context(role: "AXWebArea").isSingleLineField)
    }

    /// Any visible character after the caret, even lines further down the captured window, is the
    /// host's own text that a second ghost row would paint over; trailing whitespace alone is not.
    func test_focusedInputContext_hasTrailingContentOnlyForVisibleCharactersAfterTheCaret() {
        func context(trailingText: String) -> FocusedInputContext {
            FocusedInputContext(snapshot: CotabbyTestFixtures.focusedInputSnapshot(trailingText: trailingText), generation: 1)
        }
        XCTAssertFalse(context(trailingText: "").hasTrailingContent)
        XCTAssertFalse(context(trailingText: "  \n\t\n").hasTrailingContent)
        XCTAssertTrue(context(trailingText: " world").hasTrailingContent)
        XCTAssertTrue(context(trailingText: "\n\nNext paragraph").hasTrailingContent)
    }

    /// Generation and ghost rendering pause while the host shows uncommitted text. A marked range of
    /// length zero holds no text, so it must not pause them; the context must agree with its snapshot.
    func test_hostMarkedText_requiresANonEmptyMarkedRange() {
        let cases: [(range: NSRange?, hasMarkedText: Bool)] = [
            (nil, false),
            (NSRange(location: 5, length: 0), false),
            (NSRange(location: 5, length: 3), true)
        ]
        for testCase in cases {
            let snapshot = CotabbyTestFixtures.focusedInputSnapshot(hostMarkedTextRange: testCase.range)
            XCTAssertEqual(snapshot.hasHostMarkedText, testCase.hasMarkedText, "\(String(describing: testCase.range))")
            XCTAssertEqual(
                FocusedInputContext(snapshot: snapshot, generation: 1).hasHostMarkedText,
                testCase.hasMarkedText,
                "\(String(describing: testCase.range))"
            )
        }
    }
}
