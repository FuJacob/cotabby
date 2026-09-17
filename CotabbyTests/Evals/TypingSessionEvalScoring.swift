import Foundation

/// Fixed editor snapshots keep model comparisons on the same text and keystroke schedule. A Tab
/// step names the intended insertion; if it was unavailable, replay still advances to that text
/// (as if the writer typed it). Acceptance opportunities are therefore reported separately from
/// actual user acceptance. These fixtures contain synthetic writing, never captured user text.
struct TypingSessionTrace {
    enum Action: String, Codable {
        case type, backspace, acceptWord, moveCaret
    }

    struct Step: Codable {
        let atMilliseconds: Int
        let action: Action
        let precedingText: String
        var trailingText = ""
        /// Exact suffixes that finish the next intended word, including its leading whitespace.
        /// Keeping spelling and spacing significant catches broken joins such as `sched ule`.
        let usefulContinuations: [String]
    }

    let id: String
    let steps: [Step]
    var finalPauseMilliseconds = 800

    static let standard: [TypingSessionTrace] = [
        .init(id: "unfinished-word", steps: [
            .init(atMilliseconds: 0, action: .type, precedingText: "Please send me the s", usefulContinuations: ["chedule"]),
            .init(atMilliseconds: 80, action: .type, precedingText: "Please send me the sc", usefulContinuations: ["hedule"]),
            .init(atMilliseconds: 160, action: .type, precedingText: "Please send me the sch", usefulContinuations: ["edule"]),
            .init(atMilliseconds: 240, action: .type, precedingText: "Please send me the sche", usefulContinuations: ["dule"]),
            .init(atMilliseconds: 320, action: .type, precedingText: "Please send me the sched", usefulContinuations: ["ule"]),
            .init(atMilliseconds: 900, action: .type, precedingText: "Please send me the schedule ", usefulContinuations: ["for", "by"])
        ]),
        .init(id: "backspace-and-retype", steps: [
            .init(atMilliseconds: 0, action: .type, precedingText: "Thanks for your patien", usefulContinuations: ["ce"]),
            .init(atMilliseconds: 250, action: .type, precedingText: "Thanks for your patient", usefulContinuations: []),
            .init(atMilliseconds: 330, action: .backspace, precedingText: "Thanks for your patien", usefulContinuations: ["ce"]),
            .init(atMilliseconds: 410, action: .type, precedingText: "Thanks for your patienc", usefulContinuations: ["e"]),
            .init(atMilliseconds: 750, action: .type, precedingText: "Thanks for your patience", usefulContinuations: [" and", "."])
        ]),
        .init(id: "rapid-word-acceptance", steps: [
            .init(atMilliseconds: 0, action: .type, precedingText: "I look forward to ", usefulContinuations: ["hearing", "seeing"]),
            .init(atMilliseconds: 650, action: .acceptWord, precedingText: "I look forward to hearing", usefulContinuations: [" from"]),
            .init(atMilliseconds: 770, action: .acceptWord, precedingText: "I look forward to hearing from", usefulContinuations: [" you"]),
            .init(atMilliseconds: 890, action: .acceptWord, precedingText: "I look forward to hearing from you", usefulContinuations: [" soon", "."])
        ]),
        .init(id: "paragraph-and-list", steps: [
            .init(atMilliseconds: 0, action: .type, precedingText: "Project checklist:\n- Review the proposal\n- Send the ", usefulContinuations: ["proposal", "update", "report"]),
            .init(atMilliseconds: 180, action: .type, precedingText: "Project checklist:\n- Review the proposal\n- Send the up", usefulContinuations: ["date"]),
            .init(atMilliseconds: 360, action: .type, precedingText: "Project checklist:\n- Review the proposal\n- Send the update\n- ", usefulContinuations: ["Schedule", "Review", "Confirm"])
        ]),
        .init(id: "edit-before-existing-text", steps: [
            .init(atMilliseconds: 0, action: .moveCaret, precedingText: "Let's meet ", trailingText: " to review the proposal.", usefulContinuations: ["tomorrow", "on"]),
            .init(atMilliseconds: 180, action: .type, precedingText: "Let's meet tom", trailingText: " to review the proposal.", usefulContinuations: ["orrow"]),
            .init(atMilliseconds: 260, action: .type, precedingText: "Let's meet tomo", trailingText: " to review the proposal.", usefulContinuations: ["rrow"]),
            .init(atMilliseconds: 700, action: .moveCaret, precedingText: "Let's meet tomorrow to review the ", trailingText: "proposal.", usefulContinuations: [])
        ])
    ]
}

