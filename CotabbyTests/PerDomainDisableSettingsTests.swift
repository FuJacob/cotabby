import XCTest
@testable import Cotabby

/// Tests for the UserDefaults-backed per-site disable configuration reader.
///
/// The contract that matters: the feature is off and the list empty unless explicitly configured, so
/// the focus-capture URL read and the per-site gate stay inert by default.
final class PerDomainDisableSettingsTests: XCTestCase {
    private let suiteName = "PerDomainDisableSettingsTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func test_isEnabled_defaultsToFalse() {
        XCTAssertFalse(PerDomainDisableSettings.isEnabled(defaults))
    }

    func test_isEnabled_readsStoredFlag() {
        defaults.set(true, forKey: PerDomainDisableSettings.enabledKey)
        XCTAssertTrue(PerDomainDisableSettings.isEnabled(defaults))
    }

    func test_disabledDomains_emptyByDefault() {
        XCTAssertEqual(PerDomainDisableSettings.disabledDomains(defaults), [])
    }

    func test_disabledDomains_readsStoredArrayAsSet() {
        defaults.set(["bank.com", "example.org", "bank.com"], forKey: PerDomainDisableSettings.disabledDomainsKey)
        XCTAssertEqual(PerDomainDisableSettings.disabledDomains(defaults), ["bank.com", "example.org"])
    }
}
