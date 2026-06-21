import Combine
import Foundation
import Logging

/// File overview:
/// Publishes app-facing MLX runtime lifecycle state and remembers the selected MLX snapshot.
///
/// This is a sibling of `RuntimeBootstrapModel`, not a replacement. The llama bootstrap owns a
/// selected GGUF filename; this type owns a selected MLX model ID that points at a snapshot
/// directory. Keeping those concerns apart lets Settings show both local backends without teaching
/// either runtime manager about the other's storage format.
@MainActor
final class MlxRuntimeBootstrapModel: ObservableObject {
    @Published private(set) var state: RuntimeBootstrapState
    @Published private(set) var diagnostics: MlxRuntimeDiagnostics
    @Published private(set) var availableModels: [MlxRuntimeModelOption]
    @Published private(set) var selectedModelID: String?

    private let runtimeManager: MlxRuntimeManager
    private let userDefaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()
    private var runtimeTask: Task<Void, Never>?
    private var runtimeTaskID: UUID?

    var onWillReloadModel: (() -> Void)?

    private static let selectedModelDefaultsKey = "cotabbySelectedMlxModelID"

    init(
        runtimeManager: MlxRuntimeManager,
        userDefaults: UserDefaults = .standard
    ) {
        self.runtimeManager = runtimeManager
        self.userDefaults = userDefaults
        state = runtimeManager.state
        diagnostics = runtimeManager.diagnostics
        availableModels = runtimeManager.availableModels

        let persistedID = userDefaults.string(forKey: Self.selectedModelDefaultsKey)
        let initialSelection = Self.initialSelectedModelID(
            persistedID,
            availableModels: runtimeManager.availableModels
        )
        selectedModelID = initialSelection
        persistSelectedModelID(initialSelection)
        runtimeManager.configureSelectedModel(id: initialSelection)

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

    func refreshAvailableModels() {
        runtimeManager.refreshAvailableModels()
    }

    func startIfNeeded() {
        guard runtimeTask == nil, !availableModels.isEmpty else {
            return
        }

        let taskID = UUID()
        runtimeTaskID = taskID
        runtimeTask = Task { [weak self] in
            guard let self else { return }
            defer { self.clearRuntimeTask(ifCurrent: taskID) }

            do {
                try await self.runtimeManager.prepare()
            } catch {
                CotabbyLogger.runtime.error("MLX runtime startup failed: \(error.localizedDescription)")
            }
        }
    }

    func selectModel(_ modelID: String) async {
        guard availableModels.contains(where: { $0.id == modelID }) else {
            return
        }

        if selectedModelID == modelID, case .ready = state {
            return
        }

        selectedModelID = modelID
        persistSelectedModelID(modelID)
        onWillReloadModel?()

        // A picker change supersedes startup or an older switch. Cancelling before publishing the
        // replacement preserves the latest user intent while the manager tears down stale work.
        runtimeTask?.cancel()
        let taskID = UUID()
        runtimeTaskID = taskID
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.clearRuntimeTask(ifCurrent: taskID) }

            do {
                try await self.runtimeManager.selectModel(id: modelID)
            } catch {
                CotabbyLogger.runtime.error("MLX runtime model switch failed: \(error.localizedDescription)")
            }
        }
        runtimeTask = task

        await task.value
    }

    func stop() {
        runtimeTask?.cancel()
        runtimeTask = nil
        runtimeTaskID = nil
        runtimeManager.stop()
    }

    func stopAndWait() async {
        runtimeTask?.cancel()
        runtimeTask = nil
        runtimeTaskID = nil
        await runtimeManager.stopAndWait()
    }

    func shutdownSync(timeoutSeconds: TimeInterval) {
        runtimeTask?.cancel()
        runtimeTask = nil
        runtimeTaskID = nil
        runtimeManager.shutdownSync(timeoutSeconds: timeoutSeconds)
    }

    /// Clears task state only when the completing task is still the active bootstrap operation.
    /// A cancelled task may finish after its replacement starts, so unconditional cleanup would
    /// make `startIfNeeded` believe no work is running and permit duplicate model loads.
    private func clearRuntimeTask(ifCurrent taskID: UUID) {
        guard runtimeTaskID == taskID else { return }
        runtimeTask = nil
        runtimeTaskID = nil
    }

    private static func initialSelectedModelID(
        _ persistedID: String?,
        availableModels: [MlxRuntimeModelOption]
    ) -> String? {
        guard !availableModels.isEmpty else {
            return nil
        }

        if let persistedID,
           availableModels.contains(where: { $0.id == persistedID }) {
            return persistedID
        }

        return availableModels.first?.id
    }

    private func persistSelectedModelID(_ id: String?) {
        userDefaults.set(id, forKey: Self.selectedModelDefaultsKey)
    }

    private func applyAvailableModels(_ availableModels: [MlxRuntimeModelOption]) {
        self.availableModels = availableModels

        let persistedID = userDefaults.string(forKey: Self.selectedModelDefaultsKey)
        let resolvedSelection = Self.resolvedSelectedModelID(
            currentSelection: selectedModelID,
            persistedSelection: persistedID,
            availableModels: availableModels
        )

        selectedModelID = resolvedSelection
        persistSelectedModelID(resolvedSelection)
        runtimeManager.configureSelectedModel(id: resolvedSelection)
    }

    private static func resolvedSelectedModelID(
        currentSelection: String?,
        persistedSelection: String?,
        availableModels: [MlxRuntimeModelOption]
    ) -> String? {
        guard !availableModels.isEmpty else {
            return nil
        }

        if let currentSelection,
           availableModels.contains(where: { $0.id == currentSelection }) {
            return currentSelection
        }

        if let persistedSelection,
           availableModels.contains(where: { $0.id == persistedSelection }) {
            return persistedSelection
        }

        return availableModels.first?.id
    }
}
