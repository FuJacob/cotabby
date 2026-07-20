import Foundation

/// Classifies applications by browser family from their bundle identifier.
///
/// Two distinct questions live here on purpose:
///
/// - `isBrowser` is the broad "is the user typing in a web browser" check used for prompt tone
///   hints. It includes Safari and Firefox.
/// - `needsWebAccessibilityPriming` is the narrow "does this app hide its web text behind the
///   Chromium/Electron lazy-accessibility model" check that gates the expensive AX recovery paths
///   (renderer priming, cursor hit-testing, deeper candidate walks). It deliberately excludes
///   Safari/Firefox: WebKit builds its accessibility tree without an assistive client flipping a
///   flag, and Gecko does not use the Chromium text-marker model, so priming/hit-testing buys
///   nothing there and would only widen the blast radius.
///
/// Matching is by case-insensitive bundle-identifier prefix to tolerate channel suffixes
/// (`com.google.Chrome.canary`, `com.google.Chrome.beta`, etc.).
nonisolated enum BrowserAppDetector {
    /// Every browser family, used for the broad "typing in a browser" tone hint.
    private static let browserBundlePrefixes: [String] = [
        "com.apple.safari",
        "com.apple.safaritechnologypreview",
        "com.google.chrome",
        "org.mozilla.firefox",
        "company.thebrowser.browser",  // Arc
        "com.brave.browser",
        "com.microsoft.edgemac"
    ]

    /// Chromium-family browsers whose web content uses the lazy web-AX tree and opaque text-marker
    /// selection model. Safari/Firefox are intentionally absent (see type doc).
    private static let chromiumBundlePrefixes: [String] = [
        "com.google.chrome",
        "company.thebrowser.browser",  // Arc
        "com.brave.browser",
        "com.microsoft.edgemac"
    ]

    /// Electron apps (Chromium under the hood) that ship editors worth covering. This is an
    /// intentional named allowlist, not a blanket Electron opt-in: most Electron apps are not
    /// text-editing surfaces, and priming them wholesale risks unexpected behavior.
    ///
    /// Entries are lowercased and matched case-insensitively (see `isElectronEditor`). VS Code's real
    /// bundle id is the mixed-case `com.microsoft.VSCode`, so an exact match would silently miss it
    /// and leave the editor's entire Electron AX tree dormant: no focused field resolves for the
    /// editor, the Copilot chat, or the integrated terminal, so no suggestions appear anywhere in the
    /// app even though screenshot-based OCR keeps working.
    ///
    /// Cursor is intentionally absent: it ships under opaque ToDesktop bundle ids
    /// (`com.todesktop.<hash>`) that change between builds, so there is no stable id to allowlist
    /// here without a broad `com.todesktop.` prefix that would also prime unrelated ToDesktop apps.
    private static let electronEditorBundleIdentifiers: Set<String> = [
        "com.clickup.desktop-app",
        "com.microsoft.vscode",          // Visual Studio Code
        "com.microsoft.vscodeinsiders",  // VS Code - Insiders
        "com.vscodium"                   // VSCodium (FOSS VS Code build)
    ]

    /// Broad check: is the user typing inside any web browser? Used for prompt tone hints.
    static func isBrowser(bundleIdentifier: String?) -> Bool {
        hasMatchingPrefix(bundleIdentifier, in: browserBundlePrefixes)
    }

    /// Narrow check: is this a Chromium-family browser (web content via lazy web-AX + text markers)?
    static func isChromiumBrowser(bundleIdentifier: String?) -> Bool {
        hasMatchingPrefix(bundleIdentifier, in: chromiumBundlePrefixes)
    }

    /// Is this a named Electron editor we intentionally cover? Case-insensitive because macOS bundle
    /// ids are case-insensitive in practice and VS Code's is mixed-case (`com.microsoft.VSCode`); a
    /// case-sensitive exact match here was the reason VS Code resolved no focus and got no suggestions.
    static func isElectronEditor(bundleIdentifier: String?) -> Bool {
        guard let lowered = bundleIdentifier?.lowercased() else { return false }
        return electronEditorBundleIdentifiers.contains(lowered)
    }

    /// Gate for the Chromium/Electron-specific AX recovery paths (renderer priming, cursor
    /// hit-testing, deeper candidate walk). True only for apps that actually hide web text behind
    /// the lazy web-AX model.
    static func needsWebAccessibilityPriming(bundleIdentifier: String?) -> Bool {
        isChromiumBrowser(bundleIdentifier: bundleIdentifier)
            || isElectronEditor(bundleIdentifier: bundleIdentifier)
    }

    private static func hasMatchingPrefix(_ bundleIdentifier: String?, in prefixes: [String]) -> Bool {
        guard let lower = bundleIdentifier?.lowercased() else { return false }
        return prefixes.contains { lower.hasPrefix($0) }
    }
}
