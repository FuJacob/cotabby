import XCTest
@testable import Cotabby

/// Pure-function tests for the base-model prompt. The contract: no instruction preamble, the
/// exact caret prefix is always the final bytes, and supplied context stays inside its budget.
/// These tests protect the inputs to generation; model quality belongs to the inference benchmark.
///
/// Outputs are asserted as whole strings wherever the rendering is deterministic, because the
/// base model continues whatever it is given: an extra label, a reordered section, or a trimmed
/// caret space is a behavior change even when every expected substring is still present.
final class BaseCompletionPromptRendererTests: XCTestCase {

    // MARK: - Bare prompts

    /// With no context the model receives the caret prefix verbatim. Mid-word endings, trailing
    /// spaces, and trailing newlines all tell the model where to resume, so none may be normalized.
    func test_noContext_returnsExactPrefixVerbatim() {
        for prefix in ["I am writing to ", "doing my aft", "see you   \n", "Hi team,\n\n\t- "] {
            XCTAssertEqual(
                BaseCompletionPromptRenderer.prompt(prefixText: prefix, applicationName: "Mail", userName: nil),
                prefix,
                "prefix \(prefix.debugDescription)"
            )
        }
    }

    /// Whitespace-only optional inputs are treated as absent, so they cannot produce an empty
    /// preface line or a dangling blank-line separator.
    func test_whitespaceOnlyOptionalInputsAddNoPreface() {
        let prompt = BaseCompletionPromptRenderer.prompt(
            prefixText: "A new thought ",
            applicationName: "Notes",
            userName: "  \n",
            trailingText: "  \n\t",
            customRules: ["", "   "],
            extendedContext: " ",
            languageInstruction: "\n",
            clipboardContext: "\t",
            visualContextSummary: "  "
        )
        XCTAssertEqual(prompt, "A new thought ")
    }

    /// A zero suffix allowance means no "following" section even when text exists after the caret.
    func test_zeroSuffixAllowanceOmitsFollowingText() {
        let prompt = BaseCompletionPromptRenderer.prompt(
            prefixText: "We are meeting ",
            applicationName: "Mail",
            userName: nil,
            trailingText: " on Friday.",
            maxSuffixCharacters: 0
        )
        XCTAssertEqual(prompt, "We are meeting ")
    }

    // MARK: - Preface shape and order

    /// Pins the complete preface: every section in render order, trimmed, one per line, with no
    /// instruction scaffolding ("Task:", "Text before caret:"), then a blank line and the exact
    /// caret prefix last. The surface description leads because it is the strongest situational
    /// cue; the quoted following text sits just before the prefix so the stable head stays cacheable.
    /// The writer's name is absent: the caret is mid-sentence, not after a sign-off (`SignOffCue`).
    func test_allContext_rendersEverySectionInOrderWithPrefixLast() {
        let prompt = BaseCompletionPromptRenderer.prompt(
            prefixText: "the meeting is at ",
            applicationName: "Mail",
            userName: " Jacob ",
            trailingText: " on Friday.",
            customRules: ["  terse ", "", "warm"],
            extendedContext: "Project Matcha ships in June.",
            languageInstruction: "Write in English.",
            clipboardContext: "zoom link",
            visualContextSummary: "Calendar: Q3 planning 3pm",
            surfaceContext: SurfaceContext(
                surfaceClass: .email, applicationName: "Mail", windowTitle: "Re: Q3",
                domain: nil, fieldPlaceholder: nil
            )
        )
        XCTAssertEqual(
            prompt,
            [
                "Format: email; App: Mail; Title: Re: Q3.",
                "Writing style: terse, warm.",
                "Write in English.",
                "Notes the writer keeps in mind: Project Matcha ships in June.",
                "On the clipboard: zoom link",
                "Nearby on screen: Calendar: Q3 planning 3pm",
                "Later in the same passage:\n“ on Friday.”"
            ].joined(separator: "\n") + "\n\nthe meeting is at "
        )
    }

    /// The following text is cut to `maxSuffixCharacters` and quoted, keeping its whitespace.
    func test_followingTextIsBoundedQuotedContextBeforeExactPrefix() {
        let prefix = "We are meeting "
        let prompt = BaseCompletionPromptRenderer.prompt(
            prefixText: prefix,
            applicationName: "Mail",
            userName: nil,
            trailingText: " on Friday.\n\nAlready written.",
            maxSuffixCharacters: 11
        )
        XCTAssertEqual(prompt, "Later in the same passage:\n“ on Friday.”\n\n" + prefix)
    }

