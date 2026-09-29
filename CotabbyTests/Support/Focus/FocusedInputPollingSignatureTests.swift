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
    /// The original's surface facts are known values: a fact that changes from one known value to
    /// another is navigation, whereas a fact that merely failed to read is covered separately below.
    func test_identityFactsDistinguishReusedComposerAndBreakContinuity() {
        let url = "https://chat.example/conversation/one"
        let title = "Conversation one"
        let placeholder = "Message #channel"
        let original = FocusedInputPollingSignature(context: CotabbyTestFixtures.focusedInputSnapshot(
            focusedURLString: url, windowTitle: title, fieldPlaceholder: placeholder
        ))
        func snapshot(
            processIdentifier: Int32 = 123, bundleIdentifier: String = "com.example.TestApp",
            role: String = "AXTextField", subrole: String? = nil,
            focusedURLString: String = url, windowTitle: String = title, fieldPlaceholder: String = placeholder
        ) -> FocusedInputSnapshot {
            CotabbyTestFixtures.focusedInputSnapshot(
                bundleIdentifier: bundleIdentifier, processIdentifier: processIdentifier, role: role, subrole: subrole,
                focusedURLString: focusedURLString, windowTitle: windowTitle, fieldPlaceholder: fieldPlaceholder
            )
        }
        let changes: [(label: String, snapshot: FocusedInputSnapshot)] = [
            ("url", snapshot(focusedURLString: "https://chat.example/conversation/two")),
            ("window title", snapshot(windowTitle: "Another conversation")),
            ("placeholder", snapshot(fieldPlaceholder: "Message #another-channel")),
            ("pid", snapshot(processIdentifier: 456)),
            ("bundle", snapshot(bundleIdentifier: "com.example.Other")),
            ("role", snapshot(role: "AXTextArea")),
            ("subrole", snapshot(subrole: "AXSearchField"))
        ]
        for (label, snapshot) in changes {
            let changed = FocusedInputPollingSignature(context: snapshot)
            XCTAssertNotEqual(original, changed, label)
            XCTAssertFalse(changed.continuesField(of: original), label)
        }
    }

    /// A surface fact that fails to read on one poll (the host was busy and the AX call hit its
    /// timeout) arrives as nil. That poll still observes the same field: treating it as navigation
    /// advanced the focus sequence and retired the active suggestion mid-way through rapid accepts.
    func test_unreadableSurfaceFactsContinueTheField() {
        let known = FocusedInputPollingSignature(context: CotabbyTestFixtures.focusedInputSnapshot(
            focusedURLString: "https://chat.example/conversation/one", windowTitle: "Conversation one",
            fieldPlaceholder: "Message"
        ))
        let blankPolls: [(label: String, snapshot: FocusedInputSnapshot)] = [
            ("title", CotabbyTestFixtures.focusedInputSnapshot(
                focusedURLString: "https://chat.example/conversation/one", fieldPlaceholder: "Message")),
            ("url", CotabbyTestFixtures.focusedInputSnapshot(windowTitle: "Conversation one", fieldPlaceholder: "Message")),
            ("all facts", CotabbyTestFixtures.focusedInputSnapshot())
        ]
        for (label, snapshot) in blankPolls {
            let blank = FocusedInputPollingSignature(context: snapshot)
            XCTAssertTrue(blank.continuesField(of: known), label)
            XCTAssertTrue(known.continuesField(of: blank), "\(label): the facts coming back is not navigation either")
        }
    }

    /// The tracker stores each continuing poll with unreadable facts filled from the previous one,
    /// so a navigation that straddles a blank poll (A, nil, B) is still caught on the B poll.
    func test_carriedKnownFactsStillCatchNavigationAfterAnUnreadablePoll() {
        let first = FocusedInputPollingSignature(context: CotabbyTestFixtures.focusedInputSnapshot(
            windowTitle: "Conversation one"
        ))
        let blank = FocusedInputPollingSignature(context: CotabbyTestFixtures.focusedInputSnapshot())
        let second = FocusedInputPollingSignature(context: CotabbyTestFixtures.focusedInputSnapshot(
            windowTitle: "Conversation two"
        ))

        XCTAssertTrue(second.continuesField(of: blank), "Against the raw blank poll the switch is invisible")
        let carried = blank.carryingKnownSurfaceFacts(from: first)
        XCTAssertEqual(carried, first, "Nothing but the unreadable title was inherited")
        XCTAssertFalse(second.continuesField(of: carried), "Against the carried signature it is navigation")
        XCTAssertEqual(blank.carryingKnownSurfaceFacts(from: nil), blank)
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
}
