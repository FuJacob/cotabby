import XCTest
@testable import Cotabby

/// Dataset-driven eval for the llama suggestion path. Runs the production pipeline per case —
/// request factory → base prompt renderer → llama engine (real model) → normalizer → display
/// guards — and scores the FINAL visible suggestion, so prompt, decode, filter, and suppression
/// changes are measured by what the user would actually see.
///
/// Local-only by design (mirrors `FoundationModelDriftEvalTests`): xcodebuild does not forward
/// shell environment variables into the macOS test host, so the switch is a compile flag, and the
/// model is a multi-GB local download. Run with:
///
///   xcodebuild test -project Cotabby.xcodeproj -scheme Cotabby -destination 'platform=macOS' \
///     -only-testing:CotabbyTests/LlamaSuggestionEvalTests \
///     SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) RUN_LLAMA_EVAL' \
///     CODE_SIGNING_ALLOWED=NO -derivedDataPath build/DerivedData
///
/// Add `-configuration Release ENABLE_TESTABILITY=YES` when quoting latency numbers: Debug
/// inflates the Swift-side per-token work by an order of magnitude and is only meaningful for
/// correctness (testability must be forced on because Release builds disable it, and this file
/// `@testable import`s the app).
///
/// The model comes from the app's own runtime directory (`~/Library/Application Support/Cotabby/
/// LlamaRuntime/`, resolved through `BundledRuntimeLocator` because the test host IS Cotabby.app),
/// so whichever catalog model the app would load is what gets measured. The suite skips with a
/// hint when no model is downloaded.
///
/// Scoring is non-negative (correct suppression scores like a correct insert) so "suppress
/// everything" cannot win, and `precisionWhenShown` is a relative metric: the acceptable lists
/// are not exhaustive, so absolute values matter less than deltas across branches on this fixed
/// dataset. A JSON artifact is written to `build/eval/` (gitignored) for diffing runs.
@MainActor
final class LlamaSuggestionEvalTests: XCTestCase {
    func test_reportEvalSuite() async throws {
        #if RUN_LLAMA_EVAL
        let manager = LlamaRuntimeManager()
        do {
            try await manager.prepare()
        } catch {
            throw XCTSkip(
                "No llama runtime available (\(error)). Download a model in the app first; " +
                "the eval loads it from ~/Library/Application Support/Cotabby/LlamaRuntime/."
            )
        }
        let engine = LlamaSuggestionEngine(runtimeManager: manager)
        let spellChecker = CurrentWordSpellChecker()
        let cases = try Self.loadCases()

        var results: [LlamaEvalCaseResult] = []
        for evalCase in cases {
            let result = try await Self.runCase(
                evalCase,
                engine: engine,
                spellChecker: spellChecker
            )
            results.append(result)
        }

        let report = LlamaEvalReport(modelLabel: Self.modelLabel(), results: results)
        print(report.rendered())
        try Self.writeArtifact(report)

        XCTAssertFalse(results.isEmpty)
        #else
        throw XCTSkip(
            "Llama eval is disabled. Pass SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) RUN_LLAMA_EVAL'."
        )
        #endif
    }

    /// Context-recall suite: every case hides a fact in the context (earlier in the same field,
    /// on screen, or on the clipboard) and requires the completion to reproduce it.
    ///
    /// Kept as its own dataset and its own report rather than folded into the continuation suite,
    /// because the two measure different things and mixing them would let fluent-but-ignorant
    /// prose average away a total failure to use context. `qualityScore` on this suite is the
    /// context-recall rate.
    func test_reportRecallSuite() async throws {
        #if RUN_LLAMA_EVAL
        let manager = LlamaRuntimeManager()
        do {
            try await manager.prepare()
        } catch {
            throw XCTSkip(
                "No llama runtime available (\(error)). Download a model in the app first; " +
                "the eval loads it from ~/Library/Application Support/Cotabby/LlamaRuntime/."
            )
        }
        let engine = LlamaSuggestionEngine(runtimeManager: manager)
        let spellChecker = CurrentWordSpellChecker()
        let cases = try Self.loadCases(named: "llama-recall-cases")

        var results: [LlamaEvalCaseResult] = []
        for evalCase in cases {
            let result = try await Self.runCase(evalCase, engine: engine, spellChecker: spellChecker)
            results.append(result)
        }

        let report = LlamaEvalReport(modelLabel: Self.modelLabel() + " [recall]", results: results)
        print(report.rendered())
        for result in results {
            let mark = result.outcome == .correctInsert ? "PASS" : "FAIL"
            let want = result.evalCase.expectation.mustContain.joined(separator: "|")
            print("\(mark) \(result.evalCase.id) want=\(want) got=\(result.shownText ?? "<suppressed:\(result.suppressionStage ?? "none")>")")
        }
        try Self.writeArtifact(report)

        XCTAssertFalse(results.isEmpty)
        #else
        throw XCTSkip(
            "Llama recall eval is disabled. Pass SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) RUN_LLAMA_EVAL'."
        )
        #endif
    }