    /// Production surface lines state the app; the opt-in compact variant drops app branding and
    /// generic composer labels ("Message"). Code editors get no surface section in either mode,
    /// because app metadata biases a base model toward code in exactly the wrong place.
    func test_surfaceSectionFollowsCompactFlagAndOmitsCodeEditors() {
        let email = SurfaceContext(
            surfaceClass: .email, applicationName: "Mail", windowTitle: "Re: Q3",
            domain: nil, fieldPlaceholder: "Message"
        )
        let editor = SurfaceContext(
            surfaceClass: .codeEditor, applicationName: "Xcode", windowTitle: "main.swift",
            domain: nil, fieldPlaceholder: nil
        )
        let cases: [(surface: SurfaceContext, compact: Bool, expected: String)] = [
            (email, false, "Format: email; App: Mail; Title: Re: Q3; Field: Message.\n\nThanks"),
            (email, true, "Format: email; Title: Re: Q3.\n\nThanks"),
            (editor, false, "Thanks"),
            (editor, true, "Thanks")
        ]
        for testCase in cases {
            let prompt = BaseCompletionPromptRenderer.prompt(
                prefixText: "Thanks",
                applicationName: testCase.surface.applicationName,
                userName: nil,
                surfaceContext: testCase.surface,
                usesCompactSurfaceContext: testCase.compact
            )
            XCTAssertEqual(prompt, testCase.expected, "\(testCase.surface.surfaceClass) compact=\(testCase.compact)")
        }
    }

    // MARK: - Character budget

    /// Once the prefix and a higher-priority section exhaust the budget, lower-priority context is
    /// dropped outright rather than appended past the limit.
    func test_characterBudget_dropsLowerPrioritySectionsWhenExhausted() {
        let prompt = BaseCompletionPromptRenderer.prompt(
            prefixText: "abc",
            applicationName: "Notes",
            userName: nil,
            languageInstruction: "Write in English.",
            clipboardContext: "zoom link",
            contextBudget: 3 + "Write in English.".count
        )
        XCTAssertEqual(prompt, "Write in English.\n\nabc")
    }

    /// `screenPriority` lets callers rank screen context above the language line (default 45 ranks
    /// below it).
    func test_screenPriorityCanOutrankLanguageUnderATightBudget() {
        let prompt = BaseCompletionPromptRenderer.prompt(
            prefixText: "abc",
            applicationName: "Notes",
            userName: nil,
            languageInstruction: "Write in English.",
            visualContextSummary: "green",
            contextBudget: 3 + "Nearby on screen: green".count,
            screenPriority: 65
        )
        XCTAssertEqual(prompt, "Nearby on screen: green\n\nabc")
    }

    /// `maxScreenCharacters` caps the labelled screen section (label included), keeping its start.
    func test_maxScreenCharactersCapsTheLabelledSection() {
        let prompt = BaseCompletionPromptRenderer.prompt(
            prefixText: "xyz",
            applicationName: "Notes",
            userName: nil,
            visualContextSummary: "abcdefghij",
            maxScreenCharacters: 25
        )
        XCTAssertEqual(prompt, "Nearby on screen: abcdefg\n\nxyz")
    }

    /// An over-long prefix keeps its END (the text touching the caret) and starves all context.
    func test_prefixLongerThanBudgetKeepsCaretSideAndDropsContext() {
        let prompt = BaseCompletionPromptRenderer.prompt(
            prefixText: "hello world",
            applicationName: "Notes",
            userName: "Jacob",
            contextBudget: 5
        )
        XCTAssertEqual(prompt, "world")
    }

    /// The following section is all-or-nothing: a partial quote or bare label would otherwise be
    /// continued by the model as if it were the user's text.
    func test_followingTextDropsAsAWholeWhenOnlyThePrefixFits() {
        let prefix = "We are meeting "
        let prompt = BaseCompletionPromptRenderer.prompt(
            prefixText: prefix,
            applicationName: "Mail",
            userName: nil,
            trailingText: " on Friday.",
            contextBudget: prefix.count + 10
        )
        XCTAssertEqual(prompt, prefix, "a tight budget must not leave an incomplete context label or quote")
    }

