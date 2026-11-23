import Foundation

/// How far the host's Accessibility text is known to trail the active suggestion session.
///
/// The session advances on the key event or the synthetic insert, which both land before the
/// host publishes the text. Until it does, a focus poll shows a field that looks as if the user
/// undid part of the suggestion. The two causes are never pending together, and they earn
/// different tolerance, which is why they are separate cases and not two optional sentinels.
enum HostPublicationLag: Equatable, Sendable {
    /// Accessibility has published everything the session counts as consumed.
    case settled
    /// Cotabby inserted text and the host has not published it. `consumedCount` is the session's
    /// consumed length once it does. Chromium can publish the caret, the prefix, and the suffix
    /// of one edit in separate snapshots, so this window tolerates each of them being stale.
    case awaitingSyntheticInsert(consumedCount: Int)
    /// The user typed the suggestion's next characters and the host has not published them. The
    /// range spans the consumed counts still in transit. Only an older matching prefix is
    /// tolerated: typing never excuses a changed suffix, selection, or focus.
    case awaitingTypedInput(Range<Int>)

    /// The lag once the user typed the suggestion's next characters, moving `session` to
    /// `advanced`.
    func afterTypedAdvance(
        from session: ActiveSuggestionSession,
        to advanced: ActiveSuggestionSession
    ) -> HostPublicationLag {
        switch self {
        case .awaitingSyntheticInsert:
            // A matching key can arrive before a preceding Tab insert publishes. Keep that window
            // aimed at the latest consumed prefix instead of narrowing it to typed-input tolerance
            // merely because the user typed one more expected character.
            return .awaitingSyntheticInsert(consumedCount: advanced.consumedCharacterCount)
        case .settled:
            return advanced.isExhausted ? self : .awaitingTypedInput(
                session.consumedCharacterCount..<advanced.consumedCharacterCount
            )
        case let .awaitingTypedInput(unpublished):
            // An exhausted session is retired on the next reconcile; widening the window for it
            // would only outlive the session it protects.
            return advanced.isExhausted ? self : .awaitingTypedInput(
                unpublished.lowerBound..<advanced.consumedCharacterCount
            )
        }
    }

    /// Retires typed-input tolerance as soon as the field contains the expected prefix. Later
    /// deletion of those letters is then a real edit again, not an indefinitely tolerated
    /// publication delay.
    func retiringPublishedTypedInput(
        in context: FocusedInputContext,
        session: ActiveSuggestionSession
    ) -> HostPublicationLag {
        guard case let .awaitingTypedInput(range) = self else { return self }
        let expectedPrefix = session.baseContext.precedingText + String(session.fullText.prefix(range.upperBound))
        return context.precedingText.hasPrefix(expectedPrefix) ? .settled : self
    }
}
