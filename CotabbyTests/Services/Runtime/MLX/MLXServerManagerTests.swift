import Darwin
import XCTest
@testable import Cotabby

@MainActor
final class MLXServerManagerTests: XCTestCase {
    private static var retained: [AnyObject] = []
    private var root: URL!
    private var paths: MLXPaths!
    private var launcher: MLXFakeLauncher!
    private var probe: MLXFakeProbe!
    private var sleeps: [Duration] = []
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    private let launchA = MLXServerLaunch(
        executable: URL(fileURLWithPath: "/mlx/bin/mlx_lm.server"), modelID: "mlx-community/a", promptCacheBytes: 1 << 30)
    private let launchB = MLXServerLaunch(
        executable: URL(fileURLWithPath: "/mlx/bin/mlx_lm.server"), modelID: "mlx-community/b", promptCacheBytes: 1 << 30)
    private let launchC = MLXServerLaunch(
        executable: URL(fileURLWithPath: "/mlx/bin/mlx_lm.server"), modelID: "mlx-community/c", promptCacheBytes: 1 << 30)

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mlx-server-\(UUID().uuidString)")
        paths = MLXPaths(root: root)
        launcher = MLXFakeLauncher()
        probe = MLXFakeProbe()
        sleeps = []
        Self.retained.append(contentsOf: [launcher!, probe!] as [AnyObject])
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// `sleep` overrides the recording, yielding sleep. A sleep that never returns keeps a restart
    /// pending, which lets a test freeze the state between a crash and its restart.
    private func makeManager(
        sleep: MLXServerManager.Sleep? = nil,
        verifyListener: @escaping (Int32, Int) -> Bool = { _, _ in true }
    ) -> MLXServerManager {
        let manager = MLXServerManager(
            paths: paths,
            launcher: launcher,
            probe: probe,
            pickPort: { 50123 },
            sleep: sleep ?? { [unowned self] duration in
                self.sleeps.append(duration)
                await Task.yield()
            },
            now: { [unowned self] in self.clock },
            baseEnvironment: ["HOME": "/Users/u", "PYTHONPATH": "/evil"],
            verifyListener: verifyListener
        )
        Self.retained.append(manager)
        return manager
    }

    private func isReady(_ manager: MLXServerManager) -> Bool {
        if case .ready = manager.state { return true }
        return false
    }

    private func startReady(_ manager: MLXServerManager, _ launch: MLXServerLaunch) async {
        await manager.apply(.running(launch))
        await waitUntil { self.probe.waiting >= 1 }
        probe.succeedNext()
        await waitUntil { self.isReady(manager) }
    }

    func test_startLaunchesTheExactCommandAndBecomesReady() async throws {
        let manager = makeManager()
        await manager.apply(.running(launchA))
        XCTAssertEqual(manager.state, .starting(modelID: "mlx-community/a"))
        let launch = try XCTUnwrap(launcher.launches.first)
        XCTAssertEqual(launch.executable.path, "/mlx/bin/mlx_lm.server")
        XCTAssertEqual(launch.arguments, MLXToolchainRules.serverArguments(
            modelID: "mlx-community/a", port: 50123, promptCacheBytes: 1 << 30))
        XCTAssertEqual(launch.environment["HF_HUB_OFFLINE"], "1")
        XCTAssertNil(launch.environment["PYTHONPATH"])
        XCTAssertEqual(MLXServerPIDFile(url: paths.serverPIDFile).read(), 1000)

        XCTAssertThrowsError(try manager.readyConfiguration) { error in
            XCTAssertEqual(error.localizedDescription, "MLX is loading mlx-community/a…")
        }
        await waitUntil { self.probe.waiting == 1 }
        probe.succeedNext()
        await waitUntil { manager.state == .ready(port: 50123, modelID: "mlx-community/a") }
        let configuration = try manager.readyConfiguration
        XCTAssertEqual(configuration.baseURL.absoluteString, "http://127.0.0.1:50123/v1")
        XCTAssertEqual(configuration.modelName, "mlx-community/a")
        XCTAssertEqual(configuration.apiMode, .completions)
    }

    func test_sameDesireAgainDoesNotRelaunch() async {
        let manager = makeManager()
        await startReady(manager, launchA)
        await manager.apply(.running(launchA))
        XCTAssertEqual(launcher.launches.count, 1)
    }

