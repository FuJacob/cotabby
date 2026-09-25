import XCTest
@testable import Cotabby

/// Exercises the actual OCR-selection and prompt path without loading a model. A benchmark with
/// attractive scenario descriptions is useless if those descriptions never reach inference, or
/// if its hidden reference sentence accidentally becomes visible input.
@MainActor
final class PhrasePredictionScreenContextTests: XCTestCase {
    func testEveryScenarioReachesTheProductionContextBoundaryWithoutItsAnswer() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "phrase-prediction-1337", withExtension: "json"))
        let corpus = try JSONDecoder().decode(PhrasePredictionCorpus.self, from: Data(contentsOf: url))
        try corpus.validate()
        for phrase in corpus.phrases {
            let scenario = try XCTUnwrap(phrase.scenario)
            let checkpoint = try XCTUnwrap(PhrasePredictionScorer.checkpoints(for: phrase, mode: .word).first)
            let screen = request(checkpoint, scenario, .screen)
            let none = request(checkpoint, scenario, .none)
            XCTAssertFalse((screen.visualContextSummary ?? "").isEmpty, phrase.id)
            XCTAssertNil(none.visualContextSummary, phrase.id)
            XCTAssertEqual(screen.prefixText, none.prefixText, phrase.id)
            XCTAssertEqual(screen.surfaceContext, none.surfaceContext, phrase.id)
            XCTAssertEqual(screen.context.precedingText, checkpoint.prefix, phrase.id)
            XCTAssertEqual(screen.context.trailingText, "", phrase.id)
            XCTAssertNotEqual(screen.prompt, none.prompt, phrase.id)
            XCTAssertFalse(screen.prompt.contains(phrase.text), "Future answer leaked: \(phrase.id)")
            XCTAssertLessThanOrEqual(screen.visualContextSummary?.count ?? 0, VisualContextConfiguration.local.maxSummaryCharacters)
        }
    }

    func testVisibleFactsSurviveWhileDraftEchoAndChromeNoiseAreRemoved() throws {
        let checkpoint = PhrasePredictionScorer.Checkpoint(wordIndex: 1, typedCharacters: 0,
            prefix: "Please confirm ", typedWordPrefix: "", expectedWord: "Tuesday")
        let scenario = scene("Messages\nMorgan: The inspection is Tuesday at 14:30 in room B12.\n\u{FFFD}\u{FFFD}\u{FFFD}\n--- :: --- ::")
        let built = request(checkpoint, scenario, .screen)
        let excerpt = try XCTUnwrap(built.visualContextSummary)
        // The production sanitizer replaces punctuation with spaces; the day, time components,
        // and room identifier must survive even though the colon's typography does not.
        XCTAssertTrue(excerpt.contains("Tuesday at 14 30"))
        XCTAssertTrue(excerpt.contains("B12"))
        XCTAssertFalse(excerpt.contains("Please confirm"))
        XCTAssertFalse(excerpt.contains("\u{FFFD}"))
        XCTAssertFalse(excerpt.contains("--- ::"))
        XCTAssertTrue(built.prompt.contains("Tuesday at 14 30"))
    }

    func testOversizedScreenStillUsesProductionBudgets() {
        let text = (0..<300).map { "Message \($0): The design review has moved to Tuesday afternoon in the west meeting room." }.joined(separator: "\n")
        let checkpoint = PhrasePredictionScorer.Checkpoint(wordIndex: 1, typedCharacters: 0,
            prefix: "Please ", typedWordPrefix: "", expectedWord: "confirm")
        let built = request(checkpoint, scene(text), .screen)
        XCTAssertLessThanOrEqual(built.visualContextSummary?.count ?? 0, VisualContextConfiguration.local.maxSummaryCharacters)
        XCTAssertLessThan(built.prompt.count, text.count)
    }

    func testExistingDraftIsInputInBothConditionsButDoesNotAddScoredWords() {
        var phrase = PhrasePredictionCorpus.Phrase(id: "example", category: "work", text: "Please confirm Tuesday.")
        phrase.scenario = scene("Morgan: Tuesday is the only free inspection slot.", prefix: "Hi Morgan,\n\n")
        let checkpoints = PhrasePredictionScorer.checkpoints(for: phrase, mode: .word)
        XCTAssertEqual(checkpoints.count, 2)
        XCTAssertEqual(checkpoints.map(\.expectedWord), ["confirm", "Tuesday"])
        XCTAssertEqual(checkpoints.first?.prefix, "Hi Morgan,\n\nPlease ")
    }

    func testCompactSurfaceExperimentChangesOnlyPromptRepresentation() {
        let checkpoint = PhrasePredictionScorer.Checkpoint(wordIndex: 1, typedCharacters: 0,
            prefix: "Please confirm ", typedWordPrefix: "", expectedWord: "Tuesday")
        let scenario = scene("Morgan: Tuesday is the only free inspection slot.")
        let settings = CotabbyTestFixtures.settingsSnapshot(userName: "Alex", responseLanguages: ["English"])
        let current = PhrasePredictionScreenContext.request(checkpoint: checkpoint, scenario: scenario,
            condition: .screen, settings: settings, configuration: .standard)
        let compact = PhrasePredictionScreenContext.request(checkpoint: checkpoint, scenario: scenario,
            condition: .screen, settings: settings, configuration: .standard, promptVariant: "compact-surface")
        XCTAssertTrue(current.prompt.contains("App: Mail"))
        XCTAssertFalse(compact.prompt.contains("App: Mail"))
        XCTAssertTrue(current.prompt.contains("Match the language"))
        XCTAssertTrue(compact.prompt.contains("Match the language"))
        XCTAssertEqual(current.context, compact.context)
        XCTAssertEqual(current.prefixText, compact.prefixText)
        XCTAssertEqual(current.visualContextSummary, compact.visualContextSummary)
        XCTAssertEqual(current.surfaceContext, compact.surfaceContext)
        XCTAssertEqual(current.maxPredictionTokens, compact.maxPredictionTokens)
        XCTAssertEqual(current.temperature, compact.temperature)
        XCTAssertEqual(current.randomSeed, compact.randomSeed)
        XCTAssertTrue(compact.prompt.hasSuffix(checkpoint.prefix))
    }

    private func request(_ checkpoint: PhrasePredictionScorer.Checkpoint, _ scene: PhrasePredictionCorpus.ScreenScenario,
                         _ condition: PhrasePredictionScorer.ContextCondition) -> SuggestionRequest {
        PhrasePredictionScreenContext.request(
            checkpoint: checkpoint, scenario: scene, condition: condition,
            settings: CotabbyTestFixtures.settingsSnapshot(isClipboardContextEnabled: false, isSurfaceContextEnabled: true),
            configuration: .standard
        )
    }

    private func scene(_ text: String, prefix: String = "") -> PhrasePredictionCorpus.ScreenScenario {
        .init(kind: "email", applicationName: "Mail", bundleIdentifier: "com.apple.mail", windowTitle: "Inspection",
              fieldPlaceholder: "Reply", documentPrefix: prefix, screenText: text)
    }
}
