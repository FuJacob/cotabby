import Testing
@testable import Cotabby

/// Verifies the small contract that lets a demo localize a complete sentence while animating only
/// its typed run and rendering the rest as ghost text.
@MainActor
struct CompletionPreviewTextTests {
    @Test
    func test_splitsAtTheTranslatorSelectedBoundaryWithoutTrimmingEitherRun() {
        let preview = CompletionPreviewText(resolvedSentence: "Thanks for the¦ quick reply!")

        #expect(preview.typedText == "Thanks for the")
        #expect(preview.ghostText == " quick reply!")
    }

    @Test
    func test_keepsPunctuationAndSpacingWhenBoundaryMovesForAnotherGrammar() {
        let preview = CompletionPreviewText(resolvedSentence: "明日¦、また会いましょう")

        #expect(preview.typedText == "明日")
        #expect(preview.ghostText == "、また会いましょう")
    }
    @Test(arguments: ["A whole sentence", "A¦ whole¦ sentence"])
    func malformedCatalogMarkersDegradeToReadableText(_ sentence: String) {
        let preview = CompletionPreviewText(resolvedSentence: sentence)
        #expect(preview.typedText == "A whole sentence")
        #expect(preview.ghostText.isEmpty)
    }
}
