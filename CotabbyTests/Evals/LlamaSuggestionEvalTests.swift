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
///   xcodebuild test -project CoHamster.xcodeproj -scheme CoHamster -destination 'platform=macOS' \
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
        let manager = try LlamaEvalRuntime.makeManager()
        do {
            try await manager.prepare()
        } catch {
            if ProcessInfo.processInfo.environment["COTABBY_EVAL_MODEL_PATH"] != nil { throw error }
            throw XCTSkip(
                "No llama runtime available (\(error)). Download a model in the app first; " +
                "the eval loads it from the app's model storage directory."
            )
        }
        defer { manager.shutdownSync(timeoutSeconds: 5) }
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

        let report = LlamaEvalReport(
            modelLabel: manager.diagnostics.modelFilePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "unknown-model",
            results: results
        )
        print("Sampler seed: \(LlamaEvalRuntime.seed)")
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
            configuration: LlamaEvalRuntime.configuration
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
                spellingAssessment: { word in
                    guard spellChecker.isTypo(word) else {
                        return .known
                    }
                    return spellChecker.bestCorrection(for: word) == nil
                        ? .uncorrectableTypo
                        : .correctableTypo
                }
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

    /// Repo-relative artifact path derived from this source file so the output lands in the
    /// gitignored build/ directory regardless of the test process working directory or this
    /// test file's nesting depth.
    private static func writeArtifact(_ report: LlamaEvalReport) throws {
        guard let repoRoot = repositoryRoot(startingAt: URL(fileURLWithPath: #filePath)) else {
            throw XCTSkip("Could not find project.yml above the eval source path")
        }
        let directory = repoRoot.appendingPathComponent("build/eval", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = report.modelLabel.replacingOccurrences(of: ".gguf", with: "")
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

#if RUN_LLAMA_EVAL
/// Both real-model suites use the same explicit override. Supplying this environment variable in
/// an xctestrun's EnvironmentVariables permits repo-local models without changing app preferences
/// or copying assets into the user's Library. Xcode does not forward arbitrary shell variables to
/// the app-hosted runner, so merely exporting the variable before xcodebuild is insufficient.
@MainActor
enum LlamaEvalRuntime {
    static let seed: UInt32 = 42

    /// Copy product tuning while fixing only the sampling seed. Both eval suites share this so
    /// an A/B run compares prompt/cache changes without a different random sequence per case.
    static var configuration: SuggestionConfiguration {
        let defaults = SuggestionConfiguration.standard
        return SuggestionConfiguration(
            maxPredictionTokens: defaults.maxPredictionTokens, debounceMilliseconds: defaults.debounceMilliseconds,
            temperature: defaults.temperature, topK: defaults.topK, topP: defaults.topP, minP: defaults.minP,
            repetitionPenalty: defaults.repetitionPenalty, randomSeed: seed,
            maxPrefixWords: defaults.maxPrefixWords, maxPrefixCharacters: defaults.maxPrefixCharacters,
            maxPrefixWordsFoundationModel: defaults.maxPrefixWordsFoundationModel,
            maxPrefixCharactersFoundationModel: defaults.maxPrefixCharactersFoundationModel,
            maxSuffixCharacters: defaults.maxSuffixCharacters, llamaPromptTokenBudget: defaults.llamaPromptTokenBudget,
            defaultUserName: defaults.defaultUserName,
            // Share the explicit harness length with the typing replay; otherwise a 4–7-word
            // campaign silently measures streaming with the older 12–20-word default.
            defaultWordCountPreset: ProcessInfo.processInfo.environment["COTABBY_PHRASE_WORD_COUNT"]
                .flatMap(SuggestionWordCountPreset.init(rawValue:)) ?? defaults.defaultWordCountPreset,
            focusPollIntervalMilliseconds: defaults.focusPollIntervalMilliseconds
        )
    }

    static func makeManager() throws -> LlamaRuntimeManager {
        guard let path = ProcessInfo.processInfo.environment["COTABBY_EVAL_MODEL_PATH"], !path.isEmpty else {
            return LlamaRuntimeManager()
        }
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else {
            throw NSError(domain: "LlamaEvalRuntime", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "COTABBY_EVAL_MODEL_PATH must name an existing absolute GGUF path: \(path)"
            ])
        }
        let url = URL(fileURLWithPath: path)
        let defaults = LlamaRuntimeConfiguration.default
        return LlamaRuntimeManager(
            configuration: LlamaRuntimeConfiguration(
                runtimeDirectoryPath: url.deletingLastPathComponent().path,
                preferredModelNames: [url.lastPathComponent],
                contextWindowTokens: defaults.contextWindowTokens,
                batchSize: defaults.batchSize,
                gpuLayerCount: defaults.gpuLayerCount
            ),
            runtimeLocator: BundledRuntimeLocator()
        )
    }
}
#endif
