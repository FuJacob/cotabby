import Combine
import Darwin
import Foundation
import Logging

/// File overview:
/// Owns Cotabby's `mlx_lm.server` child process. It launches the server on a free loopback port,
/// waits until the model is loaded, restarts it with backoff after a crash, stops it
/// (SIGTERM, then SIGKILL after 3 s), and cleans up a server orphaned by an earlier crash of
/// Cotabby. It publishes one `MLXServerState` that Settings and the router read.
///
/// Owned by `CotabbyAppEnvironment` for the app's lifetime. It never decides *whether* MLX should
/// run; `MLXServerDesireResolver` does, and the environment calls `apply(_:)` with the answer.
/// The process, readiness probe, port, clock and sleep are injected so the whole lifecycle is
/// testable without Python.
///
/// Concurrency: everything runs on the main actor. Every launch bumps `generation`, and so does
/// every intended stop. A readiness answer, exit callback or restart timer that belongs to an
/// older generation is ignored, which is what keeps a slow probe from reviving a stopped server.

/// Why the server could not be started or kept ready. Its `errorDescription` is what the user sees
/// in the Settings callout, so each message says what happened, not how the code failed.
nonisolated enum MLXServerError: LocalizedError, Equatable {
    case noFreePort
    case readinessTimedOut
    case warmUpFailed(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .noFreePort: return "No free local port for MLX."
        case .readinessTimedOut: return "The model did not load within 2 minutes."
        case .warmUpFailed(let code): return "The first test completion failed (HTTP \(code))."
        }
    }
}

/// The pid of the server Cotabby launched, kept on disk so the next launch can find a server
/// orphaned when Cotabby crashed or was force-quit.
nonisolated struct MLXServerPIDFile {
    let url: URL

    func write(pid: Int32) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("\(pid)\n".utf8).write(to: url, options: .atomic)
    }

    func read() -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Asks the kernel for a free loopback port by binding 127.0.0.1:0, then releases it for the
/// server. Another process could take it in between; the server then fails to bind, exits, and
/// the restart picks a new port.
nonisolated enum MLXLoopbackPort {
    static func next() throws -> Int {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw MLXServerError.noFreePort }
        defer { close(socketFD) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, length) }
        }
        guard bound == 0 else { throw MLXServerError.noFreePort }
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
        }
        guard named == 0 else { throw MLXServerError.noFreePort }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

/// Reads another process's state through BSD calls; used only for orphan cleanup. A caseless enum
/// because it holds no state: each call is one `kill` or `sysctl` probe of a pid.
nonisolated enum MLXProcessInspector {
    static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    /// The process's argv via `sysctl(KERN_PROCARGS2)`; nil if it exited or is not ours to read.
    static func arguments(of pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return MLXToolchainRules.parseProcArgs(Array(buffer.prefix(size)))
    }

    /// True when `pid` has a TCP socket whose local port is `port`. libproc lists a process's file
    /// descriptors; each socket descriptor is then asked for its details. Kernel ports come back in
    /// network byte order, so they are swapped before comparing.
    static func ownsTCPSocket(pid: Int32, port: Int) -> Bool {
        // First call sizes the list, second call fills it. The fd count can change in between, so
        // only the entries the second call reports are read.
        let listSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard listSize > 0 else { return false }
        var descriptors = [proc_fdinfo](
            repeating: proc_fdinfo(), count: Int(listSize) / MemoryLayout<proc_fdinfo>.stride)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, listSize)
        guard filled > 0 else { return false }
        let count = Int(filled) / MemoryLayout<proc_fdinfo>.stride
        for descriptor in descriptors.prefix(count) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            // A descriptor can close between the list and this call; a short read means no answer.
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == SOCKINFO_TCP
            else { continue }
            let localPort = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)))
            if localPort == port { return true }
        }
        return false
    }
}

/// The state machine around one `mlx_lm.server` child. It is owned by `CotabbyAppEnvironment` (one
/// per app) and collaborates with the resolver (what to run), the launcher and probe (how to run
/// and check it, injected so tests use fakes), and the pid file (orphan recovery). Views and the
/// router only read its published `state`.
@MainActor
final class MLXServerManager: ObservableObject {
    typealias Sleep = (Duration) async throws -> Void

