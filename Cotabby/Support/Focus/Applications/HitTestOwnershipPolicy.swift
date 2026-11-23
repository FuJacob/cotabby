import Foundation

/// File overview:
/// Decides whether an element found by the Chromium cursor hit-test fallback may be adopted as the
/// frontmost app's focused field.
///
/// `FocusTracker` hit-tests at the mouse pointer only after every focused-element query failed for a
/// Chromium or Electron app. That hit-test is system-wide, so the element under the pointer can
/// belong to a different app whose window overlaps or sits beside the browser. The tracker then
/// attributes the element to the frontmost app, so adopting a foreign element would read another
/// app's field and judge it by the browser's per-app settings (disable list, terminal block, history
/// exclusions). This type is the ownership rule, kept pure so it can be tested without live AX.
///
/// AXFocused is deliberately not part of the rule: the fallback runs exactly when Chromium's focus
/// reporting already failed, and the tracker's existing AXFocused re-check of the adopted element
/// was not observed to pass on this path, so requiring it would disable the fallback outright.
nonisolated enum HitTestOwnershipPolicy {
    /// True when the element served by `elementPID` belongs to the frontmost application.
    ///
    /// Same process is the normal case: Chromium and Electron serve the whole composed AX tree,
    /// out-of-process iframes included, from the browser process, which is the app the user sees.
    /// The one cross-process case allowed is a Chromium app shim (an installed web app such as a
    /// Gmail window, bundle id `<browser id>.app.<app id>`): its window lives in the shim process
    /// while the browser process serves the web content inside it. `elementBundleIdentifier` is an
    /// `@autoclosure` because resolving it costs a process lookup that only that case needs.
    ///
    /// Fails closed: an unknown pid, or a mismatch that is not a shim and its host, is rejected.
    static func belongsToFrontmostApplication(
        elementPID: pid_t?,
        elementBundleIdentifier: @autoclosure () -> String?,
        frontmostPID: pid_t,
        frontmostBundleIdentifier: String?
    ) -> Bool {
        guard let elementPID, elementPID > 0, frontmostPID > 0 else { return false }
        if elementPID == frontmostPID { return true }
        guard let host = elementBundleIdentifier()?.lowercased(), !host.isEmpty,
              BrowserAppDetector.isChromiumBrowser(bundleIdentifier: host),
              let frontmost = frontmostBundleIdentifier?.lowercased()
        else {
            return false
        }
        return frontmost.hasPrefix(host + ".app.")
    }
}
