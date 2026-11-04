import CoreGraphics
import Foundation

/// Stable, bounded focus state captured before debounce and carried through generation.
/// Keeping this value independent of live AX elements is a central stale-result safety boundary.

/// This is the stable context used across debounce and generation boundaries.
/// It extends the AX snapshot with a monotonically increasing generation number.
struct FocusedInputContext: Equatable, Sendable {
    let applicationName: String
    let bundleIdentifier: String
    let processIdentifier: Int32
    let elementIdentifier: String
    let role: String
    let subrole: String?
    let caretRect: CGRect
    let inputFrameRect: CGRect?
    let caretQuality: CaretGeometryQuality
    /// Human-readable label of the geometry source that produced `caretRect` (e.g. "derived
    /// primary"), carried through so presentation-time repair logs can attribute a misplaced
    /// overlay to the exact resolver branch.
    let caretSource: String
    /// Average character width in points observed from AX child frame measurements.
    /// Used by caret prediction after tab insertion to match the target app's actual font.
    let observedCharWidth: CGFloat?
    /// Content edges measured from the host's child text-run frames, carried through so the caret
    /// layout estimator can anchor to the field's real padding instead of guessed insets.
    let observedContentEdges: ObservedContentEdges?
    let precedingText: String
    let trailingText: String
    let selection: NSRange
    let isSecure: Bool
    /// Whether the field's text is rendered by a web engine (see `WebContentFieldDetector`),
    /// carried through so the presentation-time caret repair can scope estimator authority to
    /// hosts whose AX caret geometry actually needs repairing.
    let isWebContentField: Bool
    /// The host field's own text font/color, carried through so the overlay can match it.
    let resolvedFieldStyle: ResolvedFieldStyle?
    /// Measured host text geometry (width sample, line box, line pitch), carried through so the
    /// overlay can match the host's typeface and wrap exactly where the host would.
    let hostTextMetrics: HostTextMetrics?
    /// The focused element's unwidened frame (see `FocusedInputSnapshot.elementFrameRect`), the
    /// only frame the overlay may use to decide where a ghost row must wrap.
    let elementFrameRect: CGRect?
    /// The host's uncommitted text range, if any (see `FocusedInputSnapshot.hostMarkedTextRange`).
    let hostMarkedTextRange: NSRange?
    /// Surface metadata captured with the current focus snapshot, carried through so the request factory
    /// can condition the prompt on what the user is writing in (see `SurfaceContextComposer`).
    let windowTitle: String?
    let fieldPlaceholder: String?
    let focusedURLString: String?
    let isIntegratedTerminal: Bool
    /// Carries the immutable focus-observation identity across debounce/generation boundaries.
    /// Without this, later visual-context lookups could fall back to `elementIdentifier` alone and
    /// reintroduce the CFHash collision class this sequence is meant to avoid.
    let focusChangeSequence: UInt64
    let generation: UInt64
    /// Content-only fingerprint — mirrors `FocusedInputSnapshot.contentSignature`.
    /// Computed once in `init`: materialize runs several times per keystroke cycle and each
    /// staleness check would otherwise re-join the full text window.
    let contentSignature: String

