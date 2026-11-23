import Combine
import Foundation
import Logging

/// File overview:
/// Owns app-facing runtime lifecycle state and the persisted model selection for the in-process
/// llama runtime. SwiftUI views depend on this type instead of performing bootstrap directly,
/// which keeps the runtime's process lifetime independent of any view's lifetime.
@MainActor
final class RuntimeBootstrapModel: ObservableObject {
    @Published private(set) var state: RuntimeBootstrapState
    @Published private(set) var availableModels: [RuntimeModelOption]
    @Published private(set) var selectedModelFilename: String?

    private let runtimeManager: LlamaRuntimeManager
    private let userDefaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()
    private var activity: Activity = .idle

    /// The one runtime operation this model is driving. A start and a model switch are mutually
    /// exclusive, so a second request made while one is in flight is refused rather than queued.
    private enum Activity {
        case idle
        case starting(id: UUID, task: Task<Void, Never>)
        case switching(id: UUID, to: String, task: Task<Void, Never>)

        var id: UUID? {
            switch self {
            case .idle:
                return nil
            case .starting(let id, _), .switching(let id, _, _):
                return id
            }
        }

        var task: Task<Void, Never>? {
            switch self {
            case .idle:
                return nil
            case .starting(_, let task), .switching(_, _, let task):
                return task
            }
        }

        var logDescription: String {
            switch self {
            case .idle:
                return "idle"
            case .starting:
                return "starting the runtime"
            case .switching(_, let filename, _):
                return "switching to \(filename)"
            }
        }
    }

    /// Called immediately before the runtime begins switching models so suggestion state can reset.
    var onWillReloadModel: (() -> Void)?

    private static let selectedModelDefaultsKey = "cotabbySelectedModelFilename"

    init(
        runtimeManager: LlamaRuntimeManager,
        userDefaults: UserDefaults = .standard
    ) {
        self.runtimeManager = runtimeManager
        self.userDefaults = userDefaults
        state = runtimeManager.state
        availableModels = runtimeManager.availableModels
        let initialSelection = RuntimeModelSelection.resolve(
            candidates: [userDefaults.string(forKey: Self.selectedModelDefaultsKey)],
            available: runtimeManager.availableModels
        )
        selectedModelFilename = initialSelection
        persistSelectedModelFilename(initialSelection)
        runtimeManager.configureSelectedModel(filename: initialSelection)

        runtimeManager.$state
            .sink { [weak self] state in
                self?.state = state
            }
            .store(in: &cancellables)

        runtimeManager.$availableModels
            .sink { [weak self] availableModels in
                self?.applyAvailableModels(availableModels)
            }
            .store(in: &cancellables)
    }

    /// Triggers a fresh scan of local model files after downloads complete.
    func refreshAvailableModels() {
        runtimeManager.refreshAvailableModels()
    }

    /// Starts runtime preparation unless a launch or model switch is already in flight, so
    /// duplicate launch attempts from app lifecycle callbacks stay idempotent.
    func startIfNeeded() {
        guard case .idle = activity, !availableModels.isEmpty else {
            return
        }

        let id = UUID()
        let task = makeTask(id: id, failureLabel: "Runtime startup failed") { runtimeManager in
            try await runtimeManager.prepare()
        }
        activity = .starting(id: id, task: task)
    }

    /// Persists the user's chosen model and reloads the existing runtime manager in place.
    /// Keeping one runtime owner avoids rebuilding the app dependency graph on every switch.
    func selectModel(_ filename: String) async {
        guard availableModels.contains(where: { $0.filename == filename }) else {
            return
        }

        if selectedModelFilename == filename, case .ready = state {
            return
        }

        guard case .idle = activity else {
            // The picker shows the previous model again after this; the log line is what explains
            // a selection that appeared to do nothing.
            CotabbyLogger.runtime.info("Ignored model selection \(filename) while \(self.activity.logDescription)")
            return
        }

        selectedModelFilename = filename
        persistSelectedModelFilename(filename)
        onWillReloadModel?()

        let id = UUID()
        let task = makeTask(id: id, failureLabel: "Runtime model switch failed") { runtimeManager in
            try await runtimeManager.selectModel(filename: filename)
        }
        activity = .switching(id: id, to: filename, task: task)

        await task.value
    }

    /// Runs one runtime operation and returns the activity to idle when it ends. The identity
    /// check matters after `stop()`: a cancelled operation finishes later than the stop that
    /// replaced it, and must not clear an operation started in the meantime.
    private func makeTask(
        id: UUID,
        failureLabel: String,
        operation: @escaping @MainActor (LlamaRuntimeManager) async throws -> Void
    ) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else {
                return
            }

            defer {
                if self.activity.id == id {
                    self.activity = .idle
                }
            }

            do {
                try await operation(self.runtimeManager)
            } catch {
                CotabbyLogger.runtime.error("\(failureLabel): \(error.localizedDescription)")
            }
        }
    }

    /// Persists the user's chosen model without loading it. `selectModel` would load the GGUF right
    /// away, which is wrong while the runtime is meant to stay unloaded, as with the Apple
    /// Intelligence fallback picker when "Keep Fallback Model Loaded" is off. The runtime manager
    /// resolves the selection on every prepare, so the next on-demand fallback or engine switch
    /// loads this model, replacing any model a previous fallback left loaded.
    func selectModelWithoutLoading(_ filename: String) {
        guard availableModels.contains(where: { $0.filename == filename }),
              selectedModelFilename != filename else {
            return
        }

        selectedModelFilename = filename
        persistSelectedModelFilename(filename)
        // Signal the switch even though nothing loads yet: a model an earlier fallback loaded may
        // still be generating or showing a suggestion, and the next request runs on the new model.
        // Clearing that state now matches `selectModel`, so no completion from the old model is
        // left on screen to accept.
        onWillReloadModel?()
        runtimeManager.configureSelectedModel(filename: filename)
    }

    /// Cancels pending startup work and forwards shutdown to the underlying runtime manager.
    func stop() {
        cancelActivity()
        runtimeManager.stop()
    }

    /// Synchronously releases the runtime on the calling thread, bounded by `timeoutSeconds`.
    /// Used by `applicationWillTerminate` so llama Metal resources are torn down before `exit()`
    /// runs C++ static destructors. See `LlamaRuntimeManager.shutdownSync` for rationale.
    func shutdownSync(timeoutSeconds: TimeInterval) {
        cancelActivity()
        runtimeManager.shutdownSync(timeoutSeconds: timeoutSeconds)
    }

    private func cancelActivity() {
        activity.task?.cancel()
        activity = .idle
    }

    /// Stores the last chosen runtime model so the next launch reuses the same selection.
    private func persistSelectedModelFilename(_ filename: String?) {
        userDefaults.set(filename, forKey: Self.selectedModelDefaultsKey)
    }

    /// Reconciles persisted/current selection with the newest discovered model list.
    private func applyAvailableModels(_ availableModels: [RuntimeModelOption]) {
        self.availableModels = availableModels

        // The live selection outranks the stored one so a rescan can never revert the user's
        // current pick to a stale persisted value.
        let resolvedSelection = RuntimeModelSelection.resolve(
            candidates: [selectedModelFilename, userDefaults.string(forKey: Self.selectedModelDefaultsKey)],
            available: availableModels
        )

        selectedModelFilename = resolvedSelection
        persistSelectedModelFilename(resolvedSelection)
        runtimeManager.configureSelectedModel(filename: resolvedSelection)
    }
}
