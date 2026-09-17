import XCTest
@testable import Cotabby

/// Replays synthetic keystrokes through the real local engine, including streamed display guards
/// and cooperative cancellation. Unlike the isolated-case eval, a trace keeps one engine/cache
/// alive across edits. Cold and prewarmed runs both start from a reset prompt cache; model loading
/// is excluded. No Accessibility reads, key injection, or external endpoints are used.
///
/// Enable with RUN_LLAMA_EVAL as documented in LlamaSuggestionEvalTests and select
/// `-only-testing:CotabbyTests/LlamaTypingSessionEvalTests`. Use Release + ENABLE_TESTABILITY=YES
/// for latency comparisons. This measures input→display-eligible text, not pixels on screen:
/// focus polling, overlay layout, adaptive debounce, and coordinator acceptance-tail reuse need
/// separate end-to-end measurements. The report records this scope alongside every run.
@MainActor
final class LlamaTypingSessionEvalTests: XCTestCase {
    func testReportTypingSessions() async throws {
        #if RUN_LLAMA_EVAL
        let manager = try LlamaEvalRuntime.makeManager()
        do {
            try await manager.prepare()
        } catch {
            if ProcessInfo.processInfo.environment["COTABBY_EVAL_MODEL_PATH"] != nil { throw error }
            throw XCTSkip("Download a local catalog model before running typing evals: \(error)")
        }
        defer { manager.shutdownSync(timeoutSeconds: 5) }
        let engine = LlamaSuggestionEngine(runtimeManager: manager)
        let runner = TypingSessionReplay(engine: engine)
        var sessions: [TypingSessionEvalReport.Session] = []
        for trace in TypingSessionTrace.standard {
            for prewarmed in [false, true] {
                for streamingEnabled in [false, true] {
                    let session = try await runner.run(trace, prewarmed: prewarmed, streamingEnabled: streamingEnabled)
                    sessions.append(session)
                    for measurement in session.measurements {
                        XCTAssertNil(measurement.failure, "\(trace.id): \(measurement.failure ?? "")")
                    }
                }
            }
        }
        let report = TypingSessionEvalReport(
            modelFilename: manager.diagnostics.modelFilePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "unknown",
            seed: LlamaEvalRuntime.seed,
            debounceMilliseconds: runner.configuration.debounceMilliseconds,
            sessions: sessions
        )
        print(report.measurementScope)
        print(report.rendered())
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/eval", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let artifact = directory.appendingPathComponent("typing-eval-\(report.modelFilename).json")
        try encoder.encode(report).write(to: artifact)
        print("Typing eval artifact: \(artifact.path)")
        #else
        throw XCTSkip("Pass SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) RUN_LLAMA_EVAL' to run local typing traces.")
        #endif
    }
}

#if RUN_LLAMA_EVAL
/// One main-actor probe belongs to each input revision. The task and its delayed callbacks retain
/// it until they drain; invalidation prevents stale callbacks from inflating useful-output scores.
@MainActor
private final class TypingSessionProbe {
    var measurement: TypingSessionStepMeasurement
    var isCurrent = true
    var streaming = SuggestionStreamingState()

    nonisolated deinit {}

    init(step: TypingSessionTrace.Step, inputMilliseconds: Double) {
        measurement = .init(step: step, inputMilliseconds: inputMilliseconds)
    }

    func observe(_ result: SuggestionResult, at milliseconds: Double, final: Bool, spellChecker: CurrentWordSpellChecker) {
        guard isCurrent, measurement.finishedMilliseconds == nil else {
            measurement.stalePartialCount += 1
            return
        }
        let prefix = measurement.step.precedingText
        let spelling: (String) -> CompletionSeamGuard.SpellingAssessment = { word in
            guard spellChecker.isTypo(word) else { return .known }
            return spellChecker.bestCorrection(for: word) == nil ? .uncorrectableTypo : .correctableTypo
        }
        if final {
            guard !result.text.isEmpty, CompletionSeamGuard.verdict(
                precedingText: prefix, completion: result.text, spellingAssessment: spelling
            ) == .allow else {
                measurement.recordHidden()
                return
            }
        } else {
            guard streaming.canRender(result.text),
                  CompletionSeamGuard.allowsStreamedPartial(precedingText: prefix, completion: result.text) else { return }
            if streaming.leadingWordGateState == .pending {
                switch CompletionSeamGuard.streamedLeadingWordVerdict(
                    precedingText: prefix, completion: result.text, spellingAssessment: spelling
                ) {
                case .wait: return
                case .allow: streaming.resolveLeadingWordGate(.allowed)
                case .suppress: streaming.resolveLeadingWordGate(.suppressed)
                }
            }
            guard streaming.leadingWordGateState == .allowed else { return }
        }
        guard !result.text.isEmpty else { return }
        if final { measurement.finalVisibleMilliseconds = milliseconds }
        streaming.recordRendered(result.text)
        measurement.recordVisible(result.text, at: milliseconds)
    }
}

/// Schedules revisions against one monotonic origin, rather than sleeping after each generation.
/// This allows the next keystroke to cancel expensive work and measures how long that work takes
/// to unwind. All tasks are drained before cache reset, so adjacent sessions cannot contaminate
/// each other's cold/prewarmed label.
@MainActor
private final class TypingSessionReplay {
    let configuration = LlamaEvalRuntime.configuration
    private let engine: LlamaSuggestionEngine
    private let spellChecker = CurrentWordSpellChecker()

