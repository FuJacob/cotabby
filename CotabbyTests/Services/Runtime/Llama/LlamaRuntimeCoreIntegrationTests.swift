import Foundation
import XCTest
@testable import Cotabby

/// Opt-in real-model checks for the Swift/native boundary. Pure byte-buffer tests cover individual
/// Unicode fragments; these tests verify that a loaded runtime streams and restores full requests.
final class LlamaRuntimeCoreIntegrationTests: XCTestCase {
    func testRestoredRequestMatchesFreshRequest() throws {
        let core = try makeCore()
        defer { core.shutdown() }
        let prompt = "Hi Alex, thanks for sending the project update. I will review the schedule and send you my"
        let cold = try core.generate(prompt: prompt, options: options)
        let warm = try core.generate(prompt: prompt, cachedPrefixBytes: prompt.utf8.count, options: options)
        XCTAssertFalse(cold.text.isEmpty)
        XCTAssertEqual(warm.text, cold.text, "Discarded suggestions must not change sampler or prompt state")
        XCTAssertEqual(warm.averageLogprob, cold.averageLogprob)
        XCTAssertEqual(warm.suppressedByLowConfidence, cold.suppressedByLowConfidence)
    }

    /// Cache reuse must reset the distribution sampler as well as native KV. A fixed seed belongs
    /// to each request, so repeatedly discarding a sampled suggestion cannot advance the next
    /// request's random stream or leave generated words in its repetition history.
    func testSampledRestoredRequestResetsRandomStreamAndRepetitionHistory() throws {
        let core = try makeCore()
        defer { core.shutdown() }
        let prompt = "Hi Alex, thanks for sending the project update. I will review the schedule and send you my"

        for configuration in sampledConfigurations {
            core.resetPromptCache()
            let cold = try core.generate(prompt: prompt, options: configuration.options)
            XCTAssertFalse(cold.text.isEmpty, configuration.label)
            for repetition in 1...2 {
                let reused = try core.generate(
                    prompt: prompt, cachedPrefixBytes: prompt.utf8.count, options: configuration.options
                )
                XCTAssertEqual(
                    reused.text, cold.text,
                    "\(configuration.label), discarded tail \(repetition): sampler state must restart from the writer's prompt"
                )
            }
        }
    }

    /// Changing the writer's prompt exercises restoration beyond an identical-request shortcut.
    /// The same edited prompt must produce the same sampled continuation with retained native
    /// state or a freshly reset cache; neither the discarded tail nor its RNG draws are context.
    func testSampledEditedPromptMatchesFreshStateAfterDiscardedGeneration() throws {
        let core = try makeCore()
        defer { core.shutdown() }
        let original = "Hi Alex, thanks for sending the project update. I will review the schedule and send you my"
        let editedPrompts = [original + " feedback", String(original.dropLast(2)) + "our feedback"]

        for configuration in sampledConfigurations {
            for edited in editedPrompts {
                core.resetPromptCache()
                _ = try core.generate(prompt: original, options: configuration.options)
                let hint = zip(original.utf8, edited.utf8).prefix { $0.0 == $0.1 }.count
                let reused = try core.generate(
                    prompt: edited, cachedPrefixBytes: hint, options: configuration.options
                )
                core.resetPromptCache()
                let fresh = try core.generate(prompt: edited, options: configuration.options)
                XCTAssertFalse(fresh.text.isEmpty, configuration.label)
                XCTAssertEqual(
                    reused.text, fresh.text,
                    "\(configuration.label): retained generation changed the sampled result for \(edited)"
                )
            }
        }
    }

    func testHealingStreamsOnlyValidCumulativeContinuation() throws {
        let core = try makeCore()
        defer { core.shutdown() }
        // Include both a partial word and a completed word. Healing permits a whitespace-leading
        // next token after a complete word; it does not force another letter onto every word.
        for prompt in ["Please send me the sched", "Please send me the schedule", "The café serves "] {
            var partials: [String] = []
            let result = try core.generate(prompt: prompt, options: options) { partials.append($0) }
            XCTAssertFalse(result.text.isEmpty)
            XCTAssertFalse(result.text.contains("\u{FFFD}"))
            XCTAssertEqual(partials.last, result.text)
            for pair in zip(partials, partials.dropFirst()) {
                XCTAssertTrue(pair.1.hasPrefix(pair.0), "Streaming text must grow monotonically")
            }
        }
    }

