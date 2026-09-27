import XCTest
@testable import Cotabby

/// Tests for streamed-render monotonicity and safe lookahead: partials must neither replace a
/// longer visible offer nor turn an unfinished hidden token into the next acceptable word.
final class StreamedGhostTextPolicyTests: XCTestCase {
    func test_hiddenTrailingFragmentWaitsForItsBoundaryBeforeBeingBuffered() {
        XCTAssertEqual(buffered("world ag"), "world ")
        XCTAssertEqual(buffered("world again tom"), "world again ")
        XCTAssertEqual(buffered("world again\n  tom"), "world again\n  ")
        XCTAssertEqual(buffered("world ag\t"), "world ag\t")
    }

    func test_punctuationCompletesHiddenWordsWithoutNeedingWhitespace() {
        for text in ["world again.", "world again,", "world again!", "world (again)",
                     "world \"again\"", "world 'again'", "world ‘again’"] {
            XCTAssertEqual(buffered(text), text)
        }
    }

    func test_lexicalConnectorsAndIdentifiersDoNotCompleteHiddenTokens() {
        for token in ["don't", "don'", "state-of-the-art", "state-", "item_2", "42", "(ag"] {
            XCTAssertEqual(buffered("world " + token), "world ", token)
        }
    }

    func test_visibleCharactersAndWhitespaceSurviveBufferTrimming() {
        XCTAssertEqual(StreamedGhostTextPolicy.completedBufferedPrediction("world ag", visibleCharacterCount: 7), "world a")
        XCTAssertEqual(StreamedGhostTextPolicy.completedBufferedPrediction("world ag", visibleCharacterCount: 8), "world ag")
        XCTAssertEqual(StreamedGhostTextPolicy.completedBufferedPrediction("world ag", visibleCharacterCount: 99), "world ag")
        XCTAssertEqual(StreamedGhostTextPolicy.completedBufferedPrediction("world ag", visibleCharacterCount: -1), "world ")
        XCTAssertEqual(StreamedGhostTextPolicy.completedBufferedPrediction("  ag", visibleCharacterCount: 0), "  ")
        XCTAssertEqual(StreamedGhostTextPolicy.completedBufferedPrediction("", visibleCharacterCount: 0), "")
    }

    func test_bufferBoundariesCountUserCharactersRatherThanUTF16Units() {
        let visible = "🐈 café"
        XCTAssertEqual(StreamedGhostTextPolicy.completedBufferedPrediction(visible + " cafe\u{301}",
            visibleCharacterCount: visible.count), visible + " ")
        XCTAssertEqual(StreamedGhostTextPolicy.completedBufferedPrediction("你好世界", visibleCharacterCount: 2), "你好")
    }

    private func buffered(_ text: String) -> String {
        StreamedGhostTextPolicy.completedBufferedPrediction(text, visibleCharacterCount: "world".count)
    }

    func test_renderableExtensionRequiresAStrictlyLongerPrefixExtension() {
        let cases: [(candidate: String, rendered: String?, expected: Bool, reason: String)] = [
            (" wor", nil, true, "the first non-empty partial renders"),
            (" wor", "", true, "an empty rendered string behaves like nothing rendered"),
            ("", nil, false, "an empty candidate never renders"),
            ("", " wor", false, "an empty candidate never replaces visible text"),
            (" world", " wor", true, "a strict extension renders"),
            (" wor", " world", false, "an older, shorter partial arriving late is dropped"),
            (" world", " world", false, "equal text is redundant"),
            // A normalizer can legally rewrite a fragment rather than extend it; the render must wait
            // for the authoritative final result instead of flickering through rewrites.
            (" worse idea", " world", false, "a divergent rewrite is dropped"),
            // Length is measured in user characters: a combining accent merges into the last visible
            // character, so it does not lengthen the ghost and cannot count as an extension.
            (" cafe\u{301}", " cafe", false, "a combining mark does not add a character")
        ]
        for testCase in cases {
            XCTAssertEqual(
                StreamedGhostTextPolicy.isRenderableExtension(
                    candidate: testCase.candidate, currentlyRendered: testCase.rendered
                ),
                testCase.expected,
                testCase.reason
            )
        }
    }
}