    func test_modelChangeStopsTheOldServerAndStartsTheNew() async {
        let manager = makeManager()
        await startReady(manager, launchA)
        await manager.apply(.running(launchB))
        XCTAssertEqual(launcher.launches[0].process.terminateCount, 1)
        XCTAssertEqual(launcher.launches.count, 2)
        XCTAssertEqual(manager.state, .starting(modelID: "mlx-community/b"))
    }

    func test_stopSendsTermThenKillAfterTheGracePeriod() async {
        launcher.exitsOnTerminate = false
        let manager = makeManager()
        await startReady(manager, launchA)
        await manager.apply(.stopped)
        let process = launcher.launches[0].process
        XCTAssertEqual(process.terminateCount, 1)
        XCTAssertEqual(process.killCount, 1)
        XCTAssertEqual(sleeps, Array(repeating: .milliseconds(100), count: 30))
        XCTAssertEqual(manager.state, .idle)
        XCTAssertNil(MLXServerPIDFile(url: paths.serverPIDFile).read())
    }

    func test_aCooperativeServerIsNotKilled() async {
        let manager = makeManager()
        await startReady(manager, launchA)
        await manager.apply(.stopped)
        XCTAssertEqual(launcher.launches[0].process.killCount, 0)
        XCTAssertTrue(sleeps.isEmpty)
    }

    func test_crashesRestartWithBackoffAndTheThirdWithinTwoMinutesFails() async {
        let manager = makeManager()
        await startReady(manager, launchA)

        launcher.crash(0)
        await waitUntil { self.launcher.launches.count == 2 }
        XCTAssertEqual(sleeps, [.seconds(1)])

        clock += 10
        launcher.crash(1)
        await waitUntil { self.launcher.launches.count == 3 }
        XCTAssertEqual(sleeps, [.seconds(1), .seconds(5)])

        clock += 10
        launcher.launches[2].process.tail = ["Traceback", "boom"]
        launcher.crash(2)
        await waitUntil { if case .failed = manager.state { return true } else { return false } }
        XCTAssertEqual(manager.state, .failed(reason: "MLX stopped unexpectedly (exit status 1).",
                                              logTail: ["Traceback", "boom"]))
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(launcher.launches.count, 3, "no restarts after failing")
    }

    func test_threeConsecutiveSlowFailuresFail() async {
        let manager = makeManager()
        await startReady(manager, launchA)
        for index in 0..<3 {
            clock += 121
            launcher.crash(index)
            if index < 2 { await waitUntil { self.launcher.launches.count == index + 2 } }
        }
        await waitUntil { if case .failed = manager.state { return true } else { return false } }
        XCTAssertEqual(sleeps, [.seconds(1), .seconds(5)])
        XCTAssertEqual(launcher.launches.count, 3, "no restart after the third consecutive failure")
    }

    func test_retryAfterFailureStartsAgain() async {
        let manager = makeManager()
        await startReady(manager, launchA)
        for index in 0..<3 {
            launcher.crash(index)
            if index < 2 { await waitUntil { self.launcher.launches.count == index + 2 } }
        }
        await waitUntil { if case .failed = manager.state { return true } else { return false } }
        await manager.apply(.running(launchA))
        XCTAssertEqual(launcher.launches.count, 3, "the same desire does not leave the failed state")
        await manager.retry()
        XCTAssertEqual(launcher.launches.count, 4)
        XCTAssertEqual(manager.state, .starting(modelID: "mlx-community/a"))
    }

    /// Review focus 1.
    func test_stopWhileStartingTerminatesAndIgnoresLateReadiness() async {
        let manager = makeManager()
        await manager.apply(.running(launchA))
        await waitUntil { self.probe.waiting == 1 }
        await manager.apply(.stopped)
        XCTAssertEqual(launcher.launches[0].process.terminateCount, 1)
        probe.succeedNext()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(manager.state, .idle)
    }

    func test_readinessFailureTerminatesAndRestarts() async {
        let manager = makeManager()
        await manager.apply(.running(launchA))
        await waitUntil { self.probe.waiting == 1 }
        probe.failNext()
        await waitUntil { self.launcher.launches.count == 2 }
        XCTAssertEqual(launcher.launches[0].process.terminateCount, 1)
        XCTAssertEqual(sleeps, [.seconds(1)])
    }

