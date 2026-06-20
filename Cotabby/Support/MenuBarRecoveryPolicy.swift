import Foundation

/// Decides whether a cold launch needs to reveal Settings as a recovery surface.
///
/// This pure policy lives in `Support/` so AppKit launch details stay in `AppDelegate`, while the
/// product rule remains deterministic and unit-testable. Manual launches recover users who hid the
/// status item; login-item launches remain background-only; the development override always wins.
enum MenuBarRecoveryPolicy {
    static func shouldShowSettingsOnColdLaunch(
        isMenuBarIconVisible: Bool,
        wasLaunchedAtLogin: Bool,
        wasSettingsExplicitlyRequested: Bool
    ) -> Bool {
        wasSettingsExplicitlyRequested
            || (!isMenuBarIconVisible && !wasLaunchedAtLogin)
    }

    /// Lets AppKit perform its normal reopen work when the status item is available, or when the app
    /// already has visible windows and the Settings window exists (so AppKit can activate/restore it).
    /// If only a non-Settings window is visible, Cotabby still opens Settings as the recovery surface.
    static func shouldLetAppKitHandleReopen(
        isMenuBarIconVisible: Bool,
        hasVisibleWindows: Bool,
        isSettingsWindowOpen: Bool
    ) -> Bool {
        isMenuBarIconVisible
            || (hasVisibleWindows && isSettingsWindowOpen)
    }
}
