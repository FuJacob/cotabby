import Foundation

/// Decides how Cotabby reveals Settings as a recovery surface on cold launch and on reopen.
///
/// This pure policy lives in `Support/` so AppKit launch details stay in `AppDelegate`, while the
/// product rule remains deterministic and unit-testable. Manual launches recover users who hid the
/// status item; login-item launches remain background-only; the development override always wins.
enum MenuBarRecoveryPolicy {
    /// What `applicationShouldHandleReopen` should do. The two Settings cases call the same
    /// `showSettings()` path; they stay distinct so the delegate only logs the recovery case.
    enum ReopenAction: Equatable {
        /// The status item is the user's way back in, so AppKit's default reopen handling is enough.
        case letAppKitHandle
        /// Settings already exists, possibly minimized. While it exists Cotabby has a Dock tile, so
        /// this is usually a Dock click. AppKit does not reliably deminiaturize on reopen, so Cotabby
        /// restores the single existing window itself.
        case focusExistingSettings
        /// Neither the status item nor Settings is available, so without this the reopen would
        /// produce no visible response at all.
        case openSettingsForRecovery
    }

    static func shouldShowSettingsOnColdLaunch(
        isMenuBarIconVisible: Bool,
        wasLaunchedAtLogin: Bool,
        wasSettingsExplicitlyRequested: Bool
    ) -> Bool {
        wasSettingsExplicitlyRequested
            || (!isMenuBarIconVisible && !wasLaunchedAtLogin)
    }

    /// An existing Settings window wins over the status item, because handing a minimized window to
    /// AppKit leaves it parked in the Dock. AppKit's `hasVisibleWindows` flag is deliberately not an
    /// input: once Settings is ruled out, a visible Welcome or permission window is not a way back to
    /// Cotabby's controls, so only the status item's visibility decides.
    static func reopenAction(
        isMenuBarIconVisible: Bool,
        isSettingsWindowOpen: Bool
    ) -> ReopenAction {
        if isSettingsWindowOpen {
            return .focusExistingSettings
        }
        return isMenuBarIconVisible ? .letAppKitHandle : .openSettingsForRecovery
    }
}
