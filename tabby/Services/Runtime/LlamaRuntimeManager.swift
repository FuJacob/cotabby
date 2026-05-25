import Combine
import Foundation
import Logging

/// File overview:
/// Publishes runtime bootstrap state and user-facing diagnostics for the menu bar and startup UI.
/// The manager does not talk to native llama.cpp APIs directly anymore; it delegates that work to
/// `LlamaRuntimeCore`, which keeps pointer ownership and generation serialization in a separate file.
///
/// `@MainActor` keeps the published state SwiftUI-friendly while the heavy inference work still runs
/// inside the separate core actor.
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
        TabbyLogger.runtime.info("Discovered \(self.availableModels.count) model(s)")
    }

    /// Records which discovered model should be loaded when preparation starts.
    /// This keeps persisted UI state separate from the runtime loading lifecycle.
    func configureSelectedModel(filename: String?) {
        selectedModelFilename = normalizedModelFilename(filename)
        TabbyLogger.runtime.info("Configured selected model: \(self.selectedModelFilename ?? "none")")
    }

    /// Ensures the selected local model is resolved and prepared before any generation requests run.
    func prepare() async throws {
        _ = try await preparedRuntime()
    }

    /// Reloads the runtime in place with a newly selected local model.
    /// The manager instance stays alive; only the loaded model changes.
    func selectModel(filename: String) async throws {
        TabbyLogger.runtime.info("Selecting model: \(filename)")
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

    /// Forwards one generation request into the serialized runtime actor after ensuring preparation.
    /// `cachedPrefixBytes` is a caller-provided reuse hint, not a correctness guarantee; the core
    /// actor still validates the token prefix before trusting any native KV state.
    func generate(
        prompt: String,
        cachedPrefixBytes: Int? = nil,
        options: LlamaGenerationOptions
    ) async throws -> String {
        _ = try await preparedRuntime()

        do {
            return try await core.generate(
                prompt: prompt,
                cachedPrefixBytes: cachedPrefixBytes,
                options: options
            )
        } catch is CancellationError {
            TabbyLogger.runtime.debug("Generation cancelled")
            throw LlamaRuntimeError.cancelled
        } catch let error as LlamaRuntimeError {
            TabbyLogger.runtime.error("Generation runtime error: \(error.localizedDescription)")
            diagnostics.lastError = error.localizedDescription
            throw error
        } catch {
            TabbyLogger.runtime.error("Generation failed: \(error.localizedDescription)")
            let runtimeError = LlamaRuntimeError.generationFailed(error.localizedDescription)
            diagnostics.lastError = runtimeError.localizedDescription
            throw runtimeError
        }
    }

    /// Clears the native prompt KV cache without unloading the model.
    /// The manager exposes this as a lifecycle command because focus/settings resets originate in
    /// the app layer, while the actor still owns the raw llama pointers.

    /// Generates a short summary using an ephemeral context so the autocomplete cache is unaffected.
    func summarize(
        prompt: String,
        maxPredictionTokens: Int,
        temperature: Double
    ) async throws -> String {
        _ = try await preparedRuntime()

        do {
            return try await core.summarize(
                prompt: prompt,
                options: .summary(
                    maxPredictionTokens: maxPredictionTokens,
                    temperature: temperature
                )
            )
        } catch is CancellationError {
            throw LlamaRuntimeError.cancelled
        } catch let error as LlamaRuntimeError {
            diagnostics.lastError = error.localizedDescription
            throw error
        } catch {
            let runtimeError = LlamaRuntimeError.generationFailed(error.localizedDescription)
            diagnostics.lastError = runtimeError.localizedDescription
            throw runtimeError
        }
    }

    func resetPromptCache() async {
        await core.resetPromptCache()
    }

    /// Cancels any retained prepared runtime and asks the actor to release backend resources.
    func stop() {
        TabbyLogger.runtime.info("Runtime stop requested")
        prepareForStop()

        Task {
            await core.shutdown()
        }
    }

    /// Cancels runtime work and waits until native llama resources are released.
    /// Destructive flows such as uninstall need this stronger guarantee before deleting model files
    /// that may have been memory-mapped by the runtime.
    func stopAndWait() async {
        TabbyLogger.runtime.info("Runtime stop-and-wait requested")
        prepareForStop()
        await core.shutdown()
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
            TabbyLogger.runtime.trace("Using cached runtime for \(requestedModelFilename)")
            return cachedRuntime
        }

        // Deduplicate concurrent prepare calls for the same selected model, but cancel and
        // replace the task if the requested model changed while startup was already in flight.
        if let startupTask {
            if startupModelFilename == requestedModelFilename {
                TabbyLogger.runtime.debug("Reusing in-flight startup for \(requestedModelFilename)")
                return try await awaitPreparedRuntime(startupTask)
            }

            TabbyLogger.runtime.info("Model changed to \(requestedModelFilename), cancelling previous startup")
            startupTask.cancel()
            self.startupTask = nil
            startupModelFilename = nil
        }

        cachedRuntime = nil

        state = .starting("Initializing the in-process llama runtime.")
        diagnostics.lastError = nil
        diagnostics.lastLoadStatus = "Starting"
        diagnostics.modelFilePath = resolvedRuntime.modelFileURL.path
        let startupTask = Task { [core, configuration] in
            try await core.prepare(
                resolvedRuntime: resolvedRuntime,
                configuration: configuration
            )
        }
        self.startupTask = startupTask
        startupModelFilename = requestedModelFilename
        TabbyLogger.runtime.info("Loading \(resolvedRuntime.modelDisplayName) into memory")
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
        TabbyLogger.runtime.info(
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
