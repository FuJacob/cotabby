import Foundation
import XCTest
@testable import Cotabby

/// Drives the production coordinator/session with a real local model and a synthetic editor.
/// Unlike model-only typing evals, every typed character and accepted word takes the app's input,
/// presentation, cancellation, and reconciliation paths. The synthetic editor publishes each edit
/// after the input callback, exposing one stale snapshot without touching the user's applications.
/// This measures submitted ghost text, not AX, key injection, compositor latency, or visual quality.
///
/// Enable RUN_LLAMA_EVAL and run `CotabbyTests/TypingExperienceEvalTests`. The shared LlamaEvalRuntime
/// accepts COTABBY_EVAL_MODEL_PATH in the xctestrun EnvironmentVariables; exporting it in the shell
/// alone does not reach the app-hosted runner. Results contain synthetic text only and are written
/// to build/eval/typing-experience.json. Use Release + ENABLE_TESTABILITY=YES for useful timings.
@MainActor
final class TypingExperienceEvalTests: XCTestCase {
    func testRealModelTypingExperience() async throws {
        #if RUN_LLAMA_EVAL
        let manager = try LlamaEvalRuntime.makeManager()
        do { try await manager.prepare() }
        catch {
            if ProcessInfo.processInfo.environment["COTABBY_EVAL_MODEL_PATH"] != nil { throw error }
            throw XCTSkip("Download a local model before running the typing experience replay: \(error)")
        }
        defer { manager.shutdownSync(timeoutSeconds: 5) }
        let engine = LlamaSuggestionEngine(runtimeManager: manager)
        var runs: [TypingExperienceRun] = []
        for showFollowing in [true, false] {
            let recording = ExperienceRecordingEngine(engine: engine)
            var run = TypingExperienceRun(name: showFollowing ? "word-to-phrase" : "one-word-at-a-time")
            do { try await replayWordBoundary(showFollowing: showFollowing, engine: recording, run: &run) }
            catch { run.failure = error.localizedDescription }
            run.requests = recording.records
            runs.append(run)
        }
        let correctionEngine = ExperienceRecordingEngine(engine: engine)
        var correction = TypingExperienceRun(name: "correction-lookahead-after-publication")
        do { try await replayCorrection(engine: correctionEngine, run: &correction) }
        catch { correction.failure = error.localizedDescription }
        correction.requests = correctionEngine.records
        runs.append(correction)

        let recording = ExperienceRecordingEngine(engine: engine)
        var cancellation = TypingExperienceRun(name: "divergence-cancels-real-generation")
        do { try await replayCancellation(engine: recording, run: &cancellation) }
        catch { cancellation.failure = error.localizedDescription }
        cancellation.requests = recording.records
        runs.append(cancellation)

        let report = TypingExperienceReport(
            model: manager.diagnostics.modelFilePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "unknown",
            runs: runs
        )
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/eval")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let artifact = directory.appendingPathComponent("typing-experience.json")
        try encoder.encode(report).write(to: artifact)
        print("Typing experience artifact: \(artifact.path)")
        for run in runs {
            print("\(run.name): \(run.requests.count) requests, \(run.events.count) recorded transitions, \(run.failure ?? "completed")")
            XCTAssertNil(run.failure, "\(run.name): \(run.failure ?? "")")
        }
        #else
        throw XCTSkip("Pass SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) RUN_LLAMA_EVAL' to run the real-model coordinator replay.")
        #endif
    }

