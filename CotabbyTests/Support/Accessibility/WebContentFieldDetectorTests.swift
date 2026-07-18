import XCTest
@testable import Cotabby

/// Locks the web-vs-native field classification the caret-geometry trust policy depends on.
/// A false negative here merely forgoes a repair (pre-estimator behavior); a false positive
/// exposes trustworthy native AX geometry to estimator overrides, which is the Notes-class
/// regression the detector exists to prevent.
final class WebContentFieldDetectorTests: XCTestCase {
    // MARK: - DOM-attribute signal

    func test_domIdentifierMarksElementAsWebContent() {
        XCTAssertTrue(WebContentFieldDetector.vendsDOMAttributes(["AXRole", "AXDOMIdentifier"]))
    }

    func test_domClassListMarksElementAsWebContent() {
        XCTAssertTrue(WebContentFieldDetector.vendsDOMAttributes(["AXDOMClassList"]))
    }

    func test_nativeAttributeSetDoesNotMarkElementAsWebContent() {
        // The attribute surface Apple Notes' body text area actually advertises (probed live):
        // a rich native text element, no DOM reflection.
        XCTAssertFalse(
            WebContentFieldDetector.vendsDOMAttributes(
                ["AXRole", "AXValue", "AXSelectedTextRange", "AXFrame", "AXNumberOfCharacters"]
            )
        )
    }

    // MARK: - Combined classification

    func test_unknownElectronBundleWithDOMAttributesIsWebContent() {
        // Cursor ships under opaque per-build `com.todesktop.*` bundle ids no allowlist can
        // track; the element-level DOM signal is what catches it.
        XCTAssertTrue(
            WebContentFieldDetector.isWebContentField(
                bundleIdentifier: "com.todesktop.230313mzl4w4u92",
                vendsDOMAttributes: true
            )
        )
    }

    func test_browserChromeFieldWithoutDOMAttributesIsWebContent() {
        // The omnibox is not DOM-backed but still speaks the browser toolkit's AX dialect, not
        // AppKit's, so it stays inside the estimator's jurisdiction.
        XCTAssertTrue(
            WebContentFieldDetector.isWebContentField(
                bundleIdentifier: "com.google.Chrome",
                vendsDOMAttributes: false
            )
        )
    }

    func test_safariIsWebContentByBundle() {
        XCTAssertTrue(
            WebContentFieldDetector.isWebContentField(
                bundleIdentifier: "com.apple.Safari",
                vendsDOMAttributes: false
            )
        )
    }

    func test_electronEditorBundleIsWebContent() {
        XCTAssertTrue(
            WebContentFieldDetector.isWebContentField(
                bundleIdentifier: "com.microsoft.VSCode",
                vendsDOMAttributes: false
            )
        )
    }

    func test_nativeAppIsNotWebContent() {
        XCTAssertFalse(
            WebContentFieldDetector.isWebContentField(
                bundleIdentifier: "com.apple.Notes",
                vendsDOMAttributes: false
            )
        )
    }

    func test_unknownBundleDefaultsToNative() {
        // Unknown hosts default to the conservative side: keeping pre-repair behavior can never
        // be worse than before the estimator existed.
        XCTAssertFalse(
            WebContentFieldDetector.isWebContentField(
                bundleIdentifier: "com.example.SomeNativeApp",
                vendsDOMAttributes: false
            )
        )
    }

    func test_nilBundleDefaultsToNative() {
        XCTAssertFalse(
            WebContentFieldDetector.isWebContentField(
                bundleIdentifier: nil,
                vendsDOMAttributes: false
            )
        )
    }

    func test_embeddedWebViewInNativeAppIsWebContent() {
        // A WKWebView-hosted field inside a non-browser app: the bundle says native, the element
        // says web. The element wins, because the text is rendered by the web engine.
        XCTAssertTrue(
            WebContentFieldDetector.isWebContentField(
                bundleIdentifier: "com.example.SomeNativeApp",
                vendsDOMAttributes: true
            )
        )
    }
}
