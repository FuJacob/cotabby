import Combine
import Foundation

/// File overview:
/// Owns the second `mlx_lm.server` that Rewrite with MLX uses when autocomplete is NOT on MLX (when it
/// is, rewrites share autocomplete's server and this controller stays idle). It runs autocomplete's
/// MLX model, so no rewrite-only model is loaded; asking one server for another model would swap
/// weights, which is why the second server exists at all. Started on demand by the first rewrite and
/// stopped after `idleTimeout` without one.
///
/// The controller is a thin policy layer over an `MLXServerManager` (the same state machine
/// autocomplete uses, given its own pid file). It decides *whether* the server should run with the
/// same pure `MLXServerDesireResolver`, serializes the manager's `apply` calls, waits for the
/// server to be ready, and runs the idle timer. Built once by `CotabbyAppEnvironment`; used by
/// `MLXRewriteProvider` and stopped by the environment and `AppDelegate`.
@MainActor
final class MLXRewriteServerController {
    typealias Sleep = (Duration) async throws -> Void

    /// A smaller prompt cache than autocomplete's 1 GiB: rewrites do not reuse long prefixes.
    static let promptCacheBytes = 512 << 20
    nonisolated static let defaultIdleTimeout: Duration = .seconds(300)
    /// Load (up to 120 s in the manager) plus its warm-up, with a little slack.
    nonisolated static let defaultReadyTimeout: Duration = .seconds(150)

    let manager: MLXServerManager
    private let toolchain: @MainActor () -> MLXToolchainState
    private let cachedModels: @MainActor () -> [MLXCachedModel]?
    private let rejectedModels: @MainActor () -> [MLXRepoID: MLXModelCompatibility.Reason]
    private let isAppleSilicon: Bool
    private let idleTimeout: Duration
    private let readyTimeout: Duration
    private let sleep: Sleep

    /// Tail of the apply chain. Each apply waits for the previous one and runs in its own
    /// unstructured task, so a cancelled rewrite never cancels a stop halfway through its 3 s
    /// SIGTERM grace (the same reason the autocomplete pipeline has `mlxApplyChain`).
    private var applyChain: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    /// Rewrites between `beginUse()` and `endUse()`. The idle timer never stops a busy server.
    private var inFlight = 0
    /// A `stop()` that arrived while a rewrite was in flight; it runs when the last one ends.
    private var stopWhenIdle = false
    /// Callers of a deferred `stop()`, resumed once the stop ran, a new rewrite cancelled it, or the
    /// app began to quit.
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var isShutDown = false

    init(
        manager: MLXServerManager,
        toolchain: @escaping @MainActor () -> MLXToolchainState,
        cachedModels: @escaping @MainActor () -> [MLXCachedModel]?,
        rejectedModels: @escaping @MainActor () -> [MLXRepoID: MLXModelCompatibility.Reason],
        isAppleSilicon: Bool = MLXHardware.isAppleSilicon,
        idleTimeout: Duration = defaultIdleTimeout,
        readyTimeout: Duration = defaultReadyTimeout,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.manager = manager
        self.toolchain = toolchain
        self.cachedModels = cachedModels
        self.rejectedModels = rejectedModels
        self.isAppleSilicon = isAppleSilicon
        self.idleTimeout = idleTimeout
        self.readyTimeout = readyTimeout
        self.sleep = sleep
    }

    nonisolated deinit {}

    /// What the server should do for `modelID` right now. `.mlx` is passed as the engine because
    /// this server runs whenever a rewrite needs it, independent of the autocomplete engine.
    private func desire(modelID: String) -> MLXServerDesire {
        MLXServerDesireResolver.desire(for: .init(
            engine: .mlx,
            isAppleSilicon: isAppleSilicon,
            toolchain: toolchain(),
            modelID: modelID,
            cachedModels: cachedModels(),
            promptCacheBytes: Self.promptCacheBytes,
            rejectedModels: rejectedModels()
        ))
    }

    /// Whether a rewrite on `modelID` could start a server: the provider's `isAvailable`.
    func canRun(modelID: String) -> Bool {
        if case .running = desire(modelID: modelID) { return true }
        return false
    }

    /// Why a rewrite on `modelID` cannot start a server, or nil when it can.
    func unavailableReason(modelID: String) -> String? {
        switch desire(modelID: modelID) {
        case .running: return nil
        case .unavailable(let reason): return reason.message
        case .stopped: return "MLX is still being checked. Try again in a moment."
        }
    }

    /// Starts (or reuses) the server for `modelID` and returns its endpoint once it is ready.
    /// Throws `RewriteError.unavailable` with the reason when it cannot run, fails, or does not
    /// become ready in time. Nothing is launched when the resolver says it cannot run. A server
    /// that already failed is retried: a rewrite is the user explicitly trying again.
    func readyConfiguration(modelID rawModelID: String) async throws -> OpenAICompatibleEndpointConfiguration {
        guard !isShutDown else { throw RewriteError.unavailable("Cotabby is quitting.") }
        // The id is compared with what the server reports, so use the validated, trimmed form.
        guard let repoID = MLXRepoID(rawModelID) else {
            throw RewriteError.unavailable(MLXUnavailableReason.noModel.message)
        }
        let modelID = repoID.value
        let wanted = desire(modelID: modelID)
        if let reason = unavailableReason(modelID: modelID) { throw RewriteError.unavailable(reason) }
        // This rewrite wants the server, so a stop deferred by an earlier Settings change (for
        // example a change that was undone before the in-flight rewrite ended) no longer applies.
        // The apply below still restarts the server if the model differs.
        stopWhenIdle = false
        resumeStopWaiters()
        await enqueue { await $0.apply(wanted) }
        // The same desire again changes nothing in the manager, so a failed server needs retry().
        if case .failed = manager.state {
            await enqueue { await $0.retry() }
        }

        return try await manager.waitUntilReady(
            modelID: modelID, timeout: readyTimeout, sleep: sleep,
            stoppedMessage: "The MLX model was stopped.")
    }

