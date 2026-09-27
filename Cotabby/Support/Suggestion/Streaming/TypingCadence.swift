import Foundation

/// Short-lived, text-free typing rhythm owned by the coordinator. Generation can begin during a
/// burst; presentation waits slightly longer than the recent inter-letter interval. Injected
/// monotonic times make both the delay and cancellation races testable without wall-clock sleeps.
nonisolated struct TypingCadence {
    private var identityKey: UInt64?
    private var lastLetterAt: TimeInterval?
    private var intervals: [TimeInterval] = []

    mutating func record(identityKey: UInt64, characters: String, at time: TimeInterval) {
        guard time.isFinite else { return }
        if self.identityKey != identityKey {
            self = TypingCadence()
            self.identityKey = identityKey
        }
        guard characters.count == 1, characters.last?.isLetter == true else {
            lastLetterAt = nil
            return
        }
        if let last = lastLetterAt {
            let interval = time - last
            if (0.025...0.6).contains(interval) {
                intervals.append(interval)
                intervals = Array(intervals.suffix(6))
            } else {
                intervals.removeAll()
            }
        }
        lastLetterAt = time
    }

    func remainingDelay(identityKey: UInt64, precedingText: String, at time: TimeInterval) -> TimeInterval {
        guard self.identityKey == identityKey, let last = lastLetterAt,
              CaretWordContext.unfinishedWord(in: precedingText) != nil else { return 0 }
        let ordered = intervals.sorted()
        // These are bounded presentation limits, not a new global debounce. Before enough rhythm
        // exists, 80ms merely absorbs an ordinary brief hesitation; a completed word pays no delay.
        let quietWindow = ordered.count >= 2 ? min(0.22, max(0.08, ordered[ordered.count / 2] * 1.2)) : 0.08
        return max(0, quietWindow - max(0, time - last))
    }
}
