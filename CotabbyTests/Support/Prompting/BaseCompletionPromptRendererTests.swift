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

    func test_personaFramingConditionsOnNameStyleAndLanguage() {
        let prompt = BaseCompletionPromptRenderer.prompt(
            prefixText: "Hi team,",
            applicationName: "Mail",
            userName: "Jacob",
            customRules: ["friendly", "professional"],
            languageInstruction: "Write in English."
        )
        XCTAssertTrue(prompt.contains("Written by Jacob"))
        XCTAssertTrue(prompt.contains("friendly, professional"))
        XCTAssertTrue(prompt.contains("Write in English."))
        XCTAssertTrue(prompt.hasSuffix("Hi team,"))
    }

    func test_trailingWhitespaceTrimmedButMidWordPreserved() {
        XCTAssertEqual(
            BaseCompletionPromptRenderer.prompt(prefixText: "doing my aft", applicationName: "X", userName: nil),
            "doing my aft"
        )
        XCTAssertEqual(
            BaseCompletionPromptRenderer.prompt(prefixText: "see you   \n", applicationName: "X", userName: nil),
            "see you"
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
        XCTAssertTrue(prompt.hasPrefix("An email being written in Mail. The window is titled \"Re: Q3 budget review\"."))
        XCTAssertTrue(prompt.contains("Written by Jacob"))
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
            tokenBudget: SuggestionConfiguration.standard.llamaPromptTokenBudget
        )
        XCTAssertTrue(prompt.hasSuffix("and the end"))
        XCTAssertTrue(prompt.contains("every word counts here"), "the full prefix survives the token budget")
        XCTAssertTrue(prompt.contains("Written by Jacob"), "context still fits alongside a large prefix")
    }
}
