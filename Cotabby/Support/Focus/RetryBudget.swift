import Foundation

/// How many more times a cache may ask a host for something it has not answered yet.
///
/// Hosts that build their text geometry lazily (Chromium's inline text boxes) answer empty at
/// first and correctly a few polls later, so an empty answer is worth asking again; a host that
/// never answers must stop costing cross-process calls. A budget counts the asks against a cap.
nonisolated struct RetryBudget: Equatable, Sendable {
    let maximumAttempts: Int
    private(set) var attempts = 0

    init(maximumAttempts: Int) {
        self.maximumAttempts = maximumAttempts
    }

    var hasAttemptsLeft: Bool {
        attempts < maximumAttempts
    }

    mutating func spend() {
        attempts += 1
    }
}

/// Spaces attempts at least `interval` apart, so retries land on later polls (when a lazy host may
/// have caught up) instead of being burnt on consecutive ticks. Kept apart from `RetryBudget`
/// because several budgets for one field can share one pacing: any attempt delays all of them.
nonisolated struct RetryPacing: Equatable, Sendable {
    let interval: TimeInterval
    private(set) var lastAttemptAt: Date?

    init(interval: TimeInterval) {
        self.interval = interval
    }

    /// True before the first attempt and once a full interval has passed since the last one.
    func allowsAttempt(at now: Date) -> Bool {
        guard let lastAttemptAt else {
            return true
        }
        return now.timeIntervalSince(lastAttemptAt) >= interval
    }

    mutating func recordAttempt(at now: Date) {
        lastAttemptAt = now
    }
}
