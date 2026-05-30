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

    /// Primes the application if it is a Chromium/Electron surface we cover and has not been primed
    /// (or marked unsupported) yet. Safe to call every poll tick.
    func primeIfNeeded(application: NSRunningApplication) {
        guard BrowserAppDetector.needsWebAccessibilityPriming(
            bundleIdentifier: application.bundleIdentifier)
        else {
            return
        }

        let pid = application.processIdentifier
        guard pid > 0, !primedPIDs.contains(pid), !unsupportedPIDs.contains(pid) else {
            return
        }

        switch AXHelper.setManualAccessibility(true, forApplicationPID: pid) {
        case .success:
            primedPIDs.insert(pid)
            CotabbyLogger.focus.debug(
                "CHROME-PRIME enabled web accessibility for \(application.localizedName ?? "?")")
        case .attributeUnsupported:
            // Electron build that does not expose AXManualAccessibility; stop retrying.
            unsupportedPIDs.insert(pid)
        default:
            // Transient (app still launching, busy): leave it unmarked so the next tick retries.
            break
        }
    }
}
