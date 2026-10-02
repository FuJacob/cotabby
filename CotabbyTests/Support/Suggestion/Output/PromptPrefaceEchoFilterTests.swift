import XCTest
@testable import Cotabby

/// `PromptPrefaceEchoFilter` cuts a completion where it starts writing Cotabby's own prompt
/// preface, and its phrase list must stay the renderer's real wording.
final class PromptPrefaceEchoFilterTests: XCTestCase {
    func testMeasuredEchoKeepsOnlyTheTextBeforeIt() {
        // Measured in ChatGPT with the Open Source engine.
        XCTAssertEqual(PromptPrefaceEchoFilter.truncated("4 5.6 Sol\nThe user usually writes in"), "4 5.6 Sol")
        XCTAssertEqual(PromptPrefaceEchoFilter.truncated(" the agenda. Nearby on screen: Inbox"), " the agenda.")
        XCTAssertEqual(PromptPrefaceEchoFilter.truncated("Notes the writer keeps in mind: Imperum"), "")
    }

    func testLineStartPhrasesOnlyCountAtTheStartOfALine() {
        XCTAssertEqual(PromptPrefaceEchoFilter.truncated(" a book written by her"), " a book written by her")
        XCTAssertEqual(PromptPrefaceEchoFilter.truncated(" thanks,\nWritten by Senad."), " thanks,")
        XCTAssertEqual(PromptPrefaceEchoFilter.truncated("Writing style: concise"), "")
    }

    func testOrdinaryCompletionsAreUnchanged() {
        for text in [" proposal we discussed last week.", " meeting\nnext line", ""] {
            XCTAssertEqual(PromptPrefaceEchoFilter.truncated(text), text)
        }
    }

    func testEveryPhraseIsWordingTheRendererActuallyWrites() {
        let prompt = BaseCompletionPromptRenderer.prompt(
            prefixText: "Best regards,\n",
            applicationName: "Mail",
            userName: "Senad",
            trailingText: "rest of the passage",
            customRules: ["concise"],
            extendedContext: "Imperum builds a SOC platform.",
            languageInstruction: LanguageCatalog.promptInstruction(for: ["en", "tr"]),
            clipboardContext: "copied text",
            visualContextSummary: "screen text"
        )
        for phrase in PromptPrefaceEchoFilter.anywherePhrases {
            XCTAssertTrue(prompt.contains(phrase), "not in the prompt any more: \(phrase)")
        }
        XCTAssertTrue(prompt.contains("Writing style:"))
    }
}
