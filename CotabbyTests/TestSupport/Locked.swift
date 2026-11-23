import Foundation

/// A value guarded by a lock, for test state written from a background queue or `@Sendable`
/// closure and read back by the test. `@unchecked Sendable` is sound because every access to the
/// stored value goes through the lock.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        lock.withLock { stored }
    }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try lock.withLock { try body(&stored) }
    }
}
