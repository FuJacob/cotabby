import CoreGraphics
import Foundation

/// Presentation-facing suggestion state shared by the coordinator, presenter, overlays, and diagnostics.

/// High-level suggestion states surfaced to the menu and overlay logic.
enum SuggestionDebugState: Equatable {
    case idle
    case disabled(String)
    case debouncing
    case generating
    case ready(text: String, latency: TimeInterval)
    case failed(String)

}

/// Geometry needed to render ghost text in the same visual line box as the host editor.
///
/// `caretRect` tells Cotabby where the current insertion point is. `inputFrameRect` gives the
/// broader editor bounds, which lets the overlay wrap overflow text back to the field's left edge
/// instead of drawing past the right edge of the text container.
struct SuggestionOverlayGeometry: Equatable, Sendable {
    let caretRect: CGRect
    let inputFrameRect: CGRect?
    let caretQuality: CaretGeometryQuality
    /// Host identity used to resolve presentation that varies by app.
    let bundleIdentifier: String?
    /// The page URL when the host is a browser (`FocusedInputContext.focusedURLString`), so what the
    /// overlay remembers about a host's text keeps one site's apart from another's.
    let focusedURLString: String?
    /// True when the caret is at the end of its line: only whitespace, if anything, precedes the
    /// next line break. When false, real characters follow the caret on this line, so the
    /// render-mode policy promotes the suggestion to the card: inline ghost text would otherwise
    /// paint over those trailing characters. Carried from `FocusedInputContext.isCaretAtEndOfLine`.
    /// Defaults to `true` so call sites that predate the mid-line rule keep the prior inline path.
    let isCaretAtEndOfLine: Bool
    /// Average character width from AX child-frame sampling when available. Layout uses this as a
    /// cheap approximation for host-editor text width before falling back to local font metrics.
    let observedCharWidth: CGFloat?
    /// When `true`, the text near the caret is Right-to-Left (Arabic, Hebrew, etc.) and the ghost
    /// text overlay should appear to the left of the caret instead of the right.
    let isRightToLeft: Bool
    /// Identifies the focus session that produced this geometry. `OverlayController` keys its
    /// per-session font-size stabilization on this value, so a field switch (or focus loss) starts
    /// a fresh size baseline. Defaults to 0 for tests that do not exercise session-scoped behavior.
    let focusChangeSequence: UInt64
    /// Stable identity for the focused input field, used to scope ghost-font stabilization.
    /// Unlike `focusChangeSequence`, this does NOT change when the field resizes (e.g., a chat
    /// composer growing taller as text wraps), so the stabilizer's per-session minimum survives
    /// self-growing inputs. It DOES change when the user focuses a genuinely different field.
    /// Defaults to 0 for tests that do not exercise session-scoped behavior.
    let focusedInputIdentityKey: UInt64
    /// When `true`, the overlay is rendering a typo correction rather than a forward continuation.
    /// `OverlayController` switches to a green tint on this signal so the user can tell at a glance
    /// that pressing the accept key will replace their last word, not extend it.
    let isCorrection: Bool
    /// The host field's own text font/color, so the overlay can render ghost text that matches the
    /// field instead of always using the system font and a fixed gray. Nil falls back to defaults.
    let resolvedFieldStyle: ResolvedFieldStyle?
    /// Measured host text geometry (see `HostTextMetrics`): width sample for typeface matching,
    /// line box for the content left edge, and line pitch for exact multi-row placement.
    let hostTextMetrics: HostTextMetrics?
    /// True when the field's text is rendered by a web engine. The baseline rule differs between
    /// TextKit (baseline at the layout manager's default offset) and web engines (rounded ascent
    /// centered in the line box), so the renderer must know which one produced the caret box.
    let isWebContentField: Bool
    /// True when non-whitespace text follows the caret. A ghost may then occupy only one row: a
    /// second row would paint over the host's own following lines.
    let hasTrailingContent: Bool
    /// True for a field the host keeps on one line (`FocusedInputContext.isSingleLineField`): its
    /// text scrolls sideways rather than wrapping, so a ghost takes one row there and reveals the
    /// rest as it is accepted.
    let isSingleLineField: Bool
    /// The focused element's own frame, unwidened (see `FocusedInputSnapshot.elementFrameRect`).
    /// Wrapped ghost rows must stay inside it; `inputFrameRect` is grown for card placement and
    /// would let a row run past the host's real right edge.
    let elementFrameRect: CGRect?
    /// The text between the last hard line break and the caret. The pixel typeface match renders
    /// its tail in candidate faces; `GhostCaretRefinement` measures its advance for the exact caret.
    let lineTextBeforeCaret: String?
    /// Set when the caret sits inside a paragraph the host exposes only as one union-framed text
    /// run (CodeMirror in Obsidian). AX cannot say which visual line the caret is on or where in it;
    /// `PixelCaretLocator` measures both from the host's own pixels before the ghost is placed.
    let wrappedRun: WrappedRunAnchor?
    /// The caret line's baseline as an offset below the caret box top, read from the same pixels
    /// that placed a pixel-measured caret; nil for every other caret. It outranks the baseline
    /// policy and the calibrator's own strip for that presentation.
    let pixelBaselineOffset: CGFloat?
    /// Width of the ink on the caret's line as the pixel caret saw it; the typeface match trims
    /// the paragraph tail to what fits it. Nil for every other caret.
    let pixelLineInkWidth: CGFloat?

