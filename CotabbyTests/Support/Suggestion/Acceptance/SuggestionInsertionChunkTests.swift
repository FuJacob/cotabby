import XCTest
@testable import Cotabby

/// Covers the accept-time text shaping in `SuggestionSessionReconciler`: how an acceptance chunk's
/// leading whitespace is reconciled against the live field, how the opt-in trailing space is added,
/// and how accepted words are counted for metrics.
final class SuggestionInsertionChunkTests: XCTestCase {
    private struct ChunkCase {
        let chunk: String
        let preceding: String
        let expected: String
        let reason: String
    }

    // MARK: - insertionChunk(forAcceptedChunk:precedingText:)

    func test_insertionChunk_dropsLeadingHorizontalWhitespaceWhenFieldAlreadyEndsInIt() {
        let cases = [
            ChunkCase(chunk: " you", preceding: "How are ", expected: "you",
                      reason: "field space plus chunk space must not stack"),
            ChunkCase(chunk: "  you", preceding: "How are ", expected: "you",
                      reason: "the reported 'bunch of spaces' case: the whole leading run collapses"),
            ChunkCase(chunk: " you", preceding: "How are\t", expected: "you",
                      reason: "a tab is horizontal boundary whitespace"),
            ChunkCase(chunk: " you", preceding: "How are\u{00A0}", expected: "you",
                      reason: "Mail publishes a typed space as NBSP, which is still horizontal whitespace"),
            ChunkCase(chunk: " ", preceding: "Hello ", expected: "",
                      reason: "a whitespace-only chunk against a field space types nothing"),
            ChunkCase(chunk: "\nnext", preceding: "first ", expected: "\nnext",
                      reason: "the drop predicate mirrors the guard, so a structural leading newline survives")
        ]
        for testCase in cases {
            XCTAssertEqual(
                SuggestionSessionReconciler.insertionChunk(forAcceptedChunk: testCase.chunk, precedingText: testCase.preceding),
                testCase.expected,
                testCase.reason
            )
        }
    }

    /// Trust-the-model: when the field does not end in horizontal whitespace, the chunk is typed
    /// verbatim. A genuine new word arrives with the model's own leading space; when the model
    /// omits it the words glue, which is exactly what the ghost text showed, so accept stays WYSIWYG.
    func test_insertionChunk_typesChunkVerbatimWhenFieldDoesNotEndInHorizontalWhitespace() {
        let cases = [
            ChunkCase(chunk: " you", preceding: "How are", expected: " you",
                      reason: "the model's leading space is the real word boundary"),
            ChunkCase(chunk: " are", preceding: "How are you", expected: " are",
                      reason: "mid-suggestion inter-word space survives"),
            ChunkCase(chunk: " you", preceding: "", expected: " you",
                      reason: "an empty field has no whitespace to reconcile against"),
            ChunkCase(chunk: "World", preceding: "", expected: "World",
                      reason: "no boundary is synthesized at the start of an empty field"),
            ChunkCase(chunk: " you", preceding: "line\n", expected: " you",
                      reason: "a newline is not horizontal whitespace"),
            ChunkCase(chunk: "World", preceding: "line\n", expected: "World",
                      reason: "no indent space is synthesized after a line break"),
            ChunkCase(chunk: "noon", preceding: "after", expected: "noon",
                      reason: "issue #621: 'after' + 'noon' must glue into 'afternoon'"),
            ChunkCase(chunk: "World", preceding: "Hello", expected: "World",
                      reason: "no boundary is synthesized between letters"),
            ChunkCase(chunk: "abc", preceding: "123", expected: "abc",
                      reason: "no boundary is synthesized across a digit/letter seam"),
            ChunkCase(chunk: "1st", preceding: "Hello", expected: "1st",
                      reason: "no boundary is synthesized across a letter/digit seam"),
            ChunkCase(chunk: ".", preceding: "Hello", expected: ".",
                      reason: "sentence punctuation hugs the prior word"),
            ChunkCase(chunk: "'s", preceding: "John", expected: "'s",
                      reason: "a possessive hugs the prior word"),
            ChunkCase(chunk: ", more", preceding: "first", expected: ", more",
                      reason: "a list continuation hugs the prior word"),
            ChunkCase(chunk: "World", preceding: "Hello (", expected: "World",
                      reason: "opening punctuation in the prefix is hugged, not separated")
        ]
        for testCase in cases {
            XCTAssertEqual(
                SuggestionSessionReconciler.insertionChunk(forAcceptedChunk: testCase.chunk, precedingText: testCase.preceding),
                testCase.expected,
                testCase.reason
            )
        }
    }

    // MARK: - insertionChunkAppendingTrailingSpace(_:)

    func test_insertionChunkAppendingTrailingSpace_appendsOnlyAfterAFinishedSpaceDelimitedWord() {
        let cases: [(chunk: String, expected: String, reason: String)] = [
            ("hello", "hello ", "a finished word gets the convenience space"),
            ("section 12", "section 12 ", "a trailing digit is a finished word"),
            ("done.", "done.", "trailing punctuation already marks the boundary"),
            ("really?!", "really?!", "a trailing punctuation run already marks the boundary"),
            ("(yes)", "(yes)", "a closing bracket already marks the boundary"),
            ("hello ", "hello ", "existing whitespace is not doubled"),
            ("資料", "資料", "space-less scripts never separate words with spaces"),
            ("", "", "an empty chunk stays empty")
        ]
        for testCase in cases {
            XCTAssertEqual(
                SuggestionSessionReconciler.insertionChunkAppendingTrailingSpace(testCase.chunk),
                testCase.expected,
                testCase.reason
            )
        }
    }

    // MARK: - acceptanceChunkConsumingTrailingSpace(_:remainingText:)

    func test_acceptanceChunkConsumingTrailingSpace_takesOnlyTheModelsOwnHorizontalWhitespace() {
        let cases: [(chunk: String, remaining: String, expected: String, reason: String)] = [
            ("world", "world how are you", "world ", "the following space lands with this accept"),
            (" world", " world how", " world ", "leading whitespace from the chunker is kept"),
            ("world", "world\t  how", "world\t  ", "the whole horizontal run is consumed"),
            ("world", "world", "world", "end of suggestion: the exhaustion-time append covers it"),
            ("line", "line\nnext", "line", "a newline must not be swallowed as a space"),
            ("world", "world, how", "world", "punctuation stays attached to the model's layout"),
            ("done.", "done. next", "done.", "a chunk ending in punctuation is not a finished word"),
            ("資料", "資料 です", "資料", "space-less scripts never take even a stray following space"),
            ("world", "world\u{00A0}how", "world", "only ASCII space and tab are consumed, not NBSP")
        ]
        for testCase in cases {
            XCTAssertEqual(
                SuggestionSessionReconciler.acceptanceChunkConsumingTrailingSpace(
                    testCase.chunk, remainingText: testCase.remaining
                ),
                testCase.expected,
                testCase.reason
            )
        }
    }

    // MARK: - acceptedWordCount(in:)

    func test_acceptedWordCount_countsOnlyTokensWithAlphanumerics() {
        let cases: [(text: String, expected: Int)] = [
            ("hello, !!! world 123 --", 3),
            ("", 0),
            ("   \n\t", 0),
            ("first\nsecond\tthird", 3),
            ("資料 です", 2),
            ("don't state-of-the-art", 2)
        ]
        for testCase in cases {
            XCTAssertEqual(
                SuggestionSessionReconciler.acceptedWordCount(in: testCase.text),
                testCase.expected,
                testCase.text.debugDescription
            )
        }
    }
}
