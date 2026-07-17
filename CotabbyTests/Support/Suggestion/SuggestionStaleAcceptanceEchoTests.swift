import XCTest
@testable import Cotabby

/// Focused coverage for one responsibility of `SuggestionSessionReconciler`.
final class SuggestionStaleAcceptanceEchoTests: XCTestCase {
    func test_isStaleAcceptanceEcho_dropsRepeatOfAcceptedTailWhileFieldUnchanged() {
        XCTAssertTrue(
            SuggestionSessionReconciler.isStaleAcceptanceEcho(
                resultText: " today",
                acceptedChunk: " today",
                currentPrecedingText: "what's on your mind",
                acceptedPrecedingText: "what's on your mind"
            )
        )
    }

    func test_isStaleAcceptanceEcho_toleratesLeadingWhitespaceDifference() {
        XCTAssertTrue(
            SuggestionSessionReconciler.isStaleAcceptanceEcho(
                resultText: "today",
                acceptedChunk: " today",
                currentPrecedingText: "what's on your mind",
                acceptedPrecedingText: "what's on your mind"
            )
        )
    }

    func test_isStaleAcceptanceEcho_allowsSuggestionOnceTheInsertPublished() {
        XCTAssertFalse(
            SuggestionSessionReconciler.isStaleAcceptanceEcho(
                resultText: " today",
                acceptedChunk: " today",
                currentPrecedingText: "what's on your mind today",
                acceptedPrecedingText: "what's on your mind"
            )
        )
    }

    func test_isStaleAcceptanceEcho_allowsGenuinelyDifferentContinuation() {
        XCTAssertFalse(
            SuggestionSessionReconciler.isStaleAcceptanceEcho(
                resultText: " tomorrow",
                acceptedChunk: " today",
                currentPrecedingText: "what's on your mind",
                acceptedPrecedingText: "what's on your mind"
            )
        )
    }

    func test_isStaleAcceptanceEcho_ignoresWhitespaceOnlyAcceptedChunk() {
        XCTAssertFalse(
            SuggestionSessionReconciler.isStaleAcceptanceEcho(
                resultText: " ",
                acceptedChunk: " ",
                currentPrecedingText: "what's on your mind",
                acceptedPrecedingText: "what's on your mind"
            )
        )
    }
}