    /// Each transition starts with a generated tail still in native KV. Appending, retokenizing,
    /// and shortening must restore only the shared prompt or fall back to a fresh sequence; the
    /// previous prediction must never become context merely because it remains allocated.
    func testRetainedGenerationTailDoesNotChangeEditedPromptResults() throws {
        let core = try makeCore()
        defer { core.shutdown() }
        let original = "Hi Alex, thanks for sending the project update. I will review the schedule and send you my"
        let editedPrompts = [
            original + " feedback",
            String(original.dropLast(2)) + "our feedback",
            String(original.dropLast(18)),
            "A different document starts with the following summary of the project"
        ]

        for edited in editedPrompts {
            _ = try core.generate(prompt: original, options: options)
            let hint = zip(original.utf8, edited.utf8).prefix { $0.0 == $0.1 }.count
            let reused = try core.generate(prompt: edited, cachedPrefixBytes: hint, options: options)
            core.resetPromptCache()
            let fresh = try core.generate(prompt: edited, options: options)
            XCTAssertEqual(reused.text, fresh.text, "Retained tail changed the completion for: \(edited)")
            XCTAssertEqual(reused.averageLogprob, fresh.averageLogprob)
        }
    }

    func testCancelledRetainedTailCanBeRestoredByNextRequest() throws {
        let core = try makeCore()
        defer { core.shutdown() }
        let prompt = "Hi Alex, thanks for sending the project update. I will review the schedule and send you my"
        let operationID = UUID()
        var didCancel = false
        _ = try core.generate(prompt: prompt, options: options, operationID: operationID) { _ in
            // This deterministic native cancellation happens after visible generation began,
            // exercising restoration of a retained tail and a still-set cancellation flag.
            if !didCancel {
                didCancel = true
                core.abortInFlightGeneration(operationID: operationID)
            }
        }
        XCTAssertTrue(didCancel)
        let reused = try core.generate(prompt: prompt, cachedPrefixBytes: prompt.utf8.count, options: options)
        core.resetPromptCache()
        let fresh = try core.generate(prompt: prompt, options: options)
        XCTAssertEqual(reused.text, fresh.text)
    }

    private var options: LlamaGenerationOptions {
        LlamaGenerationOptions(
            maxPredictionTokens: 12,
            temperature: 0,
            topK: 20,
            topP: 0.7,
            minP: 0.08,
            repetitionPenalty: 1.05,
            seed: 42,
            stopAtArgmaxEOG: false
        )
    }

    /// The first two entries cover the production sampler and this round's no-penalty candidate.
    /// Their low temperature can collapse to one allowed token, so the final diagnostic entry
    /// deliberately leaves more choices available and makes a missing RNG reset observable.
    /// These are per-test values; they never change app preferences or the benchmark defaults.
    private var sampledConfigurations: [(label: String, options: LlamaGenerationOptions)] {
        [
            ("sampled baseline", 0.1, 20, 0.7, 0.08, 1.05),
            ("sampled without repetition penalty", 0.1, 20, 0.7, 0.08, 1.0),
            ("RNG diagnostic", 0.8, 0, 1.0, 0.0, 1.0)
        ].map { label, temperature, topK, topP, minP, repetitionPenalty in
            (label, LlamaGenerationOptions(
                maxPredictionTokens: 12,
                temperature: temperature,
                topK: topK,
                topP: topP,
                minP: minP,
                repetitionPenalty: repetitionPenalty,
                seed: 42,
                stopAtArgmaxEOG: false
            ))
        }
    }

    private func makeCore() throws -> LlamaRuntimeCore {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["COTABBY_TEST_MODEL_PATH"] ?? environment["COTABBY_EVAL_MODEL_PATH"],
              path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Set COTABBY_TEST_MODEL_PATH to an absolute GGUF path for native integration tests")
        }
        let modelURL = URL(fileURLWithPath: path)
        let core = LlamaRuntimeCore()
        _ = try core.prepare(
            resolvedRuntime: ResolvedLlamaRuntime(
                runtimeDirectoryURL: modelURL.deletingLastPathComponent(),
                modelFileURL: modelURL,
                modelDisplayName: modelURL.lastPathComponent
            ),
            configuration: LlamaRuntimeConfiguration(
                runtimeDirectoryPath: nil,
                preferredModelNames: [],
                contextWindowTokens: 1024,
                batchSize: 256,
                gpuLayerCount: -1
            )
        )
        return core
    }
}
