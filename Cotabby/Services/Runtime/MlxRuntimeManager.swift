import Combine
import Foundation
import Logging

/// File overview:
/// Publishes MLX runtime bootstrap state and user-facing diagnostics.
///
/// The manager is `@MainActor` because SwiftUI observes it. Heavy work is delegated to
/// `MlxRuntimeCore` on detached tasks, preserving the same ownership pattern as the llama runtime:
/// UI state here, backend correctness in the core.
@MainActor
final class MlxRuntimeManager: ObservableObject {
    @Published private(set) var state: RuntimeBootstrapState = .idle
    @Published private(set) var diagnostics = MlxRuntimeDiagnostics()
    @Published private(set) var availableModels: [MlxRuntimeModelOption] = []

    private let configuration: MlxRuntimeConfiguration
    private let runtimeLocator: MlxRuntimeLocator
    private let core: MlxRuntimeCore
    private var startupTask: Task<PreparedMlxRuntime, Error>?
    private var startupModelID: String?
    private var cachedRuntime: PreparedMlxRuntime?
    private var selectedModelID: String?

    var currentModelID: String? {
        selectedModelID
    }

    convenience init() {
        self.init(
            configuration: .default,
            runtimeLocator: MlxRuntimeLocator()
        )
    }

    init(
        configuration: MlxRuntimeConfiguration,
        runtimeLocator: MlxRuntimeLocator
    ) {
        self.configuration = configuration
        self.runtimeLocator = runtimeLocator
        core = MlxRuntimeCore()
        refreshAvailableModels()
    }

    func refreshAvailableModels() {
        availableModels = runtimeLocator.availableModels(configuration: configuration)
        selectedModelID = normalizedModelID(selectedModelID)
        CotabbyLogger.runtime.info("Discovered \(self.availableModels.count) MLX model(s)")
    }

    func configureSelectedModel(id: String?) {
        selectedModelID = normalizedModelID(id)
        CotabbyLogger.runtime.info("Configured selected MLX model: \(self.selectedModelID ?? "none")")
    }

    func prepare() async throws {
        _ = try await preparedRuntime()
    }

    func selectModel(id: String) async throws {
        CotabbyLogger.runtime.info("Selecting MLX model: \(id)")
        guard let normalizedID = normalizedModelID(id) else {
            let error = MlxRuntimeError.unavailable("The selected MLX model \(id) is unavailable.")
            diagnostics.lastError = error.localizedDescription
            throw error
        }

        selectedModelID = normalizedID

        if cachedRuntime?.resolvedRuntime.modelID == normalizedID {
            return
        }

        startupTask?.cancel()
        startupTask = nil
        startupModelID = nil
        cachedRuntime = nil

        _ = try await preparedRuntime()
    }

    func generate(
        prompt: String,
        cachedPrefixBytes: Int? = nil,
        options: LlamaGenerationOptions
    ) async throws -> String {
        _ = try await preparedRuntime()
        let core = self.core
        let configuration = self.configuration

        do {
            let task = Task.detached {
                try await core.generate(
                    prompt: prompt,
                    cachedPrefixBytes: cachedPrefixBytes,
                    options: options,
                    configuration: configuration
                )
            }
            return try await withTaskCancellationHandler {
                let partial = try await task.value
                try Task.checkCancellation()
                return partial
            } onCancel: {
                task.cancel()
            }
        } catch is CancellationError {
            CotabbyLogger.runtime.debug("MLX generation cancelled")
            throw MlxRuntimeError.cancelled
        } catch let error as MlxRuntimeError {
            CotabbyLogger.runtime.error("MLX generation runtime error: \(error.localizedDescription)")
            diagnostics.lastError = error.localizedDescription
            throw error
        } catch {
            CotabbyLogger.runtime.error("MLX generation failed: \(error.localizedDescription)")
            let runtimeError = MlxRuntimeError.generationFailed(error.localizedDescription)
            diagnostics.lastError = runtimeError.localizedDescription
            throw runtimeError
        }
    }

    func resetPromptCache() {
        core.resetPromptCache()
        diagnostics.lastCacheStatus = "Reset"
    }

    func stop() {
        CotabbyLogger.runtime.info("MLX runtime stop requested")
        prepareForStop()
        Task.detached { [core] in
            core.shutdown()
        }
    }

    func stopAndWait() async {
        prepareForStop()
        await Task.detached { [core] in
            core.shutdown()
        }.value
    }

    func shutdownSync(timeoutSeconds: TimeInterval) {
        prepareForStop()
        core.shutdown(timeoutSeconds: timeoutSeconds)
    }

    private func prepareForStop() {
        startupTask?.cancel()
        startupTask = nil
        startupModelID = nil
        cachedRuntime = nil

        diagnostics.lastLoadStatus = "Stopped"
        state = .idle
    }