    #if RUN_LLAMA_EVAL
    private func replayWordBoundary(
        showFollowing: Bool, engine: ExperienceRecordingEngine, run: inout TypingExperienceRun
    ) async throws {
        await engine.resetCachedGenerationContext()
        var text = "Please send me the schedu"
        let rig = makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: text),
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(
                selectedWordCountPreset: .twelveToTwenty, isClipboardContextEnabled: false,
                isSurfaceContextEnabled: false, debounceMilliseconds: 1, showFollowingWords: showFollowing
            ), generationEngine: engine, configuration: LlamaEvalRuntime.configuration
        )
        var stopped = false
        defer { if !stopped { rig.coordinator.stop() } }
        // Exercise the ordinary local fallback if the real model produces an unusable seam.
        // A valid model ending is kept; no result is replaced merely to force the fallback path.
        rig.coordinator.symSpellCorrector.loadForTesting(contents: "schedule 100\nscheduled 5\n")
        run.record("input-prefix", text: text, rig: rig, engine: engine)
        rig.coordinator.schedulePrediction()
        try await waitFor("No usable word ending from model or local fallback") {
            rig.interactionState.activeSession != nil
        }
        try await waitFor("Prepared following words did not settle") {
            engine.inFlightCount == 0 && rig.coordinator.preparedContinuation == nil
        }
        let first = try XCTUnwrap(rig.interactionState.activeSession)
        run.record("first-word-offer", text: text, rig: rig, engine: engine)
        let ending = SuggestionSessionReconciler.nextAcceptanceChunk(from: first.remainingText)
        XCTAssertFalse(ending.isEmpty)
        XCTAssertFalse(ending.first?.isWhitespace == true, "An unfinished word must not be abandoned.")
        let originalPrediction = first.fullText
        let hadFollowingWords = originalPrediction.count > ending.count
        let requestCountBeforeTyping = engine.records.count

        for character in ending {
            _ = rig.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .textMutation, characters: String(character)))
            text.append(character)
            publish(text, in: rig)
            rig.coordinator.reconcileActiveSession(with: rig.focusProvider.snapshot)
        }
        run.record("typed-word-ending", text: text, rig: rig, engine: engine)
        if hadFollowingWords {
            XCTAssertEqual(rig.interactionState.activeSession?.predictedRemainingText, String(originalPrediction.dropFirst(ending.count)))
            XCTAssertEqual(engine.records.count, requestCountBeforeTyping, "Typing a known ending must preserve its existing prediction.")
        }

        let beforeSpace = rig.interactionState.activeSession?.predictedRemainingText
        _ = rig.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .textMutation, characters: " "))
        text += " "
        publish(text, in: rig)
        rig.coordinator.reconcileActiveSession(with: rig.focusProvider.snapshot)
        if let beforeSpace, beforeSpace.hasPrefix(" "), !beforeSpace.dropFirst().isEmpty {
            XCTAssertEqual(rig.interactionState.activeSession?.predictedRemainingText, String(beforeSpace.dropFirst()))
        }
        run.record("typed-space", text: text, rig: rig, engine: engine)

        for index in 1...2 {
            try await waitFor("No following word available for acceptance \(index)") {
                rig.interactionState.activeSession != nil
            }
            let session = try XCTUnwrap(rig.interactionState.activeSession)
            let offered = session.remainingText
            XCTAssertEqual(rig.overlayController.state.experienceText, offered)
            let chunk = showFollowing ? SuggestionSessionReconciler.nextAcceptanceChunk(from: offered) : offered
            let expectedInsertion = SuggestionSessionReconciler.insertionChunk(forAcceptedChunk: chunk, precedingText: text)
            let previousInsertCount = rig.inserter.insertedChunks.count
            let previousRequestCount = engine.records.count
            let accepted = showFollowing ? rig.coordinator.acceptCurrentSuggestion() : rig.coordinator.acceptEntireSuggestion()
            XCTAssertTrue(accepted)
            let inserted = rig.inserter.insertedChunks.dropFirst(previousInsertCount).joined()
            XCTAssertEqual(inserted, expectedInsertion, "Full acceptance in one-word mode must never insert hidden following words.")
            text += inserted
            publish(text, in: rig)
            rig.coordinator.reconcileActiveSession(with: rig.focusProvider.snapshot)
            if session.predictedRemainingText.count > chunk.count {
                XCTAssertEqual(rig.interactionState.activeSession?.predictedRemainingText, String(session.predictedRemainingText.dropFirst(chunk.count)))
                XCTAssertEqual(engine.records.count, previousRequestCount, "Buffered progression needs no extra model request.")
            }
            run.record("accepted-word-\(index)", text: text, rig: rig, engine: engine, accepted: inserted)
        }
        XCTAssertTrue(rig.inserter.replacements.isEmpty, "Completing a prefix must preserve the user's letters.")
        rig.coordinator.stop()
        stopped = true
        await rig.coordinator.awaitCachedGenerationContextResetIfNeeded()
    }

    private func replayCancellation(engine: ExperienceRecordingEngine, run: inout TypingExperienceRun) async throws {
        await engine.resetCachedGenerationContext()
        let prefix = "I look forward to "
        let rig = makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: prefix),
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(
                selectedWordCountPreset: .twelveToTwenty, isClipboardContextEnabled: false,
                isSurfaceContextEnabled: false, debounceMilliseconds: 1, streamSuggestionsWhileGenerating: true
            ), generationEngine: engine, configuration: LlamaEvalRuntime.configuration
        )
        var stopped = false
        defer { if !stopped { rig.coordinator.stop() } }
        rig.coordinator.schedulePrediction()
        try await waitFor("Real model generation did not start") { engine.inFlightCount > 0 }
        let originalWork = rig.coordinator.currentWorkID
        run.record("generation-started", text: prefix, rig: rig, engine: engine)
        _ = rig.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .textMutation, characters: "z"))
        publish(prefix + "z", in: rig)
        // Escape ends the new edit's own pending request, making any later ghost unambiguously stale.
        _ = rig.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .dismissal))
        XCTAssertGreaterThan(rig.coordinator.currentWorkID, originalWork)
        let shownAfterDismissal = rig.overlayController.shownTexts.count
        try await waitFor("Cancelled model generation did not drain") { engine.inFlightCount == 0 }
        await Task.yield()
        XCTAssertTrue(engine.records.contains { $0.outcome == "cancelled" })
        XCTAssertEqual(rig.overlayController.shownTexts.count, shownAfterDismissal)
        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertTrue(rig.inserter.insertedChunks.isEmpty)
        run.record("divergence-and-dismissal-drained", text: prefix + "z", rig: rig, engine: engine)
        rig.coordinator.stop()
        stopped = true
        await rig.coordinator.awaitCachedGenerationContextResetIfNeeded()
    }

    private func replayCorrection(engine: ExperienceRecordingEngine, run: inout TypingExperienceRun) async throws {
        await engine.resetCachedGenerationContext()
        let source = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "I look forwad ")
        let target = "I look forward "
        let rig = makeCoordinatorRig(snapshot: source,
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(
                selectedWordCountPreset: .twelveToTwenty, isClipboardContextEnabled: false,
                isSurfaceContextEnabled: false, debounceMilliseconds: 1
            ), generationEngine: engine, configuration: LlamaEvalRuntime.configuration)
        var stopped = false
        defer { if !stopped { rig.coordinator.stop() } }

        // Seed the accepted output of spelling assessment so OS dictionary versions cannot change
        // the test's correction choice. Presentation, real-model lookahead, replacement acceptance,
        // host-publication polling, and promotion all use the production coordinator boundaries.
        let context = rig.interactionState.materializeContext(from: source)
        let session = rig.interactionState.startSession(fullText: "forward", liveContext: context,
            latency: 0, kind: .correction(typoWord: "forwad"))
        rig.coordinator.state = .ready(text: "forward", latency: 0)
        rig.coordinator.presentOverlay(text: "forward", at: source.caretRect, context: context, isCorrection: true)
        rig.coordinator.prepareContinuation(after: session, rawContext: source)
        run.record("correction-offered", text: source.precedingText, rig: rig, engine: engine)
        try await waitFor("Real-model correction lookahead did not produce a usable continuation") {
            rig.coordinator.preparedContinuation?.text != nil && engine.inFlightCount == 0
        }
        let prepared = try XCTUnwrap(rig.coordinator.preparedContinuation?.text)
        XCTAssertEqual(engine.records.map(\.prefix), [target])
        XCTAssertFalse(prepared.isEmpty)
        XCTAssertEqual(rig.interactionState.activeSession?.fullText, "forward")
        XCTAssertEqual(rig.overlayController.shownTexts, ["forward"], "Prepared words must remain hidden while a correction is only offered.")
        run.record("lookahead-ready-hidden", text: source.precedingText, rig: rig, engine: engine)

        let refreshCount = rig.focusProvider.refreshCount
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
        XCTAssertEqual(rig.inserter.replacements.map(\.text), ["forward "])
        XCTAssertEqual(rig.inserter.replacements.map(\.deleteCount), ["forwad ".utf16.count])
        try await waitFor("Correction did not poll for the replacement's publication") {
            rig.focusProvider.refreshCount > refreshCount
        }
        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertFalse(rig.overlayController.state.isVisible)
        XCTAssertEqual(engine.records.count, 1)
        run.record("correction-accepted-before-publish", text: source.precedingText, rig: rig, engine: engine,
            accepted: "forward ")

        publish(target, in: rig)
        try await waitFor("Published correction did not promote its prepared continuation") {
            rig.interactionState.activeSession?.kind == .continuation
        }
        let continuation = try XCTUnwrap(rig.interactionState.activeSession)
        XCTAssertEqual(continuation.fullText, prepared)
        XCTAssertEqual(rig.overlayController.state.experienceText, continuation.remainingText)
        XCTAssertEqual(engine.records.count, 1, "Publishing a correction must reuse the actual model's prepared words.")
        run.record("corrected-text-published", text: target, rig: rig, engine: engine)
        let chunk = SuggestionSessionReconciler.nextAcceptanceChunk(from: continuation.remainingText)
        let insertion = SuggestionSessionReconciler.insertionChunk(forAcceptedChunk: chunk, precedingText: target)
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
        XCTAssertEqual(rig.inserter.insertedChunks, [insertion])
        XCTAssertEqual(engine.records.count, 1)
        publish(target + insertion, in: rig)
        rig.coordinator.reconcileActiveSession(with: rig.focusProvider.snapshot)
        run.record("accepted-prepared-word", text: target + insertion, rig: rig, engine: engine, accepted: insertion)
        rig.coordinator.stop()
        stopped = true
        await rig.coordinator.awaitCachedGenerationContextResetIfNeeded()
    }

    private func publish(_ text: String, in rig: CoordinatorRig) {
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: text)
        rig.focusProvider.snapshot = FocusSnapshot(applicationName: snapshot.applicationName,
            bundleIdentifier: snapshot.bundleIdentifier, capability: .supported, context: snapshot)
    }

    private func waitFor(_ failure: String, condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                throw NSError(domain: "TypingExperienceEval", code: 1, userInfo: [NSLocalizedDescriptionKey: failure])
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    #endif
}

