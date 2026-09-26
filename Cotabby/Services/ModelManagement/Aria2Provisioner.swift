import Foundation
import Logging

nonisolated enum Aria2ProvisioningError: LocalizedError, Equatable {
    case homebrewUnavailable
    case installFailed
    case installTimedOut

    var errorDescription: String? {
        switch self {
        case .homebrewUnavailable:
            return "Homebrew is not available, so Cotabby will use its standard downloader."
        case .installFailed:
            return "Homebrew could not install aria2. Cotabby will use its standard downloader."
        case .installTimedOut:
            return "Installing aria2 timed out. Cotabby will use its standard downloader."
        }
    }
}

/// Coalesces one bounded Homebrew installation when aria2c is not already available.
/// A verified standalone macOS artifact is not published by aria2, so Macs without Homebrew
/// deliberately fall back to URLSession instead of copying a dynamically linked bottle binary.
nonisolated final class Aria2Provisioner: @unchecked Sendable {
    typealias BrewLocator = @Sendable () -> URL?
    typealias Installer = @Sendable (URL) async throws -> Bool

    static let shared = Aria2Provisioner()

    private let fileManager: FileManager
    private let brewLocator: BrewLocator
    private let installer: Installer
    private let lock = NSLock()
    private struct ActiveProvision {
        let id: UUID
        let task: Task<URL, Error>
        var waiterCount: Int
    }
    private var activeProvision: ActiveProvision?

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        brewLocator = Self.defaultBrewExecutable
        installer = Self.installWithHomebrew
    }

    init(
        fileManager: FileManager,
        brewLocator: @escaping BrewLocator,
        installer: @escaping Installer
    ) {
        self.fileManager = fileManager
        self.brewLocator = brewLocator
        self.installer = installer
    }

    /// Returns an existing executable or installs aria2 once for all concurrent callers.
    func provisionIfNeeded() async throws -> URL {
        if let existingURL = Aria2Locator.executableURL(fileManager: fileManager) {
            return existingURL
        }

        let selection: (id: UUID, task: Task<URL, Error>) = lock.withLock {
            if var activeProvision {
                activeProvision.waiterCount += 1
                self.activeProvision = activeProvision
                return (activeProvision.id, activeProvision.task)
            }

            let fileManager = self.fileManager
            let brewLocator = self.brewLocator
            let installer = self.installer
            let id = UUID()
            let task = Task<URL, Error> {
                try await Self.performProvision(
                    fileManager: fileManager,
                    brewLocator: brewLocator,
                    installer: installer
                )
            }
            activeProvision = ActiveProvision(id: id, task: task, waiterCount: 1)
            return (id, task)
        }

        let waiter = ProvisioningWaiter(task: selection.task) { [weak self] in
            self?.releaseWaiter(for: selection.id)
        }
        return try await waiter.value()
    }

    /// Releases one caller's claim on the shared install. The subprocess is cancelled only after
    /// the last caller withdraws, so cancelling one model download cannot disrupt another.
    private func releaseWaiter(for id: UUID) {
        let taskToCancel: Task<URL, Error>? = lock.withLock {
            guard var activeProvision, activeProvision.id == id else {
                return nil
            }
            activeProvision.waiterCount -= 1
            if activeProvision.waiterCount == 0 {
                self.activeProvision = nil
                return activeProvision.task
            }
            self.activeProvision = activeProvision
            return nil
        }
        taskToCancel?.cancel()
    }

    private static func performProvision(
        fileManager: FileManager,
        brewLocator: BrewLocator,
        installer: Installer
    ) async throws -> URL {
        guard let brewURL = brewLocator() else {
            throw Aria2ProvisioningError.homebrewUnavailable
        }
        guard try await installer(brewURL),
              let executableURL = Aria2Locator.executableURL(fileManager: fileManager) else {
            throw Aria2ProvisioningError.installFailed
        }

        CotabbyLogger.runtime.info("Installed aria2 with Homebrew at \(executableURL.path)")
        return executableURL
    }

    private static func defaultBrewExecutable() -> URL? {
        let fileManager = FileManager.default
        let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func installWithHomebrew(_ brewURL: URL) async throws -> Bool {
        try await installWithHomebrew(brewURL, timeout: .seconds(120))
    }

    static func installWithHomebrew(_ brewURL: URL, timeout: Duration) async throws -> Bool {
        let process = Process()
        process.executableURL = brewURL
        process.arguments = ["install", "aria2"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        var environment = ProcessInfo.processInfo.environment
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["NONINTERACTIVE"] = "1"
        process.environment = environment

        let execution = BlockingProcessExecution(process: process)
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Int32.self) { group in
                group.addTask {
                    try await Task.detached(priority: .utility) {
                        try execution.runAndWait()
                    }.value
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw Aria2ProvisioningError.installTimedOut
                }

                defer {
                    group.cancelAll()
                    execution.cancel()
                }
                guard let status = try await group.next() else {
                    throw Aria2ProvisioningError.installFailed
                }
                try Task.checkCancellation()
                return status == 0
            }
        } onCancel: {
            execution.cancel()
        }
    }
}

/// Gives each caller an independently cancellable wait on one shared provisioning task.
/// Its small lock-protected state machine closes the race where cancellation arrives before the
/// checked continuation is installed, while `didFinish` releases the caller's shared-task lease once.
nonisolated private final class ProvisioningWaiter: @unchecked Sendable {
    private typealias Continuation = CheckedContinuation<URL, Error>

    private enum State {
        case waiting
        case suspended(Continuation)
        case finished(Result<URL, Error>)
    }

    private let task: Task<URL, Error>
    private let didFinish: @Sendable () -> Void
    private let lock = NSLock()
    private var state = State.waiting

    init(
        task: Task<URL, Error>,
        didFinish: @escaping @Sendable () -> Void
    ) {
        self.task = task
        self.didFinish = didFinish
    }

    func value() async throws -> URL {
        let observer = Task { [weak self, task] in
            let result: Result<URL, Error>
            do {
                result = .success(try await task.value)
            } catch {
                result = .failure(error)
            }
            self?.finish(with: result)
        }
        defer { observer.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let completedResult: Result<URL, Error>? = lock.withLock {
                    switch state {
                    case .waiting:
                        state = .suspended(continuation)
                        return nil
                    case .finished(let result):
                        return result
                    case .suspended:
                        preconditionFailure("A provisioning waiter can only be awaited once")
                    }
                }
                if let completedResult {
                    continuation.resume(with: completedResult)
                }
            }
        } onCancel: {
            finish(with: .failure(CancellationError()))
        }
    }

    private func finish(with result: Result<URL, Error>) {
        let completion: (continuation: Continuation?, didTransition: Bool) = lock.withLock {
            switch state {
            case .waiting:
                state = .finished(result)
                return (nil, true)
            case .suspended(let continuation):
                state = .finished(result)
                return (continuation, true)
            case .finished:
                return (nil, false)
            }
        }
        guard completion.didTransition else {
            return
        }
        completion.continuation?.resume(with: result)
        didFinish()
    }
}

/// Runs the blocking `waitUntilExit` call on a detached worker and closes cancellation races.
nonisolated private final class BlockingProcessExecution: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var cancellationRequested = false

    init(process: Process) {
        self.process = process
    }

    func runAndWait() throws -> Int32 {
        try lock.withLock {
            if cancellationRequested {
                throw CancellationError()
            }
            try process.run()
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    func cancel() {
        lock.withLock {
            cancellationRequested = true
            if process.isRunning {
                process.terminate()
            }
        }
    }
}
