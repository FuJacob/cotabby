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

    /// Returns `true` when the coordinator should call `presentOverlay` for this reconcile tick.
    /// Returns `false` to hold the existing overlay geometry exactly as it was last drawn.
    ///
    /// Re-anchor when:
    ///   - The overlay is currently hidden (this is a fresh show).
    ///   - The focus session changed (different field, or the same field after focus toggled).
    ///   - The displayed text changed (user partially accepted, or typed-through advanced the tail).
    ///   - The host editor's frame moved on screen (window drag, sheet appear, etc.).
    static func shouldRePresent(
        currentOverlay: OverlayState,
        newText: String,
        newInputFrameRect: CGRect?,
        newFocusChangeSequence: UInt64
    ) -> Bool {
        guard case let .visible(currentText, currentGeometry) = currentOverlay else {
            return true
        }
        if currentGeometry.focusChangeSequence != newFocusChangeSequence {
            return true
        }
        if currentText != newText {
            return true
        }
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
