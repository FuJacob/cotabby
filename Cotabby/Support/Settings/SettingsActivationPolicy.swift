import AppKit

/// Decides which macOS activation policy Cotabby should run under.
///
/// Cotabby ships as an agent app (`LSUIElement` in `CotabbyInfo.plist`), which launches it as
/// `.accessory`: no Dock tile, no Command-Tab entry, no app menu bar. That is right while it only
/// lives in the menu bar, but it means a user who opens Settings can never Command-Tab back to it
/// after switching away. An `.accessory` process is simply not in the switcher.
///
/// The fix is to promote the process to `.regular` while Settings is open and demote it again when
/// Settings closes. `LSUIElement` stays in the plist because it only sets the *launch-time* policy,
/// and launching as an agent is what keeps a Dock icon from flashing at every login.
///
/// This stays a pure function in `Support/` so the rule is unit-testable without AppKit windows;
/// `SettingsCoordinator` owns the side effect of actually calling `setActivationPolicy`.
enum SettingsActivationPolicy {
    static func policy(isSettingsWindowOpen: Bool) -> NSApplication.ActivationPolicy {
        isSettingsWindowOpen ? .regular : .accessory
    }
}