    #if RUN_LLAMA_EVAL
    /// One case through the production pipeline. `shownText` is nil wherever the pipeline would
    /// have shown nothing: the pre-generation gate, the normalizer (empty result), the
    /// trailing-duplication check inside the normalizer, or the display-time seam guard.
    private static func runCase(
        _ evalCase: LlamaEvalCase,
        engine: LlamaSuggestionEngine,
        spellChecker: CurrentWordSpellChecker
    ) async throws -> LlamaEvalCaseResult {
        // Mirrors the coordinator's pre-generation gate, caret position included.
        guard SuggestionRequestFactory.shouldGenerateSuggestion(
            for: evalCase.precedingText, trailingText: evalCase.trailingText
        ) else {
            return LlamaEvalCaseResult(
                evalCase: evalCase,
                shownText: nil,
                rawText: "",
                outcome: LlamaEvalScorer.outcome(shownText: nil, for: evalCase),
                suppressionStage: "pre-generation-gate",
                latencySeconds: 0
            )
        }

        // Mirrors the coordinator's typo gate with the shipping defaults (suppress on typo, offer
        // corrections, no automatic fixing): a misspelled current word shows no continuation, and a
        // correction offer is not a continuation either.
        let typoDecision = TypoGate.resolve(
            precedingText: evalCase.precedingText,
            settings: TypoGate.Settings(suppressCompletionsOnTypo: true, offerTypoCorrections: true, automaticallyFixTypos: false),
            isTypo: { spellChecker.isTypo($0) },
            bestCorrection: { spellChecker.bestCorrection(for: $0) },
            isWordInProgress: { spellChecker.hasCompletions(forPartialWord: $0) }
        )
        if typoDecision != .proceed {
            return LlamaEvalCaseResult(
                evalCase: evalCase,
                shownText: nil,
                rawText: "",
                outcome: LlamaEvalScorer.outcome(shownText: nil, for: evalCase),
                suppressionStage: "typo-gate",
                latencySeconds: 0
            )
        }

        let context = CotabbyTestFixtures.focusedInputContext(
            applicationName: evalCase.applicationName,
            bundleIdentifier: evalCase.bundleIdentifier,
            precedingText: evalCase.precedingText,
            trailingText: evalCase.trailingText
        )
        let settings = CotabbyTestFixtures.settingsSnapshot(
            selectedEngine: .llamaOpenSource,
            selectedWordCountPreset: .twelveToTwenty,
            // Only a case that supplies clipboard text turns the section on, so the ordinary
            // continuation cases keep the exact prompt shape they have always been scored against.
            isClipboardContextEnabled: evalCase.clipboardContext != nil,
            isMultiLineEnabled: evalCase.isMultiLineEnabled
        )
        let request = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: settings,
            configuration: .standard,
            clipboardContext: evalCase.clipboardContext,
            visualContextSummary: evalCase.visualContextSummary
        ).request

        let start = Date()
        var result = try await engine.generateSuggestion(for: request)
        var latency = Date().timeIntervalSince(start)

        let assessment: (String) -> CompletionSeamGuard.SpellingAssessment = { word in
            guard spellChecker.isTypo(word) else {
                return .known
            }
            return spellChecker.bestCorrection(for: word) == nil
                ? .uncorrectableTypo
                : .correctableTypo
        }
        var shownText: String? = result.text.isEmpty ? nil : result.text
        var suppressionStage: String? = result.text.isEmpty ? "normalizer" : nil

        // Mirrors the coordinator's display-time seam guard.
        if let candidate = shownText {
            let verdict = CompletionSeamGuard.verdict(
                precedingText: evalCase.precedingText, completion: candidate, spellingAssessment: assessment
            )
            if verdict != .allow {
                shownText = nil
                suppressionStage = "seam-guard"
            }
        }

        return LlamaEvalCaseResult(
            evalCase: evalCase,
            shownText: shownText,
            rawText: result.rawText,
            outcome: LlamaEvalScorer.outcome(shownText: shownText, for: evalCase),
            suppressionStage: suppressionStage,
            latencySeconds: latency
        )
    }

    private static func loadCases(named resource: String = "llama-eval-cases") throws -> [LlamaEvalCase] {
        guard let url = Bundle(for: LlamaSuggestionEvalTests.self)
            .url(forResource: resource, withExtension: "json") else {
            throw XCTSkip("\(resource).json missing from the test bundle")
        }
        return try LlamaEvalCase.loadDataset(from: url)
    }

    /// The model file the runtime locator would pick, for the report header. Mirrors the
    /// preferred-name-first resolution without reaching into the manager's internals.
    private static func modelLabel() -> String {
        let directory = BundledRuntimeLocator.userRuntimeDirectoryURL()
        let discovered = BundledRuntimeLocator.discoverGGUFModelURLs(in: directory)
            .map(\.lastPathComponent)
        for preferred in LlamaRuntimeConfiguration.default.preferredModelNames
        where discovered.contains(preferred) {
            return preferred
        }
        return discovered.first ?? "unknown-model"
    }

    /// Repo-relative artifact path derived from this source file so the output lands in the
    /// gitignored build/ directory regardless of the test process working directory or this
    /// test file's nesting depth.
    private static func writeArtifact(_ report: LlamaEvalReport) throws {
        guard let repoRoot = repositoryRoot(startingAt: URL(fileURLWithPath: #filePath)) else {
            throw XCTSkip("Could not find project.yml above the eval source path")
        }
        let directory = repoRoot.appendingPathComponent("build/eval", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = report.modelLabel
            .replacingOccurrences(of: ".gguf", with: "")
            .replacingOccurrences(of: " [recall]", with: "-recall")
        let url = directory.appendingPathComponent("llama-eval-\(stem).json")
        try report.jsonArtifact().write(to: url)
        print("Eval artifact written to \(url.path)")
    }

    private static func repositoryRoot(startingAt sourceURL: URL) -> URL? {
        var candidate = sourceURL.deletingLastPathComponent()
        while candidate.path != "/" {
            if FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("project.yml").path
            ) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }
    #endif
}