    static let restartBackoff: [Duration] = [.seconds(1), .seconds(5), .seconds(30)]
    /// Failure policy: restart after 1 s, 5 s, 30 s; give up (`failed`) after `failureLimit`
    /// failures inside `failureWindow`, or after `failureLimit` consecutive failures regardless
    /// of timing (a server that takes 60 s+ to fail each time never fills the window).
    static let failureWindow: TimeInterval = 120
    static let failureLimit = 3
    static let readinessTimeout: Duration = .seconds(120)
    static let stopGrace: Duration = .seconds(3)
    private static let stopPoll: Duration = .milliseconds(100)

    @Published private(set) var state: MLXServerState = .idle

    private struct RunningServer {
        let launch: MLXServerLaunch
        let port: Int
        let process: any MLXRunningProcess
    }

    private let launcher: any MLXProcessLaunching
    private let probe: any MLXReadinessProbing
    private let pickPort: () throws -> Int
    private let sleep: Sleep
    private let now: () -> Date
    private let pidFile: MLXServerPIDFile
    private let baseEnvironment: [String: String]
    /// Answers "does this pid own a TCP socket on this port?" before `.ready` is published. The
    /// port was only probed, not reserved, so another local program may have taken it.
    private let verifyListener: (Int32, Int) -> Bool

    private var desired: MLXServerDesire = .stopped
    private var current: RunningServer?
    /// The live server's pid, for the Performance pane's resource graph. Nil when none is running.
    var runningProcessIdentifier: Int32? { current?.process.processIdentifier }
    /// The process a stop is waiting on right now (inside its SIGTERM grace). `current` is already
    /// nil by then, so `shutdownSync` needs this reference to still reach it.
    private var stoppingProcess: (any MLXRunningProcess)?
    private var generation: UInt64 = 0
    private var readinessTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    /// Failure times inside the two-minute window (decides `failed`).
    private var recentFailures: [Date] = []
    /// Failures since the last time the server became ready (decides the backoff step).
    private var consecutiveFailures = 0

    init(
        paths: MLXPaths,
        launcher: any MLXProcessLaunching,
        probe: any MLXReadinessProbing,
        pickPort: @escaping () throws -> Int = MLXLoopbackPort.next,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        now: @escaping () -> Date = Date.init,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        verifyListener: @escaping (Int32, Int) -> Bool = MLXProcessInspector.ownsTCPSocket(pid:port:)
    ) {
        self.launcher = launcher
        self.probe = probe
        self.pickPort = pickPort
        self.sleep = sleep
        self.now = now
        self.pidFile = MLXServerPIDFile(url: paths.serverPIDFile)
        self.baseEnvironment = baseEnvironment
        self.verifyListener = verifyListener
    }

    static func live(paths: MLXPaths) -> MLXServerManager {
        MLXServerManager(paths: paths, launcher: MLXLiveProcessLauncher(), probe: MLXHTTPReadinessProbe())
    }

    /// The endpoint the MLX engine instance talks to. Only a ready server yields one; otherwise
    /// the reason surfaces as the request's `.unavailable` message (no fallback engine).
    var readyConfiguration: OpenAICompatibleEndpointConfiguration {
        get throws {
            guard case .ready(let port, let modelID) = state else {
                throw SuggestionClientError.unavailable(state.notReadyMessage)
            }
            return try OpenAICompatibleEndpointConfiguration(
                baseURLString: "http://127.0.0.1:\(port)/v1",
                modelName: modelID,
                apiMode: .completions
            )
        }
    }

    /// Moves toward `desire`. Idempotent: the same desire again changes nothing (a failed server
    /// stays failed until `retry()` or a different desire).
    func apply(_ desire: MLXServerDesire) async {
        guard desire != desired else { return }
        desired = desire
        recentFailures = []
        consecutiveFailures = 0
        await stopCurrent()
        // Another apply may have arrived while the old server was stopping; the newest wins.
        guard desired == desire else { return }
        switch desire {
        case .stopped:
            state = .idle
        case .unavailable(let reason):
            state = .unavailable(reason)
        case .running(let launch):
            start(launch)
        }
    }

