import CryptoKit
import XCTest
@testable import Cotabby

/// Opt-in accuracy replay. One runner owns one local engine for the suite, resets its prompt
/// cache at phrase boundaries, and advances only through the reference text. Waiting for final
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
        let manager = try LlamaEvalRuntime.makeManager()
        // Missing models and failed loads are errors for an explicitly requested benchmark, not
        // a successful-looking skip. Do not download or select a different model automatically.
        try await manager.prepare()
        defer { manager.shutdownSync(timeoutSeconds: 5) }
        let engine = LlamaSuggestionEngine(runtimeManager: manager)
        let spellChecker = CurrentWordSpellChecker()
        let configuration = LlamaEvalRuntime.configuration
        let settings = CotabbyTestFixtures.settingsSnapshot(
            selectedEngine: .llamaOpenSource, selectedWordCountPreset: configuration.defaultWordCountPreset,
            isClipboardContextEnabled: false, isSurfaceContextEnabled: false,
            userName: "", isMultiLineEnabled: false
        )
        var configurationRecord = Dictionary(uniqueKeysWithValues: Mirror(reflecting: configuration).children.compactMap {
            child -> (String, String)? in
            child.label.map { ($0, String(describing: child.value)) }
        })
        configurationRecord["settings"] = "single-line; no screen/clipboard/profile/custom rules; product word-count preset"
        configurationRecord["os"] = ProcessInfo.processInfo.operatingSystemVersionString
        configurationRecord["processors"] = String(ProcessInfo.processInfo.processorCount)
        let modelPath = try XCTUnwrap(manager.diagnostics.modelFilePath)
        configurationRecord["modelSHA256"] = try Self.fileSHA256(URL(fileURLWithPath: modelPath))
        let metadata = PhrasePredictionReport.Metadata(
            corpusSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            corpusVersion: corpus.version, model: modelPath, seed: LlamaEvalRuntime.seed,
            mode: options.mode, configuration: configurationRecord, runLabel: options.label
        )
        try FileManager.default.createDirectory(at: options.output, withIntermediateDirectories: true)
        let observationsURL = options.output.appendingPathComponent("phrases.jsonl")
        guard !FileManager.default.fileExists(atPath: observationsURL.path) else {
            throw Options.invalid("Output already contains phrase results; choose a new output directory")
        }
        FileManager.default.createFile(atPath: observationsURL.path, contents: nil)
        let journal = try FileHandle(forWritingTo: observationsURL)
        defer { try? journal.close() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Persist identity before inference, so interrupted journals can still be interpreted.
        try encoder.encode(metadata).write(to: options.output.appendingPathComponent("metadata.json"), options: .atomic)
        var results: [PhrasePredictionReport.PhraseResult] = []
        for (index, phrase) in selected.enumerated() {
            try Task.checkCancellation()
            await engine.resetCachedGenerationContext()
            var observations: [PhrasePredictionObservation] = []
            for checkpoint in PhrasePredictionScorer.checkpoints(for: phrase, mode: options.mode) {
                try Task.checkCancellation()
                observations.append(try await observe(
                    checkpoint, engine: engine, spellChecker: spellChecker,
                    settings: settings, configuration: configuration
                ))
            }
            let result = PhrasePredictionReport.PhraseResult(phrase: phrase, observations: observations)
            results.append(result)
            // One durable record per completed phrase survives an interrupted long run. The
            // complete report is written only after the requested selection has finished.
            try journal.write(contentsOf: encoder.encode(result) + Data([0x0A]))
            try journal.synchronize()
            print("PHRASE \(index + 1)/\(selected.count) \(phrase.id): \(result.nextWord.correct)/\(result.nextWord.checkpoints)")
        }
        let report = PhrasePredictionReport(metadata: metadata, phrases: results)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: options.output.appendingPathComponent("report.json"), options: .atomic)
        try (report.rendered() + "\n").write(to: options.output.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
        print(report.measurementScope)
        print(report.rendered())
        XCTAssertEqual(report.suite.all.errors, 0, "Inference errors are recorded as misses; inspect report.json")
        #else
        throw XCTSkip("Local phrase benchmark: use python3 scripts/phrase_eval.py run")
        #endif
    }

    #if RUN_LLAMA_EVAL
    private func observe(
        _ checkpoint: PhrasePredictionScorer.Checkpoint, engine: LlamaSuggestionEngine,
        spellChecker: CurrentWordSpellChecker, settings: SuggestionSettingsSnapshot,
        configuration: SuggestionConfiguration
    ) async throws -> PhrasePredictionObservation {
        guard SuggestionRequestFactory.shouldGenerateSuggestion(for: checkpoint.prefix) else {
            return .init(checkpoint: checkpoint, raw: "", shown: nil, suppression: "pre-generation-gate", latencyMilliseconds: 0, error: nil)
        }
        let context = CotabbyTestFixtures.focusedInputContext(
            applicationName: "Phrase Benchmark", bundleIdentifier: "com.cotabby.phrase-benchmark",
            precedingText: checkpoint.prefix, trailingText: ""
        )
        let request = SuggestionRequestFactory.buildRequest(context: context, settings: settings, configuration: configuration).request
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
                         latencyMilliseconds: elapsed(), error: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch SuggestionClientError.cancelled {
            throw CancellationError()
        } catch {
            return .init(checkpoint: checkpoint, raw: "", shown: nil, suppression: nil,
                         latencyMilliseconds: elapsed(), error: error.localizedDescription)
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
        let category: String?
        let phraseID: String?
        let limit: Int?
        let output: URL
        let label: String

        init(_ environment: [String: String]) throws {
            guard let mode = PhrasePredictionScorer.Mode(rawValue: environment["COTABBY_PHRASE_MODE"] ?? "word") else {
                throw Self.invalid("Mode must be word or character")
            }
            self.mode = mode
            category = environment["COTABBY_PHRASE_CATEGORY"]
            phraseID = environment["COTABBY_PHRASE_ID"]
            if let raw = environment["COTABBY_PHRASE_LIMIT"] {
                guard let value = Int(raw), value > 0 else { throw Self.invalid("Limit must be a positive integer") }
                limit = value
            } else { limit = nil }
            guard let path = environment["COTABBY_PHRASE_OUTPUT"], path.hasPrefix("/") else {
                throw Self.invalid("An absolute output directory is required")
            }
            output = URL(fileURLWithPath: path, isDirectory: true)
            label = environment["COTABBY_PHRASE_LABEL"] ?? "unlabeled"
        }

        func select(_ phrases: [PhrasePredictionCorpus.Phrase]) throws -> [PhrasePredictionCorpus.Phrase] {
            let filtered = phrases.filter { (category == nil || $0.category == category) && (phraseID == nil || $0.id == phraseID) }
            guard !filtered.isEmpty else { throw Self.invalid("No phrases matched the selection") }
            return Array(filtered.prefix(limit ?? filtered.count))
        }

        static func invalid(_ message: String) -> Error { PhrasePredictionCorpus.ValidationError.invalid(message) }
    }
    #endif
}
