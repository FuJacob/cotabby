import Combine
import Foundation
import Logging

/// File overview:
/// Publishes runtime bootstrap state and the discovered model list for the menu bar and settings.
/// The manager never touches native llama.cpp APIs; `LlamaRuntimeCore` owns the pointers and
/// serializes generation, so this type can stay a plain main-actor observable.
///
/// `@MainActor` keeps the published state SwiftUI-friendly while the heavy inference work runs
/// inside `LlamaRuntimeCore`, a thread-safe class backed by the C++ `CotabbyInferenceEngine`.
@MainActor
final class LlamaRuntimeManager: ObservableObject {
    @Published private(set) var state: RuntimeBootstrapState = .idle
    /// Deliberately not `@Published`: no view renders it, and every generation error writes it,
    /// which would otherwise invalidate each view observing the runtime for nothing.
    private(set) var diagnostics = LlamaRuntimeDiagnostics()
    @Published private(set) var availableModels: [RuntimeModelOption] = []

    private let configuration: LlamaRuntimeConfiguration
    private let runtimeLocator: BundledRuntimeLocator
    private let core: LlamaRuntimeCore
    private var startupTask: Task<PreparedLlamaRuntime, Error>?
    private var startupModelFilename: String?
    private var cachedRuntime: PreparedLlamaRuntime?
    private var selectedModelFilename: String?

    /// Read-only view of the model currently selected for autocomplete generation. Used by
    /// downstream observers (the performance metrics recorder) that want to label a recorded
    /// request with the actual GGUF filename, e.g. `gemma-4-E2B.i1-Q6_K.gguf`. Returns nil when no
    /// model has been configured yet.
    var currentModelFilename: String? {
        selectedModelFilename
    }

    convenience init() {
        self.init(
            configuration: .default,
            runtimeLocator: BundledRuntimeLocator()
        )
    }

    init(
        configuration: LlamaRuntimeConfiguration,
        runtimeLocator: BundledRuntimeLocator
    ) {
        self.configuration = configuration
        self.runtimeLocator = runtimeLocator
        core = LlamaRuntimeCore()
        refreshAvailableModels()
    }

    /// Re-scans local runtime directories for GGUF files and republishes discovered options.
    /// This is called after model downloads so selection UI updates without app restart.
    func refreshAvailableModels() {
        availableModels = runtimeLocator.availableModels(configuration: configuration)
        selectedModelFilename = RuntimeModelSelection.resolve(
            candidates: [selectedModelFilename],
            available: availableModels
        )
        CotabbyLogger.runtime.info("Discovered \(self.availableModels.count) model(s)")
    }

    /// Records which discovered model should be loaded when preparation starts.
    /// This keeps persisted UI state separate from the runtime loading lifecycle.
    func configureSelectedModel(filename: String?) {
        selectedModelFilename = RuntimeModelSelection.resolve(candidates: [filename], available: availableModels)
        CotabbyLogger.runtime.info("Configured selected model: \(self.selectedModelFilename ?? "none")")
    }

    /// Ensures the selected local model is resolved and prepared before any generation requests run.
    func prepare() async throws {
        _ = try await preparedRuntime()
    }

    /// Reloads the runtime in place with a newly selected local model.
    /// The manager instance stays alive; only the loaded model changes.
    func selectModel(filename: String) async throws {
        CotabbyLogger.runtime.info("Selecting model: \(filename)")
        guard let normalizedFilename = RuntimeModelSelection.resolve(candidates: [filename], available: availableModels) else {
            let error = LlamaRuntimeError.unavailable(
                "The selected model \(filename) is unavailable.")
            diagnostics.lastError = error.localizedDescription
            throw error
        }

        selectedModelFilename = normalizedFilename

        if cachedRuntime?.resolvedRuntime.modelFileURL.lastPathComponent == normalizedFilename {
            return
        }

        startupTask?.cancel()
        startupTask = nil
        startupModelFilename = nil
        cachedRuntime = nil

        _ = try await preparedRuntime()
    }

    /// Forwards one generation request to the runtime core after ensuring preparation.
    func generate(
        prompt: String,
        options: LlamaGenerationOptions
    ) async throws -> LlamaGenerationOutput {
        try await generate(prompt: prompt, options: options, onPartialRawText: nil)
    }

