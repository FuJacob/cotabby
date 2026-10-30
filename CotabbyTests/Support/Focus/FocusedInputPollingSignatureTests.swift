import XCTest
@testable import Cotabby

/// Replays navigation with identical composer geometry, without depending on a live browser.
final class FocusedInputPollingSignatureTests: XCTestCase {
    func test_sameHostDifferentConversationAndFragmentAreNavigation() {
        let first = FocusedInputPollingSignature(context: CotabbyTestFixtures.focusedInputSnapshot(
            focusedURLString: "https://chat.example/conversation/one#thread-a"
        ))
        for url in ["https://chat.example/conversation/two#thread-a", "https://chat.example/conversation/one#thread-b"] {
            XCTAssertNotEqual(first, FocusedInputPollingSignature(context:
                CotabbyTestFixtures.focusedInputSnapshot(focusedURLString: url)))
        }
    }

    func test_typingAndAXWrapperChurnDoNotSignalNavigation() {
        let first = FocusedInputPollingSignature(context: CotabbyTestFixtures.focusedInputSnapshot())
        let typed = FocusedInputPollingSignature(context: CotabbyTestFixtures.focusedInputSnapshot(
            elementIdentifier: "new-wrapper", precedingText: "Hello world", focusChangeSequence: 2
        ))
        XCTAssertEqual(first, typed)
        XCTAssertTrue(typed.continuesField(of: first))
    }

    func test_composerResizingInPlaceContinuesTheSameField() {
        let original = signature(frame: CGRect(x: 100, y: 500, width: 400, height: 32))
        // A bottom-anchored chat composer grows upward when a line wraps; a top-anchored editor
        // grows downward. Either way the writer is still in the same field.
        for grown in [CGRect(x: 100, y: 482, width: 400, height: 50), CGRect(x: 100, y: 500, width: 400, height: 50)] {
            XCTAssertTrue(signature(frame: grown).continuesField(of: original), "\(grown)")
        }
        XCTAssertTrue(original.continuesField(of: original))
    }

    func test_distinctFieldsInTheSameColumnAreNotContinuous() {
        let original = signature(frame: CGRect(x: 100, y: 500, width: 400, height: 32))
        let others = [
            CGRect(x: 100, y: 560, width: 400, height: 32), // the next field of a stacked form
            CGRect(x: 140, y: 500, width: 400, height: 32), // a field beside it
            CGRect(x: 100, y: 500, width: 360, height: 32)  // a narrower field
        ]
        for frame in others {
            XCTAssertFalse(signature(frame: frame).continuesField(of: original), "\(frame)")
        }
    }

    /// Every identity fact must match for continuity, even when the composer geometry is reused
    /// verbatim (a chat app swapping conversations inside one window is the motivating case).
    func test_identityFactsDistinguishReusedComposerAndBreakContinuity() {
        let original = FocusedInputPollingSignature(context: CotabbyTestFixtures.focusedInputSnapshot())
        let changes: [(label: String, snapshot: FocusedInputSnapshot)] = [
            ("url", CotabbyTestFixtures.focusedInputSnapshot(focusedURLString: "https://chat.example/conversation/two")),
            ("window title", CotabbyTestFixtures.focusedInputSnapshot(windowTitle: "Another conversation")),
            ("placeholder", CotabbyTestFixtures.focusedInputSnapshot(fieldPlaceholder: "Message #another-channel")),
            ("pid", CotabbyTestFixtures.focusedInputSnapshot(processIdentifier: 456)),
            ("bundle", CotabbyTestFixtures.focusedInputSnapshot(bundleIdentifier: "com.example.Other")),
            ("role", CotabbyTestFixtures.focusedInputSnapshot(role: "AXTextArea")),
            ("subrole", CotabbyTestFixtures.focusedInputSnapshot(subrole: "AXSearchField"))
        ]
        for (label, snapshot) in changes {
            let changed = FocusedInputPollingSignature(context: snapshot)
            XCTAssertNotEqual(original, changed, label)
            XCTAssertFalse(changed.continuesField(of: original), label)
        }
    }

    /// Replays the Claude desktop composer as logged: it reports "Type / for commands." while empty,
    /// keeps it for a poll after the first character (AX lags the DOM), drops it once text exists,
    /// and restores it after the field is cleared. None of that is navigation.
    func test_placeholderShownOnlyWhileEmptyKeepsOneSessionAcrossTypingAndClearing() {
        let shown = "Type / for commands."
        let polls: [(text: String, placeholder: String?)] = [
            ("", shown), ("d", shown), ("df", nil), ("dfasdf", nil), ("", nil), ("", shown), ("h", nil)
        ]
        let boundaries = sessionBoundaries(polls.map { poll in
            CotabbyTestFixtures.focusedInputSnapshot(precedingText: poll.text, fieldPlaceholder: poll.placeholder)
        })
        XCTAssertEqual(boundaries, [0], "Only the first poll opens a focus session")
    }

    func test_continuationRemembersTheLastShownPlaceholderWhileTheHostHidesIt() {
        let empty = FocusedInputPollingSignature(context: CotabbyTestFixtures.focusedInputSnapshot(
            precedingText: "", fieldPlaceholder: "Message #general"
        ))
        let typed = FocusedInputPollingSignature(context: CotabbyTestFixtures.focusedInputSnapshot(
            precedingText: "Hello", fieldPlaceholder: nil
        ))
        XCTAssertEqual(typed.continuation(of: empty)?.fieldPlaceholder, "Message #general")
    }