    func retry() async {
        guard case .running(let launch) = desired else { return }
        recentFailures = []
        consecutiveFailures = 0
        await stopCurrent()
        guard desired == .running(launch) else { return }
        start(launch)
    }

    /// Blocking stop for `applicationWillTerminate`, where no run loop turn is left for `async`.
    func shutdownSync(timeoutSeconds: TimeInterval = 3) {
        generation &+= 1
        readinessTask?.cancel()
        restartTask?.cancel()
        desired = .stopped
        defer {
            pidFile.remove()
            state = .idle
        }
        // A server already being stopped has had its SIGTERM sent; it only needs the wait and the
        // SIGKILL fallback, so it is not terminated a second time.
        let stopping = stoppingProcess
        let running = current?.process
        current = nil
        running?.terminate()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while [running, stopping].contains(where: { $0?.isRunning == true }), Date() < deadline {
            usleep(50_000)
        }
        for process in [running, stopping] {
            if let process, process.isRunning { process.forceKill() }
        }
    }

    /// Terminates a server left running by an earlier Cotabby that crashed or was force-quit.
    /// Only a process whose live command line is our loopback `mlx_lm.server` is signalled, so a
    /// reused pid never kills an unrelated program.
    func cleanUpOrphan(
        isAlive: @escaping (Int32) -> Bool = MLXProcessInspector.isAlive,
        arguments: @escaping (Int32) -> [String]? = MLXProcessInspector.arguments(of:),
        signal: @escaping (Int32, Int32) -> Void = { pid, signal in _ = kill(pid, signal) }
    ) async {
        guard let pid = pidFile.read() else { return }
        // The file names the live server when one is running; that record belongs to it, not to an orphan.
        guard current?.process.processIdentifier != pid else { return }
        pidFile.remove()
        guard isAlive(pid),
              let processArguments = arguments(pid),
              MLXToolchainRules.isOurServer(arguments: processArguments)
        else { return }
        CotabbyLogger.runtime.warning("Stopping an MLX server left by an earlier Cotabby run", metadata: ["pid": .stringConvertible(pid)])
        signal(pid, SIGTERM)
        var waited: Duration = .zero
        while isAlive(pid), waited < Self.stopGrace {
            try? await sleep(Self.stopPoll)
            waited += Self.stopPoll
        }
        if isAlive(pid) { signal(pid, SIGKILL) }
    }

    // MARK: - Lifecycle

    private func start(_ launch: MLXServerLaunch) {
        generation &+= 1
        let launchGeneration = generation
        state = .starting(modelID: launch.modelID)
        let port: Int
        let process: any MLXRunningProcess
        do {
            port = try pickPort()
            let command = MLXToolchainRules.serverCommand(
                serverScript: launch.executable,
                interpreter: launch.interpreter,
                arguments: MLXToolchainRules.serverArguments(
                    modelID: launch.modelID, port: port, promptCacheBytes: launch.promptCacheBytes)
            )
            process = try launcher.launch(
                executable: command.executable,
                arguments: command.arguments,
                environment: MLXToolchainRules.serverEnvironment(base: baseEnvironment),
                onExit: { [weak self] status in
                    self?.processExited(generation: launchGeneration, status: status)
                }
            )
        } catch {
            recordFailure(launch, reason: "MLX could not start: \(error.localizedDescription)", logTail: [])
            return
        }
        current = RunningServer(launch: launch, port: port, process: process)
        pidFile.write(pid: process.processIdentifier)
        CotabbyLogger.runtime.info("MLX server launched", metadata: [
            "model": .string(launch.modelID),
            "port": .stringConvertible(port),
            "pid": .stringConvertible(process.processIdentifier),
            "prompt_cache_bytes": .stringConvertible(launch.promptCacheBytes)
        ])
        let startedAt = now()
        readinessTask = Task { [weak self, probe] in
            do {
                try await probe.waitUntilReady(port: port, modelID: launch.modelID, timeout: Self.readinessTimeout)
                // A crash or stop can land while the probe is suspended. Its exit clears `current`
                // without bumping `generation`, so the identity check is what stops a dead server
                // from being published as ready.
                guard let self, self.generation == launchGeneration, !Task.isCancelled,
                      self.current?.process === process else { return }
                guard self.verifyListener(process.processIdentifier, port) else {
                    await self.failCurrent(
                        generation: launchGeneration,
                        reason: "Another program answered on MLX's port."
                    )
                    return
                }
                self.consecutiveFailures = 0
                self.state = .ready(port: port, modelID: launch.modelID)
                CotabbyLogger.runtime.info("MLX server ready", metadata: [
                    "model": .string(launch.modelID),
                    "ready_ms": .stringConvertible(Int(self.now().timeIntervalSince(startedAt) * 1000))
                ])
            } catch {
                guard let self, self.generation == launchGeneration, !(error is CancellationError) else { return }
                await self.failCurrent(
                    generation: launchGeneration,
                    reason: "MLX did not become ready: \(error.localizedDescription)"
                )
            }
        }
    }

