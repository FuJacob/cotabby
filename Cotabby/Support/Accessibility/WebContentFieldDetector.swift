import Foundation

/// File overview:
/// Classifies whether a focused text field's content is rendered by a web engine
/// (Chromium/WebKit/Gecko) rather than a native macOS text view. The caret layout repair uses
/// this to decide how much authority the hidden-text-layout estimate has over AX-measured
/// geometry: web engines have known wrong-line caret-bounds pathologies the estimate exists to
/// repair, while native AX bounds come from the app's real layout manager and outrank any
/// re-layout Cotabby could compute.
///
/// Why this distinction is trustworthy: probing real hosts showed both sides concretely.
/// Apple Notes (native TextKit) answers per-character `AXBoundsForRange` with rects that match
/// its rendered lines exactly, including the taller title line (23pt) above 16pt body lines,
/// which a uniform hidden layout cannot model; its geometry must win. Gmail in Chrome answers
/// the same queries through the renderer's lossy AX bridge, which maps carets into neighboring
/// visual lines around blank lines; there the estimate must be allowed to override.
///
/// Two independent signals, either of which marks a field as web content:
///   - The element vends DOM-reflection attributes (`AXDOMIdentifier`/`AXDOMClassList`).
///     Chromium and WebKit attach these to web-content nodes only; native AppKit elements never
///     vend them. This catches web fields in apps no bundle list could anticipate (opaque
///     Electron bundle ids like Cursor's `com.todesktop.*`, or a WKWebView embedded in a native
///     app).
///   - The host bundle is a known browser or Electron editor (`BrowserAppDetector`). This covers
///     browser-chrome fields (e.g. the omnibox) that are not DOM-backed but still speak the
///     browser toolkit's AX dialect rather than AppKit's, and engines whose DOM reflection is
///     absent (Gecko).
///
/// Defaulting unknown hosts to "native" is deliberate: the failure mode for a misclassified
/// native field is keeping pre-repair behavior (never worse than before the estimator existed),
/// while misclassifying a web field merely forgoes a repair.
enum WebContentFieldDetector {
    /// Attribute names only web-engine accessibility nodes vend. Checked against the element's
    /// advertised attribute list, which the focus resolver already fetches, so this costs no
    /// extra AX round-trip.
    private static let domReflectionAttributes: Set<String> = [
        "AXDOMIdentifier",
        "AXDOMClassList"
    ]

    /// Whether the element's advertised attribute names mark it as a web-content node.
    static func vendsDOMAttributes(_ attributeNames: Set<String>) -> Bool {
        !domReflectionAttributes.isDisjoint(with: attributeNames)
    }

    /// Whether the focused field should be treated as web-rendered content for caret-geometry
    /// trust decisions.
    static func isWebContentField(
        bundleIdentifier: String?,
        vendsDOMAttributes: Bool
    ) -> Bool {
        if vendsDOMAttributes {
            return true
        }
        return BrowserAppDetector.isBrowser(bundleIdentifier: bundleIdentifier)
            || BrowserAppDetector.isElectronEditor(bundleIdentifier: bundleIdentifier)
    }
}