    /// A reused composer whose placeholder names another channel or chat is still a new field, even
    /// when the user had typed in the first one (so its placeholder was hidden at the time).
    func test_differentPlaceholderIsNavigationEvenAfterTypingHidThePreviousOne() {
        let polls: [FocusedInputSnapshot] = [
            CotabbyTestFixtures.focusedInputSnapshot(precedingText: "", fieldPlaceholder: "Message #general"),
            CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Draft", fieldPlaceholder: nil),
            CotabbyTestFixtures.focusedInputSnapshot(precedingText: "", fieldPlaceholder: "Message #random")
        ]
        XCTAssertEqual(sessionBoundaries(polls), [0, 2])
    }

    /// With no placeholder seen yet, one appearing is treated as a possible different field. This
    /// keeps detecting navigation from a drafted field to an empty one that reuses the geometry, at
    /// the cost of one new session when a field first observed with text is cleared.
    func test_placeholderAppearingWhereNoneWasShownIsNavigation() {
        let drafted = FocusedInputPollingSignature(context: CotabbyTestFixtures.focusedInputSnapshot(
            precedingText: "Draft", fieldPlaceholder: nil
        ))
        let cleared = FocusedInputPollingSignature(context: CotabbyTestFixtures.focusedInputSnapshot(
            precedingText: "", fieldPlaceholder: "Reply"
        ))
        XCTAssertNil(cleared.continuation(of: drafted))
        XCTAssertEqual(cleared.changedFacts(since: drafted), ["placeholder"])
    }

    func test_changedFactsNamesOnlyTheFactsThatBrokeContinuity() {
        let original = FocusedInputPollingSignature(context: CotabbyTestFixtures.focusedInputSnapshot(
            fieldPlaceholder: "Reply"
        ))
        let hidden = FocusedInputPollingSignature(context: CotabbyTestFixtures.focusedInputSnapshot())
        XCTAssertEqual(hidden.changedFacts(since: original), [], "A hidden placeholder is not a changed fact")
        let moved = FocusedInputPollingSignature(context: CotabbyTestFixtures.focusedInputSnapshot(
            inputFrameRect: CGRect(x: 40, y: 0, width: 240, height: 32),
            windowTitle: "Another conversation"
        ))
        XCTAssertEqual(moved.changedFacts(since: original), ["title", "frame"])
    }

    func test_subPointFrameJitterRoundsToTheSameSignature() {
        // AX frames arrive as floating-point points; rounding keeps half-point jitter from reading as
        // a different field.
        let original = signature(frame: CGRect(x: 100, y: 500, width: 400, height: 32))
        let jittered = signature(frame: CGRect(x: 100.3, y: 499.8, width: 400.2, height: 31.9))
        XCTAssertEqual(original, jittered)
        XCTAssertTrue(jittered.continuesField(of: original))
    }

    func test_geometryAndGeometrylessSnapshotsNeverContinueEachOther() {
        // Losing (or gaining) the frame switches the anchor kind; the two kinds are never comparable.
        let withFrame = FocusedInputPollingSignature(context: CotabbyTestFixtures.focusedInputSnapshot())
        let withoutFrame = FocusedInputPollingSignature(context: CotabbyTestFixtures.focusedInputSnapshot(inputFrameRect: nil))
        XCTAssertFalse(withoutFrame.continuesField(of: withFrame))
        XCTAssertFalse(withFrame.continuesField(of: withoutFrame))
    }

    func test_fieldsWithoutGeometryContinueOnlyWithTheSameElement() {
        let original = FocusedInputPollingSignature(context: CotabbyTestFixtures.focusedInputSnapshot(inputFrameRect: nil))
        let same = FocusedInputPollingSignature(context: CotabbyTestFixtures.focusedInputSnapshot(inputFrameRect: nil))
        let other = FocusedInputPollingSignature(context: CotabbyTestFixtures.focusedInputSnapshot(
            elementIdentifier: "other-field", inputFrameRect: nil
        ))
        XCTAssertTrue(same.continuesField(of: original))
        XCTAssertFalse(other.continuesField(of: original))
    }

    private func signature(frame: CGRect) -> FocusedInputPollingSignature {
        FocusedInputPollingSignature(context: CotabbyTestFixtures.focusedInputSnapshot(inputFrameRect: frame))
    }

    /// Folds polls the way `FocusTracker.captureSnapshot` does and returns the indices of the polls
    /// that opened a new focus session (and so would advance `focusChangeSequence`).
    private func sessionBoundaries(_ polls: [FocusedInputSnapshot]) -> [Int] {
        var remembered: FocusedInputPollingSignature?
        var boundaries: [Int] = []
        for (index, poll) in polls.enumerated() {
            let next = FocusedInputPollingSignature(context: poll)
            if let previous = remembered, let continued = next.continuation(of: previous) {
                remembered = continued
            } else {
                boundaries.append(index)
                remembered = next
            }
        }
        return boundaries
    }
}