    /// An exit nobody asked for. Intended stops bump `generation` or clear `current` first, so
    /// their exits land here and are ignored.
    private func processExited(generation exitGeneration: UInt64, status: Int32) {
        guard exitGeneration == generation, let running = current else { return }
        current = nil
        readinessTask?.cancel()
        readinessTask = nil
        pidFile.remove()
        CotabbyLogger.runtime.error("MLX server exited", metadata: ["status": .stringConvertible(status)])
        recordFailure(running.launch, reason: "MLX stopped unexpectedly (exit status \(status)).",
                      logTail: running.process.stderrTail())
    }

    /// A request showed that the server's generator died while the process stayed up (mlx_lm answers
    /// 404 "generation thread died" and `/v1/models` keeps working), so the exit callback never
    /// fires. This restarts it through the normal failure path: backoff 1 s / 5 s / 30 s, and
    /// `failed` after three. Only a report for the live, ready server's port counts; a late report
    /// from a request to an old port, or one made while the server is already restarting, is
    /// ignored. Dozens of in-flight requests fail together, so everything that must happen once
    /// (clearing `current`, leaving `.ready`) happens synchronously before the first suspension.
    func reportBroken(port: Int, reason: String) {
        guard let running = current, running.port == port, case .ready = state else { return }
        let failedGeneration = generation
        let tail = running.process.stderrTail()
        // Clearing `current` makes the process's own exit callback a no-op; `.starting` makes new
        // requests fail fast with "loading" instead of hitting the broken server. SIGTERM goes out
        // and the process is recorded as stopping before the task below is scheduled, so a quit
        // that lands first still finds it in `shutdownSync` (which then waits and SIGKILLs).
        current = nil
        state = .starting(modelID: running.launch.modelID)
        stoppingProcess = running.process
        running.process.terminate()
        CotabbyLogger.runtime.error("MLX generator stopped working", metadata: [
            "reason": .string(reason),
            "port": .stringConvertible(port),
            "log_tail": .string(tail.joined(separator: "\n"))
        ])
        Task { [weak self] in
            guard let self else { return }
            await self.waitForExitTracked(running.process)
            self.removePIDFile(ownedBy: running.process.processIdentifier)
            // A stop, model change or shutdown can land during the SIGTERM grace; it owns the
            // state then, so no failure is recorded for a server the user no longer wants.
            guard self.generation == failedGeneration, self.desired == .running(running.launch) else { return }
            self.recordFailure(running.launch, reason: "MLX's generator stopped working: \(reason)", logTail: tail)
        }
    }

    /// Readiness failed: the process is still up but useless. Kill it, then count a failure.
    private func failCurrent(generation failedGeneration: UInt64, reason: String) async {
        guard let running = current else { return }
        let tail = running.process.stderrTail()
        current = nil
        await terminateTracked(running.process)
        removePIDFile(ownedBy: running.process.processIdentifier)
        guard generation == failedGeneration, desired == .running(running.launch) else { return }
        recordFailure(running.launch, reason: reason, logTail: tail)
    }