#if RUN_LLAMA_EVAL
/// Counts the production engine's actual work without changing model output or delaying results.
/// One instance belongs to one replay; records remain readable after cooperative cancellation.
@MainActor
private final class ExperienceRecordingEngine: SuggestionGenerating {
    nonisolated struct RequestRecord: Encodable {
        let prefix: String
        var outcome = "running"
        var milliseconds: Double = 0
        var result: String?
    }
    private let engine: LlamaSuggestionEngine
    private(set) var records: [RequestRecord] = []
    private(set) var inFlightCount = 0
    nonisolated deinit {}

    init(engine: LlamaSuggestionEngine) { self.engine = engine }

    func generateSuggestion(for request: SuggestionRequest) async throws -> SuggestionResult {
        try await generateSuggestion(for: request, onPartial: nil)
    }

    func generateSuggestion(for request: SuggestionRequest, onPartial: (@MainActor (SuggestionResult) -> Void)?) async throws -> SuggestionResult {
        let index = records.count
        records.append(.init(prefix: request.prefixText))
        inFlightCount += 1
        let start = ProcessInfo.processInfo.systemUptime
        defer {
            inFlightCount -= 1
            records[index].milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1_000
        }
        do {
            let result = try await engine.generateSuggestion(for: request, onPartial: onPartial)
            try Task.checkCancellation()
            records[index].outcome = "completed"
            records[index].result = result.text
            return result
        } catch {
            records[index].outcome = Task.isCancelled ? "cancelled" : "failed: \(error.localizedDescription)"
            throw error
        }
    }

