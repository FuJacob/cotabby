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
    }
}
