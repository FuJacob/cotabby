import Foundation
import XCTest
@testable import Cotabby

/// Locks the engine routing contract: which backend serves a request for each selected engine,
/// when the Apple Intelligence locale failure falls back to the local model, and when a finished
/// result lands in the performance ring buffer. A routing regression silently sends every request
/// to the wrong backend, so each path asserts which engine was actually asked.
@MainActor
final class SuggestionEngineRouterRoutingTests: XCTestCase {
    /// Production classes built with the app target's default MainActor isolation crash the
    /// app-hosted runner when deallocated (back-deploy executor shim); quarantine them for the
    /// process lifetime instead.
    private static var retained: [AnyObject] = []

    private struct Rig {
        let router: SuggestionEngineRouter
        let settings: SuggestionSettingsModel
        let foundation: ScriptedEngine
        let llama: ScriptedEngine
        let metrics: PerformanceMetricsStore
    }

    @MainActor
    private final class ScriptedEngine: SuggestionGenerating {
        var script: (SuggestionRequest) async throws -> SuggestionResult
        private(set) var requests: [SuggestionRequest] = []
        private(set) var prewarmCount = 0
        private(set) var resetCount = 0

        init(latency: TimeInterval = 0.02) {
            script = { request in
                SuggestionResult(generation: request.generation, rawText: " ok", text: " ok", latency: latency)
            }
        }

        func generateSuggestion(for request: SuggestionRequest) async throws -> SuggestionResult {
            requests.append(request)
            return try await script(request)
        }

        func resetCachedGenerationContext() async {
            resetCount += 1
        }

        func prewarm(for request: SuggestionRequest) async {
            prewarmCount += 1
        }
    }

    private func makeRig(
        engine: SuggestionEngineKind,
        performanceTracking: Bool = true,
        llamaModelName: String? = "test-model.gguf"
    ) -> Rig {
        let suiteName = "cotabby.test.router.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)
        settings.selectEngine(engine)
        settings.setPerformanceTrackingEnabled(performanceTracking)
        let metrics = PerformanceMetricsStore(userDefaults: defaults)
        let foundation = ScriptedEngine()
        let llama = ScriptedEngine()
        let router = SuggestionEngineRouter(
            suggestionSettings: settings,
            foundationModelEngine: foundation,
            llamaEngine: llama,
            performanceMetricsStore: metrics,
            llamaModelNameProvider: { llamaModelName }
        )
        Self.retained.append(contentsOf: [router, settings, metrics] as [AnyObject])
        return Rig(router: router, settings: settings, foundation: foundation, llama: llama, metrics: metrics)
    }

    func test_appleIntelligenceSelection_routesToFoundationEngineAndRecordsMetric() async throws {
        let rig = makeRig(engine: .appleIntelligence)

        let result = try await rig.router.generateSuggestion(for: CotabbyTestFixtures.suggestionRequest())

        XCTAssertEqual(result.text, " ok")
        XCTAssertEqual(rig.foundation.requests.count, 1)
        XCTAssertTrue(rig.llama.requests.isEmpty)
        XCTAssertEqual(rig.metrics.entries.first?.modelName, "Apple Intelligence")
        XCTAssertEqual(rig.metrics.entries.first?.latencyMs, 20)
    }

    func test_llamaSelection_routesToLlamaEngineAndRecordsTheModelName() async throws {
        let rig = makeRig(engine: .llamaOpenSource)

        _ = try await rig.router.generateSuggestion(for: CotabbyTestFixtures.suggestionRequest())

        XCTAssertEqual(rig.llama.requests.count, 1)
        XCTAssertTrue(rig.foundation.requests.isEmpty)
        XCTAssertEqual(rig.metrics.entries.first?.modelName, "test-model.gguf")
    }

    func test_llamaSelection_missingModelNameFallsBackToGenericLabel() async throws {
        let rig = makeRig(engine: .llamaOpenSource, llamaModelName: nil)

        _ = try await rig.router.generateSuggestion(for: CotabbyTestFixtures.suggestionRequest())

        XCTAssertEqual(rig.metrics.entries.first?.modelName, "Llama")
    }

