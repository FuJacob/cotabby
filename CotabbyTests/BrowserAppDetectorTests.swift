import XCTest
@testable import Cotabby

/// Verifies `BrowserAppDetector`'s two distinct classifications: the broad `isBrowser` used for
/// prompt tone hints, and the narrow `needsWebAccessibilityPriming` that gates the Chromium/Electron
/// AX recovery paths. The split matters: Safari/Firefox are browsers but must NOT trigger priming
/// or hit-testing.
final class BrowserAppDetectorTests: XCTestCase {
    func testIsBrowserCoversAllFamiliesIncludingSafariAndFirefox() {
        XCTAssertTrue(BrowserAppDetector.isBrowser(bundleIdentifier: "com.google.Chrome"))
        XCTAssertTrue(BrowserAppDetector.isBrowser(bundleIdentifier: "com.apple.Safari"))
        XCTAssertTrue(BrowserAppDetector.isBrowser(bundleIdentifier: "org.mozilla.firefox"))
        XCTAssertTrue(BrowserAppDetector.isBrowser(bundleIdentifier: "com.brave.Browser"))
        XCTAssertTrue(BrowserAppDetector.isBrowser(bundleIdentifier: "company.thebrowser.Browser"))
        XCTAssertFalse(BrowserAppDetector.isBrowser(bundleIdentifier: "com.apple.Terminal"))
        XCTAssertFalse(BrowserAppDetector.isBrowser(bundleIdentifier: nil))
    }

    func testMatchingIsCaseInsensitiveAndPrefixBased() {
        // Channel suffixes (canary/beta) and case variations still match the family prefix.
        XCTAssertTrue(BrowserAppDetector.isChromiumBrowser(bundleIdentifier: "com.google.Chrome.canary"))
        XCTAssertTrue(BrowserAppDetector.isChromiumBrowser(bundleIdentifier: "COM.GOOGLE.CHROME"))
    }

    func testChromiumExcludesSafariAndFirefox() {
        XCTAssertTrue(BrowserAppDetector.isChromiumBrowser(bundleIdentifier: "com.google.Chrome"))
        XCTAssertTrue(BrowserAppDetector.isChromiumBrowser(bundleIdentifier: "com.microsoft.edgemac"))
        XCTAssertTrue(BrowserAppDetector.isChromiumBrowser(bundleIdentifier: "com.brave.Browser"))
        XCTAssertFalse(BrowserAppDetector.isChromiumBrowser(bundleIdentifier: "com.apple.Safari"))
        XCTAssertFalse(BrowserAppDetector.isChromiumBrowser(bundleIdentifier: "org.mozilla.firefox"))
    }

    func testElectronEditorAllowlist() {
        XCTAssertTrue(BrowserAppDetector.isElectronEditor(bundleIdentifier: "com.clickup.desktop-app"))
        XCTAssertFalse(BrowserAppDetector.isElectronEditor(bundleIdentifier: "com.hnc.Discord"))
        XCTAssertFalse(BrowserAppDetector.isElectronEditor(bundleIdentifier: nil))
    }

    func testNeedsPrimingForChromiumAndElectronOnly() {
        XCTAssertTrue(
            BrowserAppDetector.needsWebAccessibilityPriming(bundleIdentifier: "com.google.Chrome"))
        XCTAssertTrue(
            BrowserAppDetector.needsWebAccessibilityPriming(bundleIdentifier: "com.clickup.desktop-app"))
        XCTAssertFalse(
            BrowserAppDetector.needsWebAccessibilityPriming(bundleIdentifier: "com.apple.Safari"))
        XCTAssertFalse(
            BrowserAppDetector.needsWebAccessibilityPriming(bundleIdentifier: "org.mozilla.firefox"))
        XCTAssertFalse(
            BrowserAppDetector.needsWebAccessibilityPriming(bundleIdentifier: nil))
    }
}