    init(
        caretRect: CGRect,
        inputFrameRect: CGRect?,
        caretQuality: CaretGeometryQuality,
        bundleIdentifier: String? = nil,
        focusedURLString: String? = nil,
        isCaretAtEndOfLine: Bool = true,
        observedCharWidth: CGFloat?,
        isRightToLeft: Bool,
        focusChangeSequence: UInt64 = 0,
        focusedInputIdentityKey: UInt64 = 0,
        isCorrection: Bool = false,
        resolvedFieldStyle: ResolvedFieldStyle? = nil,
        hostTextMetrics: HostTextMetrics? = nil,
        isWebContentField: Bool = false,
        hasTrailingContent: Bool = false,
        isSingleLineField: Bool = false,
        elementFrameRect: CGRect? = nil,
        lineTextBeforeCaret: String? = nil,
        wrappedRun: WrappedRunAnchor? = nil,
        pixelBaselineOffset: CGFloat? = nil,
        pixelLineInkWidth: CGFloat? = nil
    ) {
        self.caretRect = caretRect
        self.inputFrameRect = inputFrameRect
        self.caretQuality = caretQuality
        self.bundleIdentifier = bundleIdentifier
        self.focusedURLString = focusedURLString
        self.isCaretAtEndOfLine = isCaretAtEndOfLine
        self.observedCharWidth = observedCharWidth
        self.isRightToLeft = isRightToLeft
        self.focusChangeSequence = focusChangeSequence
        self.focusedInputIdentityKey = focusedInputIdentityKey
        self.isCorrection = isCorrection
        self.resolvedFieldStyle = resolvedFieldStyle
        self.hostTextMetrics = hostTextMetrics
        self.isWebContentField = isWebContentField
        self.hasTrailingContent = hasTrailingContent
        self.isSingleLineField = isSingleLineField
        self.elementFrameRect = elementFrameRect
        self.lineTextBeforeCaret = lineTextBeforeCaret
        self.wrappedRun = wrappedRun
        self.pixelBaselineOffset = pixelBaselineOffset
        self.pixelLineInkWidth = pixelLineInkWidth
    }

    /// Returns a copy with only `caretRect` replaced. Used to advance the ghost by an exact measured
    /// width on word acceptance without re-reading (and re-jittering against) a fresh AX caret.
    func withCaretRect(_ caretRect: CGRect) -> SuggestionOverlayGeometry {
        SuggestionOverlayGeometry(
            caretRect: caretRect,
            inputFrameRect: inputFrameRect,
            caretQuality: caretQuality,
            bundleIdentifier: bundleIdentifier,
            focusedURLString: focusedURLString,
            isCaretAtEndOfLine: isCaretAtEndOfLine,
            observedCharWidth: observedCharWidth,
            isRightToLeft: isRightToLeft,
            focusChangeSequence: focusChangeSequence,
            focusedInputIdentityKey: focusedInputIdentityKey,
            isCorrection: isCorrection,
            resolvedFieldStyle: resolvedFieldStyle,
            hostTextMetrics: hostTextMetrics,
            isWebContentField: isWebContentField,
            hasTrailingContent: hasTrailingContent,
            isSingleLineField: isSingleLineField,
            elementFrameRect: elementFrameRect,
            lineTextBeforeCaret: lineTextBeforeCaret,
            wrappedRun: wrappedRun
        )
    }

    /// A copy carrying a pixel-measured caret: the measured box replaces the caret, the quality
    /// becomes `.derived` (a real measurement, not an estimate), and the measured line box and
    /// pitch ride along as host metrics so wrapped rows land on the host's real next lines.
    func withPixelMeasuredCaret(
        _ caretRect: CGRect, lineRect: CGRect, linePitch: CGFloat?, baselineOffsetFromTop: CGFloat? = nil, lineInkWidth: CGFloat? = nil
    ) -> SuggestionOverlayGeometry {
        SuggestionOverlayGeometry(
            caretRect: caretRect,
            inputFrameRect: inputFrameRect,
            caretQuality: .derived,
            bundleIdentifier: bundleIdentifier,
            focusedURLString: focusedURLString,
            isCaretAtEndOfLine: isCaretAtEndOfLine,
            observedCharWidth: observedCharWidth,
            isRightToLeft: isRightToLeft,
            focusChangeSequence: focusChangeSequence,
            focusedInputIdentityKey: focusedInputIdentityKey,
            isCorrection: isCorrection,
            resolvedFieldStyle: resolvedFieldStyle,
            hostTextMetrics: HostTextMetrics(
                sampleText: hostTextMetrics?.sampleText,
                sampleWidth: hostTextMetrics?.sampleWidth,
                lineRect: lineRect,
                linePitch: linePitch ?? hostTextMetrics?.linePitch
            ),
            isWebContentField: isWebContentField,
            hasTrailingContent: hasTrailingContent,
            isSingleLineField: isSingleLineField,
            elementFrameRect: elementFrameRect,
            lineTextBeforeCaret: lineTextBeforeCaret,
            wrappedRun: wrappedRun,
            pixelBaselineOffset: baselineOffsetFromTop,
            pixelLineInkWidth: lineInkWidth
        )
    }
}

/// The overlay is intentionally modeled as data so diagnostics can reason about visibility
/// without poking into AppKit window objects directly.
///
/// `visible` carries the active `CompletionRenderMode` so the focus debug overlay, tests, and
/// presenter state-diffing can distinguish an inline ghost from a mirror card without inspecting
/// `OverlayController` internals.
enum OverlayState: Equatable {
    case hidden(reason: String)
    case visible(text: String, geometry: SuggestionOverlayGeometry, mode: CompletionRenderMode)

    var isVisible: Bool {
        if case .visible = self {
            return true
        }

        return false
    }

    var visibleMode: CompletionRenderMode? {
        guard case let .visible(_, _, mode) = self else {
            return nil
        }
        return mode
    }
}
