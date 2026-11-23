import Foundation
import XCTest
@testable import Cotabby

/// A stand-in for `LlamaRuntimeCore.prepare` that never touches llama.cpp. Each load can be held
/// open and released by call order, so a test decides exactly when a model "finishes loading"
/// relative to a model switch or a stop.
final class GatedModelLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var holdsLoads = false
    private var gates: [DispatchSemaphore] = []
    private var started: [String] = []
    private var failureMessages: [String: String] = [:]

    /// Filenames in the order their loads began.
    var startedFilenames: [String] {
        lock.withLock { started }
    }

    /// Every load that starts after this call blocks until `release(call:)` names it.
    func holdLoads() {
        lock.withLock { holdsLoads = true }
    }

    /// Lets the load that started `call`-th (zero-based) finish.
    func release(call: Int) {
        lock.withLock { gates.indices.contains(call) ? gates[call] : nil }?.signal()
    }

    func failLoads(of filename: String, message: String) {
        lock.withLock { failureMessages[filename] = message }
    }

    func load(_ resolvedRuntime: ResolvedLlamaRuntime, _ configuration: LlamaRuntimeConfiguration) throws -> PreparedLlamaRuntime {
        let filename = resolvedRuntime.modelFileURL.lastPathComponent
        let (gate, failureMessage) = lock.withLock { () -> (DispatchSemaphore, String?) in
            started.append(filename)
            // Always created at zero and balanced by exactly one signal: libdispatch traps when
            // a semaphore is released below the value it was created with.
            let gate = DispatchSemaphore(value: 0)
            if !holdsLoads {
                gate.signal()
            }
            gates.append(gate)
            return (gate, failureMessages[filename])
        }
        gate.wait()
        if let failureMessage {
            throw LlamaRuntimeError.unavailable(failureMessage)
        }
        return PreparedLlamaRuntime(
            resolvedRuntime: resolvedRuntime,
            contextWindowTokens: Int(configuration.contextWindowTokens),
            batchSize: Int(configuration.batchSize),
            threadCount: 1,
            gpuLayerCount: 0,
            backendName: "gated test loader"
        )
    }

    /// Plants placeholder `.gguf` files in `directory` and returns a manager whose loads go
    /// through this loader. The files only need to exist for `BundledRuntimeLocator` to list them.
    @MainActor
    func makeManager(in directory: URL, filenames: [String]) throws -> LlamaRuntimeManager {
        for filename in filenames {
            try Data("not a real model".utf8).write(to: directory.appendingPathComponent(filename))
        }
        return TestLifetime.retain(LlamaRuntimeManager(
            configuration: LlamaRuntimeConfiguration(
                runtimeDirectoryPath: directory.path,
                // An empty preferred list keeps discovery ordering purely alphabetical.
                preferredModelNames: [],
                contextWindowTokens: 512,
                batchSize: 128,
                gpuLayerCount: 0
            ),
            runtimeLocator: BundledRuntimeLocator(),
            loadModel: { [self] resolvedRuntime, configuration in
                try load(resolvedRuntime, configuration)
            }
        ))
    }

    /// Polls until the `count`-th load has begun. Loads start on a detached task, so there is no
    /// main-actor signal to await instead.
    func waitForStartedLoads(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<1_000 {
            if startedFilenames.count >= count {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected \(count) load(s) to start, saw \(startedFilenames)", file: file, line: line)
    }
}
