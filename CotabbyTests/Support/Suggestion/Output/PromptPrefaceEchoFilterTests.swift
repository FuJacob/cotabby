import XCTest
@testable import Cotabby

/// `PromptPrefaceEchoFilter` cuts a completion where it starts writing Cotabby's own prompt
/// preface, and its phrase list must stay the renderer's real wording.
final class PromptPrefaceEchoFilterTests: XCTestCase {
    func testMeasuredEchoKeepsOnlyTheTextBeforeIt() {
        // Measured in ChatGPT with the Open Source engine.
        XCTAssertEqual(PromptPrefaceEchoFilter.truncated("4 5.6 Sol\nThe user usually writes in"), "4 5.6 Sol")
        XCTAssertEqual(PromptPrefaceEchoFilter.truncated(" the agenda. Nearby on screen: Inbox"), " the agenda.")
        XCTAssertEqual(PromptPrefaceEchoFilter.truncated("Notes the writer keeps in mind: Contoso"), "")
    }

    func testLineStartPhrasesOnlyCountAtTheStartOfALine() {
        XCTAssertEqual(PromptPrefaceEchoFilter.truncated(" a book written by her"), " a book written by her")
        XCTAssertEqual(PromptPrefaceEchoFilter.truncated(" thanks,\nWritten by Robin."), " thanks,")
        XCTAssertEqual(PromptPrefaceEchoFilter.truncated("Writing style: concise"), "")
    }

    func testOrdinaryCompletionsAreUnchanged() {
        for text in [" proposal we discussed last week.", " meeting\nnext line", ""] {
            XCTAssertEqual(PromptPrefaceEchoFilter.truncated(text), text)
        }
    }

    func testEveryPhraseIsWordingTheRendererActuallyWrites() {
        let prompts = Self.surfaceClasses.map(Self.fullPrompt)
        for phrase in PromptPrefaceEchoFilter.anywherePhrases + PromptPrefaceEchoFilter.lineStartPhrases {
            XCTAssertTrue(prompts.contains { $0.contains(phrase) }, "not in the prompt any more: \(phrase)")
        }
    }

    /// The reverse of the wording check: every line of Cotabby's own preface, echoed on its own or
    /// after a real start, must be cut. Renders the preface with every optional section on, once
    /// per writing surface that gets a surface line, so a renderer wording change or a new section
    /// fails here instead of reaching the ghost text. Lines opening with a curly quote are the
    /// user's own text (history examples, the following passage), not preface wording.
    func testEveryRenderedPrefaceLineIsCut() {
        for surfaceClass in Self.surfaceClasses {
            let prompt = Self.fullPrompt(surfaceClass: surfaceClass)
            let caretTail = "\n\n" + Self.prefix
            XCTAssertTrue(prompt.hasSuffix(caretTail))
            let preface = prompt.dropLast(caretTail.count)
            let lines = preface.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("“") }
            // Every optional section rendered: surface, persona, style, language, notes, history
            // heading, clipboard, screen, following heading.
            XCTAssertEqual(lines.count, 9, "\(surfaceClass): \(lines)")
            for line in lines {
                XCTAssertEqual(PromptPrefaceEchoFilter.truncated(line), "", "\(surfaceClass) echo not cut: \(line)")
                XCTAssertEqual(
                    PromptPrefaceEchoFilter.truncated("4 5.6 Sol\n" + line), "4 5.6 Sol",
                    "\(surfaceClass) echo after a real start not cut: \(line)"
                )
            }
        }
    }

    func testSurfaceFormatWordOnlyCountsInItsRenderedForm() {
        for text in [" the format: email is fine", "\nFormat: PDF, two pages", " App: Mail"] {
            XCTAssertEqual(PromptPrefaceEchoFilter.truncated(text), text)
        }
        XCTAssertEqual(PromptPrefaceEchoFilter.truncated(" soon.\nFormat: chat; App: Slack."), " soon.")
        XCTAssertEqual(PromptPrefaceEchoFilter.truncated("Earlier writing by the same author:\n“Hi”"), "")
    }

    private static let prefix = "Best regards,\n"

    /// Every class that gets a surface line; code editors and terminals get none.
    private static let surfaceClasses: [AppSurfaceClass] = [.email, .chat, .browser, .other]

    private static func fullPrompt(surfaceClass: AppSurfaceClass) -> String {
        BaseCompletionPromptRenderer.prompt(
            prefixText: prefix,
            userName: "Robin",
            trailingText: "rest of the passage",
            customRules: ["concise"],
            extendedContext: "Contoso builds a SOC platform.",
            languageInstruction: LanguageCatalog.promptInstruction(for: ["en", "tr"]),
            clipboardContext: "copied text",
            visualContextSummary: "screen text",
            surfaceContext: SurfaceContext(
                surfaceClass: surfaceClass, applicationName: "Mail", windowTitle: "Re: Q3",
                domain: "mail.example.com", fieldPlaceholder: "Message"
            ),
            historyExamples: ["See you at the offsite."]
        )
    }
}
