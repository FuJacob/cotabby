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

    func test_firstNonEmptyPartialRenders() {
        XCTAssertTrue(StreamedGhostTextPolicy.isRenderableExtension(candidate: " wor", currentlyRendered: nil))
        XCTAssertTrue(StreamedGhostTextPolicy.isRenderableExtension(candidate: " wor", currentlyRendered: ""))
    }

    func test_emptyCandidateNeverRenders() {
        XCTAssertFalse(StreamedGhostTextPolicy.isRenderableExtension(candidate: "", currentlyRendered: nil))
        XCTAssertFalse(StreamedGhostTextPolicy.isRenderableExtension(candidate: "", currentlyRendered: " wor"))
    }

    func test_strictExtensionRenders() {
        XCTAssertTrue(
            StreamedGhostTextPolicy.isRenderableExtension(candidate: " world", currentlyRendered: " wor")
        )
    }

    func test_staleShorterPartialIsDropped() {
        XCTAssertFalse(
            StreamedGhostTextPolicy.isRenderableExtension(candidate: " wor", currentlyRendered: " world")
        )
    }

    func test_equalTextIsDroppedAsRedundant() {
        XCTAssertFalse(
            StreamedGhostTextPolicy.isRenderableExtension(candidate: " world", currentlyRendered: " world")
        )
    }

    func test_divergentRewriteIsDropped() {
        // A normalizer can legally rewrite a fragment rather than extend it; the render must wait
        // for the authoritative final result instead of flickering through rewrites.
        XCTAssertFalse(
            StreamedGhostTextPolicy.isRenderableExtension(candidate: " worse idea", currentlyRendered: " world")
        )
    }
}
