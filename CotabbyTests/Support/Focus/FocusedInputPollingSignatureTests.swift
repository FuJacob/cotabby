import XCTest
@testable import Cotabby

/// Replays navigation with identical composer geometry, without depending on a live browser.
final class FocusedInputPollingSignatureTests: XCTestCase {
    func test_navigationFactsDistinguishReusedComposer() {
        let original = FocusedInputPollingSignature(context: CotabbyTestFixtures.focusedInputSnapshot())
        let navigations = [
            CotabbyTestFixtures.focusedInputSnapshot(focusedURLString: "https://chat.example/conversation/two"),
            CotabbyTestFixtures.focusedInputSnapshot(windowTitle: "Another conversation"),
            CotabbyTestFixtures.focusedInputSnapshot(fieldPlaceholder: "Message #another-channel")
        ]
        for snapshot in navigations {
            XCTAssertNotEqual(original, FocusedInputPollingSignature(context: snapshot))
        }
    }

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

    func test_navigationFactsBreakContinuityEvenWithIdenticalGeometry() {
        let original = FocusedInputPollingSignature(context: CotabbyTestFixtures.focusedInputSnapshot())
        let navigations = [
            CotabbyTestFixtures.focusedInputSnapshot(focusedURLString: "https://chat.example/conversation/two"),
            CotabbyTestFixtures.focusedInputSnapshot(windowTitle: "Another conversation"),
            CotabbyTestFixtures.focusedInputSnapshot(fieldPlaceholder: "Message #another-channel"),
            CotabbyTestFixtures.focusedInputSnapshot(processIdentifier: 456)
        ]
        for snapshot in navigations {
            XCTAssertFalse(FocusedInputPollingSignature(context: snapshot).continuesField(of: original))
        }
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
