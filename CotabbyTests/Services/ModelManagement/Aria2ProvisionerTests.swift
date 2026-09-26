import XCTest
@testable import Cotabby

final class Aria2ProvisionerTests: XCTestCase {
    func test_aria2ProvisioningError_errorDescription() {
        XCTAssertEqual(
            Aria2ProvisioningError.homebrewUnavailable.errorDescription,
            "Homebrew is not available, so Cotabby will use its standard downloader."
        )
        XCTAssertEqual(
            Aria2ProvisioningError.installFailed.errorDescription,
            "Homebrew could not install aria2. Cotabby will use its standard downloader."
        )
        XCTAssertEqual(
            Aria2ProvisioningError.installTimedOut.errorDescription,
            "Installing aria2 timed out. Cotabby will use its standard downloader."
        )
    }

    func test_provisioner_returnsExistingURLIfAvailable() async throws {
        let stub = StubExecutableFileManager()
        stub.executablePaths = ["/opt/homebrew/bin/aria2c"]
        let provisioner = Aria2Provisioner(fileManager: stub)

        let url = try await provisioner.provisionIfNeeded()
        XCTAssertEqual(url.path, "/opt/homebrew/bin/aria2c")
    }

    func test_provisioner_reportsUnavailableWhenHomebrewIsMissing() async {
        let provisioner = Aria2Provisioner(
            fileManager: StubExecutableFileManager(),
            brewLocator: { nil },
            installer: { _ in false }
        )

        do {
            _ = try await provisioner.provisionIfNeeded()
            XCTFail("Expected Homebrew-unavailable error")
        } catch let error as Aria2ProvisioningError {
            XCTAssertEqual(error, .homebrewUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_provisioner_returnsInstalledExecutable() async throws {
        let stub = StubExecutableFileManager()
        let brewURL = URL(fileURLWithPath: "/mock/bin/brew")
        let provisioner = Aria2Provisioner(
            fileManager: stub,
            brewLocator: { brewURL },
            installer: { _ in
                stub.executablePaths = ["/opt/homebrew/bin/aria2c"]
                return true
            }
        )

        let url = try await provisioner.provisionIfNeeded()
        XCTAssertEqual(url.path, "/opt/homebrew/bin/aria2c")
    }

    func test_provisioner_reportsFailedInstallWhenExecutableIsStillMissing() async {
        let brewURL = URL(fileURLWithPath: "/mock/bin/brew")
        let provisioner = Aria2Provisioner(
            fileManager: StubExecutableFileManager(),
            brewLocator: { brewURL },
            installer: { _ in true }
        )

        do {
            _ = try await provisioner.provisionIfNeeded()
            XCTFail("Expected install-failed error")
        } catch let error as Aria2ProvisioningError {
            XCTAssertEqual(error, .installFailed)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_provisioner_keepsSharedInstallAliveWhenOneCallerCancels() async throws {
        let stub = StubExecutableFileManager()
        let brewURL = URL(fileURLWithPath: "/mock/bin/brew")
        let installerStarted = expectation(description: "installer started")
        let gate = AsyncTestGate()
        let installCount = LockedCounter()
        let provisioner = Aria2Provisioner(
            fileManager: stub,
            brewLocator: { brewURL },
            installer: { _ in
                installCount.increment()
                installerStarted.fulfill()
                await gate.wait()
                try Task.checkCancellation()
                stub.executablePaths = ["/opt/homebrew/bin/aria2c"]
                return true
            }
        )

        let cancelledCaller = Task { try await provisioner.provisionIfNeeded() }
        await fulfillment(of: [installerStarted], timeout: 1)
        let survivingCaller = Task { try await provisioner.provisionIfNeeded() }
        try await Task.sleep(for: .milliseconds(20))

        cancelledCaller.cancel()
        do {
            _ = try await cancelledCaller.value
            XCTFail("Expected the first caller to observe cancellation")
        } catch is CancellationError {
            // The shared installer must continue for the surviving caller.
        }

        await gate.open()
        let resolvedURL = try await survivingCaller.value

        XCTAssertEqual(resolvedURL.path, "/opt/homebrew/bin/aria2c")
        XCTAssertEqual(installCount.value, 1)
    }

    func test_homebrewInstallReturnsProcessStatus() async throws {
        let successfulExecutable = try makeExecutableScript("exit 0")
        let failingExecutable = try makeExecutableScript("exit 9")
        defer { removeFixtures(successfulExecutable, failingExecutable) }

        let succeeded = try await Aria2Provisioner.installWithHomebrew(
            successfulExecutable,
            timeout: .seconds(1)
        )
        let failed = try await Aria2Provisioner.installWithHomebrew(
            failingExecutable,
            timeout: .seconds(1)
        )

        XCTAssertTrue(succeeded)
        XCTAssertFalse(failed)
    }

    func test_homebrewInstallTimesOutAndTerminatesProcess() async throws {
        let executable = try makeExecutableScript(
            "trap 'exit 0' TERM; while true; do sleep 0.05; done"
        )
        defer { removeFixtures(executable) }

        do {
            _ = try await Aria2Provisioner.installWithHomebrew(
                executable,
                timeout: .milliseconds(50)
            )
            XCTFail("Expected timeout")
        } catch let error as Aria2ProvisioningError {
            XCTAssertEqual(error, .installTimedOut)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_homebrewInstallRespondsToTaskCancellation() async throws {
        let executable = try makeExecutableScript(
            "trap 'exit 0' TERM; while true; do sleep 0.05; done"
        )
        defer { removeFixtures(executable) }
        let task = Task {
            try await Aria2Provisioner.installWithHomebrew(
                executable,
                timeout: .seconds(5)
            )
        }

        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: the process is terminated by the installer's cancellation handler.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeExecutableScript(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-brew-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func removeFixtures(_ urls: URL...) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

private actor AsyncTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pendingWaiters = waiters
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.resume()
        }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock {
            count += 1
        }
    }
}