/// One input revision's observations. The runner owns this value until its task has drained;
/// callbacks from superseded work can be counted without ever replacing the visible candidate.
/// All offsets use a monotonic clock, so wall-clock corrections cannot produce negative latency.
struct TypingSessionStepMeasurement: Codable {
    let step: TypingSessionTrace.Step
    let inputMilliseconds: Double
    var generationStartedMilliseconds: Double?
    var finishedMilliseconds: Double?
    var cancellationRequestedMilliseconds: Double?
    var firstVisibleMilliseconds: Double?
    var firstUsefulMilliseconds: Double?
    var finalVisibleMilliseconds: Double?
    var visibleText: String?
    var visibleRevisionCount = 0
    var nonUsefulVisibleRevisionCount = 0
    var withdrawnSuggestionCount = 0
    var stalePartialCount = 0
    var acceptanceOpportunityCharacters = 0
    var failure: String?

    var firstUsefulLatencyMilliseconds: Double? {
        firstUsefulMilliseconds.map { $0 - inputMilliseconds }
    }

    var cancellationDrainMilliseconds: Double? {
        guard let cancellation = cancellationRequestedMilliseconds, let finish = finishedMilliseconds else { return nil }
        return max(0, finish - cancellation)
    }

    /// Elapsed generation lifetime is a queue/work proxy, NOT CPU/GPU execution time. Some
    /// cancelled requests showed useful output first, so keep those out of the wasted-work proxy.
    var cancelledWithoutUsefulOutputMilliseconds: Double {
        guard cancellationRequestedMilliseconds != nil, firstUsefulMilliseconds == nil,
              let start = generationStartedMilliseconds, let finish = finishedMilliseconds else { return 0 }
        return max(0, finish - start)
    }

    mutating func recordVisible(_ text: String, at milliseconds: Double) {
        guard !text.isEmpty, text != visibleText else { return }
        firstVisibleMilliseconds = firstVisibleMilliseconds ?? milliseconds
        if TypingSessionScorer.containsUsefulWord(text, references: step.usefulContinuations) {
            firstUsefulMilliseconds = firstUsefulMilliseconds ?? milliseconds
        } else {
            nonUsefulVisibleRevisionCount += 1
        }
        visibleText = text
        visibleRevisionCount += 1
    }

    mutating func recordHidden() {
        if visibleText != nil { withdrawnSuggestionCount += 1 }
        visibleText = nil
    }
}

enum TypingSessionScorer {
    /// A partial `sched` is not a useful `schedule`, and a following letter cannot turn `cat`
    /// into an apparently correct prefix of `catalog`. References are whole words or the exact
    /// missing suffix of the word at the caret; matching preserves all whitespace at that seam.
    static func containsUsefulWord(_ candidate: String, references: [String]) -> Bool {
        references.contains { reference in
            guard !reference.isEmpty, candidate.hasPrefix(reference) else { return false }
            let remainder = candidate.dropFirst(reference.count)
            guard let next = remainder.first else { return true }
            return !next.isLetter && !next.isNumber && next != "'" && next != "-"
        }
    }

    static func percentile(_ fraction: Double, values: [Double]) -> Double? {
        let ordered = values.sorted()
        guard !ordered.isEmpty else { return nil }
        let bounded = min(1, max(0, fraction))
        return ordered[Int((Double(ordered.count - 1) * bounded).rounded())]
    }
}

/// Codable reports preserve the raw schedule and per-revision measurements for comparisons.
/// Nil latency means the useful word never appeared; it is not silently counted as a fast zero.
struct TypingSessionEvalReport: Codable {
    struct Session: Codable {
        let traceID: String
        let cacheMode: String
        let streamingEnabled: Bool
        let measurements: [TypingSessionStepMeasurement]
    }

    let modelFilename: String
    let seed: UInt32
    let debounceMilliseconds: Int
    let sessions: [Session]
    var measurementScope = "Scripted input to display-eligible text; excludes AX, overlay layout, and coordinator tail reuse. " +
        "Tab counts are opportunities, not observed user accepts. " +
        "Fixed settings: multiline=true, surface context=false, word-count preset=12–20; clipboard context disabled."

    func rendered() -> String {
        sessions.map { session in
            let measurements = session.measurements
            let useful = measurements.compactMap(\.firstUsefulLatencyMilliseconds)
            let expectedUseful = measurements.filter { !$0.step.usefulContinuations.isEmpty }.count
            let p50 = TypingSessionScorer.percentile(0.5, values: useful).map { String(format: "%.0fms", $0) } ?? "n/a"
            let p95 = TypingSessionScorer.percentile(0.95, values: useful).map { String(format: "%.0fms", $0) } ?? "n/a"
            let cancelled = measurements.filter { $0.cancellationRequestedMilliseconds != nil }.count
            let wasted = measurements.map(\.cancelledWithoutUsefulOutputMilliseconds).reduce(0, +)
            return "\(session.traceID) [\(session.cacheMode), streaming=\(session.streamingEnabled)] " +
                "useful \(useful.count)/\(expectedUseful) " +
                "first-useful p50 \(p50) p95 \(p95) cancelled \(cancelled) " +
                String(format: "cancelled-without-useful elapsed %.0fms", wasted)
        }.joined(separator: "\n")
    }
}
