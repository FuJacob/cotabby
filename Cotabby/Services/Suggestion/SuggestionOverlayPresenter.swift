import CoreGraphics
import Foundation

/// File overview:
/// Adapts coordinator intent into overlay-controller actions. The coordinator still decides when
/// a suggestion should be visible, but this helper owns the small UX rules for whether the overlay
/// is actually changing and which status message should accompany that change.
///
/// This separation is useful because overlay bugs often mix two concerns:
/// "should ghost text be shown?" and "what AppKit action did we take?" Those questions now live in
/// different places.
@MainActor
struct SuggestionOverlayPresenter {
    private let overlayController: any SuggestionOverlayControlling

    init(overlayController: any SuggestionOverlayControlling) {
        self.overlayController = overlayController
    }

    /// Shows or repositions ghost text while preserving the previous overlay message when nothing changed.
    ///
    /// The state diff intentionally ignores the active `CompletionRenderMode` when deciding whether
    /// to skip the AppKit call: the controller picks the mode internally each time and re-applying
    /// the same text/geometry is cheap. The diagnostic messages below do distinguish a mode flip so
    /// operators see when inline → mirror (or back) actually happened.
    func present(
        text: String,
        geometry: SuggestionOverlayGeometry,
        previousState: OverlayState
    ) -> String? {
        let displayText = text.trimmingCharacters(in: .whitespaces).isEmpty ? "" : text
        guard !displayText.isEmpty else {
            return hide(reason: "Overlay hidden because the suggestion text was empty.")
        }

        // Compare against the previous visible content while ignoring `mode`, which the controller
        // resolves from geometry each call. If the controller swaps modes for the same text+geometry
        // it does the resulting state transition; we still need to invoke `showSuggestion` so the
        // panel re-renders.
        if case let .visible(previousText, previousGeometry, _) = previousState,
           previousText == displayText,
           previousGeometry == geometry {
            return nil
        }

        overlayController.showSuggestion(displayText, geometry: geometry)

        switch previousState {
        case .visible(let previousText, let previousGeometry, let previousMode)
        where previousText == displayText
            && previousGeometry.caretRect == geometry.caretRect
            && previousMode.isMirror != currentModeIsMirror():
            return "Switched overlay render mode for the latest geometry."

        case .visible(let previousText, let previousGeometry, _)
        where previousText == displayText
            && previousGeometry.caretRect == geometry.caretRect
            && previousGeometry.caretQuality != geometry.caretQuality:
            return "Updated ghost text styling for the latest caret quality."

        case .visible(let previousText, let previousGeometry, _)
        where previousText == displayText && previousGeometry.caretRect != geometry.caretRect:
            return "Moved ghost text to the latest caret position."

        case .visible(let previousText, _, _)
        where previousText == displayText:
            return "Updated ghost text layout for the latest input bounds."

        default:
            return "Displayed ghost text near the caret."
        }
    }

    /// Reads the live overlay state after the controller updated it, so the mode-flip diagnostic
    /// reflects whatever the controller actually picked this presentation.
    private func currentModeIsMirror() -> Bool {
        overlayController.state.visibleMode?.isMirror ?? false
    }

    func hide(reason: String) -> String {
        overlayController.hide(reason: reason)
        return reason
    }
}