    /// A rewrite starts: the server counts as busy and the idle countdown is paused.
    func beginUse() {
        inFlight += 1
        idleTask?.cancel()
        idleTask = nil
    }

    /// A rewrite ended (however it ended). The idle window counts from the last one finishing, or
    /// a stop requested meanwhile runs now.
    func endUse() {
        inFlight = max(0, inFlight - 1)
        guard inFlight == 0 else { return }
        if stopWhenIdle {
            stopWhenIdle = false
            Task {
                await self.stop()
                self.resumeStopWaiters()
            }
        } else {
            armIdleTimer()
        }
    }

    /// Stops the server after `idleTimeout`; a timer that wakes while a rewrite is in flight
    /// waits another window instead of stopping.
    private func armIdleTimer() {
        idleTask?.cancel()
        guard !isShutDown else { return }
        idleTask = Task { [weak self, sleep, idleTimeout] in
            while true {
                guard (try? await sleep(idleTimeout)) != nil, !Task.isCancelled, let self else { return }
                if self.inFlight == 0 { break }
            }
            await self?.stop()
        }
    }

    /// Stops the server, but never under a running rewrite: Settings changes (provider, engine,
    /// model) call this, and killing the server mid-stream would surface a raw connection error in
    /// the popup. While a rewrite is in flight the stop is deferred to its `endUse()`.
    ///
    /// It returns once the server has stopped, so a caller can wait for the model's memory to be
    /// released: the environment does before autocomplete starts its own MLX server, which loads
    /// the same model. A deferred stop returns when it has run, or early when a new rewrite that
    /// wants the server cancelled it or the app began to quit.
    func stop() async {
        idleTask?.cancel()
        idleTask = nil
        guard inFlight == 0 else {
            stopWhenIdle = true
            await withCheckedContinuation { stopWaiters.append($0) }
            return
        }
        await enqueue { await $0.apply(.stopped) }
    }

    private func resumeStopWaiters() {
        let waiters = stopWaiters
        stopWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// Blocking stop for the app's termination path. `AppDelegate` prefers
    /// `MLXServerManager.shutdownSync(_:)` over both managers so their SIGTERMs share one wait;
    /// this form serves a caller holding only the controller.
    func shutdownSync(timeoutSeconds: TimeInterval = 3) {
        prepareForShutdown()
        manager.shutdownSync(timeoutSeconds: timeoutSeconds)
    }

    /// Cancels the idle timer and refuses further starts, so a rewrite racing the quit cannot
    /// relaunch the server after it was stopped.
    func prepareForShutdown() {
        isShutDown = true
        idleTask?.cancel()
        idleTask = nil
        // The quit path stops the server itself; nobody should wait on a deferred stop now.
        stopWhenIdle = false
        resumeStopWaiters()
    }

    private func enqueue(_ work: @escaping @MainActor (MLXServerManager) async -> Void) async {
        let previous = applyChain
        let task = Task { [manager] in
            await previous?.value
            await work(manager)
        }
        applyChain = task
        await task.value
    }
}

extension MLXServerManager {
    private static let readyPollInterval: Duration = .milliseconds(100)

    /// Waits until this server is `.ready` on `modelID` and returns its endpoint. `.starting`,
    /// `.stopping` and a `.ready` server on another model (mid-switch) keep waiting, up to
    /// `timeout`; `.failed`, `.unavailable` and `.idle` throw `RewriteError.unavailable` at once
    /// with the server's own reason (`stoppedMessage` overrides the `.idle` text). It never starts
    /// anything, so a caller that must not launch a server can use it on autocomplete's. Shared by
    /// the on-demand controller and the provider's wait on autocomplete's server.
    func waitUntilReady(
        modelID: String,
        timeout: Duration,
        sleep: (Duration) async throws -> Void,
        stoppedMessage: String? = nil
    ) async throws -> OpenAICompatibleEndpointConfiguration {
        var waited: Duration = .zero
        while true {
            switch state {
            case .ready(_, let readyModel) where readyModel == modelID:
                return try readyConfiguration
            case .failed, .unavailable:
                throw RewriteError.unavailable(state.notReadyMessage)
            case .idle:
                throw RewriteError.unavailable(stoppedMessage ?? state.notReadyMessage)
            case .starting, .stopping, .ready:
                break
            }
            guard waited < timeout else {
                throw RewriteError.unavailable("The MLX model did not load in time.")
            }
            try await sleep(Self.readyPollInterval)
            waited += Self.readyPollInterval
        }
    }
}