    /// Streaming variant: `onPartialRawText` is invoked from the decode thread with the cumulative
    /// raw completion after each sampled token; see `LlamaRuntimeGenerating`.
    func generate(
        prompt: String,
        options: LlamaGenerationOptions,
        onPartialRawText: (@Sendable (String) -> Void)?
    ) async throws -> LlamaGenerationOutput {
        _ = try await preparedRuntime()

        let core = self.core
        let operationID = UUID()
        do {
            // `Task.detached` does not inherit the caller's cancellation, so an outer cancel
            // would otherwise leave `core.generate` running to its full prediction budget while
            // holding `autocompleteLock`. The handler forwards the cancel signal, and the loop
            // inside `core.generate` polls `Task.isCancelled` between sampleNext calls.
            let task = Task.detached {
                try core.generate(
                    prompt: prompt,
                    options: options,
                    operationID: operationID,
                    onPartialRawText: onPartialRawText
                )
            }
            return try await withTaskCancellationHandler {
                // `core.generate` cooperates with cancellation by returning the partial buffer it
                // accumulated instead of throwing, which is the right behavior for the inference
                // layer (the abort target must clear and the lock must release on the way out;
                // cache restoration waits until the next request's prefix is known).
                // The manager surfaces the cancellation as a thrown `CancellationError` so the
                // `catch` below stays reachable and so callers see the same vocabulary as a
                // throwing path. The outer task is the one that was cancelled (that is why
                // `onCancel` ran), so `Task.checkCancellation()` throws here.
                let partial = try await task.value
                try Task.checkCancellation()
                return partial
            } onCancel: {
                task.cancel()
                // Task cancellation is only polled between sampled tokens, so an in-flight prompt
                // prefill would otherwise run to completion while holding the autocomplete lock,
                // making the superseding request wait out the whole stale decode. The engine-level
                // flag stops before the next prompt batch; an already-submitted batch finishes.
                core.abortInFlightGeneration(operationID: operationID)
            }
        } catch is CancellationError {
            CotabbyLogger.runtime.debug("Generation cancelled")
            throw LlamaRuntimeError.cancelled
        } catch let error as LlamaRuntimeError {
            CotabbyLogger.runtime.error("Generation runtime error: \(error.localizedDescription)")
            diagnostics.lastError = error.localizedDescription
            throw error
        } catch {
            CotabbyLogger.runtime.error("Generation failed: \(error.localizedDescription)")
            let runtimeError = LlamaRuntimeError.generationFailed(error.localizedDescription)
            diagnostics.lastError = runtimeError.localizedDescription
            throw runtimeError
        }
    }

    /// Clears the native prompt KV cache without unloading the model.
    func resetPromptCache() {
        core.resetPromptCache()
    }

    /// Decodes `prompt` into the native prompt cache without sampling (the llama half of
    /// prewarm-on-focus). Best-effort by contract: cancellation is silent and failures only log,
    /// because a missed warmup just means the next generate pays the cold prefill it would have
    /// paid anyway. Errors are deliberately kept out of `diagnostics.lastError`.
    func prefill(prompt: String, options: LlamaGenerationOptions) async throws {
        _ = try await preparedRuntime()

        let core = self.core
        let operationID = UUID()
        let task = Task.detached {
            try core.prefill(prompt: prompt, options: options, operationID: operationID)
        }
        try await withTaskCancellationHandler {
            try await task.value
            try Task.checkCancellation()
        } onCancel: {
            task.cancel()
            // A prefill is superseded the moment a real generation arrives; abort its native
            // work between batches so generation need not wait for the entire stale prompt.
            core.abortInFlightGeneration(operationID: operationID)
        }
    }

    /// Cancels any retained prepared runtime and releases backend resources.
    /// Shutdown runs on a detached thread so it does not block the main actor.
    func stop() {
        CotabbyLogger.runtime.info("Runtime stop requested")
        prepareForStop()
        Task.detached { [core] in
            core.shutdown()
        }
    }

    /// Synchronously releases the llama runtime on the current thread, bounded by `timeoutSeconds`.
    /// This is the termination-time path: C++ static destructors during `exit()` tear down the Metal
    /// device, so llama contexts must be released first to avoid `ggml_metal_rsets_free`. Returning
    /// quickly also keeps macOS's "Quit & Reopen" TCC handshake working after a permission grant:
    /// replying `.terminateLater` delays exit long enough that the relaunched process never picks
    /// up the new permission.
    func shutdownSync(timeoutSeconds: TimeInterval) {
        prepareForStop()
        core.shutdown(timeoutSeconds: timeoutSeconds)
    }

    private func prepareForStop() {
        startupTask?.cancel()
        startupTask = nil
        startupModelFilename = nil
        cachedRuntime = nil

        diagnostics.lastLoadStatus = "Stopped"
        state = .idle
    }

