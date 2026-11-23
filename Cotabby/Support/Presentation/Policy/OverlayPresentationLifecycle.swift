import CoreGraphics
import Foundation

/// File overview:
/// The lifecycle of the suggestion overlay, as one value: what is on screen, and which requested
/// presentation (if any) is being held back from it.
///
/// Why this is a type of its own: `OverlayController.showSuggestion` does not always apply what it
/// is asked to show. A presentation whose caret must first be read from the host's pixels, or
/// whose caret the host has not moved yet, is held, and the previous presentation stays exactly as
/// it was until the held one lands or is retired. Those are two independent facts (what is
/// presented, what is held) with a small set of legal combinations and transitions, and the
/// transitions below are the only way to move between them: every show and hide retires the hold,
/// a session exists only while an inline ghost is what is presented, and a late pixel read can
/// only land if nothing was asked of the overlay since it was held.
///
/// Pure: no AppKit, no panel. `Session` is whatever the controller needs to redraw an inline ghost
/// without reading Accessibility again; this type only guarantees when one exists.
struct OverlayPresentationLifecycle<Session> {
    /// What the overlay shows, which is what `OverlayState` reports to the coordinator.
    enum Presentation {
        case hidden(reason: String)
        /// An inline ghost. `text` and `geometry` are what the coordinator was told: after a
        /// typed-through or accepted prefix they are the remaining text and the predicted caret,
        /// while `session` keeps the full text and the geometry it was first anchored at.
        case inline(session: Session, text: String, geometry: SuggestionOverlayGeometry)
        case mirror(text: String, geometry: SuggestionOverlayGeometry, reason: CompletionRenderMode.MirrorReason)
    }

    /// A presentation `showSuggestion` accepted but has not applied. While one is held,
    /// `presentation` still describes the previous presentation.
    enum Hold {
        /// The host has published text its caret has not moved for yet (`CaretLagPolicy`); the next
        /// focus snapshot brings the real caret and a fresh show.
        case caretLag(text: String)
        /// The caret is being read from the host's pixels. `panelTakenDown` is true when the ghost
        /// covered the run and was ordered out so the capture could see it: nothing is on screen to
        /// slide until the held presentation puts it back.
        case pixelCapture(text: String, panelTakenDown: Bool)

        var text: String {
            switch self {
            case .caretLag(let text), .pixelCapture(let text, _): return text
            }
        }
    }

    /// Proof that a pixel-capture hold was the latest thing asked of the overlay; see `isCurrent`.
    struct HoldTicket: Equatable {
        fileprivate let generation: UInt64
    }

    private(set) var presentation = Presentation.hidden(reason: "Overlay idle.")
    private(set) var hold: Hold?
    /// Counts shows and hides. A hold is only ever placed right after a count, so a ticket for an
    /// older count belongs to a hold that has since been retired.
    private var generation: UInt64 = 0

    var state: OverlayState {
        switch presentation {
        case .hidden(let reason):
            return .hidden(reason: reason)
        case .inline(_, let text, let geometry):
            return .visible(text: text, geometry: geometry, mode: .inline)
        case .mirror(let text, let geometry, let reason):
            return .visible(text: text, geometry: geometry, mode: .mirror(reason: reason))
        }
    }

    /// The text of the held presentation, for `SuggestionOverlayControlling.heldPresentationText`.
    var heldText: String? { hold?.text }

    /// The session of the inline ghost being presented, nil when the card or nothing is.
    var inlineSession: Session? {
        if case .inline(let session, _, _) = presentation { return session }
        return nil
    }

    /// True while the ghost is ordered out for a pixel read of the run it covered.
    var isPanelTakenDownForCapture: Bool {
        if case .pixelCapture(_, true)? = hold { return true }
        return false
    }

    // MARK: - Holds

    /// A new show begins: whatever was held is retired, so its late pixel read cannot land.
    mutating func beginShow() {
        retireHold()
    }

    mutating func holdForCaretLag(text: String) {
        hold = .caretLag(text: text)
    }

    /// Holds `text` for a pixel read. The ticket must be taken before the read is started: a read
    /// that answers at once re-enters the show synchronously, and that show must find this hold.
    mutating func holdForPixelCapture(text: String, panelTakenDown: Bool) -> HoldTicket {
        hold = .pixelCapture(text: text, panelTakenDown: panelTakenDown)
        return HoldTicket(generation: generation)
    }

    /// Whether the hold `ticket` was issued for is still the latest thing asked of the overlay.
    /// False once any show or hide has happened since, whatever it did.
    func isCurrent(_ ticket: HoldTicket) -> Bool {
        ticket.generation == generation
    }

    // MARK: - Presentations

    mutating func presentInline(_ session: Session, text: String, geometry: SuggestionOverlayGeometry) {
        presentation = .inline(session: session, text: text, geometry: geometry)
    }

    mutating func presentMirror(text: String, geometry: SuggestionOverlayGeometry, reason: CompletionRenderMode.MirrorReason) {
        presentation = .mirror(text: text, geometry: geometry, reason: reason)
    }

    mutating func hide(reason: String) {
        retireHold()
        presentation = .hidden(reason: reason)
    }

    /// Replaces the presented inline ghost's session after it was redrawn in place (a measured
    /// baseline, a face that finished registering). What the coordinator was told does not change.
    /// Returns false, changing nothing, when no inline ghost is presented.
    @discardableResult
    mutating func replaceInlineSession(_ session: Session) -> Bool {
        guard case .inline(_, let text, let geometry) = presentation else { return false }
        presentation = .inline(session: session, text: text, geometry: geometry)
        return true
    }

    /// Moves the presented inline ghost past a consumed prefix: `session` is the advanced session,
    /// `remainingText` and `geometry` what the coordinator is told. Returns false, changing
    /// nothing, when no inline ghost is presented.
    @discardableResult
    mutating func advanceInline(to session: Session, remainingText: String, geometry: SuggestionOverlayGeometry) -> Bool {
        guard case .inline = presentation else { return false }
        presentation = .inline(session: session, text: remainingText, geometry: geometry)
        return true
    }

    private mutating func retireHold() {
        generation &+= 1
        hold = nil
    }
}
