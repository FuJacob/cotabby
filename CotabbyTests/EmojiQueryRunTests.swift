import XCTest
@testable import Cotabby

/// Tests for the trailing `:query` run measurement used to size the commit deletion.
///
/// The picker deletes exactly this run before inserting the glyph, so the count must match what is
/// actually in the field for both Mode A (`:smile`) and Mode B (`:smile:`), and must refuse text that
/// does not end in a run so we never delete unrelated characters.
final class EmojiQueryRunTests: XCTestCase {

    func test_measuresModeARun() {
        XCTAssertEqual(EmojiQueryRun.trailingRunUTF16Length(in: "hello :smile"), 6)
    }

    func test_measuresModeBRunWithClosingColon() {
        XCTAssertEqual(EmojiQueryRun.trailingRunUTF16Length(in: "hello :smile:"), 7)
    }

    func test_measuresAliasPunctuation() {
        XCTAssertEqual(EmojiQueryRun.trailingRunUTF16Length(in: "nice :+1"), 3)
    }

    func test_measuresBareTrigger() {
        XCTAssertEqual(EmojiQueryRun.trailingRunUTF16Length(in: "a :"), 1)
    }

    func test_picksTrailingRunWhenMultiplePresent() {
        XCTAssertEqual(EmojiQueryRun.trailingRunUTF16Length(in: ":tada done :smile"), 6)
    }

    func test_returnsNilWhenNoTrailingRun() {
        XCTAssertNil(EmojiQueryRun.trailingRunUTF16Length(in: "hello world"))
        XCTAssertNil(EmojiQueryRun.trailingRunUTF16Length(in: ""))
        XCTAssertNil(EmojiQueryRun.trailingRunUTF16Length(in: ":smile not anymore"))
    }
}
