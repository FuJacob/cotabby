/// Pure state machine for the short Tab-ownership window after a suggestion is exhausted.
///
/// The coordinator owns one instance for its lifetime and supplies the side effects: installing the
/// input interception, scheduling the timeout, and accepting a regenerated continuation. Keeping
/// those effects outside this value makes the hard rules explicit: only one accept may be queued,
/// every arm invalidates older timeout callbacks, and consuming or clearing the window is atomic.
struct PostExhaustionAcceptanceState: Equatable {
    private(set) var backstopGeneration: UInt64 = 0
    private(set) var isArmed = false
    private(set) var hasQueuedAccept = false

    /// Whether a release has any state to clear. Kept separate from `isArmed` so an inconsistent
    /// queued flag still fails safe by returning Tab ownership to the host.
    var needsRelease: Bool {
        isArmed || hasQueuedAccept
    }

    /// Opens a fresh window and returns the identity its timeout callback must capture.
    @discardableResult
    mutating func arm() -> UInt64 {
        isArmed = true
        hasQueuedAccept = false
        backstopGeneration &+= 1
        return backstopGeneration
    }

    /// Queues one rapid accept while the continuation is unavailable.
    ///
    /// Repeated presses deliberately collapse into one Boolean so a user mashing Tab cannot cause a
    /// regenerated suggestion to accept multiple unseen chunks.
    @discardableResult
    mutating func queueAcceptIfArmed() -> Bool {
        guard isArmed else {
            return false
        }

        hasQueuedAccept = true
        return true
    }

    /// Returns true only for the timeout belonging to the current arm operation.
    func ownsBackstop(generation: UInt64) -> Bool {
        backstopGeneration == generation
    }

    /// Closes the window and invalidates every timeout callback already in flight.
    mutating func clear() {
        isArmed = false
        hasQueuedAccept = false
        backstopGeneration &+= 1
    }

    /// Atomically closes the window and reports whether the regenerated continuation owes one accept.
    mutating func consumeQueuedAccept() -> Bool {
        let shouldAccept = isArmed && hasQueuedAccept
        clear()
        return shouldAccept
    }
}