    func resetCachedGenerationContext() async { await engine.resetCachedGenerationContext() }
    func prewarm(for request: SuggestionRequest) async { await engine.prewarm(for: request) }
}

private struct TypingExperienceReport: Encodable {
    let model: String
    let measurementScope = "Production coordinator and local model with synthetic focus/input/insertion; excludes real AX, host key injection, compositor timing, and human judgments of wording."
    let runs: [TypingExperienceRun]
}

private struct TypingExperienceRun: Encodable {
    struct Event: Encodable {
        let action: String
        let milliseconds: Double
        let input: String
        let shown: String?
        let buffered: String?
        let accepted: String?
        let requestCount: Int
    }
    let name: String
    var failure: String?
    var events: [Event] = []
    var requests: [ExperienceRecordingEngine.RequestRecord] = []
    private let started = ProcessInfo.processInfo.systemUptime

    @MainActor mutating func record(_ action: String, text: String, rig: CoordinatorRig, engine: ExperienceRecordingEngine, accepted: String? = nil) {
        events.append(.init(action: action, milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1_000,
            input: text, shown: rig.overlayController.state.experienceText,
            buffered: rig.interactionState.activeSession?.predictedRemainingText, accepted: accepted,
            requestCount: engine.records.count))
    }
}

private extension OverlayState {
    var experienceText: String? {
        guard case let .visible(text, _, _) = self else { return nil }
        return text
    }
}
#endif