    private func recordFailure(_ launch: MLXServerLaunch, reason: String, logTail: [String]) {
        let at = now()
        recentFailures = recentFailures.filter { at.timeIntervalSince($0) < Self.failureWindow } + [at]
        consecutiveFailures += 1
        CotabbyLogger.runtime.error("MLX server failure", metadata: [
            "reason": .string(reason),
            "failures_in_window": .stringConvertible(recentFailures.count)
        ])
        // Two ways to give up: a burst (limit failures inside the window) or a slow loop (limit
        // failures in a row without ever becoming ready, each attempt outlasting the window).
        guard recentFailures.count < Self.failureLimit, consecutiveFailures < Self.failureLimit else {
            generation &+= 1
            state = .failed(reason: reason, logTail: logTail)
            return
        }
        let delay = Self.restartBackoff[min(consecutiveFailures - 1, Self.restartBackoff.count - 1)]
        let restartGeneration = generation
        state = .starting(modelID: launch.modelID)
        restartTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.sleep(delay) } catch { return }
            guard self.generation == restartGeneration, self.desired == .running(launch) else { return }
            self.restartTask = nil
            self.start(launch)
        }
    }

    /// Stops whatever runs now. Bumping `generation` first invalidates any pending readiness,
    /// restart or exit callback that belongs to it.
    private func stopCurrent() async {
        generation &+= 1
        readinessTask?.cancel()
        readinessTask = nil
        restartTask?.cancel()
        restartTask = nil
        guard let running = current else {
            pidFile.remove()
            return
        }
        current = nil
        state = .stopping
        await terminateTracked(running.process)
        removePIDFile(ownedBy: running.process.processIdentifier)
        CotabbyLogger.runtime.info("MLX server stopped", metadata: ["model": .string(running.launch.modelID)])
    }

    /// Sends SIGTERM and waits for the exit while keeping the process visible to `shutdownSync`.
    private func terminateTracked(_ process: any MLXRunningProcess) async {
        stoppingProcess = process
        process.terminate()
        await waitForExitTracked(process)
    }

    /// The second half of a stop, for a process that has already had its SIGTERM: waits out the
    /// grace period, SIGKILLs it if needed, then stops tracking it.
    private func waitForExitTracked(_ process: any MLXRunningProcess) async {
        await Self.waitForExit(process, sleep: sleep)
        if stoppingProcess === process { stoppingProcess = nil }
    }

    /// Removes the pid file only while it still names `pid`. A stop waits up to 3 s, and a newer
    /// `start` may have written its own pid into the same file during that wait.
    private func removePIDFile(ownedBy pid: Int32) {
        if pidFile.read() == pid { pidFile.remove() }
    }

    private static func waitForExit(_ process: any MLXRunningProcess, sleep: Sleep) async {
        var waited: Duration = .zero
        while process.isRunning, waited < stopGrace {
            try? await sleep(stopPoll)
            waited += stopPoll
        }
        if process.isRunning { process.forceKill() }
    }
}

// MARK: - Live process and probe

/// Starts the real `mlx_lm.server` with stdout discarded. Its stderr always feeds an in-memory tail
/// for the failure message. Under `-cotabby-debug` the full stream is also appended to
/// `mlx-server.log`, like the app's other on-disk logs, so a failure can be diagnosed afterwards;
/// a normal run writes nothing to disk.
final class MLXLiveProcessLauncher: MLXProcessLaunching {
    private let logWriter: MLXServerLogWriter?

    init(logWriter: MLXServerLogWriter? = CotabbyDebugOptions.isEnabled ? .shared : nil) {
        self.logWriter = logWriter
    }