    func test_unavailableDesirePublishesTheReasonWithoutLaunching() async {
        let manager = makeManager()
        await manager.apply(.unavailable(.noModel))
        XCTAssertEqual(manager.state, .unavailable(.noModel))
        XCTAssertTrue(launcher.launches.isEmpty)
        XCTAssertThrowsError(try manager.readyConfiguration) { error in
            XCTAssertEqual(error.localizedDescription, MLXUnavailableReason.noModel.message)
        }
    }

    func test_shutdownSyncKillsAStubbornServer() async {
        launcher.exitsOnTerminate = false
        let manager = makeManager()
        await startReady(manager, launchA)
        manager.shutdownSync(timeoutSeconds: 0.05)
        XCTAssertEqual(launcher.launches[0].process.terminateCount, 1)
        XCTAssertEqual(launcher.launches[0].process.killCount, 1)
        XCTAssertEqual(manager.state, .idle)
    }

    func test_orphanCleanupOnlySignalsOurOwnServer() async {
        let manager = makeManager()
        let pidFile = MLXServerPIDFile(url: paths.serverPIDFile)
        var signals: [Int32] = []

        pidFile.write(pid: 4242)
        await manager.cleanUpOrphan(isAlive: { _ in true }, arguments: { _ in ["/usr/bin/vim"] },
                                    signal: { _, signal in signals.append(signal) })
        XCTAssertEqual(signals, [])
        XCTAssertNil(pidFile.read())

        pidFile.write(pid: 4242)
        await manager.cleanUpOrphan(
            isAlive: { _ in true },
            arguments: { _ in ["/p/python", "/x/MLX/bin/mlx_lm.server", "--host", "127.0.0.1", "--port", "9"] },
            signal: { _, signal in signals.append(signal) })
        XCTAssertEqual(signals, [SIGTERM, SIGKILL])
        XCTAssertNil(pidFile.read())
    }

    func test_loopbackPortIsUsable() throws {
        let port = try MLXLoopbackPort.next()
        XCTAssertTrue((1024...65535).contains(port))
    }

    /// Review fix 1: a crash clears `current` while the probe is still suspended. The probe's later
    /// success must not publish `.ready` for a process that no longer exists.
    func test_lateReadinessAfterACrashIsIgnored() async {
        let manager = makeManager(sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        await manager.apply(.running(launchA))
        await waitUntil { self.probe.waiting == 1 }
        launcher.crash(0)
        probe.succeedNext()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(manager.state, .starting(modelID: "mlx-community/a"))
        XCTAssertEqual(launcher.launches.count, 1, "the restart is still pending, so nothing relaunched")
    }

    /// Review fix 2: stopping A waits out its grace period. Meanwhile C starts and writes its pid.
    /// A's late cleanup must leave C's pid file alone.
    func test_stoppingAnOldServerKeepsTheNewServersPidFile() async {
        launcher.exitsOnTerminate = false
        let gate = SleepGate()
        let manager = makeManager(sleep: { _ in await gate.pause() })
        await startReady(manager, launchA)
        let stopping = Task { await manager.apply(.running(launchB)) }
        await waitUntil { gate.count == 1 }
        // A is frozen inside its grace period. C takes over, then A exits and its cleanup runs.
        await manager.apply(.running(launchC))
        launcher.launches[0].process.isRunning = false
        gate.releaseAll()
        await stopping.value

        XCTAssertEqual(launcher.launches.count, 2, "B was superseded before it launched")
        XCTAssertEqual(launcher.launches[1].arguments[1], "mlx-community/c")
        XCTAssertEqual(MLXServerPIDFile(url: paths.serverPIDFile).read(), launcher.launches[1].process.processIdentifier)
    }

    /// Review fix 3: the pid file names the live server, so orphan cleanup must not treat it as one.
    func test_orphanCleanupLeavesTheCurrentServersPidFile() async {
        let manager = makeManager()
        await startReady(manager, launchA)
        var signals: [Int32] = []
        await manager.cleanUpOrphan(
            isAlive: { _ in true },
            arguments: { _ in ["/p/python", "/x/MLX/bin/mlx_lm.server", "--host", "127.0.0.1"] },
            signal: { _, signal in signals.append(signal) })
        XCTAssertEqual(signals, [])
        XCTAssertEqual(MLXServerPIDFile(url: paths.serverPIDFile).read(), 1000)
    }

    /// Review fix 4: app quit during a stop must still reach the process being stopped.
    func test_shutdownSyncKillsAServerThatIsStillStopping() async {
        launcher.exitsOnTerminate = false
        let gate = SleepGate()
        let manager = makeManager(sleep: { _ in await gate.pause() })
        await startReady(manager, launchA)
        let stopping = Task { await manager.apply(.stopped) }
        await waitUntil { gate.count == 1 }
        manager.shutdownSync(timeoutSeconds: 0.05)
        XCTAssertEqual(launcher.launches[0].process.killCount, 1, "only shutdown can kill it: the stop is frozen")
        gate.releaseAll()
        await stopping.value
        XCTAssertEqual(launcher.launches[0].process.killCount, 1, "the resumed stop does not kill it twice")
        XCTAssertEqual(manager.state, .idle)
    }

    /// Review fix 6: a readiness answer from a process that does not own the port is refused.
    func test_readinessFromAForeignListenerIsRejected() async {
        let manager = makeManager(verifyListener: { _, _ in false })
        await manager.apply(.running(launchA))
        await waitUntil { self.probe.waiting == 1 }
        probe.succeedNext()
        await waitUntil { self.launcher.launches[0].process.terminateCount == 1 }
        XCTAssertFalse(isReady(manager))
        XCTAssertEqual(manager.state, .starting(modelID: "mlx-community/a"), "a restart follows the failure")
    }

    /// Proves the libproc port check against a real socket this test process owns.
    func test_ownsTCPSocketFindsOurOwnListener() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(listener, 1), 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        let port = Int(UInt16(bigEndian: address.sin_port))

        XCTAssertTrue(MLXProcessInspector.ownsTCPSocket(pid: getpid(), port: port))
        XCTAssertFalse(MLXProcessInspector.ownsTCPSocket(pid: getpid(), port: port == 1 ? 2 : 1))
    }
}

