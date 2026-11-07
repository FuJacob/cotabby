import CryptoKit
import Foundation
import XCTest
@testable import Cotabby

/// Pins the memory controller's lifecycle around engines that take a while to start: a start
/// made stale by a stop or a newer start never attaches (two engines never run on one store), and
/// stored memory can be deleted while memory is off, with no engine or model involved.
///
/// The engine factory is injected: the engines here are opened without loading a model, and the
/// first one can be held back to stand in for a slow model load.
@MainActor
final class MemoryEngineControllerTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("memory-controller-\(UUID().uuidString)")
        let paths = MemoryPaths(root: root)
        try FileManager.default.createDirectory(at: paths.modelsDirectory, withIntermediateDirectories: true)
        // The controller only checks that the model file is there.
        FileManager.default.createFile(
            atPath: paths.modelsDirectory.appendingPathComponent(MemoryEngineController.embeddingModel.filename).path,
            contents: Data("GGUF".utf8)
        )
        suiteName = "memory-controller-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    private func makeController(factory: @escaping MemoryEngineController.EngineFactory) -> MemoryEngineController {
        let controller = MemoryEngineController(
            paths: MemoryPaths(root: root), userDefaults: defaults, keyStore: FixedKeyStore(),
            isOnACPower: { true }, makeEngine: factory
        )
        Self.retained.append(controller)
        return controller
    }

    /// Off and on again while the first engine is still starting: the first one, arriving late, is
    /// stopped instead of replacing the second.
    func test_aStartMadeStaleByAStopNeverAttaches() async throws {
        let gate = Gate()
        let made = EngineLog()
        let controller = makeController { paths, key, modelURL, conditions in
            let engine = try MemoryEngine(paths: paths, rootKey: key, modelURL: modelURL, conditions: conditions)
            if made.append(engine) == 1 { gate.wait() }
            return engine
        }
        controller.setEnabled(true)
        try await waitUntil { made.count == 1 }
        controller.setEnabled(false)
        controller.setEnabled(true)
        try await waitUntil { controller.state == .running }
        let second = try XCTUnwrap(controller.engine)
        gate.open()
        try await waitUntil { made.first?.isStopped == true }
        XCTAssertTrue(controller.engine === second, "the late engine never replaces the running one")
        XCTAssertFalse(second.isStopped)
        XCTAssertEqual(made.count, 2)
    }

    /// Memory switched off still lets the user delete what it stored; nothing starts.
    func test_storedMemoryCanBeDeletedWhileMemoryIsOff() async throws {
        let made = EngineLog()
        let controller = makeController { paths, key, modelURL, conditions in
            let engine = try MemoryEngine(paths: paths, rootKey: key, modelURL: modelURL, conditions: conditions)
            made.append(engine)
            return engine
        }
        let store = MemoryEngine.Paths(dataDirectory: MemoryPaths(root: root).dataDirectory).store
        try FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: store.path, contents: Data("db".utf8))
        FileManager.default.createFile(atPath: store.path + "-wal", contents: Data("wal".utf8))
        XCTAssertTrue(controller.hasStoredMemory)

        await controller.deleteMemoryData().value
        XCTAssertFalse(controller.hasStoredMemory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path + "-wal"))
        XCTAssertEqual(controller.state, .disabled)
        XCTAssertEqual(made.count, 0, "deleting needs no engine")
    }

    private struct TimedOut: Error {}

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out", file: file, line: line)
                throw TimedOut()
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static var retained: [AnyObject] = []
}

/// A key store with one fixed key (no Keychain).
private nonisolated struct FixedKeyStore: TypingHistoryKeyStore {
    func existingKey() throws -> SymmetricKey? { SymmetricKey(data: Data(0..<32)) }
    func createKey() throws -> SymmetricKey { SymmetricKey(data: Data(0..<32)) }
    func deleteKey() throws {}
}

/// Holds the first engine's start back until the test opens it.
private nonisolated final class Gate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func wait() { semaphore.wait() }
    func open() { semaphore.signal() }
}

/// The engines the factory made, in order.
private nonisolated final class EngineLog: @unchecked Sendable {
    private let lock = NSLock()
    private var engines: [MemoryEngine] = []

    @discardableResult
    func append(_ engine: MemoryEngine) -> Int {
        lock.lock()
        defer { lock.unlock() }
        engines.append(engine)
        return engines.count
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return engines.count
    }

    var first: MemoryEngine? {
        lock.lock()
        defer { lock.unlock() }
        return engines.first
    }
}
