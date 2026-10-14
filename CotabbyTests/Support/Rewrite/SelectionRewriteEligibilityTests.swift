import XCTest
@testable import Cotabby

/// The button appears only for a real draft selection in an ordinary field: never in a password
/// field or a terminal, never in an app where Cotabby is off.
final class SelectionRewriteEligibilityTests: XCTestCase {
    private let draft = "Please let me know if te dates are ok and wors for you."

    private func snapshot(selected: String, secure: Bool = false, terminal: Bool = false,
                          bundle: String = "net.whatsapp.WhatsApp") -> FocusedInputSnapshot {
        CotabbyTestFixtures.focusedInputSnapshot(
            bundleIdentifier: bundle, precedingText: "", isSecure: secure, isIntegratedTerminal: terminal,
            selectedText: selected
        )
    }

    func test_draftSelectionIsEligible() {
        XCTAssertEqual(SelectionRewriteEligibility.verdict(for: snapshot(selected: draft), appAllowed: true), .eligible)
    }

    func test_noSelection() {
        XCTAssertEqual(SelectionRewriteEligibility.verdict(for: snapshot(selected: ""), appAllowed: true), .noSelection)
    }

    func test_singleWordIsTooShort() {
        XCTAssertEqual(SelectionRewriteEligibility.verdict(for: snapshot(selected: "Charlie"), appAllowed: true), .tooShort)
        XCTAssertEqual(SelectionRewriteEligibility.verdict(for: snapshot(selected: "  wors  "), appAllowed: true), .tooShort)
    }

    func test_longSelectionIsTooLongButStillReported() {
        let long = String(repeating: "word ", count: 401) // 2,005 characters
        XCTAssertEqual(SelectionRewriteEligibility.verdict(for: snapshot(selected: long), appAllowed: true), .tooLong)
    }

    func test_secureFieldIsNeverEligible() {
        XCTAssertEqual(SelectionRewriteEligibility.verdict(for: snapshot(selected: draft, secure: true), appAllowed: true), .ineligible)
    }

    func test_terminalsAreNeverEligible() {
        XCTAssertEqual(SelectionRewriteEligibility.verdict(for: snapshot(selected: draft, terminal: true), appAllowed: true), .ineligible)
        XCTAssertEqual(
            SelectionRewriteEligibility.verdict(for: snapshot(selected: draft, bundle: "com.mitchellh.ghostty"), appAllowed: true),
            .ineligible
        )
    }

    func test_disabledAppIsNeverEligible() {
        XCTAssertEqual(SelectionRewriteEligibility.verdict(for: snapshot(selected: draft), appAllowed: false), .ineligible)
    }

    /// Japanese has no spaces between words; a sentence is still a draft.
    func test_languagesWithoutSpacesCountWords() {
        XCTAssertEqual(SelectionRewriteEligibility.verdict(for: snapshot(selected: "明日の会議に参加できますか"), appAllowed: true), .eligible)
        XCTAssertGreaterThanOrEqual(SelectionRewriteEligibility.wordCount("明日の会議に参加できますか"), 2)
    }

    @MainActor
    func test_appGateHonoursCotabbysSwitches() {
        let page = CotabbyTestFixtures.focusedInputSnapshot(
            bundleIdentifier: "com.google.Chrome", focusedURLString: "https://mail.example.com/compose", selectedText: draft
        )
        func allowed(_ settings: SuggestionSettingsSnapshot?, lowPower: Bool = false, domains: Set<String> = []) -> Bool {
            SelectionRewriteEligibility.isAppAllowed(for: page, settings: settings, isLowPowerModeEnabled: lowPower, disabledDomains: domains)
        }
        XCTAssertTrue(allowed(CotabbyTestFixtures.settingsSnapshot()))
        XCTAssertFalse(allowed(nil))
        XCTAssertFalse(allowed(CotabbyTestFixtures.settingsSnapshot(isGloballyEnabled: false)))
        XCTAssertFalse(allowed(CotabbyTestFixtures.settingsSnapshot(isTemporarilyPaused: true)))
        XCTAssertFalse(allowed(CotabbyTestFixtures.settingsSnapshot(disabledAppBundleIdentifiers: ["com.google.Chrome"])))
        XCTAssertFalse(allowed(CotabbyTestFixtures.settingsSnapshot(), lowPower: true))
        XCTAssertTrue(allowed(CotabbyTestFixtures.settingsSnapshot(isLowPowerModeAutoDisableEnabled: false), lowPower: true))
        XCTAssertFalse(allowed(CotabbyTestFixtures.settingsSnapshot(), domains: ["example.com"]), "a disabled domain covers its subdomains")
        XCTAssertTrue(allowed(CotabbyTestFixtures.settingsSnapshot(), domains: ["other.org"]))
    }
}
