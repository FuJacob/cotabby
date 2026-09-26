import Foundation

/// File overview:
/// The pure decision behind Cotabby's "never complete inside our own UI" rule and its single
/// sanctioned exception. It is kept free of Accessibility objects and timer state so the invariant
/// that matters most here can be unit-tested directly: completions must never leak into Cotabby's own
/// settings surfaces (search field, Extended Context editor, menus) except the one live-preview box.
///
/// `FocusTracker` owns the AX reads; it hands the focused element's bundle and identifier to this type
/// and lets it answer yes/no.
enum SelfCaptureGate {
    /// Whether the focus pipeline may capture the currently focused element.
    ///
    /// Apps other than Cotabby are always allowed: this rule only constrains capturing Cotabby's own
    /// UI. When Cotabby itself is focused, capture is allowed only for the sanctioned element (the
    /// Context pane's live-preview field, matched by AX identifier) and blocked for everything else.
    ///
    /// Fails closed: with no sanctioned identifier configured, or an element whose identifier cannot
    /// be read, self-capture stays blocked. `focusedElementIdentifier` is an `@autoclosure` so the AX
    /// read it usually wraps is skipped entirely for every other app (the common path, run on every
    /// poll tick).
    static func allowsCapture(
        focusedBundleIdentifier: String?,
        ignoredBundleIdentifier: String?,
        focusedElementIdentifier: @autoclosure () -> String?,
        sanctionedElementIdentifier: String?
    ) -> Bool {
        // Not our own process: untouched by this rule.
        guard focusedBundleIdentifier == ignoredBundleIdentifier else { return true }
        // Our own process: allow only the one sanctioned element.
        guard let sanctioned = sanctionedElementIdentifier else { return false }
        return focusedElementIdentifier() == sanctioned
    }
}