    func test_performanceTrackingOff_recordsNothing() async throws {
        let rig = makeRig(engine: .llamaOpenSource, performanceTracking: false)

        _ = try await rig.router.generateSuggestion(for: CotabbyTestFixtures.suggestionRequest())

        XCTAssertTrue(rig.metrics.entries.isEmpty, "The default user must never pay the metrics write cost")
    }

    func test_unsupportedLocale_fallsBackToLlamaAndReturnsItsResult() async throws {
        let rig = makeRig(engine: .appleIntelligence)
        rig.foundation.script = { _ in
            throw SuggestionClientError.unsupportedLanguageOrLocale("Locale not supported.")
        }

        let result = try await rig.router.generateSuggestion(for: CotabbyTestFixtures.suggestionRequest())

        XCTAssertEqual(result.text, " ok")
        XCTAssertEqual(rig.llama.requests.count, 1, "The locale failure must reach the local model")
        XCTAssertEqual(rig.metrics.entries.first?.modelName, "test-model.gguf")
    }

    func test_unsupportedLocale_fallbackFailureComposesBothMessages() async {
        struct LlamaDown: Error {}
        let rig = makeRig(engine: .appleIntelligence)
        rig.foundation.script = { _ in
            throw SuggestionClientError.unsupportedLanguageOrLocale("Locale not supported.")
        }
        rig.llama.script = { _ in throw LlamaDown() }

        do {
            _ = try await rig.router.generateSuggestion(for: CotabbyTestFixtures.suggestionRequest())
            XCTFail("Expected the composed unavailable error")
        } catch let SuggestionClientError.unavailable(message) {
            XCTAssertTrue(message.contains("Locale not supported."))
            XCTAssertTrue(message.contains("fallback also failed"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_unsupportedLocale_fallbackCancellationStaysCancellation() async {
        let rig = makeRig(engine: .appleIntelligence)
        rig.foundation.script = { _ in
            throw SuggestionClientError.unsupportedLanguageOrLocale("Locale not supported.")
        }
        rig.llama.script = { _ in throw SuggestionClientError.cancelled }

        do {
            _ = try await rig.router.generateSuggestion(for: CotabbyTestFixtures.suggestionRequest())
            XCTFail("Expected cancellation to propagate")
        } catch SuggestionClientError.cancelled {
            // Cancellation must never be rewrapped as unavailability: the coordinator treats it
            // as silence, not as an error state.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_prewarm_reachesOnlyTheSelectedEngine() async {
        let appleRig = makeRig(engine: .appleIntelligence)
        await appleRig.router.prewarm(for: CotabbyTestFixtures.suggestionRequest())
        XCTAssertEqual(appleRig.foundation.prewarmCount, 1)
        XCTAssertEqual(appleRig.llama.prewarmCount, 0)

        let llamaRig = makeRig(engine: .llamaOpenSource)
        await llamaRig.router.prewarm(for: CotabbyTestFixtures.suggestionRequest())
        XCTAssertEqual(llamaRig.foundation.prewarmCount, 0)
        XCTAssertEqual(llamaRig.llama.prewarmCount, 1)
    }

    func test_resetCachedGenerationContext_fansOutToBothEngines() async {
        let rig = makeRig(engine: .appleIntelligence)

        await rig.router.resetCachedGenerationContext()

        XCTAssertEqual(rig.foundation.resetCount, 1)
        XCTAssertEqual(rig.llama.resetCount, 1, "Switching engines must not leave stale state behind")
    }

    func test_unavailableEngine_throwsItsConfiguredMessage() async {
        let engine = UnavailableSuggestionEngine(message: "Needs macOS 26.")
        Self.retained.append(engine)

        do {
            _ = try await engine.generateSuggestion(for: CotabbyTestFixtures.suggestionRequest())
            XCTFail("Expected unavailable error")
        } catch let SuggestionClientError.unavailable(message) {
            XCTAssertEqual(message, "Needs macOS 26.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        await engine.resetCachedGenerationContext()
    }
}
