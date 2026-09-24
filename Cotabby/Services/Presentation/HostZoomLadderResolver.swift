import AppKit

/// File overview:
/// Which zoom ladder (`HostZoomLadder.Kind`) a host app paints on, decided once per bundle.
///
/// Chromium browsers are known by bundle id (`BrowserAppDetector`). An Electron app is known by the
/// framework every Electron app carries in its bundle, `Contents/Frameworks/Electron
/// Framework.framework` (Claude, Obsidian and VS Code on this Mac); no bundle-id list could keep up
/// with them, and the list of Electron editors worth priming is deliberately short. Any other host
/// has no ladder, and its measured sizes stand.
///
/// Owned by `OverlayController` for the app's lifetime, beside `HostBundledFontRegistry`, which
/// finds a host's bundle the same way. One file-existence check per bundle, cached.
@MainActor
final class HostZoomLadderResolver {
    private var kinds: [String: HostZoomLadder.Kind?] = [:]

    func kind(forBundleIdentifier bundleIdentifier: String?) -> HostZoomLadder.Kind? {
        guard let bundleIdentifier else { return nil }
        if let known = kinds[bundleIdentifier] {
            return known
        }
        let kind: HostZoomLadder.Kind?
        if BrowserAppDetector.isChromiumBrowser(bundleIdentifier: bundleIdentifier) {
            kind = .chromeBrowser
        } else if let bundleURL = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?.bundleURL {
            let framework = bundleURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework", isDirectory: true)
            kind = FileManager.default.fileExists(atPath: framework.path) ? .electron : nil
        } else {
            // Not running: nothing is rendered for it now, and the next lookup asks again.
            return nil
        }
        kinds[bundleIdentifier] = kind
        return kind
    }
}
