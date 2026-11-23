import Foundation

/// Runs a main-actor body synchronously from a nonisolated XCTest method.
///
/// XCTest invokes synchronous test methods on the main thread, so `assumeIsolated` is normally all
/// that is needed; the `DispatchQueue.main.sync` branch covers a body reached from a background
/// queue. Suites use this instead of `async` test methods when the object under test must not be
/// touched from a Swift concurrency task.
func runOnMainActor<Result>(
    _ body: @MainActor () throws -> Result
) rethrows -> Result {
    if Thread.isMainThread {
        return try MainActor.assumeIsolated(body)
    }

    return try DispatchQueue.main.sync {
        try MainActor.assumeIsolated(body)
    }
}

/// Keeps test-created objects alive until the test process exits.
///
/// App-hosted tests on macOS 15 can over-release `@MainActor` instances in Swift's back-deployed
/// isolated-deinit shim, crashing the runner when a short-lived production object is deallocated
/// at the end of a test. Retaining the object sidesteps the deinit entirely. Production ownership
/// is unchanged, and a test must still stop or cancel whatever the object started, because nothing
/// ends that work at deinit any more.
///
/// A value that only holds objects, such as the coordinator rig's fixture graph, is retained whole,
/// which keeps every object it references alive.
enum TestLifetime {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var retained: [Any] = []

    @discardableResult
    static func retain<Value>(_ value: Value) -> Value {
        lock.withLock { retained.append(value) }
        return value
    }
}
