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
    private var runtimeTask: Task<Void, Never>?

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
        guard runtimeTask == nil, !availableModels.isEmpty else {
            return
        }

        // A Task lets us call async startup from non-async app lifecycle methods.
        runtimeTask = Task { [weak self] in
            guard let self else {
                return
            }

            defer {
                self.runtimeTask = nil
            }

            do {
                try await self.runtimeManager.prepare()
            } catch {
                CotabbyLogger.runtime.error("Runtime startup failed: \(error.localizedDescription)")
            }
        }
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

        guard runtimeTask == nil else {
            return
        }

        selectedModelFilename = filename
        persistSelectedModelFilename(filename)
        onWillReloadModel?()

        runtimeTask = Task { [weak self] in
            guard let self else {
                return
            }

            defer {
                self.runtimeTask = nil
            }

            do {
                try await self.runtimeManager.selectModel(filename: filename)
            } catch {
                CotabbyLogger.runtime.error("Runtime model switch failed: \(error.localizedDescription)")
            }
        }

        await runtimeTask?.value
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
        runtimeTask?.cancel()
        runtimeTask = nil
        runtimeManager.stop()
    }

    /// Synchronously releases the runtime on the calling thread, bounded by `timeoutSeconds`.
    /// Used by `applicationWillTerminate` so llama Metal resources are torn down before `exit()`
    /// runs C++ static destructors. See `LlamaRuntimeManager.shutdownSync` for rationale.
    func shutdownSync(timeoutSeconds: TimeInterval) {
        runtimeTask?.cancel()
        runtimeTask = nil
        runtimeManager.shutdownSync(timeoutSeconds: timeoutSeconds)
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