/// Holds each stop-grace sleep until the test releases it, so a stop can be frozen mid-grace.
@MainActor
final class SleepGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    var count: Int { waiting.count }

    func pause() async {
        await withCheckedContinuation { waiting.append($0) }
    }

    func releaseAll() {
        let released = waiting
        waiting = []
        released.forEach { $0.resume() }
    }
}

// The three doubles below are internal (not private) so `MLXEngineWiringTests` can reuse them.

@MainActor
final class MLXFakeProcess: MLXRunningProcess {
    let processIdentifier: Int32
    var isRunning = true
    var exitsOnTerminate = true
    var tail: [String] = []
    private(set) var terminateCount = 0
    private(set) var killCount = 0

    init(pid: Int32) { processIdentifier = pid }

    func terminate() {
        terminateCount += 1
        if exitsOnTerminate { isRunning = false }
    }

    func forceKill() {
        killCount += 1
        isRunning = false
    }

    func stderrTail() -> [String] { tail }
}

@MainActor
final class MLXFakeLauncher: MLXProcessLaunching {
    struct Launch {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
        let process: MLXFakeProcess
        let onExit: @MainActor (Int32) -> Void
    }

    private(set) var launches: [Launch] = []
    var exitsOnTerminate = true

    func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        onExit: @escaping @MainActor (Int32) -> Void
    ) throws -> any MLXRunningProcess {
        let process = MLXFakeProcess(pid: Int32(1000 + launches.count))
        process.exitsOnTerminate = exitsOnTerminate
        launches.append(Launch(executable: executable, arguments: arguments, environment: environment,
                               process: process, onExit: onExit))
        return process
    }

    /// Simulates launch `index` dying on its own.
    func crash(_ index: Int, status: Int32 = 1) {
        launches[index].process.isRunning = false
        launches[index].onExit(status)
    }
}

/// Each readiness wait suspends until the test resolves it, so tests control exactly when (and
/// whether) a server becomes ready, including after it was stopped.
@MainActor
final class MLXFakeProbe: MLXReadinessProbing {
    private var pending: [CheckedContinuation<Void, Error>] = []
    var waiting: Int { pending.count }

    func waitUntilReady(port: Int, modelID: String, timeout: Duration) async throws {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }

    func succeedNext() { pending.removeFirst().resume() }
    func failNext() { pending.removeFirst().resume(throwing: MLXServerError.readinessTimedOut) }
}

// MARK: - reportBroken (generator died while the process stayed up)

