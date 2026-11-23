/// Pure state machine for the short Tab-ownership window after a suggestion is exhausted.
///
/// The coordinator owns one instance for its lifetime and supplies the side effects: installing the
/// input interception, scheduling the timeout, and accepting a regenerated continuation. Keeping
/// those effects outside this value makes the hard rules explicit: only one accept may be queued,
/// every arm invalidates older timeout callbacks, and consuming or clearing the window is atomic.
struct PostExhaustionAcceptanceState: Equatable {
    /// A queued accept only exists inside an open window, so the two facts are one value.
    private enum Window: Equatable {
        case closed
        case armed
        case armedWithQueuedAccept
    }

    private(set) var backstopGeneration: UInt64 = 0
    private var window: Window = .closed

    /// Whether Cotabby still owns Tab for a continuation that has not appeared yet.
    var isArmed: Bool {
        window != .closed
    }

    var hasQueuedAccept: Bool {
        window == .armedWithQueuedAccept
    }

    /// Opens a fresh window and returns the identity its timeout callback must capture.
    @discardableResult
    mutating func arm() -> UInt64 {
        window = .armed
        backstopGeneration &+= 1
        return backstopGeneration
    }

    /// Queues one rapid accept while the continuation is unavailable.
    ///
    /// Repeated presses deliberately collapse into one queued accept so a user mashing Tab cannot
    /// cause a regenerated suggestion to accept multiple unseen chunks.
    @discardableResult
    mutating func queueAcceptIfArmed() -> Bool {
        guard isArmed else {
            return false
        }

        window = .armedWithQueuedAccept
        return true
    }

    /// Returns true only for the timeout belonging to the current arm operation.
    func ownsBackstop(generation: UInt64) -> Bool {
        backstopGeneration == generation
    }

    /// Closes the window and invalidates every timeout callback already in flight.
    mutating func clear() {
        window = .closed
        backstopGeneration &+= 1
    }

    /// Atomically closes the window and reports whether the regenerated continuation owes one accept.
    mutating func consumeQueuedAccept() -> Bool {
        let shouldAccept = hasQueuedAccept
        clear()
        return shouldAccept
    }
}