    func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        onExit: @escaping @MainActor (Int32) -> Void
    ) throws -> any MLXRunningProcess {
        // The exit arrives on a background thread; hop to the main actor for the manager.
        let stderr = Pipe()
        // Raw lines are kept generously (300) because the filter in `stderrTail()` drops
        // access-log lines and disconnect tracebacks, which are most of what the server prints.
        let output = MLXOutputCollector(tailLines: 300)
        let process = Self.configuredProcess(
            executable: executable,
            arguments: arguments,
            environment: environment,
            stderr: stderr,
            onExit: { @Sendable status in
                Task { @MainActor in onExit(status) }
            }
        )
        try process.run()
        // The header needs the pid, so the reader starts after `run()`; the pipe buffers whatever
        // the server wrote in between.
        logWriter?.writeHeader(
            pid: process.processIdentifier,
            model: Self.value(after: "--model", in: arguments) ?? "?",
            port: Int(Self.value(after: "--port", in: arguments) ?? "") ?? 0)
        Self.startReading(stderr, into: output, log: logWriter)
        return MLXLiveRunningProcess(process: process, output: output)
    }

    /// Builds the process outside the main actor. Its handlers run on background threads, and
    /// with the target's default MainActor isolation a closure formed in a main-actor method could
    /// be inferred main-actor-isolated and trip Swift's runtime isolation check there.
    nonisolated private static func configuredProcess(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        stderr: Pipe,
        onExit: @escaping @Sendable (Int32) -> Void
    ) -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        process.terminationHandler = { finished in onExit(finished.terminationStatus) }
        return process
    }

    /// Drains stderr off the main actor: each chunk goes to the in-memory collector and, when one
    /// is given, the log file.
    /// At EOF the handler is called with empty data, and it keeps being called until it is removed.
    /// Removing it there and recording the close matches `MLXProcessRunner`.
    nonisolated private static func startReading(_ pipe: Pipe, into output: MLXOutputCollector, log: MLXServerLogWriter?) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                output.markStderrClosed()
            } else {
                output.appendStderr(data)
                log?.write(data)
            }
        }
    }

    nonisolated private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}

/// Adapts a Foundation `Process` to `MLXRunningProcess`. It is created by
/// `MLXLiveProcessLauncher` and owned by the manager's `RunningServer`; it lives exactly as long as
/// that launch. It holds the stderr collector so the failure message can quote the server's last
/// lines even after the process has exited.
final class MLXLiveRunningProcess: MLXRunningProcess {
    private let process: Process
    private let output: MLXOutputCollector

    init(process: Process, output: MLXOutputCollector) {
        self.process = process
        self.output = output
    }

    var processIdentifier: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    func forceKill() {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    func stderrTail() -> [String] { MLXServerLogFilter.relevantTail(output.stderrTail, limit: 20) }
}

/// Polls `/v1/models` every 250 ms, then sends two streamed warm-up completions shaped like real
/// suggestions for the exact model id, so the weights and Metal kernels load now, not on the
/// user's first keystroke (about 6 s for Gemma 4 E4B).
nonisolated struct MLXHTTPReadinessProbe: MLXReadinessProbing {
    func waitUntilReady(port: Int, modelID: String, timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        let base = URL(string: "http://127.0.0.1:\(port)/v1")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        while true {
            try Task.checkCancellation()
            if let (_, response) = try? await session.data(from: base.appendingPathComponent("models")),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                break
            }
            guard ContinuousClock.now < deadline else { throw MLXServerError.readinessTimedOut }
            try await Task.sleep(for: .milliseconds(250))
        }

        // Two streamed warm-ups instead of one tiny blocking request. MLX builds its Metal kernels
        // lazily, per tensor shape and per op, and the stop-word state machine is keyed to the
        // request shape. A "Hello" with `stream: false` warms a different path than the first real
        // suggestion (streamed, several hundred prompt tokens, `stop` set), so the first user-visible
        // completion still paid that cost. The first pass uses the real sampling settings with the
        // newline stop word; the second drops `stop` to cover the multi-line path.
        try await warmUp(session: session, base: base, modelID: modelID, stop: ["\n"], deadline: deadline)
        try await warmUp(session: session, base: base, modelID: modelID, stop: nil, deadline: deadline)
    }

