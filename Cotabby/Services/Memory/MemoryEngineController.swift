import AppKit
import Combine
import CoreGraphics
import CryptoKit
import Foundation

/// File overview:
/// Owns conversation memory's lifecycle: on or off, the embedding model download, the encryption
/// key, and the `MemoryEngine` while memory is on.
///
/// Why separate from the engine: the engine does the work off the main actor; this is the
/// main-actor face the Memory pane and the suggestion pipeline observe (`state`, `status`) and
/// drive (`setEnabled`, `downloadModel`). Built once by `CotabbyAppEnvironment`; started by
/// `AppDelegate`.
@MainActor
final class MemoryEngineController: ObservableObject {
    enum State: Equatable {
        case disabled
        /// The embedding model is not on this Mac yet.
        case needsModel
        case starting
        case running
        case failed(String)
        /// The store was encrypted with a key this Mac's Keychain no longer has.
        case keyMismatch
    }

    @Published private(set) var state: State = .disabled
    @Published private(set) var isEnabled: Bool
    @Published private(set) var status = MemoryEngineStatus()
    /// The running engine; nil while memory is off or starting.
    @Published private(set) var engine: MemoryEngine?

    let paths: MemoryPaths
    let downloads: ModelDownloadManager
    private let userDefaults: UserDefaults
    private let keyStore: any TypingHistoryKeyStore
    private let isOnACPower: @MainActor () -> Bool
    private let isGenerating: @MainActor () -> Bool
    private var cancellables: Set<AnyCancellable> = []

    static let enabledDefaultsKey = "cotabbyMemoryEnabled"

    /// Qwen3-Embedding-0.6B, quantized to 8 bits by Qwen (multilingual, 1024 dimensions). Pinned to a
    /// repository commit, and by
    /// size and SHA-256, which `ModelDownloadManager` verifies before installing the file.
    static let embeddingModel = DownloadableRuntimeModel(
        filename: "Qwen3-Embedding-0.6B-Q8_0.gguf",
        displayName: "Qwen3 Embedding 0.6B",
        downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF/resolve/370f27d7550e0def9b39c1f16d3fbaa13aa67728/Qwen3-Embedding-0.6B-Q8_0.gguf")!,
        approximateSizeInGigabytes: 0.64,
        expectedSizeBytes: 639_150_592,
        sha256: "06507c7b42688469c4e7298b0a1e16deff06caf291cf0a5b278c308249c3e439"
    )

    init(
        paths: MemoryPaths = .standard(),
        userDefaults: UserDefaults = .standard,
        keyStore: (any TypingHistoryKeyStore)? = nil,
        isOnACPower: @escaping @MainActor () -> Bool,
        isGenerating: @escaping @MainActor () -> Bool = { false }
    ) {
        self.paths = paths
        self.userDefaults = userDefaults
        // The store's encryption key: its own Keychain item, per app identity, so the dev build and
        // the released app never share (or overwrite) each other's key.
        self.keyStore = keyStore ?? KeychainTypingHistoryKeyStore(
            service: "\(Bundle.main.bundleIdentifier ?? "com.jacobfu.tabby").memory",
            label: "Cotabby conversation memory key"
        )
        self.isOnACPower = isOnACPower
        self.isGenerating = isGenerating
        downloads = ModelDownloadManager(runtimeDirectoryURL: paths.modelsDirectory)
        isEnabled = userDefaults.bool(forKey: Self.enabledDefaultsKey)
        // Start as soon as the model download finishes, if memory is on and waiting for it.
        downloads.$modelStates
            .map { $0[Self.embeddingModel.id] }
            .removeDuplicates()
            .sink { [weak self] modelState in
                guard let self, modelState == .downloaded, self.isEnabled, self.state == .needsModel else { return }
                self.start()
            }
            .store(in: &cancellables)
    }

    // All stored state is safe to release from any thread (Combine publishers, closures, task
    // handles, values). A nonisolated deinit keeps teardown off the back-deployment main-actor
    // executor shim, which over-releases on macOS 26 (same as `SuggestionSettingsModel`).
    nonisolated deinit {}

