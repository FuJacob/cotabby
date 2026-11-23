import CoreGraphics
import Foundation

/// File overview:
/// Adapts coordinator intent into overlay-controller actions. The coordinator still decides when
/// a suggestion should be visible; this helper owns the two small rules for whether that intent
/// reaches AppKit at all: whitespace-only text hides instead of showing, and re-presenting the
/// text and geometry already on screen is skipped.
@MainActor
struct SuggestionOverlayPresenter {
    private let overlayController: any SuggestionOverlayControlling

    init(overlayController: any SuggestionOverlayControlling) {
        self.overlayController = overlayController
    }

    /// Shows or repositions ghost text. Returns false when the request matched what is already
    /// visible and no controller call was made, so callers can tell a real presentation from a
    /// repeat.
    ///
    /// The comparison ignores the active `CompletionRenderMode`: the controller resolves the mode
    /// from geometry on every call, so a mode flip for unchanged text and geometry is its own
    /// state transition and needs no second `showSuggestion` from here.
    @discardableResult
    func present(
        text: String,
        geometry: SuggestionOverlayGeometry,
        previousState: OverlayState
    ) -> Bool {
        let displayText = text.trimmingCharacters(in: .whitespaces).isEmpty ? "" : text
        guard !displayText.isEmpty else {
            hide(reason: "Overlay hidden because the suggestion text was empty.")
            return true
        }

        if case let .visible(previousText, previousGeometry, _) = previousState,
           previousText == displayText,
           previousGeometry == geometry {
            return false
        }

        overlayController.showSuggestion(displayText, geometry: geometry)
        return true
    }

    func hide(reason: String) {
        overlayController.hide(reason: reason)
    }
}