    func test_zeroBudgetDoesNotRestoreAnUnboundedPrefix() {
        XCTAssertEqual(
            BaseCompletionPromptRenderer.prompt(
                prefixText: "This must not escape the budget.",
                applicationName: "Notes",
                userName: nil,
                contextBudget: 0
            ),
            ""
        )
    }

    /// The notes section cap must admit the full user-entered Extended Context plus its label;
    /// otherwise the settings UI advertises a limit the prompt silently undercuts.
    @MainActor
    func test_notesSectionAdmitsTheFullAdvertisedExtendedContext() async {
        let notes = String(repeating: "n", count: SuggestionSettingsModel.maximumExtendedContextCharacters)
        let prompt = BaseCompletionPromptRenderer.prompt(
            prefixText: "abc",
            applicationName: "Notes",
            userName: nil,
            extendedContext: notes
        )
        XCTAssertEqual(prompt, "Notes the writer keeps in mind: \(notes)\n\nabc")
    }

    /// A long host and title can exceed the surface section's 240-character ceiling. Metadata must
    /// yield to the caret prefix under both a tight and a normal total budget.
    func test_surfaceSectionStaysBoundedWithoutChangingCaretWhitespace() {
        let prefix = "Hi team,\n\nNext step:\n\t- "
        let surface = SurfaceContext(
            surfaceClass: .browser,
            applicationName: "Google Chrome",
            windowTitle: String(repeating: "t", count: 80),
            domain: String(repeating: "subdomain.", count: 20) + "example.com",
            fieldPlaceholder: String(repeating: "f", count: 60)
        )
        for availableSurfaceCharacters in [24, 240] {
            let prompt = BaseCompletionPromptRenderer.prompt(
                prefixText: prefix, applicationName: "Google Chrome", userName: nil,
                surfaceContext: surface, contextBudget: prefix.count + availableSurfaceCharacters
            )
            XCTAssertTrue(prompt.hasSuffix("\n\n" + prefix), "metadata must not displace or normalize the caret prefix")
            // Section allocation counts content; the renderer adds its two newline separators.
            XCTAssertEqual(prompt.count, prefix.count + availableSurfaceCharacters + 2)
        }
    }

    // MARK: - Token budget

    /// The opt-in token path budgets in estimated tokens. "abcd" is exactly one estimated token and
    /// "Write in English." four, so a 1-token budget keeps only the prefix and 5 tokens keeps both.
    func test_tokenBudget_fillsPrefixFirstThenContext() {
        let cases: [(tokenBudget: Int, expected: String)] = [
            (1, "abcd"),
            (5, "Write in English.\n\nabcd")
        ]
        for testCase in cases {
            let prompt = BaseCompletionPromptRenderer.prompt(
                prefixText: "abcd",
                applicationName: "Notes",
                userName: nil,
                languageInstruction: "Write in English.",
                clipboardContext: "zoom link",
                tokenBudget: testCase.tokenBudget
            )
            XCTAssertEqual(prompt, testCase.expected, "tokenBudget \(testCase.tokenBudget)")
        }
    }

    func test_tokenBudget_preservesParagraphBreaksAndCaretIndentation() {
        let prefix = "Hi team,\n\nAgenda:\n\t- "
        let prompt = BaseCompletionPromptRenderer.prompt(
            prefixText: prefix,
            applicationName: "Notes",
            userName: nil,
            languageInstruction: "Write in English.",
            tokenBudget: 100
        )
        XCTAssertEqual(prompt, "Write in English.\n\n" + prefix)
    }

    /// 2500 characters of ordinary prose is ~550 estimated tokens: inside the shipped token budget
    /// even though it exceeds the old 2400-character cap. The whole prefix and the context survive.
    func test_tokenBudgetAdmitsAPrefixLargerThanTheOldCharacterBudget() {
        let prefix = String(repeating: "every word counts here ", count: 109) + "and the end"
        XCTAssertGreaterThan(prefix.count, 2400)
        let prompt = BaseCompletionPromptRenderer.prompt(
            prefixText: prefix,
            applicationName: "Pages",
            userName: nil,
            languageInstruction: "Write in English.",
            tokenBudget: SuggestionConfiguration.standard.llamaPromptTokenBudget
        )
        XCTAssertEqual(prompt, "Write in English.\n\n" + prefix)
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
}
