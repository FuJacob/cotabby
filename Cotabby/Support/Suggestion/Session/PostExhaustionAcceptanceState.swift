/// Pure state machine for the short Tab-ownership window after a suggestion is exhausted.
///
/// The coordinator owns one instance for its lifetime and supplies the side effects: installing the
/// input interception and scheduling the timeout. Keeping those effects outside this value makes the
/// hard rules explicit: a press inside the window is swallowed and never replayed as an accept,
/// every arm invalidates older timeout callbacks, and consuming or clearing the window is atomic.
///
/// The window exists so a rapid Tab after the last word does not reach the host, where it moves
/// focus out of the field. It used to save that press up and accept the regenerated continuation's
/// first word the moment it arrived, which typed text the user had not seen yet; the press is now
/// only swallowed, and the next one, made with the new ghost on screen, accepts.
struct PostExhaustionAcceptanceState: Equatable {
    /// A held press only exists inside an open window, so the two facts are one value.
    private enum Window: Equatable {
        case closed
        case armed
        case armedWithHeldPress
    }

    private(set) var backstopGeneration: UInt64 = 0
    private var window: Window = .closed

    /// Whether Cotabby still owns Tab for a continuation that has not appeared yet.
    var isArmed: Bool {
        window != .closed
    }

    /// A press arrived inside the window and was swallowed. Kept so the window's end can report the
    /// dropped press for diagnosis; it never becomes an accept.
    var hasHeldPress: Bool {
        window == .armedWithHeldPress
    }

    /// Opens a fresh window and returns the identity its timeout callback must capture.
    @discardableResult
    mutating func arm() -> UInt64 {
        window = .armed
        backstopGeneration &+= 1
        return backstopGeneration
    }

    /// Swallows a rapid press while the continuation is unavailable. Returns true when the window
    /// owns the press, so the caller consumes the key instead of passing it to the host.
    ///
    /// Repeated presses collapse into one held press; none of them is ever replayed.
    @discardableResult
    mutating func holdPressIfArmed() -> Bool {
        guard isArmed else {
            return false
        }

        window = .armedWithHeldPress
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

    /// Atomically closes the window and reports whether it swallowed a press. The answer is for
    /// diagnostics only: the continuation that ends the window was not on screen when that press
    /// was made, so the press must not accept it.
    mutating func consumeHeldPress() -> Bool {
        let heldPress = hasHeldPress
        clear()
        return heldPress
    }
}
