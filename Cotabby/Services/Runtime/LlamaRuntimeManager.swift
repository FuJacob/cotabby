import Combine
import Foundation
import Logging

/// File overview:
/// Publishes runtime bootstrap state and user-facing diagnostics for the menu bar and startup UI.
/// The manager does not talk to native llama.cpp APIs directly anymore; it delegates that work to
/// `LlamaRuntimeCore`, which keeps pointer ownership and generation serialization in a separate file.
///
/// `@MainActor` keeps the published state SwiftUI-friendly while the heavy inference work runs
/// inside `LlamaRuntimeCore`, a thread-safe class backed by the C++ `CotabbyInferenceEngine`.
@MainActor
final class LlamaRuntimeManager: ObservableObject {
    @Published private(set) var state: RuntimeBootstrapState = .idle
    @Published private(set) var diagnostics = LlamaRuntimeDiagnostics()
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
    /// request with the actual GGUF filename, e.g. `Qwen3-0.6B-Q8_0.gguf`. Returns nil when no
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
        selectedModelFilename = normalizedModelFilename(selectedModelFilename)
        CotabbyLogger.runtime.info("Discovered \(self.availableModels.count) model(s)")
    }

    /// Records which discovered model should be loaded when preparation starts.
    /// This keeps persisted UI state separate from the runtime loading lifecycle.
    func configureSelectedModel(filename: String?) {
        selectedModelFilename = normalizedModelFilename(filename)
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
        guard let normalizedFilename = normalizedModelFilename(filename) else {
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
    /// `cachedPrefixBytes` is a caller-provided reuse hint, not a correctness guarantee; the core
    /// still validates the token prefix before trusting any native KV state.
    func generate(
        prompt: String,
        cachedPrefixBytes: Int? = nil,
        options: LlamaGenerationOptions
    ) async throws -> String {
        _ = try await preparedRuntime()

        let core = self.core
        do {
            // `Task.detached` does not inherit the caller's cancellation, so an outer cancel
            // would otherwise leave `core.generate` running to its full prediction budget while
            // holding `autocompleteLock`. The handler forwards the cancel signal, and the loop
            // inside `core.generate` polls `Task.isCancelled` between sampleNext calls.
            let task = Task.detached {
                try core.generate(
                    prompt: prompt,
                    cachedPrefixBytes: cachedPrefixBytes,
                    options: options
                )
            }
            return try await withTaskCancellationHandler {
                // `core.generate` cooperates with cancellation by returning the partial buffer it
                // accumulated instead of throwing, which is the right behavior for the inference
                // layer (the KV-cache trim and lock release still need to run on the way out).
                // The manager surfaces the cancellation as a thrown `CancellationError` so the
                // `catch` below stays reachable and so callers see the same vocabulary as a
                // throwing path. The outer task is the one that was cancelled (that is why
                // `onCancel` ran), so `Task.checkCancellation()` throws here.
                let partial = try await task.value
                try Task.checkCancellation()
                return partial
            } onCancel: {
                task.cancel()
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

    /// Cancels any retained prepared runtime and releases backend resources.
    /// Shutdown runs on a detached thread so it does not block the main actor.
    func stop() {
        CotabbyLogger.runtime.info("Runtime stop requested")
        prepareForStop()
        Task.detached { [core] in
            core.shutdown()
        }
    }

    /// Cancels runtime work and waits until native llama resources are released.
    /// Destructive flows such as uninstall need this stronger guarantee before deleting model files
    /// that may have been memory-mapped by the runtime.
    func stopAndWait() async {
        prepareForStop()
        await Task.detached { [core] in
            core.shutdown()
        }.value
    }

    /// Synchronously releases the llama runtime on the current thread, bounded by `timeoutSeconds`.
    /// This is the termination-time path: C++ static destructors during `exit()` tear down the Metal
    /// device, so llama contexts must be released first to avoid `ggml_metal_rsets_free`. Returning
    /// quickly also keeps macOS's "Quit & Reopen" TCC handshake working after a permission grant —
    /// the previous `.terminateLater` approach delayed exit long enough that the relaunched process
    /// never picked up the new permission.
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

        state = .starting("Initializing the in-process llama runtime.")
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

    /// Validates the chosen filename against discovered local models and falls back to the first
    /// available option when the caller passes `nil` or a missing filename.
    private func normalizedModelFilename(_ filename: String?) -> String? {
        guard !availableModels.isEmpty else {
            return nil
        }

        guard let filename else {
            return availableModels.first?.filename
        }

        if availableModels.contains(where: { $0.filename == filename }) {
            return filename
        }

        return availableModels.first?.filename
    }

    /// Awaits the prepared runtime task and applies the published diagnostics on success.
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

    /// Copies prepared runtime metadata into published diagnostics for the menu and startup UI.
    private func apply(_ preparedRuntime: PreparedLlamaRuntime) {
        let model = preparedRuntime.resolvedRuntime.modelDisplayName
        let ctx = preparedRuntime.contextWindowTokens
        CotabbyLogger.runtime.info(
            "Runtime ready: model=\(model) ctx=\(ctx) threads=\(preparedRuntime.threadCount) gpu=\(preparedRuntime.gpuLayerCount)"
        )
        diagnostics.runtimeDirectoryPath = preparedRuntime.resolvedRuntime.runtimeDirectoryURL.path
        diagnostics.modelFilePath = preparedRuntime.resolvedRuntime.modelFileURL.path
        diagnostics.backendName = preparedRuntime.backendName
        diagnostics.contextWindowTokens = preparedRuntime.contextWindowTokens
        diagnostics.batchSize = preparedRuntime.batchSize
        diagnostics.threadCount = preparedRuntime.threadCount
        diagnostics.gpuLayerCount = preparedRuntime.gpuLayerCount
        diagnostics.lastLoadStatus = "Loaded"
        diagnostics.lastError = nil

        state = .ready("Loaded \(preparedRuntime.resolvedRuntime.modelDisplayName) in-process.")
    }
}

extension LlamaRuntimeManager: LlamaRuntimeGenerating {}
