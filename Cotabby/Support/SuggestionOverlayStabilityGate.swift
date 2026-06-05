import CoreGraphics
import Foundation

/// File overview:
/// Pure decision for whether a reconcile tick should reposition the visible ghost-text overlay.
///
/// Why this file exists:
/// `SuggestionCoordinator` reconciles the active suggestion many times: on every focus poll, on
/// every settings publication, and on the +30ms post-insertion refresh that fires after each Tab
/// accept. The post-insertion path is the one that visibly hurts: AX commonly returns a slightly
/// drifted `caretRect` / `observedCharWidth` after a synthesized insertion, and re-rendering
/// against those drifted measurements is what causes the visible one-frame "shift left and down
/// then snap back" the user sees on accept. The gate below holds the existing geometry whenever
/// the field, text, and on-screen field bounds have not materially moved; legitimate context
/// changes (field switch, window drag, text change) still re-anchor. Keeping the rule outside the
/// coordinator means it can be unit-tested in isolation from any AppKit state.
enum SuggestionOverlayStabilityGate {
    /// Slack absorbed when comparing `inputFrameRect` between renders. 1pt is enough to swallow
    /// the sub-pixel noise that mixed Retina/non-Retina setups produce on consecutive AX reads
    /// of the same field, while still catching whole-pixel movements from a real window drag.
    private static let inputFrameTolerance: CGFloat = 1

    /// Caret drift (points) beyond which the overlay re-anchors to the fresh caret. Smaller deltas
    /// are held so the slightly different caret AX returns for the same position after a synthesized
    /// insertion, plus the sub-pixel residual of an exact-width advance, do not jitter the ghost.
    /// Because the fresh caret is compared against the held (advanced) caret, this also bounds
    /// cumulative advance drift to roughly this distance before a correction fires.
    ///
    /// 6pt is chosen to sit above typical post-insertion AX caret noise (~0.5-1pt) and the per-accept
    /// kerning residual, yet below a single character's advance in common body fonts (~7-10pt at 14pt),
    /// so a genuine one-character caret move still re-anchors while noise and residual are absorbed.
    private static let caretDriftTolerance: CGFloat = 6

    /// Returns `true` when the coordinator should call `presentOverlay` for this reconcile tick.
    /// Returns `false` to hold the existing overlay geometry exactly as it was last drawn.
    ///
    /// Re-anchor when:
    ///   - The overlay is currently hidden (this is a fresh show).
    ///   - The focus session changed (different field, or the same field after focus toggled).
    ///   - The displayed text changed (user partially accepted, or typed-through advanced the tail).
    ///   - The caret moved beyond `caretDriftTolerance` from where the overlay is currently anchored
    ///     (a genuine caret move, or accumulated advance drift that needs correcting).
    ///   - The host editor's frame moved on screen (window drag, sheet appear, etc.).
    static func shouldRePresent(
        currentOverlay: OverlayState,
        newText: String,
        newCaretRect: CGRect,
        newInputFrameRect: CGRect?,
        newFocusChangeSequence: UInt64
    ) -> Bool {
        // Render mode is the third associated value; it is not part of the stability decision, so
        // we ignore it. A mode change still re-anchors because text or geometry will also differ.
        guard case let .visible(currentText, currentGeometry, _) = currentOverlay else {
            return true
        }
        if currentGeometry.focusChangeSequence != newFocusChangeSequence {
            return true
        }
        if currentText != newText {
            return true
        }
        // Hold small caret deltas (post-insertion AX noise and exact-advance residual); re-anchor on
        // genuine moves and on accumulated drift past the tolerance. Compared against the held
        // (already-advanced) caret, not a per-tick previous value, so slow drift still gets corrected.
        if abs(currentGeometry.caretRect.origin.x - newCaretRect.origin.x) > caretDriftTolerance
            || abs(currentGeometry.caretRect.origin.y - newCaretRect.origin.y) > caretDriftTolerance {
            return true
        }
        // `observedCharWidth` is intentionally NOT compared here. Drift in that value also affects
        // `GhostSuggestionLayout.singleLineFits` (and therefore the panel-origin branch), so during
        // a sustained window drag where `inputFrameRect` also moves, the first re-anchor past the
        // tolerance can render with a drifted char-width for one frame. Including char-width in the
        // gate would re-introduce the post-accept jitter this file exists to suppress, so we accept
        // the drag-time tradeoff. If a future host shows the wrong-layout frame in practice, the fix
        // belongs in `GhostSuggestionLayout` (smoothing char-width) rather than this gate.
        switch (currentGeometry.inputFrameRect, newInputFrameRect) {
        case (nil, nil):
            return false
        case (nil, _), (_, nil):
            return true
        case let (old?, new?):
            return abs(old.origin.x - new.origin.x) > inputFrameTolerance
                || abs(old.origin.y - new.origin.y) > inputFrameTolerance
                || abs(old.size.width - new.size.width) > inputFrameTolerance
                || abs(old.size.height - new.size.height) > inputFrameTolerance
        }
    }
}
