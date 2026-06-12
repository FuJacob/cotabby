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

    #if RUN_LLAMA_EVAL
    /// One case through the production pipeline. `shownText` is nil wherever the pipeline would
    /// have shown nothing: the pre-generation gate, the normalizer (empty result), the
    /// trailing-duplication check inside the normalizer, or the display-time seam guard.
    private static func runCase(
        _ evalCase: LlamaEvalCase,
        engine: LlamaSuggestionEngine,
        spellChecker: CurrentWordSpellChecker
    ) async throws -> LlamaEvalCaseResult {
        // Mirrors the coordinator's pre-generation gate.
        guard SuggestionRequestFactory.shouldGenerateSuggestion(for: evalCase.precedingText) else {
            return LlamaEvalCaseResult(
                evalCase: evalCase,
                shownText: nil,
                rawText: "",
                outcome: LlamaEvalScorer.outcome(shownText: nil, for: evalCase),
                suppressionStage: "pre-generation-gate",
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
            isClipboardContextEnabled: false,
            isMultiLineEnabled: evalCase.isMultiLineEnabled
        )
        let request = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: settings,
            configuration: .standard
        ).request

        let start = Date()
        let result = try await engine.generateSuggestion(for: request)
        let latency = Date().timeIntervalSince(start)

        var shownText: String? = result.text.isEmpty ? nil : result.text
        var suppressionStage: String? = result.text.isEmpty ? "normalizer" : nil

        // Mirrors the coordinator's display-time seam guard.
        if let candidate = shownText {
            let verdict = CompletionSeamGuard.verdict(
                precedingText: evalCase.precedingText,
                completion: candidate,
                isKnownWord: { !spellChecker.isTypo($0) }
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

    private static func loadCases() throws -> [LlamaEvalCase] {
        guard let url = Bundle(for: LlamaSuggestionEvalTests.self)
            .url(forResource: "llama-eval-cases", withExtension: "json") else {
            throw XCTSkip("llama-eval-cases.json missing from the test bundle")
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
    /// gitignored build/ directory regardless of the test process working directory.
    private static func writeArtifact(_ report: LlamaEvalReport) throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let directory = repoRoot.appendingPathComponent("build/eval", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = report.modelLabel.replacingOccurrences(of: ".gguf", with: "")
        let url = directory.appendingPathComponent("llama-eval-\(stem).json")
        try report.jsonArtifact().write(to: url)
        print("Eval artifact written to \(url.path)")
    }
    #endif
}
