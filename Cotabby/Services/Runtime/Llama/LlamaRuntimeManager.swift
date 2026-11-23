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
    @Published private(set) var availableModels: [RuntimeModelOption] = []

    private let configuration: LlamaRuntimeConfiguration
    private let runtimeLocator: BundledRuntimeLocator
    private let core: LlamaRuntimeCore
    private let loadModel: ModelLoader
    private var loadPhase: LoadPhase = .unloaded
    private var selectedModelFilename: String?

    /// Loads one resolved model off the main actor. Production uses `LlamaRuntimeCore.prepare`;
    /// tests substitute a controllable loader so the load lifecycle can be driven without a GGUF.
    typealias ModelLoader = @Sendable (ResolvedLlamaRuntime, LlamaRuntimeConfiguration) throws -> PreparedLlamaRuntime

    /// Where the manager is in loading the selected model.
    private enum LoadPhase {
        case unloaded
        /// `id` is the load's identity. A load the manager has moved on from (a newer load
        /// replaced it, or the runtime was stopped) still runs to completion natively, because
        /// model loading does not observe cancellation; the identity is what keeps its late
        /// result from being published over the current phase.
        case loading(id: UUID, modelFilename: String, task: Task<PreparedLlamaRuntime, Error>)
        case loaded(PreparedLlamaRuntime)
    }

    /// Read-only view of the model currently selected for autocomplete generation. Used by
    /// downstream observers (the performance metrics recorder) that want to label a recorded
    /// request with the actual GGUF filename, e.g. `gemma-4-E2B.i1-Q6_K.gguf`. Returns nil when no
    /// model has been configured yet.
    var currentModelFilename: String? {
        selectedModelFilename
    }

    /// The GGUF currently held in memory, or nil while nothing is loaded. Eval harnesses label and
    /// fingerprint their reports with it, which must name the file that actually generated.
    var loadedModelFileURL: URL? {
        guard case .loaded(let runtime) = loadPhase else {
            return nil
        }
        return runtime.resolvedRuntime.modelFileURL
    }

    convenience init() {
        self.init(
            configuration: .default,
            runtimeLocator: BundledRuntimeLocator()
        )
    }

    init(
        configuration: LlamaRuntimeConfiguration,
        runtimeLocator: BundledRuntimeLocator,
        loadModel: ModelLoader? = nil
    ) {
        self.configuration = configuration
        self.runtimeLocator = runtimeLocator
        let core = LlamaRuntimeCore()
        self.core = core
        self.loadModel = loadModel ?? { resolvedRuntime, configuration in
            try core.prepare(resolvedRuntime: resolvedRuntime, configuration: configuration)
        }
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
            throw LlamaRuntimeError.unavailable("The selected model \(filename) is unavailable.")
        }

        selectedModelFilename = normalizedFilename

        if case .loaded(let runtime) = loadPhase,
           runtime.resolvedRuntime.modelFileURL.lastPathComponent == normalizedFilename {
            return
        }

        unload()

        _ = try await preparedRuntime()
    }

    /// Forwards one generation request to the runtime core after ensuring preparation.
    /// `onPartialRawText` is invoked from the decode thread; see `LlamaRuntimeGenerating`.
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
            throw error
        } catch {
            CotabbyLogger.runtime.error("Generation failed: \(error.localizedDescription)")
            throw LlamaRuntimeError.generationFailed(error.localizedDescription)
        }
    }

    /// Clears the native prompt KV cache without unloading the model.
    func resetPromptCache() {
        core.resetPromptCache()
    }

    /// Decodes `prompt` into the native prompt cache without sampling (the llama half of
    /// prewarm-on-focus). Best-effort by contract: cancellation is silent and failures only log,
    /// because a missed warmup just means the next generate pays the cold prefill it would have
    /// paid anyway.
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
        unload()
        state = .idle
    }

    /// Forgets the loaded model or abandons the load in flight. Anyone still awaiting an abandoned
    /// load receives `LlamaRuntimeError.cancelled`.
    private func unload() {
        if case .loading(_, _, let task) = loadPhase {
            task.cancel()
        }
        loadPhase = .unloaded
    }

    /// Returns the loaded runtime for the selected model, joining a load already in flight for
    /// it or starting one otherwise.
    private func preparedRuntime() async throws -> PreparedLlamaRuntime {
        let resolvedRuntime = try resolveSelectedRuntime()
        let requestedModelFilename = resolvedRuntime.modelFileURL.lastPathComponent

        switch loadPhase {
        case .loaded(let runtime) where runtime.resolvedRuntime.modelFileURL == resolvedRuntime.modelFileURL:
            CotabbyLogger.runtime.trace("Using cached runtime for \(requestedModelFilename)")
            return runtime
        case .loading(_, let modelFilename, let task) where modelFilename == requestedModelFilename:
            // Concurrent prepare calls for the same model share one load.
            CotabbyLogger.runtime.debug("Reusing in-flight startup for \(requestedModelFilename)")
            return try await task.value
        case .loading:
            CotabbyLogger.runtime.info("Model changed to \(requestedModelFilename), cancelling previous startup")
            unload()
        case .loaded, .unloaded:
            break
        }

        let loadID = UUID()
        let task = Task<PreparedLlamaRuntime, Error> { [weak self, loadModel, configuration] in
            let result: Result<PreparedLlamaRuntime, Error>
            do {
                // Detached so the blocking native load never runs on the main actor.
                result = .success(try await Task.detached {
                    try loadModel(resolvedRuntime, configuration)
                }.value)
            } catch {
                result = .failure(error)
            }
            guard let self else {
                throw LlamaRuntimeError.cancelled
            }
            return try self.finishLoad(loadID, result)
        }
        loadPhase = .loading(id: loadID, modelFilename: requestedModelFilename, task: task)
        CotabbyLogger.runtime.info("Loading \(resolvedRuntime.modelDisplayName) into memory")
        state = .loading("Loading \(resolvedRuntime.modelDisplayName) into memory.")

        return try await task.value
    }

    /// The single place a finished load is applied, so every caller awaiting it sees the same
    /// outcome and the bootstrap state is published once. A load that is no longer the current
    /// one publishes nothing.
    private func finishLoad(
        _ loadID: UUID,
        _ result: Result<PreparedLlamaRuntime, Error>
    ) throws -> PreparedLlamaRuntime {
        guard case .loading(let currentID, _, _) = loadPhase, currentID == loadID else {
            throw LlamaRuntimeError.cancelled
        }

        switch result {
        case .success(let preparedRuntime):
            loadPhase = .loaded(preparedRuntime)
            apply(preparedRuntime)
            return preparedRuntime
        case .failure(let error):
            loadPhase = .unloaded
            if error is CancellationError {
                throw LlamaRuntimeError.cancelled
            }
            let runtimeError = (error as? LlamaRuntimeError) ?? .unavailable(error.localizedDescription)
            state = .failed(runtimeError.localizedDescription)
            throw runtimeError
        }
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
        state = .ready("Loaded \(preparedRuntime.resolvedRuntime.modelDisplayName) in-process.")
    }
}

extension LlamaRuntimeManager: LlamaRuntimeGenerating {}
