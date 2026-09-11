import XCTest
@testable import Cotabby

/// Pure-function tests for the experimental base-model prompt. The contract: no instruction
/// preamble or standalone labels, the prefix is always the final bytes, trailing whitespace is
/// trimmed (mid-word prefixes preserved), and persona/style/context only appear when supplied.
final class BaseCompletionPromptRendererTests: XCTestCase {

    func test_bareField_returnsTrimmedPrefixOnly() {
        let prompt = BaseCompletionPromptRenderer.prompt(
            prefixText: "I am writing to ",
            applicationName: "Mail",
            userName: nil
        )
        XCTAssertEqual(prompt, "I am writing to")
    }

    func test_noInstructionPreambleOrScaffoldingLabels() {
        let prompt = BaseCompletionPromptRenderer.prompt(
            prefixText: "Once upon",
            applicationName: "Notes",
            userName: "Jacob",
            customRules: ["friendly", "concise"]
        )
        XCTAssertFalse(prompt.contains("Task:"))
        XCTAssertFalse(prompt.contains("This is autocomplete"))
        XCTAssertFalse(prompt.contains("Text before caret:"))
        XCTAssertFalse(prompt.contains("Do not answer"))
    }

    func test_prefixIsAlwaysLastEvenWithAllContext() {
        let prompt = BaseCompletionPromptRenderer.prompt(
            prefixText: "the meeting is at",
            applicationName: "Slack",
            userName: "Jacob",
            customRules: ["terse"],
            extendedContext: "Project Matcha ships in June.",
            languageInstruction: "Write in English.",
            clipboardContext: "zoom link",
            visualContextSummary: "Calendar: Q3 planning 3pm"
        )
        XCTAssertTrue(prompt.hasSuffix("the meeting is at"))
    }

    func test_tokenBudget_keepsCaretPrefixUnderATightBudget() {
        // The opt-in token-budgeted path must keep the caret prefix (top priority) at the very end,
        // exactly like the character path, while a tight budget trims lower-priority context.
        let prompt = BaseCompletionPromptRenderer.prompt(
            prefixText: "the meeting is at",
            applicationName: "Slack",
            userName: "Jacob",
            customRules: ["terse"],
            extendedContext: "Project Matcha ships in June with a great many additional notes kept here.",
            clipboardContext: "zoom link",
            visualContextSummary: "Calendar: Q3 planning 3pm",
            tokenBudget: 8
        )
        XCTAssertTrue(prompt.hasSuffix("the meeting is at"), "the caret prefix is never starved under a token budget")
    }

    func test_styleAndLanguageConditionWithoutNamingTheWriterAtAnOpening() {
        let prompt = BaseCompletionPromptRenderer.prompt(
            prefixText: "Hi team,",
            applicationName: "Mail",
            userName: "Jacob",
            customRules: ["friendly", "professional"],
            languageInstruction: "Write in English."
        )
        // Measured live: a name in the preface at an opening made the model write "Hi, I'm Jacob".
        XCTAssertFalse(prompt.contains("Jacob"))
        XCTAssertTrue(prompt.contains("friendly, professional"))
        XCTAssertTrue(prompt.contains("Write in English."))
        XCTAssertTrue(prompt.hasSuffix("Hi team,"))
    }

    func test_writerIsNamedOnlyWhereTheCaretFollowsAValediction() {
        let signing = BaseCompletionPromptRenderer.prompt(
            prefixText: "Could you add the budget numbers before Friday?\n\nThanks again,\n",
            applicationName: "Mail",
            userName: "Jacob"
        )
        XCTAssertTrue(signing.contains("Written by Jacob."))
        // The caret is on the line after the closing, where the name goes, and the model is told so.
        XCTAssertTrue(signing.hasSuffix("Thanks again,\n"))

        for prefix in ["", "Hi", "Thanks for", "I will forward the draft to", "the rest of the"] {
            let prompt = BaseCompletionPromptRenderer.prompt(prefixText: prefix, applicationName: "Mail", userName: "Jacob")
            XCTAssertFalse(prompt.contains("Jacob"), "the name must not condition \(prefix.debugDescription)")
        }
    }

    func test_trailingWhitespaceTrimmedButMidWordPreserved() {
        XCTAssertEqual(
            BaseCompletionPromptRenderer.prompt(prefixText: "doing my aft", applicationName: "X", userName: nil),
            "doing my aft"
        )
        XCTAssertEqual(
            BaseCompletionPromptRenderer.prompt(prefixText: "see you   ", applicationName: "X", userName: nil),
            "see you"
        )
        // A line break the caret follows is the start of a new line, and the model is told so.
        XCTAssertEqual(
            BaseCompletionPromptRenderer.prompt(prefixText: "Hi Sarah,\n  ", applicationName: "X", userName: nil),
            "Hi Sarah,\n"
        )
    }

    func test_contextOnlyAppearsWhenSupplied() {
        let withContext = BaseCompletionPromptRenderer.prompt(
            prefixText: "Status:",
            applicationName: "Slack",
            userName: nil,
            visualContextSummary: "build is green"
        )
        XCTAssertTrue(withContext.contains("Nearby on screen: build is green"))
        XCTAssertTrue(withContext.hasSuffix("Status:"))
    }

    func test_surfaceContextLeadsThePrefaceAndPrefixStaysLast() {
        let surface = SurfaceContext(
            surfaceClass: .email,
            applicationName: "Mail",
            windowTitle: "Re: Q3 budget review",
            domain: nil,
            fieldPlaceholder: nil
        )
        let prompt = BaseCompletionPromptRenderer.prompt(
            prefixText: "Thanks again for",
            applicationName: "Mail",
            userName: "Jacob",
            surfaceContext: surface
        )
        XCTAssertTrue(prompt.hasPrefix("Email draft. Window title: \"Re: Q3 budget review\"."))
        // "Thanks again for" is mid-sentence, not a sign-off, so the writer stays unnamed.
        XCTAssertFalse(prompt.contains("Jacob"))
        XCTAssertTrue(prompt.hasSuffix("Thanks again for"))
    }

    func test_noSurfaceContextMeansPromptIsUnchanged() {
        let without = BaseCompletionPromptRenderer.prompt(
            prefixText: "Once upon",
            applicationName: "Notes",
            userName: nil
        )
        XCTAssertEqual(without, "Once upon")
    }

    func test_tokenBudgetAdmitsAPrefixLargerThanTheOldCharacterBudget() {
        // 2500 characters of ordinary prose is ~600 estimated tokens: comfortably inside the
        // shipped token budget even though it exceeds the old 2400-character cap. The whole
        // prefix must survive.
        let prefix = String(repeating: "every word counts here ", count: 109) + "and the end"
        XCTAssertGreaterThan(prefix.count, 2400)
        let prompt = BaseCompletionPromptRenderer.prompt(
            prefixText: prefix,
            applicationName: "Pages",
            userName: "Jacob",
            languageInstruction: "Write in English.",
            tokenBudget: SuggestionConfiguration.standard.llamaPromptTokenBudget
        )
        XCTAssertTrue(prompt.hasSuffix("and the end"))
        XCTAssertTrue(prompt.contains("every word counts here"), "the full prefix survives the token budget")
        XCTAssertTrue(prompt.contains("Write in English."), "context still fits alongside a large prefix")
    }
}