    // Copying immutable snapshot values needs no UI actor; pure continuation plans use this
    // initializer to share the same field-identity rule as coordinator-held contexts.
    nonisolated init(snapshot: FocusedInputSnapshot, generation: UInt64) {
        applicationName = snapshot.applicationName
        bundleIdentifier = snapshot.bundleIdentifier
        processIdentifier = snapshot.processIdentifier
        elementIdentifier = snapshot.elementIdentifier
        role = snapshot.role
        subrole = snapshot.subrole
        caretRect = snapshot.caretRect
        inputFrameRect = snapshot.inputFrameRect
        caretQuality = snapshot.caretQuality
        caretSource = snapshot.caretSource
        observedCharWidth = snapshot.observedCharWidth
        observedContentEdges = snapshot.observedContentEdges
        precedingText = snapshot.precedingText
        trailingText = snapshot.trailingText
        selection = snapshot.selection
        isSecure = snapshot.isSecure
        isWebContentField = snapshot.isWebContentField
        resolvedFieldStyle = snapshot.resolvedFieldStyle
        hostTextMetrics = snapshot.hostTextMetrics
        elementFrameRect = snapshot.elementFrameRect
        hostMarkedTextRange = snapshot.hostMarkedTextRange
        windowTitle = snapshot.windowTitle
        fieldPlaceholder = snapshot.fieldPlaceholder
        focusedURLString = snapshot.focusedURLString
        isIntegratedTerminal = snapshot.isIntegratedTerminal
        focusChangeSequence = snapshot.focusChangeSequence
        self.generation = generation
        contentSignature = [
            String(snapshot.selection.location),
            String(snapshot.selection.length),
            snapshot.precedingText,
            snapshot.trailingText,
            snapshot.isSecure ? "secure" : "plain"
        ].joined(separator: "::")
    }

    /// True when the caret is at the end of its line (only whitespace, if anything, before the next
    /// line break). Derived from `trailingText` via `CaretLinePosition`; used to decide when a
    /// mid-line completion strategy like fill-in-middle applies versus a plain forward continuation.
    var isCaretAtEndOfLine: Bool {
        CaretLinePosition.isAtEndOfLine(trailingText: trailingText)
    }

    /// True when real (non-whitespace) characters follow the caret anywhere in the captured
    /// trailing window. A multi-row ghost would paint over that content, so the overlay keeps the
    /// ghost to one row or promotes it to the card when this is set.
    var hasTrailingContent: Bool {
        trailingText.contains { !$0.isWhitespace }
    }

    /// True for a field the host lays out on one line: a text field or combo box by its
    /// Accessibility role (an HTML `<input>`, Chromium's address bar, an `NSTextField`). Its text
    /// scrolls sideways instead of wrapping, so a ghost row past its right edge has no line below
    /// to go to: measured 2026-09-11 in a Chrome text input and a search input, a long ghost's
    /// second row was drawn under the input, over the page.
    var isSingleLineField: Bool {
        role == "AXTextField" || role == "AXComboBox"
    }

    /// True while the host shows uncommitted text of its own: an inline prediction after the caret
    /// or an IME composition before it. Generation and ghost rendering pause until it clears.
    var hasHostMarkedText: Bool {
        (hostMarkedTextRange?.length ?? 0) > 0
    }

    /// Presentation measurements belong to the current writing session, not a recycled AX node.
    /// FocusTracker preserves the sequence during composer growth and advances it on field changes.
    /// Stable navigation URL also isolates measurements without hashing mutable window titles.
    /// Frames and typed text are excluded so normal typing and wrapping remain visually stable.
    var focusedInputIdentityKey: UInt64 {
        var hasher = Hasher()
        hasher.combine(bundleIdentifier)
        hasher.combine(processIdentifier)
        hasher.combine(elementIdentifier)
        hasher.combine(focusChangeSequence)
        hasher.combine(focusedURLString)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    nonisolated var sessionIdentity: FocusedInputSessionIdentity {
        FocusedInputSessionIdentity(
            processIdentifier: processIdentifier, bundleIdentifier: bundleIdentifier,
            focusChangeSequence: focusChangeSequence, focusedURLString: focusedURLString,
            windowTitle: windowTitle
        )
    }

    /// Prediction memory must expire on navigation even when the host reuses the AX element.
    /// Both prediction and presentation measurements are scoped to the same writing session.
    var suggestionSessionIdentityKey: UInt64 {
        var hasher = Hasher()
        hasher.combine(focusedInputIdentityKey)
        hasher.combine(sessionIdentity)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    /// Content-only fingerprint — mirrors `FocusedInputSnapshot.contentSignature`.
    /// See that type's doc comment for why `elementIdentifier` is excluded.
    /// (Stored, computed once in `init`.)
}
