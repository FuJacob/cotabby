import XCTest
@testable import Cotabby

/// Tests for the pure browser-domain parsing and matching used by per-site disable.
///
/// Two invariants matter: a focused URL reduces to a normalized host (lowercased, "www."-stripped,
/// nil when there is no web host), and matching covers a domain and its subdomains without ever
/// matching a lookalike ("evilbank.com" is not disabled by "bank.com").
final class BrowserDomainTests: XCTestCase {

    // MARK: - host(fromURLString:)

    func test_host_extractsAndLowercasesHost() {
        XCTAssertEqual(BrowserDomain.host(fromURLString: "https://Mail.Example.COM/inbox"), "mail.example.com")
    }

    func test_host_stripsLeadingWWW() {
        XCTAssertEqual(BrowserDomain.host(fromURLString: "https://www.bank.com/login"), "bank.com")
    }

    func test_host_ignoresPortAndPathAndQuery() {
        XCTAssertEqual(BrowserDomain.host(fromURLString: "http://bank.com:8443/a/b?c=d#e"), "bank.com")
    }

    func test_host_nilForNonWebSchemes() {
        XCTAssertNil(BrowserDomain.host(fromURLString: "about:blank"))
        XCTAssertNil(BrowserDomain.host(fromURLString: "file:///Users/x/notes.txt"))
        XCTAssertNil(BrowserDomain.host(fromURLString: "data:text/plain,hello"))
    }

    func test_host_nilForEmptyOrHostlessStrings() {
        XCTAssertNil(BrowserDomain.host(fromURLString: ""))
        XCTAssertNil(BrowserDomain.host(fromURLString: "   "))
        // No scheme: the string parses as a path, not a host.
        XCTAssertNil(BrowserDomain.host(fromURLString: "bank.com"))
    }

    // MARK: - isHostDisabled

    func test_isHostDisabled_exactMatch() {
        XCTAssertTrue(BrowserDomain.isHostDisabled("bank.com", disabledDomains: ["bank.com"]))
    }

    func test_isHostDisabled_subdomainMatch() {
        XCTAssertTrue(BrowserDomain.isHostDisabled("mail.bank.com", disabledDomains: ["bank.com"]))
    }

    func test_isHostDisabled_doesNotMatchLookalike() {
        XCTAssertFalse(BrowserDomain.isHostDisabled("evilbank.com", disabledDomains: ["bank.com"]))
    }

    func test_isHostDisabled_normalizesListEntries() {
        // Entries pasted as a full URL or with "www." still match a bare host.
        XCTAssertTrue(BrowserDomain.isHostDisabled("bank.com", disabledDomains: ["https://bank.com/x"]))
        XCTAssertTrue(BrowserDomain.isHostDisabled("bank.com", disabledDomains: ["www.bank.com"]))
    }

    func test_isHostDisabled_falseForEmptyInputs() {
        XCTAssertFalse(BrowserDomain.isHostDisabled(nil, disabledDomains: ["bank.com"]))
        XCTAssertFalse(BrowserDomain.isHostDisabled("bank.com", disabledDomains: []))
        XCTAssertFalse(BrowserDomain.isHostDisabled("other.com", disabledDomains: ["bank.com"]))
    }
}
