import AppKit
import ApplicationServices
import Foundation
import Logging

/// Wakes the dormant web-accessibility tree of Chromium-family browsers and allowlisted Electron
/// editors so their web text becomes readable.
///
/// Chromium and Electron build their web accessibility tree lazily: it stays asleep until an
/// assistive-technology client signals interest by setting `AXManualAccessibility` on the
/// application. Without this, a Chrome renderer reports itself AX-unaware and the system-wide
/// focus query keeps returning the omnibox (or nil) no matter where the user clicks in the page.
///
/// Priming is set on the **browser process** element, never on renderer subprocesses (which have
/// no OS-level AX element); the browser owns the composed tree and fans the request out to
/// renderers over IPC. New tabs/renderers spawned after Cotabby launches are covered because the
/// browser rebuilds the tree on demand once primed.
///
/// `@MainActor` because all AX calls must run on the main thread, matching `FocusTracker`.
@MainActor
final class ChromiumAccessibilityEnabler {
    /// Browser PIDs already primed successfully. Throttles priming to once per process so the
    /// per-tick call is a cheap set lookup.
    private var primedPIDs: Set<pid_t> = []

    /// Browser PIDs that rejected `AXManualAccessibility` as unsupported (some Electron builds do
    /// not advertise it). Recorded so we stop retrying a doomed call every tick.
    private var unsupportedPIDs: Set<pid_t> = []

    /// The frontmost PID seen on the previous poll tick, used to detect activation edges. Updated on
    /// every call (including for apps we never prime) so a switch away and back is always an edge.
    private var lastFrontmostPID: pid_t?

    /// Primes the application if it is a Chromium/Electron surface we cover and has not been primed
    /// (or marked unsupported) yet. Safe to call every poll tick.
    ///
    /// Electron editors are additionally re-primed on every activation edge (each time the app
    /// becomes frontmost), not just once per PID. Observed on VS Code: the first
    /// `AXManualAccessibility` write returns success while the app is long-running, yet the web-AX
    /// tree stays dormant for minutes; a later re-assert wakes it promptly. One extra AX write per
    /// app switch is negligible, and Chromium browsers keep the once-per-PID behavior that already
    /// works for them.
    func primeIfNeeded(application: NSRunningApplication) {
        let pid = application.processIdentifier
        let isActivationEdge = pid != lastFrontmostPID
        lastFrontmostPID = pid

        guard BrowserAppDetector.needsWebAccessibilityPriming(
            bundleIdentifier: application.bundleIdentifier)
        else {
            return
        }

        guard pid > 0, !unsupportedPIDs.contains(pid) else {
            return
        }

        let reassertForElectronEditor = isActivationEdge
            && BrowserAppDetector.isElectronEditor(bundleIdentifier: application.bundleIdentifier)
        guard !primedPIDs.contains(pid) || reassertForElectronEditor else {
            return
        }

        switch AXHelper.setManualAccessibility(true, forApplicationPID: pid) {
        case .success:
            primedPIDs.insert(pid)
            CotabbyLogger.focus.debug(
                "CHROME-PRIME enabled web accessibility for \(application.localizedName ?? "?")")
        case .attributeUnsupported:
            // `AXManualAccessibility` is an Electron addition; Chrome itself rejects it. Chrome's
            // full accessibility mode (the one that computes inline text boxes, so character bounds
            // and font attributes exist) is switched on by the VoiceOver signal instead. Without it
            // Chrome answers caret markers but never character bounds or fonts, and the ghost can
            // only guess the host's typeface. Measured 2026-09: all four test fields returned empty
            // bounds and an empty font dictionary until this flag was set.
            if BrowserAppDetector.isChromiumBrowser(bundleIdentifier: application.bundleIdentifier),
               !Self.isEnhancedUserInterfaceDisabled {
                if AXHelper.setEnhancedUserInterface(true, forApplicationPID: pid) {
                    primedPIDs.insert(pid)
                    CotabbyLogger.focus.debug(
                        "CHROME-PRIME enabled enhanced accessibility for \(application.localizedName ?? "?")")
                    return
                }
            }
            unsupportedPIDs.insert(pid)
        default:
            // Transient (app still launching, busy): leave it unmarked so the next tick retries.
            break
        }
    }

    /// Kill switch for the Chromium enhanced-accessibility fallback. Some window managers misplace
    /// windows of apps that have `AXEnhancedUserInterface` set; a user who hits that can turn the
    /// fallback off and keep the caret-marker geometry (with font matching by size only).
    static let enhancedUserInterfaceDisabledDefaultsKey = "cotabbyChromiumEnhancedAccessibilityDisabled"

    private static var isEnhancedUserInterfaceDisabled: Bool {
        UserDefaults.standard.bool(forKey: enhancedUserInterfaceDisabledDefaultsKey)
    }
}
