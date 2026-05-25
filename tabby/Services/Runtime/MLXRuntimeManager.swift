import Combine
import Foundation

/// File overview:
/// Publishes MLX runtime bootstrap state and manages the model lifecycle for the MLX engine.
/// Mirrors `LlamaRuntimeManager` but targets directory-based MLX models instead of single GGUF files.
@MainActor
final class MLXRuntimeManager: ObservableObject {
    @Published private(set) var state: RuntimeBootstrapState = .idle
    @Published private(set) var availableModels: [RuntimeModelOption] = []

    private let runtimeLocator: BundledRuntimeLocator
    private let core: MLXRuntimeCore
    private var startupTask: Task<PreparedMLXRuntime, Error>?
    private var startupModelName: String?
    private var cachedRuntime: PreparedMLXRuntime?
    private var selectedModelName: String?

    convenience init() {
        self.init(runtimeLocator: BundledRuntimeLocator())
    }

    init(runtimeLocator: BundledRuntimeLocator) {
        self.runtimeLocator = runtimeLocator
        core = MLXRuntimeCore()
        refreshAvailableModels()
    }

    func refreshAvailableModels() {
        availableModels = runtimeLocator.availableMLXModels()
        selectedModelName = normalizedModelName(selectedModelName)
    }

    func configureSelectedModel(name: String?) {
        selectedModelName = normalizedModelName(name)
    }

    func prepare() async throws {
        _ = try await preparedRuntime()
    }

    func selectModel(name: String) async throws {
        guard let normalizedName = normalizedModelName(name) else {
            let error = LlamaRuntimeError.unavailable(
                "The selected MLX model \(name) is unavailable.")
            throw error
        }

        selectedModelName = normalizedName

        if cachedRuntime?.modelDirectoryURL.lastPathComponent == normalizedName {
            return
        }

        startupTask?.cancel()
        startupTask = nil
        startupModelName = nil
        cachedRuntime = nil

        _ = try await preparedRuntime()
    }

    func generate(
        prompt: String,
        maxTokens: Int,
        temperature: Float
    ) async throws -> String {
        _ = try await preparedRuntime()

        do {
            return try await core.generate(
                prompt: prompt,
                maxTokens: maxTokens,
                temperature: temperature
            )
        } catch is CancellationError {
            throw LlamaRuntimeError.cancelled
        } catch let error as LlamaRuntimeError {
            throw error
        } catch {
            throw LlamaRuntimeError.generationFailed(error.localizedDescription)
        }
    }

    func stop() {
        prepareForStop()
        Task { await core.shutdown() }
    }

    func stopAndWait() async {
        prepareForStop()
        await core.shutdown()
    }

    private func prepareForStop() {
        startupTask?.cancel()
        startupTask = nil
        startupModelName = nil
        cachedRuntime = nil
        state = .idle
    }

    private func preparedRuntime() async throws -> PreparedMLXRuntime {
        guard let modelOption = resolveSelectedModel() else {
            let error = LlamaRuntimeError.unavailable("No MLX model is available.")
            state = .failed(error.localizedDescription)
            throw error
        }

        let requestedName = modelOption.filename

        if let cachedRuntime,
           cachedRuntime.modelDirectoryURL.lastPathComponent == requestedName {
            return cachedRuntime
        }

        if let startupTask {
            if startupModelName == requestedName {
                return try await awaitStartup(startupTask)
            }
            startupTask.cancel()
            self.startupTask = nil
            startupModelName = nil
        }

        cachedRuntime = nil
        state = .starting("Initializing the MLX runtime.")

        let modelURL = modelOption.url
        let startupTask = Task { [core] in
            try await core.prepare(modelDirectoryURL: modelURL)
        }
        self.startupTask = startupTask
        startupModelName = requestedName
        state = .loading("Loading \(modelOption.displayName) into memory.")

        return try await awaitStartup(startupTask)
    }

    private func resolveSelectedModel() -> RuntimeModelOption? {
        if let selectedModelName,
           let match = availableModels.first(where: { $0.filename == selectedModelName }) {
            return match
        }
        return availableModels.first
    }

    private func normalizedModelName(_ name: String?) -> String? {
        guard !availableModels.isEmpty else { return nil }
        guard let name else { return availableModels.first?.filename }
        if availableModels.contains(where: { $0.filename == name }) { return name }
        return availableModels.first?.filename
    }

    private func awaitStartup(
        _ startupTask: Task<PreparedMLXRuntime, Error>
    ) async throws -> PreparedMLXRuntime {
        do {
            let prepared = try await startupTask.value
            cachedRuntime = prepared
            self.startupTask = nil
            startupModelName = nil
            state = .ready("Loaded \(prepared.modelDisplayName) via MLX.")
            return prepared
        } catch is CancellationError {
            self.startupTask = nil
            startupModelName = nil
            throw LlamaRuntimeError.cancelled
        } catch {
            self.startupTask = nil
            startupModelName = nil
            state = .failed(error.localizedDescription)
            throw LlamaRuntimeError.unavailable(error.localizedDescription)
        }
    }
}