    /// Returns cached runtime metadata when available or performs one full preparation flow otherwise.
    private func preparedRuntime() async throws -> PreparedLlamaRuntime {
        let resolvedRuntime = try resolveSelectedRuntime()
        let requestedModelFilename = resolvedRuntime.modelFileURL.lastPathComponent

        if let cachedRuntime,
            cachedRuntime.resolvedRuntime.modelFileURL == resolvedRuntime.modelFileURL {
            CotabbyLogger.runtime.trace("Using cached runtime for \(requestedModelFilename)")
            return cachedRuntime
        }

        // Deduplicate concurrent prepare calls for the same selected model, but cancel and
        // replace the task if the requested model changed while startup was already in flight.
        if let startupTask {
            if startupModelFilename == requestedModelFilename {
                CotabbyLogger.runtime.debug("Reusing in-flight startup for \(requestedModelFilename)")
                return try await awaitPreparedRuntime(startupTask)
            }

            CotabbyLogger.runtime.info("Model changed to \(requestedModelFilename), cancelling previous startup")
            startupTask.cancel()
            self.startupTask = nil
            startupModelFilename = nil
        }

        cachedRuntime = nil

        diagnostics.lastError = nil
        diagnostics.lastLoadStatus = "Starting"
        diagnostics.modelFilePath = resolvedRuntime.modelFileURL.path
        let startupTask = Task.detached { [core, configuration] in
            try core.prepare(
                resolvedRuntime: resolvedRuntime,
                configuration: configuration
            )
        }
        self.startupTask = startupTask
        startupModelFilename = requestedModelFilename
        CotabbyLogger.runtime.info("Loading \(resolvedRuntime.modelDisplayName) into memory")
        state = .loading("Loading \(resolvedRuntime.modelDisplayName) into memory.")

        return try await awaitPreparedRuntime(startupTask)
    }

    /// Resolves either the explicitly selected model or the default preferred model order.
    private func resolveSelectedRuntime() throws -> ResolvedLlamaRuntime {
        do {
            return try runtimeLocator.resolve(
                configuration: configuration,
                selectedModelFilename: selectedModelFilename
            )
        } catch {
            let runtimeError = LlamaRuntimeError.unavailable(error.localizedDescription)
            diagnostics.lastError = runtimeError.localizedDescription
            diagnostics.lastLoadStatus = "Failed"
            state = .failed(runtimeError.localizedDescription)
            throw runtimeError
        }
    }

    /// Awaits the prepared runtime task and publishes the resulting bootstrap state.
    private func awaitPreparedRuntime(
        _ startupTask: Task<PreparedLlamaRuntime, Error>
    ) async throws -> PreparedLlamaRuntime {
        do {
            // `Task.value` rethrows if startup failed; the manager converts those failures into
            // user-facing bootstrap state below.
            let preparedRuntime = try await startupTask.value
            cachedRuntime = preparedRuntime
            apply(preparedRuntime)
            self.startupTask = nil
            startupModelFilename = nil
            return preparedRuntime
        } catch is CancellationError {
            self.startupTask = nil
            startupModelFilename = nil
            throw LlamaRuntimeError.cancelled
        } catch let error as LlamaRuntimeError {
            self.startupTask = nil
            startupModelFilename = nil
            diagnostics.lastError = error.localizedDescription
            diagnostics.lastLoadStatus = "Failed"
            state = .failed(error.localizedDescription)
            throw error
        } catch {
            self.startupTask = nil
            startupModelFilename = nil
            let runtimeError = LlamaRuntimeError.unavailable(error.localizedDescription)
            diagnostics.lastError = runtimeError.localizedDescription
            diagnostics.lastLoadStatus = "Failed"
            state = .failed(runtimeError.localizedDescription)
            throw runtimeError
        }
    }

    /// Publishes the ready state for a freshly loaded model.
    private func apply(_ preparedRuntime: PreparedLlamaRuntime) {
        let model = preparedRuntime.resolvedRuntime.modelDisplayName
        let ctx = preparedRuntime.contextWindowTokens
        CotabbyLogger.runtime.info(
            "Runtime ready: model=\(model) ctx=\(ctx) threads=\(preparedRuntime.threadCount) gpu=\(preparedRuntime.gpuLayerCount)"
        )
        diagnostics.modelFilePath = preparedRuntime.resolvedRuntime.modelFileURL.path
        diagnostics.lastLoadStatus = "Loaded"
        diagnostics.lastError = nil

        state = .ready("Loaded \(preparedRuntime.resolvedRuntime.modelDisplayName) in-process.")
    }
}

extension LlamaRuntimeManager: LlamaRuntimeGenerating {}
