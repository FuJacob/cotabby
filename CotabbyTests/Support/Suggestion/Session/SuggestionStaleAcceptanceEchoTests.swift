import XCTest
@testable import Cotabby

/// Detection of the Chromium AX-publish race where regeneration re-proposes the chunk that was just
/// fully accepted because the host has not published the insert yet.
final class SuggestionStaleAcceptanceEchoTests: XCTestCase {
    private let field = "what's on your mind"

    func test_isStaleAcceptanceEcho_dropsRepeatOfAcceptedChunkWhileFieldIsUnchanged() {
        // Whitespace and newlines on either side are ignored: the model may re-emit the chunk with
        // or without its leading boundary space.
        for (result, accepted) in [(" today", " today"), ("today", " today"), (" today\n", "today ")] {
            XCTAssertTrue(
                SuggestionSessionReconciler.isStaleAcceptanceEcho(
                    resultText: result, acceptedChunk: accepted,
                    currentPrecedingText: field, acceptedPrecedingText: field
                ),
                "\(result.debugDescription) vs \(accepted.debugDescription)"
            )
        }
    }

    func test_isStaleAcceptanceEcho_allowsSuggestionOnceTheInsertPublishedOrTheUserTyped() {
        for current in [field + " today", field + "x", "what's on your"] {
            XCTAssertFalse(
                SuggestionSessionReconciler.isStaleAcceptanceEcho(
                    resultText: " today", acceptedChunk: " today",
                    currentPrecedingText: current, acceptedPrecedingText: field
                ),
                current
            )
        }
    }

    func test_isStaleAcceptanceEcho_allowsDifferentOrLongerContinuations() {
        // Only an exact (trimmed) repeat is an echo; a continuation that merely starts with the
        // accepted chunk carries new text and must still show.
        for result in [" tomorrow", " today and tomorrow", " Today"] {
            XCTAssertFalse(
                SuggestionSessionReconciler.isStaleAcceptanceEcho(
                    resultText: result, acceptedChunk: " today",
                    currentPrecedingText: field, acceptedPrecedingText: field
                ),
                result
            )
        }
    }

    func test_isStaleAcceptanceEcho_ignoresEmptyOrWhitespaceOnlyAcceptedChunk() {
        for accepted in ["", " ", "\n"] {
            XCTAssertFalse(
                SuggestionSessionReconciler.isStaleAcceptanceEcho(
                    resultText: accepted, acceptedChunk: accepted,
                    currentPrecedingText: field, acceptedPrecedingText: field
                ),
                accepted.debugDescription
            )
        }
    }
}
