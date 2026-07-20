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
    /// Surface metadata captured once per field session, carried through so the request factory
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

    init(snapshot: FocusedInputSnapshot, generation: UInt64) {
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
        windowTitle = snapshot.windowTitle
        fieldPlaceholder = snapshot.fieldPlaceholder
        focusedURLString = snapshot.focusedURLString
        isIntegratedTerminal = snapshot.isIntegratedTerminal
        focusChangeSequence = snapshot.focusChangeSequence
        self.generation = generation
    }

    /// True when the caret is at the end of its line (only whitespace, if anything, before the next
    /// line break). Derived from `trailingText` via `CaretLinePosition`; used to decide when a
    /// mid-line completion strategy like fill-in-middle applies versus a plain forward continuation.
    var isCaretAtEndOfLine: Bool {
        CaretLinePosition.isAtEndOfLine(trailingText: trailingText)
    }

    /// Stable per-process key for the focused field, intentionally NOT including the input frame
    /// rect. The polling signature in `FocusTracker` bumps `focusChangeSequence` whenever the
    /// field's frame changes (e.g., a chat composer growing taller as the user types wraps onto a
    /// second line). For consumers that should treat self-resizing as "same field" — chief among
    /// them ghost-font stabilization — this key gives them a session identity that survives field
    /// growth. `hashValue` is randomized per process, which is fine: the key is only ever compared
    /// within one process's lifetime.
    var focusedInputIdentityKey: UInt64 {
        var hasher = Hasher()
        hasher.combine(bundleIdentifier)
        hasher.combine(processIdentifier)
        hasher.combine(elementIdentifier)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    /// Content-only fingerprint — mirrors `FocusedInputSnapshot.contentSignature`.
    /// See that type's doc comment for why `elementIdentifier` is excluded.
    var contentSignature: String {
        [
            String(selection.location),
            String(selection.length),
            precedingText,
            trailingText,
            isSecure ? "secure" : "plain"
        ].joined(separator: "::")
    }
}
