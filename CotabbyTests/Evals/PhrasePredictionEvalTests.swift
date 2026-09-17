import CryptoKit
import XCTest
@testable import Cotabby

/// Opt-in accuracy replay. One runner owns a bounded pool of independent local engines, resets
/// their prompt caches at phrase boundaries, and advances only through reference text. Waiting for final
/// output at each checkpoint isolates prediction quality from typing speed and cancellation;
/// LlamaTypingSessionEvalTests remains the separate timing/interruption benchmark.
///
/// Use `python3 scripts/phrase_eval.py run`. That tool injects settings into the xctestrun file
/// because xcodebuild does not reliably forward shell environment variables to the test host.
@MainActor
final class PhrasePredictionEvalTests: XCTestCase {
    func testReplayCorpus() async throws {
        #if RUN_LLAMA_EVAL
        let environment = ProcessInfo.processInfo.environment
        // RUN_LLAMA_EVAL alone must not accidentally add thousands of generations to the older
        // opt-in suites. A second runtime switch is set only by the phrase-eval CLI.
        try XCTSkipUnless(environment["COTABBY_PHRASE_EVAL"] == "1", "Use scripts/phrase_eval.py run")
        let options = try Options(environment)
        let corpusURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "phrase-prediction-1337", withExtension: "json"))
        let data = try Data(contentsOf: corpusURL)
        let corpus = try JSONDecoder().decode(PhrasePredictionCorpus.self, from: data)
        try corpus.validate()
        let selected = try options.select(corpus.phrases)
        let shards = try PhrasePredictionReplayPlan.shards(phraseCount: selected.count, workers: options.workers)
        let managers = try shards.map { _ in try LlamaEvalRuntime.makeManager() }
        // Keep every context alive until the task group has drained, including on cancellation.
        // Each manager owns a separate native core, sampler and KV cache: sharing a manager would
        // serialize all workers on that core's autocomplete lock.
        defer { managers.forEach { $0.shutdownSync(timeoutSeconds: 5) } }
        // Missing models and failed loads are errors for an explicitly requested benchmark, not
        // a successful-looking skip. Do not download or select a different model automatically.
        // Initialize the native backends sequentially before concurrent generation starts.
        for manager in managers {
            try Task.checkCancellation()
            try await manager.prepare()
        }
        let configuration = LlamaEvalRuntime.configuration
        let settings = CotabbyTestFixtures.settingsSnapshot(
            selectedEngine: .llamaOpenSource, selectedWordCountPreset: configuration.defaultWordCountPreset,
            isClipboardContextEnabled: false, isSurfaceContextEnabled: true,
            userName: "", isMultiLineEnabled: false
        )
        var configurationRecord = Dictionary(uniqueKeysWithValues: Mirror(reflecting: configuration).children.compactMap {
            child -> (String, String)? in
            child.label.map { ($0, String(describing: child.value)) }
        })
        configurationRecord["settings"] = "single-line; surface metadata and prior draft fixed; synthetic OCR varies; no clipboard/profile/custom rules"
        configurationRecord["os"] = ProcessInfo.processInfo.operatingSystemVersionString
        configurationRecord["processors"] = String(ProcessInfo.processInfo.processorCount)
        let modelPath = try XCTUnwrap(managers.first?.diagnostics.modelFilePath)
        guard managers.allSatisfy({ $0.diagnostics.modelFilePath == modelPath }) else {
            throw Options.invalid("All workers must evaluate the same model")
        }
        configurationRecord["modelSHA256"] = try Self.fileSHA256(URL(fileURLWithPath: modelPath))
        let metadata = PhrasePredictionReport.Metadata(
            corpusSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            corpusVersion: corpus.version, model: modelPath, seed: LlamaEvalRuntime.seed,
            mode: options.mode, configuration: configurationRecord, runLabel: options.label,
            contextMode: options.contextMode, workerCount: managers.count
        )
        try FileManager.default.createDirectory(at: options.output, withIntermediateDirectories: true)
        let journal = try ReplayJournal(output: options.output)
        defer { journal.close() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Persist identity before inference, so interrupted journals can still be interpreted.
        try encoder.encode(metadata).write(to: options.output.appendingPathComponent("metadata.json"), options: .atomic)
        print("REPLAY workers=\(managers.count); independent native contexts; latency includes worker contention")
        // MainActor isolates the journal and AppKit spell checker. Each awaited generation runs
        // on its manager's detached native task, allowing all three cores to compute concurrently.
        // A throwing task group cancels its siblings and waits for their cleanup before returning.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (workerIndex, indices) in shards.enumerated() {
                let manager = managers[workerIndex]
                group.addTask { @MainActor in
                    let engine = LlamaSuggestionEngine(runtimeManager: manager)
                    let spellChecker = CurrentWordSpellChecker()
                    for index in indices {
                        try Task.checkCancellation()
                        let phrase = selected[index]
                        let scenario = try XCTUnwrap(phrase.scenario)
                        for condition in PhrasePredictionReplayPlan.conditions(at: index, mode: options.contextMode) {
                            await engine.resetCachedGenerationContext()
                            var observations: [PhrasePredictionObservation] = []
                            for checkpoint in PhrasePredictionScorer.checkpoints(for: phrase, mode: options.mode) {
                                try Task.checkCancellation()
                                observations.append(try await self.observe(
                                    checkpoint, scenario: scenario, condition: condition, engine: engine, spellChecker: spellChecker,
                                    settings: settings, configuration: configuration
                                ))
                            }
                            let result = PhrasePredictionReport.PhraseResult(phrase: phrase, observations: observations, condition: condition)
                            try journal.append(result)
                            print("PHRASE \(index + 1)/\(selected.count) \(phrase.id) [\(condition.rawValue)] worker=\(workerIndex + 1): \(result.nextWord.correct)/\(result.nextWord.checkpoints)")
                        }
                    }
                }
            }
            for try await _ in group { }
        }
        let results = try PhrasePredictionReplayPlan.orderedResults(
            journal.results, phrases: selected, mode: options.mode, context: options.contextMode
        )
        let report = PhrasePredictionReport(metadata: metadata, phrases: results)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: options.output.appendingPathComponent("report.json"), options: .atomic)
        try (report.rendered() + "\n").write(to: options.output.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
        print(report.measurementScope)
        print(report.rendered())
        XCTAssertEqual(report.errorCount, 0, "Inference errors are recorded as misses; inspect report.json")
        if options.contextMode == .paired { XCTAssertNotNil(report.contextLift, "Paired results must have matching checkpoints") }
        #else
        throw XCTSkip("Local phrase benchmark: use python3 scripts/phrase_eval.py run")
        #endif
    }

    #if RUN_LLAMA_EVAL
    /// The test owns one journal for the entire replay. Actor isolation makes each append atomic
    /// with respect to other workers; the Python progress reader sees only complete JSONL lines.
    /// Results stay in completion order here and are validated/reordered before final scoring.
    @MainActor
    private final class ReplayJournal {
        private let handle: FileHandle
        private let encoder = JSONEncoder()
        private(set) var results: [PhrasePredictionReport.PhraseResult] = []

        init(output: URL) throws {
            let url = output.appendingPathComponent("phrases.jsonl")
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw Options.invalid("Output already contains phrase results; choose a new output directory")
            }
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try FileHandle(forWritingTo: url)
            encoder.outputFormatting = [.sortedKeys]
        }

        func append(_ result: PhrasePredictionReport.PhraseResult) throws {
            try handle.write(contentsOf: encoder.encode(result) + Data([0x0A]))
            try handle.synchronize()
            results.append(result)
        }

        func close() { try? handle.close() }
    }

    private func observe(
        _ checkpoint: PhrasePredictionScorer.Checkpoint, scenario: PhrasePredictionCorpus.ScreenScenario,
        condition: PhrasePredictionScorer.ContextCondition, engine: LlamaSuggestionEngine,
        spellChecker: CurrentWordSpellChecker, settings: SuggestionSettingsSnapshot,
        configuration: SuggestionConfiguration
    ) async throws -> PhrasePredictionObservation {
        guard SuggestionRequestFactory.shouldGenerateSuggestion(for: checkpoint.prefix) else {
            return .init(checkpoint: checkpoint, raw: "", shown: nil, suppression: "pre-generation-gate", latencyMilliseconds: 0, error: nil)
        }
        let request = PhrasePredictionScreenContext.request(
            checkpoint: checkpoint, scenario: scenario, condition: condition,
            settings: settings, configuration: configuration
        )
        let start = ContinuousClock.now
        func elapsed() -> Double {
            let components = start.duration(to: .now).components
            return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
        }
        do {
            let result = try await engine.generateSuggestion(for: request)
            try Task.checkCancellation()
            var shown: String? = result.text.isEmpty ? nil : result.text
            var suppression: String? = shown == nil ? "normalizer" : nil
            if let candidate = shown, CompletionSeamGuard.verdict(
                precedingText: checkpoint.prefix, completion: candidate,
                spellingAssessment: { word in
                    guard spellChecker.isTypo(word) else { return .known }
                    return spellChecker.bestCorrection(for: word) == nil ? .uncorrectableTypo : .correctableTypo
                }
            ) != .allow {
                shown = nil
                suppression = "seam-guard"
            }
            return .init(checkpoint: checkpoint, raw: result.rawText, shown: shown, suppression: suppression,
                         latencyMilliseconds: elapsed(), error: nil, screenExcerpt: request.visualContextSummary, prompt: request.prompt)
        } catch is CancellationError {
            throw CancellationError()
        } catch SuggestionClientError.cancelled {
            throw CancellationError()
        } catch {
            return .init(checkpoint: checkpoint, raw: "", shown: nil, suppression: nil,
                         latencyMilliseconds: elapsed(), error: error.localizedDescription,
                         screenExcerpt: request.visualContextSummary, prompt: request.prompt)
        }
    }

    /// Hash in bounded chunks; loading a multi-GB GGUF into Data would distort memory pressure
    /// immediately before the benchmark. This fingerprint distinguishes same-name model files.
    private static func fileSHA256(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Test-host configuration is a short-lived value, separate from the app's saved settings.
    /// Invalid filters fail loudly instead of silently reporting an empty or different suite.
    private struct Options {
        let mode: PhrasePredictionScorer.Mode
        let contextMode: PhrasePredictionScorer.ContextMode
        let category: String?
        let phraseID: String?
        let limit: Int?
        let perCategory: Int?
        let workers: Int
        let output: URL
        let label: String

        init(_ environment: [String: String]) throws {
            guard let mode = PhrasePredictionScorer.Mode(rawValue: environment["COTABBY_PHRASE_MODE"] ?? "word") else {
                throw Self.invalid("Mode must be word or character")
            }
            self.mode = mode
            guard let contextMode = PhrasePredictionScorer.ContextMode(rawValue: environment["COTABBY_PHRASE_CONTEXT"] ?? "paired") else {
                throw Self.invalid("Context must be none, screen, or paired")
            }
            self.contextMode = contextMode
            guard let workers = Int(environment["COTABBY_PHRASE_WORKERS"] ?? "3"), (1...3).contains(workers) else {
                throw Self.invalid("Workers must be 1, 2, or 3")
            }
            self.workers = workers
            category = environment["COTABBY_PHRASE_CATEGORY"]
            phraseID = environment["COTABBY_PHRASE_ID"]
            if let raw = environment["COTABBY_PHRASE_LIMIT"] {
                guard let value = Int(raw), value > 0 else { throw Self.invalid("Limit must be a positive integer") }
                limit = value
            } else { limit = nil }
            if let raw = environment["COTABBY_PHRASE_PER_CATEGORY"] {
                guard let value = Int(raw), value > 0 else { throw Self.invalid("Per-category count must be positive") }
                perCategory = value
            } else { perCategory = nil }
            guard let path = environment["COTABBY_PHRASE_OUTPUT"], path.hasPrefix("/") else {
                throw Self.invalid("An absolute output directory is required")
            }
            output = URL(fileURLWithPath: path, isDirectory: true)
            label = environment["COTABBY_PHRASE_LABEL"] ?? "unlabeled"
        }

        func select(_ phrases: [PhrasePredictionCorpus.Phrase]) throws -> [PhrasePredictionCorpus.Phrase] {
            var counts: [String: Int] = [:]
            let filtered = phrases.filter {
                guard (category == nil || $0.category == category) && (phraseID == nil || $0.id == phraseID) else { return false }
                counts[$0.category, default: 0] += 1
                return perCategory == nil || counts[$0.category, default: 0] <= (perCategory ?? 0)
            }
            guard !filtered.isEmpty else { throw Self.invalid("No phrases matched the selection") }
            return Array(filtered.prefix(limit ?? filtered.count))
        }

        static func invalid(_ message: String) -> Error { PhrasePredictionCorpus.ValidationError.invalid(message) }
    }
    #endif
}
