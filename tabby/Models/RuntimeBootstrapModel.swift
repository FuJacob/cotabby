import Combine
import Foundation
import Logging

/// File overview:
/// Owns app-facing runtime lifecycle state and republishes diagnostics from the in-process
/// llama runtime. SwiftUI views depend on this type instead of performing bootstrap directly.
///
/// Keeps process lifecycle separate from SwiftUI view lifecycle.
@MainActor
final class RuntimeBootstrapModel: ObservableObject {
    /// `@Published` automatically notifies SwiftUI views when these values change.
    @Published private(set) var state: RuntimeBootstrapState
    @Published private(set) var diagnostics: LlamaRuntimeDiagnostics
    @Published private(set) var availableModels: [RuntimeModelOption]
    @Published private(set) var selectedModelFilename: String?

    private let runtimeManager: LlamaRuntimeManager
    private let userDefaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()
    private var runtimeTask: Task<Void, Never>?

    /// Called immediately before the runtime begins switching models so suggestion state can reset.
    var onWillReloadModel: (() -> Void)?

    private static let selectedModelDefaultsKey = "selectedRuntimeModelFilename"

    init(
        runtimeManager: LlamaRuntimeManager,
        userDefaults: UserDefaults = .standard
    ) {
        self.runtimeManager = runtimeManager
        self.userDefaults = userDefaults
        state = runtimeManager.state
        diagnostics = runtimeManager.diagnostics
        availableModels = runtimeManager.availableModels
        let persistedFilename = userDefaults.string(forKey: Self.selectedModelDefaultsKey)
        let initialSelection = RuntimeBootstrapModel.initialSelectedModelFilename(
            persistedFilename,
            availableModels: runtimeManager.availableModels
        )
        selectedModelFilename = initialSelection
        persistSelectedModelFilename(initialSelection)
        runtimeManager.configureSelectedModel(filename: initialSelection)

        // `sink` subscribes to publisher updates; storing cancellables keeps subscriptions alive.
        runtimeManager.$state
            .sink { [weak self] state in
                self?.state = state
            }
            .store(in: &cancellables)

        runtimeManager.$diagnostics
            .sink { [weak self] diagnostics in
                self?.diagnostics = diagnostics
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

    /// Starts runtime preparation exactly once and keeps duplicate launch attempts idempotent.
    /// Idempotent bootstrap ensures only one launch flow is active.
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
                TabbyLogger.runtime.error("Runtime startup failed: \(error.localizedDescription)")
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
                TabbyLogger.runtime.error("Runtime model switch failed: \(error.localizedDescription)")
            }
        }

        await runtimeTask?.value
    }

    /// Cancels pending startup work and forwards shutdown to the underlying runtime manager.
    func stop() {
        runtimeTask?.cancel()
        runtimeTask = nil
        runtimeManager.stop()
    }

    /// Cancels pending startup work and waits for the runtime manager to release native resources.
    /// Normal UI shutdown can be fire-and-forget, but uninstall deletes the model directory and must
    /// not race llama.cpp cleanup.
    func stopAndWait() async {
        runtimeTask?.cancel()
        runtimeTask = nil
        await runtimeManager.stopAndWait()
    }

    /// Returns the selected model when present, otherwise falls back to the first discovered option.
    private static func initialSelectedModelFilename(
        _ persistedFilename: String?,
        availableModels: [RuntimeModelOption]
    ) -> String? {
        guard !availableModels.isEmpty else {
            return nil
        }

        if let persistedFilename,
           availableModels.contains(where: { $0.filename == persistedFilename }) {
            return persistedFilename
        }

        return availableModels.first?.filename
    }

    /// Stores the last chosen runtime model so the next launch reuses the same selection.
    private func persistSelectedModelFilename(_ filename: String?) {
        userDefaults.set(filename, forKey: Self.selectedModelDefaultsKey)
    }

    /// Reconciles persisted/current selection with the newest discovered model list.
    private func applyAvailableModels(_ availableModels: [RuntimeModelOption]) {
        self.availableModels = availableModels

        let persistedFilename = userDefaults.string(forKey: Self.selectedModelDefaultsKey)
        let resolvedSelection = RuntimeBootstrapModel.resolvedSelectedModelFilename(
            currentSelection: selectedModelFilename,
            persistedSelection: persistedFilename,
            availableModels: availableModels
        )

        selectedModelFilename = resolvedSelection
        persistSelectedModelFilename(resolvedSelection)
        runtimeManager.configureSelectedModel(filename: resolvedSelection)
    }

    private static func resolvedSelectedModelFilename(
        currentSelection: String?,
        persistedSelection: String?,
        availableModels: [RuntimeModelOption]
    ) -> String? {
        guard !availableModels.isEmpty else {
            return nil
        }

        if let currentSelection,
           availableModels.contains(where: { $0.filename == currentSelection }) {
            return currentSelection
        }

        if let persistedSelection,
           availableModels.contains(where: { $0.filename == persistedSelection }) {
            return persistedSelection
        }

        return availableModels.first?.filename
    }
}
