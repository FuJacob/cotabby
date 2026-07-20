/// Main-actor bookkeeping for one streamed suggestion delivery.
///
/// `SuggestionCoordinator` owns this value for its lifetime. The value keeps token-rate engine
/// callbacks from leaking three related invariants into the coordinator: pending partials are
/// latest-wins, at most one drain is scheduled per runloop turn, and visible text may only grow
/// monotonically. It does not schedule work or render UI; the coordinator remains responsible for
/// those side effects.
struct SuggestionStreamingState {
    /// One partial paired with the replaceable-work identity that produced it.
    struct PendingPartial {
        let result: SuggestionResult
        let workID: UInt64
    }

    private(set) var pendingPartial: PendingPartial?
    private(set) var isDrainScheduled = false
    private(set) var renderedText: String?

    /// Starts a new stream without clearing an already-enqueued drain callback.
    ///
    /// A scheduled callback cannot be cancelled. Preserving `isDrainScheduled` lets the existing
    /// callback drain a replacement partial from the new generation; clearing it here could enqueue
    /// two drains for the same runloop turn.
    mutating func beginGeneration() {
        renderedText = nil
        pendingPartial = nil
    }

    /// Stores the newest partial and returns whether the coordinator must schedule a drain.
    @discardableResult
    mutating func enqueue(_ result: SuggestionResult, workID: UInt64) -> Bool {
        pendingPartial = PendingPartial(result: result, workID: workID)
        guard !isDrainScheduled else {
            return false
        }

        isDrainScheduled = true
        return true
    }

    /// Ends the scheduled-drain window and returns the newest partial, if one survived teardown.
    mutating func drain() -> PendingPartial? {
        isDrainScheduled = false
        defer { pendingPartial = nil }
        return pendingPartial
    }

    /// Applies the backend-independent monotonic rendering rule to the current stream.
    func canRender(_ candidate: String) -> Bool {
        StreamedGhostTextPolicy.isRenderableExtension(
            candidate: candidate,
            currentlyRendered: renderedText
        )
    }

    /// Records text only after all coordinator freshness and seam guards have accepted it.
    mutating func recordRendered(_ text: String) {
        renderedText = text
    }

    /// Drops state associated with a torn-down suggestion session.
    ///
    /// As with `beginGeneration`, a scheduled callback remains responsible for clearing the drain
    /// flag when it eventually runs.
    mutating func clearSession() {
        renderedText = nil
        pendingPartial = nil
    }
}
