import XCTest
@testable import Cotabby

final class CompletionContentPolicyTests: XCTestCase {
    func testPunctuationOnlyCompletionsAreRejected() {
        // Eval: email-signoff-04 ",", email-confirm-16 ":", prose-memo-11 ":", code-comment-01 ".".
        XCTAssertEqual(CompletionContentPolicy.rejection(for: ",", precedingText: "Best "), .noWordContent)
        XCTAssertEqual(CompletionContentPolicy.rejection(for: ":", precedingText: "scheduled for "), .noWordContent)
        XCTAssertEqual(CompletionContentPolicy.rejection(for: ".", precedingText: "Thanks for your patience"), .noWordContent)
        XCTAssertEqual(CompletionContentPolicy.rejection(for: "…", precedingText: "so"), .noWordContent)
    }

    func testClosingPunctuationRightAfterATypedSpaceIsRejected() {
        // Eval: chat-weekend-12 "! the view was beautiful" after "do it again ".
        XCTAssertEqual(
            CompletionContentPolicy.rejection(for: "! the view was beautiful", precedingText: "we should do it again "),
            .punctuationAfterSpace
        )
        XCTAssertNil(CompletionContentPolicy.rejection(for: "soon!", precedingText: "we should do it again "))
        XCTAssertNil(CompletionContentPolicy.rejection(for: ", and", precedingText: "we should do it again"), "no space typed: the model may be attaching punctuation to the word")
        XCTAssertNil(CompletionContentPolicy.rejection(for: "(maybe)", precedingText: "we should "), "opening punctuation can start a word")
    }

    func testScaffoldingAndMetaResponsesAreRejected() {
        XCTAssertEqual(CompletionContentPolicy.rejection(for: "[User 0001]", precedingText: "asdkfj "), .scaffolding)
        XCTAssertEqual(CompletionContentPolicy.rejection(for: "12:03 PM · 1 min read · Reply · 1 Like", precedingText: "wfhqk "), .scaffolding)
        XCTAssertEqual(CompletionContentPolicy.rejection(for: "<code>on_message</code> function.", precedingText: "a race condition in the "), .scaffolding)
        XCTAssertEqual(
            CompletionContentPolicy.rejection(for: "I'm not sure what you mean by \"the text\".", precedingText: "xq vbnz "),
            .scaffolding
        )
        XCTAssertNil(CompletionContentPolicy.rejection(for: "<div>", precedingText: "<p>hello</p> "), "markup in a markup field is content")
        XCTAssertNil(CompletionContentPolicy.rejection(for: "thing that's like a sandwich", precedingText: "that new "))
    }

    func testLoopingCompletionsAreRejected() {
        // Live (Chrome, 90ms/key): "Hi S" -> ". Hi S. Hi S. Hi S."; ", t" -> "ttttt, 123456" passes (one word).
        let policy = CompletionContentPolicy.self
        XCTAssertEqual(policy.rejection(for: ". Hi S. Hi S. Hi S.", precedingText: "charlie. Hi S"), .repetitiveContent)
        XCTAssertEqual(policy.rejection(for: "no no no no", precedingText: "oh "), .repetitiveContent)
        XCTAssertEqual(policy.rejection(for: "over and over and over and over", precedingText: "again "), .repetitiveContent)
        XCTAssertNil(CompletionContentPolicy.rejection(for: "very very good", precedingText: "it was "), "two copies are emphasis")
        XCTAssertNil(CompletionContentPolicy.rejection(for: "day after day, week after week", precedingText: "it went on "))
    }

    func testCompletionsCopiedFromTheRecentTextAreRejected() {
        // Live: "Hi Sarah, thanks for s" -> ". Hi Sarah, thanks for s."
        XCTAssertEqual(
            CompletionContentPolicy.rejection(for: ". Hi Sarah, thanks for s.", precedingText: "Field one. Hi Sarah, thanks for s"),
            .copiesPrecedingText
        )
        XCTAssertEqual(
            CompletionContentPolicy.rejection(for: " through the first two sections and", precedingText: "I went through the first two sections and"),
            .copiesPrecedingText
        )
        XCTAssertNil(
            CompletionContentPolicy.rejection(for: " for the invitation to the party.", precedingText: "thanks for the draft. Thanks"),
            "three shared words are ordinary phrasing"
        )
        XCTAssertNil(
            CompletionContentPolicy.rejection(
                for: " Hi Sarah, thanks for sending over the draft",
                precedingText: "Hi Sarah, thanks for sending over the draft yesterday.\nThe main thing is the timeline.\nHi"
            ),
            "repeating a paragraph the document already holds is a prediction, not an echo"
        )
        XCTAssertNil(
            CompletionContentPolicy.rejection(
                for: " sending over the draft of the proposal",
                precedingText: "Thanks for sending over the draft. I also want the "
            ),
            "a four-word run inside a longer new thought stays under the copy threshold"
        )
    }
}