    nonisolated deinit {}

    init(engine: LlamaSuggestionEngine) {
        self.engine = engine
    }

    func run(
        _ trace: TypingSessionTrace, prewarmed: Bool, streamingEnabled: Bool
    ) async throws -> TypingSessionEvalReport.Session {
        await engine.resetCachedGenerationContext()
        if prewarmed, let first = trace.steps.first {
            await engine.prewarm(for: request(for: first, generation: 0))
        }
        let origin = ContinuousClock.now
        let elapsed: @MainActor @Sendable () -> Double = { Self.milliseconds(origin.duration(to: .now)) }
        var probes: [TypingSessionProbe] = []
        var tasks: [Task<Void, Never>] = []
        defer {
            // Also clean up if the test itself is interrupted while sleeping between inputs.
            for (probe, task) in zip(probes, tasks) {
                probe.isCurrent = false
                task.cancel()
            }
        }
        for (index, step) in trace.steps.enumerated() {
            try await ContinuousClock().sleep(until: origin.advanced(by: .milliseconds(step.atMilliseconds)))
            let inputTime = elapsed()
            if let previous = probes.last {
                if step.action == .acceptWord {
                    previous.measurement.acceptanceOpportunityCharacters = acceptanceOpportunity(from: previous, next: step)
                }
                cancel(previous, task: tasks.last, at: inputTime)
            }
            let probe = TypingSessionProbe(step: step, inputMilliseconds: inputTime)
            probes.append(probe)
            let request = request(for: step, generation: UInt64(index + 1))
            let task = Task<Void, Never> { @MainActor [engine, spellChecker, configuration] in
                defer { probe.measurement.finishedMilliseconds = elapsed() }
                do {
                    try await Task.sleep(for: .milliseconds(configuration.debounceMilliseconds))
                    guard SuggestionRequestFactory.shouldGenerateSuggestion(for: step.precedingText) else { return }
                    probe.measurement.generationStartedMilliseconds = elapsed()
                    let onPartial: (@MainActor @Sendable (SuggestionResult) -> Void)?
                    if streamingEnabled {
                        onPartial = { partial in
                            probe.observe(partial, at: elapsed(), final: false, spellChecker: spellChecker)
                        }
                    } else {
                        onPartial = nil
                    }
                    let result = try await engine.generateSuggestion(for: request, onPartial: onPartial)
                    try Task.checkCancellation()
                    probe.observe(result, at: elapsed(), final: true, spellChecker: spellChecker)
                } catch is CancellationError {
                    // Expected when the scripted writer types before generation finishes.
                } catch SuggestionClientError.cancelled {
                    // The native boundary translates cooperative cancellation into this case.
                } catch {
                    probe.measurement.failure = error.localizedDescription
                }
            }
            tasks.append(task)
        }
        let end = (trace.steps.last?.atMilliseconds ?? 0) + trace.finalPauseMilliseconds
        try await ContinuousClock().sleep(until: origin.advanced(by: .milliseconds(end)))
        if let last = probes.last { cancel(last, task: tasks.last, at: elapsed()) }
        for task in tasks { await task.value }
        // Engine callbacks hop independently to MainActor. They can arrive after task completion;
        // the probes reject them even after this yield and no such callback can display text.
        await Task.yield()
        return .init(
            traceID: trace.id, cacheMode: prewarmed ? "prewarmed" : "cold",
            streamingEnabled: streamingEnabled, measurements: probes.map(\.measurement)
        )
    }

    private func cancel(_ probe: TypingSessionProbe, task: Task<Void, Never>?, at milliseconds: Double) {
        probe.isCurrent = false
        if probe.measurement.finishedMilliseconds == nil {
            probe.measurement.cancellationRequestedMilliseconds = milliseconds
            task?.cancel()
        }
    }

    private func acceptanceOpportunity(from probe: TypingSessionProbe, next: TypingSessionTrace.Step) -> Int {
        guard let visible = probe.measurement.visibleText else { return 0 }
        let chunk = SuggestionSessionReconciler.nextAcceptanceChunk(from: visible)
        let insertion = SuggestionSessionReconciler.insertionChunk(
            forAcceptedChunk: chunk, precedingText: probe.measurement.step.precedingText
        )
        return probe.measurement.step.precedingText + insertion == next.precedingText ? insertion.count : 0
    }

    private func request(for step: TypingSessionTrace.Step, generation: UInt64) -> SuggestionRequest {
        SuggestionRequestFactory.buildRequest(
            context: CotabbyTestFixtures.focusedInputContext(
                precedingText: step.precedingText, trailingText: step.trailingText, generation: generation
            ),
            settings: CotabbyTestFixtures.settingsSnapshot(
                selectedEngine: .llamaOpenSource, selectedWordCountPreset: .twelveToTwenty,
                isClipboardContextEnabled: false, isSurfaceContextEnabled: false,
                isMultiLineEnabled: true, streamSuggestionsWhileGenerating: true
            ),
            configuration: configuration
        ).request
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
#endif
