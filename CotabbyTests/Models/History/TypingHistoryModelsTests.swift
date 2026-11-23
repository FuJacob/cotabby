import XCTest
@testable import Cotabby

/// Tests for the two rules every typing-history path shares: which part of a record is the user's
/// own writing, and which texts are long enough to keep at all.
final class TypingHistoryModelsTests: XCTestCase {
    private func record(_ text: String, typedLength: Int?) -> TypingHistoryRecord {
        TypingHistoryRecord(
            id: UUID(), bundleIdentifier: "com.apple.mail", domain: nil,
            createdAt: Date(), updatedAt: Date(), text: text, source: .recorded, typedLength: typedLength
        )
    }

    /// Text after the caret is usually someone else's (the quoted thread in a reply), so only the
    /// part before the caret is learned from. A record written before the caret split existed, or
    /// whose split no longer falls inside its text, counts whole.
    func test_typedText_isThePartBeforeTheCaretWhenTheSplitIsKnown() {
        XCTAssertEqual(record("Thanks!\n\nOn Monday Luuk wrote:", typedLength: 7).typedText, "Thanks!")
        XCTAssertEqual(record("Thanks!", typedLength: 0).typedText, "", "nothing was typed before the caret")
        XCTAssertEqual(record("Thanks!", typedLength: nil).typedText, "Thanks!")
        XCTAssertEqual(record("Thanks!", typedLength: 40).typedText, "Thanks!")
        // The split counts user-visible characters, so a composed emoji is never cut in half.
        XCTAssertEqual(record("👍🏽 sounds good", typedLength: 1).typedText, "👍🏽")
    }

    /// One threshold for live recording and import. Surrounding whitespace does not count toward
    /// it, so a padded fragment is still a fragment.
    func test_isWorthKeeping_countsOnlyTrimmedTextAgainstTheMinimum() {
        let minimum = TypingHistoryRecord.minimumCharacters

        XCTAssertTrue(TypingHistoryRecord.isWorthKeeping(String(repeating: "a", count: minimum)))
        XCTAssertFalse(TypingHistoryRecord.isWorthKeeping(String(repeating: "a", count: minimum - 1)))
        XCTAssertFalse(TypingHistoryRecord.isWorthKeeping("\n " + String(repeating: "a", count: minimum - 1) + "  \n"))
    }
}
