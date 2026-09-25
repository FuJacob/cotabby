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
        // Developer dogfood overrides live in the app's UserDefaults domain. Pin the shipped
        // values in this test process's higher-priority, in-memory argument domain so a personal
        // preference cannot change the experiment. Restore the old domain when this test exits;
        // no set(_:forKey:) call writes to the user's persistent app preferences.
        let defaults = UserDefaults.standard
        let previousArgumentDomain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var replayArgumentDomain = previousArgumentDomain
        replayArgumentDomain[LlamaSuggestionEngine.confidenceFloorOverrideKey] = NSNumber(value: LlamaSuggestionEngine.defaultConfidenceFloor)
        replayArgumentDomain[LlamaSuggestionEngine.argmaxStopDisabledKey] = false
        defaults.setVolatileDomain(replayArgumentDomain, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previousArgumentDomain, forName: UserDefaults.argumentDomain) }
        let corpusURL = try options.corpusURL ?? XCTUnwrap(Bundle(for: Self.self).url(forResource: "phrase-prediction-1337", withExtension: "json"))
        let data = try Data(contentsOf: corpusURL)
        let corpus = try JSONDecoder().decode(PhrasePredictionCorpus.self, from: data)
        try corpus.validate(canonical: options.corpusURL == nil)
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
        let configuration = options.configuration
        let settings = CotabbyTestFixtures.settingsSnapshot(
            selectedEngine: .llamaOpenSource, selectedWordCountPreset: options.wordCountPreset,
            isClipboardContextEnabled: false, isSurfaceContextEnabled: options.promptVariant != "content-only",
            userName: options.profile == "personalized" && options.promptVariant != "content-only" ? "Alex" : "",
            responseLanguages: options.profile == "personalized" && options.promptVariant != "content-only" ? ["English"] : [],
            isMultiLineEnabled: false, suppressCompletionsOnTypo: true, offerTypoCorrections: true
        )
        var configurationRecord = Dictionary(uniqueKeysWithValues: Mirror(reflecting: configuration).children.compactMap {
            child -> (String, String)? in
            child.label.map { ($0, String(describing: child.value)) }
        })
        configurationRecord["promptVariant"] = options.promptVariant
        configurationRecord["profile"] = options.profile
        configurationRecord["wordCountPreset"] = options.wordCountPreset.rawValue
        configurationRecord["settings"] = "single-line; surface metadata and prior draft fixed; synthetic OCR varies; no clipboard/custom rules; profile=\(options.profile); prompt=\(options.promptVariant)"
        configurationRecord["wordPolicy"] = "committed typo gate; unified first-word display; no local fallback in model-only accuracy replay"
        configurationRecord["os"] = ProcessInfo.processInfo.operatingSystemVersionString
        configurationRecord["processors"] = String(ProcessInfo.processInfo.processorCount)
        configurationRecord["confidenceFloor"] = String(LlamaSuggestionEngine.resolvedConfidenceFloor())
        configurationRecord["stopAtArgmaxEOG"] = String(LlamaSuggestionEngine.resolvedStopAtArgmaxEOG())
        configurationRecord["enginePreferenceSource"] = "test-process argument domain; product defaults"
        configurationRecord["selectionSplit"] = options.split
        configurationRecord["selectionSplitSeed"] = String(options.splitSeed)
        configurationRecord["selectionScreenPerCategory"] = String(options.screenPerCategory)
        let modelPath = try XCTUnwrap(managers.first?.diagnostics.modelFilePath)
        guard managers.allSatisfy({ $0.diagnostics.modelFilePath == modelPath }) else {
            throw Options.invalid("All workers must evaluate the same model")
        }
        configurationRecord["modelSHA256"] = try Self.fileSHA256(URL(fileURLWithPath: modelPath))
        let metadata = PhrasePredictionReport.Metadata(
            corpusSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            corpusVersion: corpus.version, model: modelPath, seed: try XCTUnwrap(configuration.randomSeed),
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
                                    settings: settings, configuration: configuration, promptVariant: options.promptVariant
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
        // These developer escape hatches are read by the engine on every generation. Record and
        // verify their effective values without writing to the user's persisted preferences.
        guard configurationRecord["confidenceFloor"] == String(LlamaSuggestionEngine.resolvedConfidenceFloor()),
              configurationRecord["stopAtArgmaxEOG"] == String(LlamaSuggestionEngine.resolvedStopAtArgmaxEOG()) else {
            throw Options.invalid("Generation preferences changed during replay; rerun with stable settings")
        }
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
    /// Exercise the CLI/native contract without loading a model. The expected IDs are also
    /// asserted by the Python tests, catching a hash recipe or filter-order mismatch early.
    func testBenchmarkOptionsPreserveSplitAndSamplingIdentity() throws {
        var environment = ["COTABBY_PHRASE_OUTPUT": "/tmp/cotabby-options-test"]
        let defaults = try Options(environment)
        XCTAssertEqual(defaults.configuration, LlamaEvalRuntime.configuration)
        XCTAssertEqual(defaults.wordCountPreset, LlamaEvalRuntime.configuration.defaultWordCountPreset)
        environment["COTABBY_PHRASE_WORD_COUNT"] = "4-7"
        environment["COTABBY_PHRASE_PROFILE"] = "personalized"
        environment["COTABBY_PHRASE_PROMPT_VARIANT"] = "compact-surface"
        XCTAssertEqual(try Options(environment).wordCountPreset, .fourToSeven)
        var badLength = environment
        badLength["COTABBY_PHRASE_WORD_COUNT"] = "100"
        XCTAssertThrowsError(try Options(badLength))
        environment.merge([
            "COTABBY_PHRASE_SPLIT": "screen", "COTABBY_PHRASE_CATEGORY": "science",
            "COTABBY_PHRASE_PER_CATEGORY": "3", "COTABBY_PHRASE_TEMPERATURE": "0",
            "COTABBY_PHRASE_REPETITION_PENALTY": "1.025", "COTABBY_PHRASE_TOP_K": "0",
            "COTABBY_PHRASE_TOP_P": "1", "COTABBY_PHRASE_MIN_P": "0", "COTABBY_PHRASE_SEED": "12648430"
        ]) { _, new in new }
        let options = try Options(environment)
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "phrase-prediction-1337", withExtension: "json"))
        let corpus = try JSONDecoder().decode(PhrasePredictionCorpus.self, from: Data(contentsOf: url))
        let selected = try options.select(corpus.phrases)
        XCTAssertEqual(selected.map(\.id), ["science-008", "science-127", "science-164"])
        environment["COTABBY_PHRASE_SPLIT"] = "heldout"
        XCTAssertEqual(try Options(environment).select(corpus.phrases).map(\.id), ["science-101", "science-135", "science-163"])
        let phrase = try XCTUnwrap(selected.first)
        let checkpoint = try XCTUnwrap(PhrasePredictionScorer.checkpoints(for: phrase, mode: .word).first)
        let request = PhrasePredictionScreenContext.request(
            checkpoint: checkpoint, scenario: try XCTUnwrap(phrase.scenario), condition: .none,
            settings: CotabbyTestFixtures.settingsSnapshot(selectedEngine: .llamaOpenSource),
            configuration: options.configuration
        )
        XCTAssertEqual(request.temperature, 0)
        XCTAssertEqual(request.repetitionPenalty, 1.025)
        XCTAssertEqual(request.topK, 0)
        XCTAssertEqual(request.topP, 1)
        XCTAssertEqual(request.minP, 0)
        XCTAssertEqual(request.randomSeed, 12648430)
        for (key, value) in [("SEED", "0"), ("SEED", "4294967295"), ("TOP_K", "-1"),
                             ("TOP_K", "2147483648"), ("TEMPERATURE", "nan"), ("REPETITION_PENALTY", "0")] {
            var invalid = environment
            invalid["COTABBY_PHRASE_\(key)"] = value
            XCTAssertThrowsError(try Options(invalid), "Should reject \(key)=\(value)")
        }
    }

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
        configuration: SuggestionConfiguration, promptVariant: String
    ) async throws -> PhrasePredictionObservation {
        guard SuggestionRequestFactory.shouldGenerateSuggestion(for: checkpoint.prefix) else {
            return .init(checkpoint: checkpoint, raw: "", shown: nil, suppression: "pre-generation-gate", latencyMilliseconds: 0, error: nil)
        }
        let typoDecision = TypoGate.resolve(precedingText: checkpoint.prefix,
            settings: .init(suppressCompletionsOnTypo: settings.suppressCompletionsOnTypo,
                            offerTypoCorrections: settings.offerTypoCorrections, automaticallyFixTypos: false),
            isTypo: { spellChecker.isTypo($0) }, bestCorrection: { spellChecker.bestCorrection(for: $0) })
        guard typoDecision == .proceed else {
            // Replacement offers cannot be scored as appended word continuations. The coordinator
            // interaction replay separately verifies replacement eligibility and accepted edits.
            return .init(checkpoint: checkpoint, raw: "", shown: nil, suppression: "committed-typo-gate",
                         latencyMilliseconds: 0, error: nil)
        }
        let request = PhrasePredictionScreenContext.request(
            checkpoint: checkpoint, scenario: scenario, condition: condition,
            settings: settings, configuration: configuration, promptVariant: promptVariant
        )
        let start = ContinuousClock.now
        func elapsed() -> Double {
            let components = start.duration(to: .now).components
            return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
        }
        do {
            let result = try await engine.generateSuggestion(for: request)
            try Task.checkCancellation()
            let references = Set(WordCompletionFallback.referenceWords(precedingText: checkpoint.prefix,
                trailingText: request.context.trailingText, glossary: settings.extendedContext).map { $0.lowercased() })
            let decision = CompletionSeamGuard.presentation(precedingText: checkpoint.prefix, completion: result.text, isFinal: true,
                spellingAssessment: { word in
                    if references.contains(word.lowercased()) || !spellChecker.isTypo(word) { return .known }
                    return spellChecker.bestCorrection(for: word) == nil ? .uncorrectableTypo : .correctableTypo
                })
            let shown: String?
            let suppression: String?
            switch decision {
            case let .show(text, _): shown = text; suppression = nil
            case .wait: shown = nil; suppression = "normalizer"
            case .suppress: shown = nil; suppression = "seam-guard"
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
    @MainActor
    private struct Options {
        let corpusURL: URL?
        let promptVariant: String
        let wordCountPreset: SuggestionWordCountPreset
        let profile: String
        let mode: PhrasePredictionScorer.Mode
        let contextMode: PhrasePredictionScorer.ContextMode
        let category: String?
        let phraseID: String?
        let limit: Int?
        let perCategory: Int?
        let split: String
        let splitSeed: UInt32
        let screenPerCategory: Int
        let configuration: SuggestionConfiguration
        let workers: Int
        let output: URL
        let label: String

        init(_ environment: [String: String]) throws {
            if let path = environment["COTABBY_PHRASE_CORPUS"] {
                guard path.hasPrefix("/") else { throw Self.invalid("Corpus path must be absolute") }
                corpusURL = URL(fileURLWithPath: path)
            } else { corpusURL = nil }
            promptVariant = environment["COTABBY_PHRASE_PROMPT_VARIANT"] ?? "production"
            profile = environment["COTABBY_PHRASE_PROFILE"] ?? "plain"
            guard ["production", "content-only", "compact-surface", "compact-language"].contains(promptVariant),
                  ["plain", "personalized"].contains(profile) else {
                throw Self.invalid("Unknown prompt variant or profile")
            }
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
            split = environment["COTABBY_PHRASE_SPLIT"] ?? "all"
            guard ["all", "screen", "heldout"].contains(split) else {
                throw Self.invalid("Split must be all, screen, or heldout")
            }
            guard let splitSeed = UInt32(environment["COTABBY_PHRASE_SPLIT_SEED"] ?? "1337") else {
                throw Self.invalid("Split seed must be an unsigned 32-bit integer")
            }
            self.splitSeed = splitSeed
            guard let screenCount = Int(environment["COTABBY_PHRASE_SCREEN_PER_CATEGORY"] ?? "20"),
                  (1..<191).contains(screenCount) else {
                throw Self.invalid("Screen per-category count must be between 1 and 190")
            }
            screenPerCategory = screenCount
            configuration = try Self.samplingConfiguration(environment)
            guard let preset = SuggestionWordCountPreset(rawValue:
                environment["COTABBY_PHRASE_WORD_COUNT"] ?? configuration.defaultWordCountPreset.rawValue) else {
                throw Self.invalid("Unknown word-count preset")
            }
            wordCountPreset = preset
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
            // SHA-256 over an explicitly encoded seed/ID pair has the same ordering in Python
            // and Swift. Swift's Hasher intentionally changes across processes and cannot define
            // an experimental split. Membership is fixed before filters, so heldout stays disjoint.
            let candidates: [PhrasePredictionCorpus.Phrase]
            if split == "all" {
                candidates = phrases
            } else {
                var ranked: [(phrase: PhrasePredictionCorpus.Phrase, digest: String)] = []
                for phrase in phrases {
                    let key = String(splitSeed) + ":" + phrase.id
                    let bytes = Data(key.utf8)
                    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                    ranked.append((phrase: phrase, digest: digest))
                }
                ranked.sort { lhs, rhs in
                    if lhs.digest == rhs.digest { return lhs.phrase.id < rhs.phrase.id }
                    return lhs.digest < rhs.digest
                }
                var ranks: [String: Int] = [:]
                candidates = ranked.compactMap { item in
                    ranks[item.phrase.category, default: 0] += 1
                    let inScreen = ranks[item.phrase.category, default: 0] <= screenPerCategory
                    return inScreen == (split == "screen") ? item.phrase : nil
                }
            }
            var counts: [String: Int] = [:]
            let filtered = candidates.filter {
                guard (category == nil || $0.category == category) && (phraseID == nil || $0.id == phraseID) else { return false }
                counts[$0.category, default: 0] += 1
                return perCategory == nil || counts[$0.category, default: 0] <= (perCategory ?? 0)
            }
            guard !filtered.isEmpty else { throw Self.invalid("No phrases matched the selection") }
            // Replay remains in corpus order even when hash order selected a capped partition.
            // This preserves worker sharding and alternating context order across paired runs.
            let ids = Set(filtered.map(\.id))
            let ordered = phrases.filter { ids.contains($0.id) }
            return Array(ordered.prefix(limit ?? ordered.count))
        }

        /// Each replay owns one immutable configuration snapshot, copied from the shared eval
        /// defaults and modified only by explicit test-host variables. Passing this value through
        /// request construction reaches the native sampler without changing the app's settings.
        private static func samplingConfiguration(_ environment: [String: String]) throws -> SuggestionConfiguration {
            func number(_ name: String, default value: Double, range: ClosedRange<Double>) throws -> Double {
                guard let raw = environment["COTABBY_PHRASE_\(name)"] else { return value }
                guard let parsed = Double(raw), parsed.isFinite, range.contains(parsed) else {
                    throw invalid("Invalid sampling \(name): \(raw)")
                }
                return parsed
            }
            let defaults = LlamaEvalRuntime.configuration
            let temperature = try number("TEMPERATURE", default: defaults.temperature, range: 0...100)
            let penalty = try number("REPETITION_PENALTY", default: defaults.repetitionPenalty, range: 0...100)
            guard penalty > 0 else { throw invalid("Repetition penalty must be positive") }
            let topP = try number("TOP_P", default: defaults.topP, range: 0...1)
            let minP = try number("MIN_P", default: defaults.minP, range: 0...1)
            guard let topK = Int(environment["COTABBY_PHRASE_TOP_K"] ?? String(defaults.topK)),
                  (0...Int(Int32.max)).contains(topK) else { throw invalid("Top-k must be a nonnegative Int32") }
            guard let seed = UInt32(environment["COTABBY_PHRASE_SEED"] ?? String(LlamaEvalRuntime.seed)),
                  seed > 0, seed < UInt32.max else { throw invalid("Seed must be a fixed integer between 1 and 4294967294") }
            return SuggestionConfiguration(
                maxPredictionTokens: defaults.maxPredictionTokens, debounceMilliseconds: defaults.debounceMilliseconds,
                temperature: temperature, topK: topK, topP: topP, minP: minP,
                repetitionPenalty: penalty, randomSeed: seed,
                maxPrefixWords: defaults.maxPrefixWords, maxPrefixCharacters: defaults.maxPrefixCharacters,
                maxPrefixWordsFoundationModel: defaults.maxPrefixWordsFoundationModel,
                maxPrefixCharactersFoundationModel: defaults.maxPrefixCharactersFoundationModel,
                maxSuffixCharacters: defaults.maxSuffixCharacters, llamaPromptTokenBudget: defaults.llamaPromptTokenBudget,
                defaultUserName: defaults.defaultUserName, defaultWordCountPreset: defaults.defaultWordCountPreset,
                focusPollIntervalMilliseconds: defaults.focusPollIntervalMilliseconds
            )
        }

        static func invalid(_ message: String) -> Error { PhrasePredictionCorpus.ValidationError.invalid(message) }
    }
    #endif
}
