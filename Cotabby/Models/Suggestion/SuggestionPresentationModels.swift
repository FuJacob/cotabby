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

    var shortLabel: String {
        switch self {
        case .idle:
            return "Idle"
        case .disabled:
            return "Disabled"
        case .debouncing:
            return "Debouncing"
        case .generating:
            return "Generating"
        case .ready:
            return "Ready"
        case .failed:
            return "Failed"
        }
    }

    var detail: String? {
        switch self {
        case .idle:
            return "No active suggestion is currently available."
        case let .disabled(reason), let .failed(reason):
            return reason
        case .debouncing:
            return "Waiting for typing to settle."
        case .generating:
            return "Requesting a completion from the active suggestion backend."
        case .ready:
            return "Ready means Cotabby has buffered a non-empty normalized completion for this field and can render it as ghost text."
        }
    }
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

    init(
        caretRect: CGRect,
        inputFrameRect: CGRect?,
        caretQuality: CaretGeometryQuality,
        isCaretAtEndOfLine: Bool = true,
        observedCharWidth: CGFloat?,
        isRightToLeft: Bool,
        focusChangeSequence: UInt64 = 0,
        focusedInputIdentityKey: UInt64 = 0,
        isCorrection: Bool = false,
        resolvedFieldStyle: ResolvedFieldStyle? = nil
    ) {
        self.caretRect = caretRect
        self.inputFrameRect = inputFrameRect
        self.caretQuality = caretQuality
        self.isCaretAtEndOfLine = isCaretAtEndOfLine
        self.observedCharWidth = observedCharWidth
        self.isRightToLeft = isRightToLeft
        self.focusChangeSequence = focusChangeSequence
        self.focusedInputIdentityKey = focusedInputIdentityKey
        self.isCorrection = isCorrection
        self.resolvedFieldStyle = resolvedFieldStyle
    }

    /// Returns a copy with only `caretRect` replaced. Used to advance the ghost by an exact measured
    /// width on word acceptance without re-reading (and re-jittering against) a fresh AX caret.
    func withCaretRect(_ caretRect: CGRect) -> SuggestionOverlayGeometry {
        SuggestionOverlayGeometry(
            caretRect: caretRect,
            inputFrameRect: inputFrameRect,
            caretQuality: caretQuality,
            isCaretAtEndOfLine: isCaretAtEndOfLine,
            observedCharWidth: observedCharWidth,
            isRightToLeft: isRightToLeft,
            focusChangeSequence: focusChangeSequence,
            focusedInputIdentityKey: focusedInputIdentityKey,
            resolvedFieldStyle: resolvedFieldStyle
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

    var shortLabel: String {
        switch self {
        case .hidden:
            return "Hidden"
        case .visible:
            return "Visible"
        }
    }

    var detail: String {
        switch self {
        case let .hidden(reason):
            return reason
        case let .visible(text, geometry, mode):
            return "Showing \(text.count) characters near " +
                "(\(Int(geometry.caretRect.minX)), \(Int(geometry.caretRect.minY))) " +
                "using \(geometry.caretQuality.label) caret geometry (\(mode.label))."
        }
    }

    var isVisible: Bool {
        if case .visible = self {
            return true
        }

        return false
    }

    var visibleText: String? {
        guard case let .visible(text, _, _) = self else {
            return nil
        }

        return text
    }

    var visibleMode: CompletionRenderMode? {
        guard case let .visible(_, _, mode) = self else {
            return nil
        }
        return mode
    }
}