@MainActor
final class MLXServerManagerBrokenGeneratorTests: XCTestCase {
    private static var retained: [AnyObject] = []
    private var root: URL!
    private var launcher: MLXFakeLauncher!
    private var probe: MLXFakeProbe!
    private var sleeps: [Duration] = []
    private let launch = MLXServerLaunch(
        executable: URL(fileURLWithPath: "/mlx/bin/mlx_lm.server"), modelID: "mlx-community/a", promptCacheBytes: 1 << 30)

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mlx-broken-\(UUID().uuidString)")
        launcher = MLXFakeLauncher()
        probe = MLXFakeProbe()
        sleeps = []
        Self.retained.append(contentsOf: [launcher!, probe!] as [AnyObject])
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeManager() -> MLXServerManager {
        let manager = MLXServerManager(
            paths: MLXPaths(root: root), launcher: launcher, probe: probe, pickPort: { 50123 },
            sleep: { [unowned self] duration in self.sleeps.append(duration); await Task.yield() },
            now: { Date(timeIntervalSince1970: 1_000_000) }, baseEnvironment: [:],
            verifyListener: { _, _ in true })
        Self.retained.append(manager)
        return manager
    }

    private func isReady(_ manager: MLXServerManager) -> Bool {
        if case .ready = manager.state { return true }
        return false
    }

    private func startReady(_ manager: MLXServerManager) async {
        await manager.apply(.running(launch))
        await waitUntil { self.probe.waiting >= 1 }
        probe.succeedNext()
        await waitUntil { self.isReady(manager) }
    }

    private func becomeReadyAgain(_ manager: MLXServerManager, launches: Int) async {
        await waitUntil { self.launcher.launches.count == launches }
        await waitUntil { self.probe.waiting >= 1 }
        probe.succeedNext()
        await waitUntil { self.isReady(manager) }
    }

    func test_reportBrokenTerminatesAndRelaunchesAfterOneSecond() async {
        let manager = makeManager()
        await startReady(manager)
        manager.reportBroken(port: 50123, reason: "HTTP 404")
        await waitUntil { self.launcher.launches.count == 2 }
        XCTAssertEqual(launcher.launches[0].process.terminateCount, 1)
        XCTAssertEqual(sleeps.first, .seconds(1))
        XCTAssertEqual(MLXServerPIDFile(url: MLXPaths(root: root).serverPIDFile).read(), 1001)
        // The old process's exit callback must not count a second failure.
        launcher.launches[0].onExit(15)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(launcher.launches.count, 2)
    }

    func test_thirdReportFailsWithTheReasonAndTail() async {
        let manager = makeManager()
        await startReady(manager)
        manager.reportBroken(port: 50123, reason: "HTTP 404")
        await becomeReadyAgain(manager, launches: 2)
        manager.reportBroken(port: 50123, reason: "HTTP 404")
        await becomeReadyAgain(manager, launches: 3)
        launcher.launches[2].process.tail = ["mlx_lm.server generation thread died: boom"]
        manager.reportBroken(port: 50123, reason: "HTTP 404")
        await waitUntil { if case .failed = manager.state { return true } else { return false } }
        XCTAssertEqual(manager.state, .failed(
            reason: "MLX's generator stopped working: HTTP 404",
            logTail: ["mlx_lm.server generation thread died: boom"]))
        XCTAssertEqual(sleeps.filter { $0 == .seconds(1) }.count, 2)
    }

    func test_aReportForAnotherPortIsIgnored() async {
        let manager = makeManager()
        await startReady(manager)
        manager.reportBroken(port: 49999, reason: "HTTP 404")
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(isReady(manager))
        XCTAssertEqual(launcher.launches[0].process.terminateCount, 0)
    }

    func test_aReportWhileStartingIsIgnored() async {
        let manager = makeManager()
        await manager.apply(.running(launch))
        XCTAssertEqual(manager.state, .starting(modelID: "mlx-community/a"))
        manager.reportBroken(port: 50123, reason: "HTTP 404")
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(launcher.launches[0].process.terminateCount, 0)
        XCTAssertEqual(manager.state, .starting(modelID: "mlx-community/a"))
    }

    func test_aSecondReportDuringTheRestartDoesNotCountAgain() async {
        let manager = makeManager()
        await startReady(manager)
        manager.reportBroken(port: 50123, reason: "HTTP 404")
        manager.reportBroken(port: 50123, reason: "HTTP 404")
        await waitUntil { self.launcher.launches.count == 2 }
        XCTAssertEqual(launcher.launches[0].process.terminateCount, 1)
        XCTAssertEqual(sleeps.filter { $0 == .seconds(1) }.count, 1)
    }
}