    private func preparedRuntime() async throws -> PreparedMlxRuntime {
        let resolvedRuntime = try resolveSelectedRuntime()
        let requestedModelID = resolvedRuntime.modelID

        if let cachedRuntime,
           cachedRuntime.resolvedRuntime.modelDirectoryURL == resolvedRuntime.modelDirectoryURL {
            CotabbyLogger.runtime.trace("Using cached MLX runtime for \(requestedModelID)")
            return cachedRuntime
        }

        if let startupTask {
            if startupModelID == requestedModelID {
                CotabbyLogger.runtime.debug("Reusing in-flight MLX startup for \(requestedModelID)")
                return try await awaitPreparedRuntime(startupTask)
            }

            CotabbyLogger.runtime.info("MLX model changed to \(requestedModelID), cancelling previous startup")
            startupTask.cancel()
            self.startupTask = nil
            startupModelID = nil
        }

        cachedRuntime = nil
        state = .starting("Initializing the in-process MLX runtime.")
        diagnostics.lastError = nil
        diagnostics.lastLoadStatus = "Starting"
        diagnostics.modelDirectoryPath = resolvedRuntime.modelDirectoryURL.path
        diagnostics.runtimeDirectoryPath = resolvedRuntime.runtimeDirectoryURL.path

        let startupTask = Task.detached { [core, configuration] in
            try await core.prepare(
                resolvedRuntime: resolvedRuntime,
                configuration: configuration
            )
        }
        self.startupTask = startupTask
        startupModelID = requestedModelID
        CotabbyLogger.runtime.info("Loading MLX \(resolvedRuntime.modelDisplayName) into memory")
        state = .loading("Loading \(resolvedRuntime.modelDisplayName) into MLX.")

        return try await awaitPreparedRuntime(startupTask)
    }

    private func resolveSelectedRuntime() throws -> ResolvedMlxRuntime {
        do {
            return try runtimeLocator.resolve(
                configuration: configuration,
                selectedModelID: selectedModelID
            )
        } catch {
            let runtimeError = MlxRuntimeError.unavailable(error.localizedDescription)
            diagnostics.lastError = runtimeError.localizedDescription
            diagnostics.lastLoadStatus = "Failed"
            state = .failed(runtimeError.localizedDescription)
            throw runtimeError
        }
    }

    private func normalizedModelID(_ id: String?) -> String? {
        guard !availableModels.isEmpty else {
            return nil
        }

        guard let id else {
            return availableModels.first?.id
        }

        if availableModels.contains(where: { $0.id == id }) {
            return id
        }

        return availableModels.first?.id
    }

    private func awaitPreparedRuntime(
        _ startupTask: Task<PreparedMlxRuntime, Error>
    ) async throws -> PreparedMlxRuntime {
        do {
            let preparedRuntime = try await startupTask.value
            cachedRuntime = preparedRuntime
            apply(preparedRuntime)
            self.startupTask = nil
            startupModelID = nil
            return preparedRuntime
        } catch is CancellationError {
            self.startupTask = nil
            startupModelID = nil
            throw MlxRuntimeError.cancelled
        } catch let error as MlxRuntimeError {
            self.startupTask = nil
            startupModelID = nil
            diagnostics.lastError = error.localizedDescription
            diagnostics.lastLoadStatus = "Failed"
            state = .failed(error.localizedDescription)
            throw error
        } catch {
            self.startupTask = nil
            startupModelID = nil
            let runtimeError = MlxRuntimeError.unavailable(error.localizedDescription)
            diagnostics.lastError = runtimeError.localizedDescription
            diagnostics.lastLoadStatus = "Failed"
            state = .failed(runtimeError.localizedDescription)
            throw runtimeError
        }
    }

    private func apply(_ preparedRuntime: PreparedMlxRuntime) {
        let model = preparedRuntime.resolvedRuntime.modelDisplayName
        CotabbyLogger.runtime.info(
            "MLX runtime ready: model=\(model)",
            metadata: ["backend": .string(preparedRuntime.backendName)]
        )
        diagnostics.runtimeDirectoryPath = preparedRuntime.resolvedRuntime.runtimeDirectoryURL.path
        diagnostics.modelDirectoryPath = preparedRuntime.resolvedRuntime.modelDirectoryURL.path
        diagnostics.backendName = preparedRuntime.backendName
        diagnostics.contextWindowTokens = preparedRuntime.contextWindowTokens
        diagnostics.maxKVSize = preparedRuntime.maxKVSize
        diagnostics.kvBits = preparedRuntime.kvBits
        diagnostics.prefillStepSize = preparedRuntime.prefillStepSize
        diagnostics.lastLoadStatus = "Loaded"
        diagnostics.lastError = nil
        diagnostics.lastCacheStatus = "Ready"

        state = .ready("Loaded \(preparedRuntime.resolvedRuntime.modelDisplayName) with MLX.")
    }
}

extension MlxRuntimeManager: MlxRuntimeGenerating {}
