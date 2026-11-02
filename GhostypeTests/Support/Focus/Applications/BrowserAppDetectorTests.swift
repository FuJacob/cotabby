import XCTest
@testable import Ghostype

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
        XCTAssertTrue(BrowserAppDetector.isBrowser(bundleIdentifier: "com.microsoft.edgemac"))
        XCTAssertTrue(BrowserAppDetector.isBrowser(bundleIdentifier: "com.apple.SafariTechnologyPreview"))
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
        // VS Code ships under the mixed-case `com.microsoft.VSCode`; matching must be case-insensitive
        // or its entire Electron AX tree stays dormant and no suggestions ever resolve.
        XCTAssertTrue(BrowserAppDetector.isElectronEditor(bundleIdentifier: "com.microsoft.VSCode"))
        XCTAssertTrue(BrowserAppDetector.isElectronEditor(bundleIdentifier: "com.microsoft.VSCodeInsiders"))
        XCTAssertTrue(BrowserAppDetector.isElectronEditor(bundleIdentifier: "com.vscodium"))
        // Obsidian (#791): Electron 39 / CodeMirror 6. Its app element advertises
        // AXManualAccessibility, but nothing flips it unless the bundle is allowlisted here, so the
        // editor's web-AX tree stays dormant and no focused field ever resolves.
        XCTAssertTrue(BrowserAppDetector.isElectronEditor(bundleIdentifier: "md.obsidian"))
        XCTAssertTrue(BrowserAppDetector.isElectronEditor(bundleIdentifier: "MD.Obsidian"))
        // Meta's Muse desktop app: without this entry its composer element vends no AXValue
        // ("Missing text value") and no suggestions ever appear in the app.
        XCTAssertTrue(BrowserAppDetector.isElectronEditor(bundleIdentifier: "com.meta.endo"))
        XCTAssertTrue(BrowserAppDetector.isElectronEditor(bundleIdentifier: "COM.META.ENDO"))
        // Electron, but not a text-editing surface we cover: must stay out of the priming allowlist.
        XCTAssertFalse(BrowserAppDetector.isElectronEditor(bundleIdentifier: "com.logi.optionsplus"))
        XCTAssertFalse(BrowserAppDetector.isElectronEditor(bundleIdentifier: nil))
    }

    func testElectronEditorAllowlistIsExactNotPrefix() {
        // Unlike the browser families, helpers and sibling ids of an allowlisted editor must not be
        // primed wholesale.
        XCTAssertFalse(BrowserAppDetector.isElectronEditor(bundleIdentifier: "com.microsoft.VSCode.helper"))
        XCTAssertFalse(BrowserAppDetector.isElectronEditor(bundleIdentifier: "com.clickup"))
    }

    func testChatGPTCodexUsesEditorRecoveryWithoutBrowserClassification() {
        // The installed app is named ChatGPT but uses the Codex bundle identity. Recovery must
        // follow that identity while unrelated OpenAI apps stay outside the explicit allowlist.
        for bundleIdentifier in ["com.openai.codex", "COM.OPENAI.CODEX"] {
            XCTAssertTrue(BrowserAppDetector.isElectronEditor(bundleIdentifier: bundleIdentifier))
            XCTAssertTrue(BrowserAppDetector.needsWebAccessibilityPriming(bundleIdentifier: bundleIdentifier))
            XCTAssertFalse(BrowserAppDetector.isBrowser(bundleIdentifier: bundleIdentifier))
        }
        XCTAssertFalse(BrowserAppDetector.needsWebAccessibilityPriming(bundleIdentifier: "com.openai.other"))
        XCTAssertFalse(BrowserAppDetector.needsWebAccessibilityPriming(bundleIdentifier: "com.openai.codex.helper"))
    }

    func testClaudeDesktopUsesEditorRecoveryWithoutBrowserClassification() {
        // Claude Desktop is an Electron app (bundle id com.anthropic.claudefordesktop, verified
        // against the installed app's Info.plist and lsregister dumps) whose chat composer is a
        // ProseMirror contenteditable. Recovery must follow that identity while the helper
        // subprocesses stay outside the explicit allowlist; it is not a browser.
        for bundleIdentifier in ["com.anthropic.claudefordesktop", "COM.ANTHROPIC.CLAUDEFORDESKTOP"] {
            XCTAssertTrue(BrowserAppDetector.isElectronEditor(bundleIdentifier: bundleIdentifier))
            XCTAssertTrue(BrowserAppDetector.needsWebAccessibilityPriming(bundleIdentifier: bundleIdentifier))
            XCTAssertFalse(BrowserAppDetector.isBrowser(bundleIdentifier: bundleIdentifier))
        }
        XCTAssertFalse(BrowserAppDetector.needsWebAccessibilityPriming(bundleIdentifier: "com.anthropic.claudefordesktop.helper"))
    }

    func testNeedsPrimingForChromiumAndElectronOnly() {
        XCTAssertTrue(
            BrowserAppDetector.needsWebAccessibilityPriming(bundleIdentifier: "com.google.Chrome"))
        XCTAssertTrue(
            BrowserAppDetector.needsWebAccessibilityPriming(bundleIdentifier: "com.clickup.desktop-app"))
        XCTAssertTrue(
            BrowserAppDetector.needsWebAccessibilityPriming(bundleIdentifier: "com.microsoft.VSCode"))
        XCTAssertTrue(
            BrowserAppDetector.needsWebAccessibilityPriming(bundleIdentifier: "md.obsidian"))
        XCTAssertFalse(
            BrowserAppDetector.needsWebAccessibilityPriming(bundleIdentifier: "com.apple.Safari"))
        XCTAssertFalse(
            BrowserAppDetector.needsWebAccessibilityPriming(bundleIdentifier: "org.mozilla.firefox"))
        XCTAssertFalse(
            BrowserAppDetector.needsWebAccessibilityPriming(bundleIdentifier: nil))
    }

    /// Every Chromium build gets the browser recovery paths, and the named chat/notes Electron apps
    /// get priming; real bundle ids, mixed case as they ship.
    func testOtherChromiumBrowsersAndChatAppsArePrimed() {
        for id in ["com.vivaldi.Vivaldi", "com.operasoftware.Opera", "com.operasoftware.OperaGX",
                   "org.chromium.Chromium", "org.chromium.Thorium", "company.thebrowser.dia",
                   "ai.perplexity.comet", "ru.yandex.desktop.yandex-browser"] {
            XCTAssertTrue(BrowserAppDetector.isChromiumBrowser(bundleIdentifier: id), id)
            XCTAssertTrue(BrowserAppDetector.isBrowser(bundleIdentifier: id), id)
        }
        for id in ["com.tinyspeck.slackmacgap", "com.hnc.Discord", "notion.id", "com.granola.app"] {
            XCTAssertTrue(BrowserAppDetector.isElectronEditor(bundleIdentifier: id), id)
            XCTAssertFalse(BrowserAppDetector.isBrowser(bundleIdentifier: id), id)
        }
    }
}
