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

    func test_personaFramingConditionsOnNameStyleAndLanguage() {
        let prompt = BaseCompletionPromptRenderer.prompt(
            prefixText: "Hi team,",
            applicationName: "Mail",
            userName: "Jacob",
            customRules: ["friendly", "professional"],
            languageInstruction: "Write in English."
        )
        XCTAssertTrue(prompt.contains("written by Jacob"))
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
}
