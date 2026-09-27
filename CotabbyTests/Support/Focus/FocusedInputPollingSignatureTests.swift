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
