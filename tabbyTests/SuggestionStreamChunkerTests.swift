import XCTest
@testable import tabby

/// Tests for streaming-safe output boundaries.
///
/// These are intentionally pure. The runtime may emit arbitrary token pieces, but the overlay
/// should only receive completed user-facing chunks.
final class SuggestionStreamChunkerTests: XCTestCase {
    func test_stablePrefix_waitsForWordBoundary() {
        XCTAssertEqual(
            SuggestionStreamChunker.stablePrefix(from: " autocom", isFinal: false),
            ""
        )

        XCTAssertEqual(
            SuggestionStreamChunker.stablePrefix(from: " autocomplete systems", isFinal: false),
            " autocomplete"
        )
    }

    func test_stablePrefix_keepsPhrasePunctuation() {
        XCTAssertEqual(
            SuggestionStreamChunker.stablePrefix(from: " sounds good,", isFinal: false),
            " sounds good,"
        )
    }

    func test_stablePrefix_returnsFinalTextEvenWithoutBoundary() {
        XCTAssertEqual(
            SuggestionStreamChunker.stablePrefix(from: " autocomplete", isFinal: true),
            " autocomplete"
        )
    }
}