    var modelURL: URL { paths.modelsDirectory.appendingPathComponent(Self.embeddingModel.filename) }

    var isModelInstalled: Bool { downloads.isModelInstalled(Self.embeddingModel) }

    // MARK: - Controls

    /// Called once at launch: brings memory up if the user left it on.
    func startIfEnabled() {
        if isEnabled { start() } else { state = .disabled }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        userDefaults.set(enabled, forKey: Self.enabledDefaultsKey)
        if enabled { start() } else { stop() }
    }

    func downloadModel() {
        downloads.download(Self.embeddingModel)
    }

    func restart() {
        stop()
        if isEnabled { start() }
    }

    /// Stops the engine (its model and indexing). `restart` and `deleteMemoryData` start it again.
    /// The returned task finishes once the engine has stopped. A sync still holding the engine
    /// cannot write any more from the moment this returns (`MemoryEngine.markStopped`).
    @discardableResult
    func stop() -> Task<Void, Never> {
        let engine = engine
        engine?.markStopped()
        self.engine = nil
        status = MemoryEngineStatus()
        state = .disabled
        return Task.detached(priority: .utility) { engine?.stop() }
    }

    /// Deletes the stored messages and starts again. Settings stay. Offered after a key mismatch,
    /// when no engine ever opened the store; the files are still removed only after any engine
    /// has stopped, so a closing connection can never touch the new store's journal.
    func deleteMemoryData() {
        let stopping = stop()
        let store = MemoryEngine.Paths(dataDirectory: paths.dataDirectory).store
        Task {
            await stopping.value
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: store.path + suffix)
            }
            if isEnabled { start() }
        }
    }

    // MARK: - Starting

    private func start() {
        guard isEnabled else { return }
        guard isModelInstalled else {
            state = .needsModel
            return
        }
        state = .starting
        let paths = MemoryEngine.Paths(dataDirectory: self.paths.dataDirectory)
        let modelURL = modelURL
        let keyStore = keyStore
        let conditions = conditionsProvider()
        Task {
            do {
                let engine = try await Task.detached(priority: .userInitiated) { () throws -> MemoryEngine in
                    let key = try keyStore.existingKey() ?? keyStore.createKey()
                    let engine = try MemoryEngine(paths: paths, rootKey: key, modelURL: modelURL, conditions: conditions)
                    try engine.start()
                    return engine
                }.value
                guard isEnabled else {
                    Task.detached { engine.stop() }
                    return
                }
                attach(engine)
            } catch MemoryVault.VaultError.keyMismatch {
                state = .keyMismatch
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Makes a started engine the running one and mirrors its status for the pane.
    private func attach(_ engine: MemoryEngine) {
        // The engine reports from its own thread; the relay hops to the main actor without the
        // callback holding the controller (a weak reference that crosses threads safely).
        let relay = StatusRelay(controller: self)
        engine.onStatusChange = { status in
            Task { @MainActor in relay.controller?.status = status }
        }
        status = engine.status
        self.engine = engine
        state = .running
    }

    /// What the indexing policy needs, read on the main actor (the power monitor lives there).
    private func conditionsProvider() -> @Sendable () async -> EmbeddingSchedulePolicy.Conditions {
        let isOnACPower = isOnACPower
        let isGenerating = isGenerating
        return {
            await MainActor.run {
                // kCGAnyInputEventType (~0): the time since any keyboard or mouse input.
                let anyInput = CGEventType(rawValue: ~0) ?? .null
                return EmbeddingSchedulePolicy.Conditions(
                    isOnACPower: isOnACPower(),
                    isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                    thermalState: ProcessInfo.processInfo.thermalState,
                    userIdleSeconds: CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput),
                    isGenerating: isGenerating(),
                    pendingPassages: 0
                )
            }
        }
    }
}

/// Holds the controller weakly for the engine's status callback (see `attach`). Read only on the
/// main actor, which is what makes the unchecked `Sendable` sound.
nonisolated private final class StatusRelay: @unchecked Sendable {
    weak var controller: MemoryEngineController?

    init(controller: MemoryEngineController) {
        self.controller = controller
    }
}