    /// A fixed, realistic draft in the shape Cotabby sends: a conditioning preface line, a blank
    /// line, then prose that ends mid-sentence. Its length (about 1,900 characters) is what makes
    /// the warm-up prefill match a real request.
    private static let warmUpPrompt = """
    Format: email; Title: Project status and next steps

    Hi Dana,

    Thanks for sending the revised timeline on Monday. I went through it line by line with the team this \
    morning, and most of the dates hold up well against what we are seeing in the build pipeline. The \
    integration work for the storage layer finished ahead of schedule, which gives us a little room at the \
    end of the month for the reviewer feedback that we always seem to collect late. I still have concerns \
    about the migration step, though. The current plan assumes that every customer account can be moved in a \
    single window on the weekend, but the account export we ran last Thursday took almost twice as long as \
    we estimated, and it only covered about a third of the records. If the remaining records scale the same \
    way, the window will not be long enough, and we would have to split the work across two weekends. That \
    is not a disaster, but it changes who needs to be on call and how we communicate the maintenance notice \
    to customers, so I would like to settle it before we commit to the calendar invitations. Ibrahim has \
    offered to rerun the export with the new indexes enabled, and I think his numbers will tell us quickly \
    whether the single window is realistic. In the meantime, I would suggest we keep the draft schedule as \
    it is, mark the migration as a risk in the tracker, and avoid sending anything to the customer success \
    team until we have the new figures. I know this is not the answer you were hoping for on a Monday \
    morning, and I appreciate that you have been patient while we worked through the details. If it helps, I \
    can join a short call tomorrow to walk through the export log together and agree on the fallback plan \
    before the end of the week, so that everyone leaves the meeting with the same picture of what happens \
    next and who owns each
    """

    /// Sends one streamed completion shaped like a real suggestion and reads it to `[DONE]` or the
    /// end of the stream. The sampling values are the ones `SuggestionConfiguration.standard` sends,
    /// so the server takes the same sampler path. The request timeout is whatever remains of the
    /// readiness deadline, so a slow warm-up cannot outlive the readiness budget.
    private func warmUp(
        session: URLSession,
        base: URL,
        modelID: String,
        stop: [String]?,
        deadline: ContinuousClock.Instant
    ) async throws {
        var body: [String: Any] = [
            "model": modelID,
            "prompt": Self.warmUpPrompt,
            "max_tokens": 8,
            "stream": true,
            "temperature": 0.1,
            "top_p": 0.7,
            "top_k": 20,
            "min_p": 0.08,
            "repetition_penalty": 1.025
        ]
        if let stop { body["stop"] = stop }

        var request = URLRequest(url: base.appendingPathComponent("completions"))
        request.timeoutInterval = Self.remainingSeconds(until: deadline)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw MLXServerError.warmUpFailed(statusCode: status) }
        // The server finishes generation only once the client has read the stream, so drain it.
        for try await line in bytes.lines where line == "data: [DONE]" {
            break
        }
    }

    /// Seconds left until `deadline`, floored at one second so a request is never sent with a zero
    /// timeout, which URLSession would treat as "no timeout" in some configurations.
    private static func remainingSeconds(until deadline: ContinuousClock.Instant) -> TimeInterval {
        let remaining = deadline - ContinuousClock.now
        let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
        return max(1, seconds)
    }
}

extension OpenAICompatibleSuggestionEngine {
    /// The MLX engine: the shared OpenAI-compatible client pointed at Cotabby's own server. The
    /// configuration is read per request, so a request made while the server is loading or
    /// failed throws `.unavailable` with the reason at once: no HTTP, and no fallback engine.
    static func mlx(client: OpenAICompatibleAPIClient, serverManager: MLXServerManager) -> OpenAICompatibleSuggestionEngine {
        OpenAICompatibleSuggestionEngine(
            client: client,
            configurationProvider: { [weak serverManager] in
                guard let serverManager else {
                    throw SuggestionClientError.unavailable("MLX is not running.")
                }
                return try serverManager.readyConfiguration
            },
            apiKeyProvider: { nil },
            backend: .mlx,
            onServerBroken: { [weak serverManager] port, reason in
                serverManager?.reportBroken(port: port, reason: reason)
            }
        )
    }
}
