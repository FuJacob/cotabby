import Foundation

/// File overview:
/// The animation model behind the self-playing onboarding demos (ghost text, autocorrect, emoji
/// picker, welcome hero). Every one of them tells the same three-beat story: text types itself in,
/// Cotabby offers something, the offer is accepted. Modelling that as one phase value means a demo
/// cannot draw a combination that never happens in the product, such as an accepted suggestion
/// that was never offered.
///
/// Pure on purpose: the SwiftUI side only maps a phase to pixels and sleeps between steps, so the
/// order and pacing of a demo can be unit tested without rendering anything.

/// Where a typing demo is in its loop.
enum DemoTypingPhase: Equatable {
    /// The user's own text is appearing; `count` characters are visible so far.
    case typing(count: Int)
    /// Typing is complete and Cotabby's offer (ghost text, correction, or picker) is on screen.
    case offered
    /// The offer was taken and has become ordinary text.
    case accepted

    /// How many of `total` typed characters are visible. Everything is typed once an offer exists.
    func typedCount(outOf total: Int) -> Int {
        switch self {
        case let .typing(count):
            return min(max(count, 0), total)
        case .offered, .accepted:
            return total
        }
    }

    /// Whether what Cotabby produced is on screen at all, pending or already accepted.
    var showsOffer: Bool {
        switch self {
        case .typing:
            return false
        case .offered, .accepted:
            return true
        }
    }

    /// Whether the offer is still waiting for the accept key, the only time its keycap and
    /// "not yet yours" styling are shown.
    var isAwaitingAccept: Bool {
        self == .offered
    }
}

/// The pacing of one demo. All times are milliseconds except the three animation durations, which
/// are seconds because that is what SwiftUI animations take.
struct DemoTypingTimeline: Equatable {
    /// One moment in a loop: switch to `phase` (animated over `animationDuration` seconds when
    /// set), then hold it for `holdMilliseconds` before the next step.
    struct Step: Equatable {
        let phase: DemoTypingPhase
        let animationDuration: Double?
        let holdMilliseconds: UInt64
    }

    /// Delay before the first loop only, so stacked demos do not all move in lockstep.
    var startDelayMilliseconds: UInt64 = 0
    /// Empty field at the top of each loop.
    var emptyHoldMilliseconds: UInt64
    /// Time per typed character.
    var perCharacterMilliseconds: UInt64
    /// Extra beat after the last character before the offer appears.
    var pauseBeforeOfferMilliseconds: UInt64 = 0
    var offerAnimationDuration: Double
    /// How long the offer sits unaccepted, long enough to read it.
    var offerHoldMilliseconds: UInt64
    var acceptAnimationDuration: Double
    var acceptedHoldMilliseconds: UInt64
    var resetAnimationDuration: Double
    /// Empty field after the reset, before the next loop starts.
    var resetHoldMilliseconds: UInt64

    /// The steps of one full loop for text of `characterCount` characters, ending back on an empty
    /// field. The pre-offer pause is folded into the last character's hold rather than emitted as
    /// its own step, because nothing changes on screen between the two.
    func loop(characterCount: Int) -> [Step] {
        var steps = [Step(phase: .typing(count: 0), animationDuration: nil, holdMilliseconds: emptyHoldMilliseconds)]
        for count in stride(from: 1, through: characterCount, by: 1) {
            let isLastCharacter = count == characterCount
            steps.append(Step(
                phase: .typing(count: count),
                animationDuration: nil,
                holdMilliseconds: perCharacterMilliseconds + (isLastCharacter ? pauseBeforeOfferMilliseconds : 0)
            ))
        }
        steps.append(Step(
            phase: .offered,
            animationDuration: offerAnimationDuration,
            holdMilliseconds: offerHoldMilliseconds
        ))
        steps.append(Step(
            phase: .accepted,
            animationDuration: acceptAnimationDuration,
            holdMilliseconds: acceptedHoldMilliseconds
        ))
        steps.append(Step(
            phase: .typing(count: 0),
            animationDuration: resetAnimationDuration,
            holdMilliseconds: resetHoldMilliseconds
        ))
        return steps
    }
}
