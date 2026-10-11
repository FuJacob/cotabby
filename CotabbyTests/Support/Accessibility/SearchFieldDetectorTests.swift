import ApplicationServices
import XCTest
@testable import Cotabby

final class SearchFieldDetectorTests: XCTestCase {
    private let textField = kAXTextFieldRole as String
    private let comboBox = kAXComboBoxRole as String

    private func isSearch(
        role: String? = nil,
        subrole: String? = nil,
        labels: [String?] = [],
        domIdentifier: String? = nil,
        isBrowserChrome: Bool = false
    ) -> Bool {
        SearchFieldDetector.isSearchField(
            role: role ?? textField,
            subrole: subrole,
            labels: labels,
            domIdentifier: domIdentifier,
            isBrowserChrome: isBrowserChrome
        )
    }

    func test_searchRoleOrSubroleIsBlockedWithoutALabel() {
        XCTAssertTrue(isSearch(role: "AXSearchField"))
        XCTAssertTrue(isSearch(subrole: "AXSearchField"))
    }

    func test_teamsSearchPlaceholderIsBlocked() {
        XCTAssertTrue(isSearch(role: comboBox, labels: [nil, nil, "Look for people, messages, files, and more."]))
    }

    func test_commonSearchLabelsAreBlocked() {
        for label in ["Search", "Search mail", "Find in page", "Filter results", "Jump to…", "Kişi ara", "Arama"] {
            XCTAssertTrue(isSearch(labels: [label]), label)
        }
    }

    func test_searchDOMIdentifiersAreBlocked() {
        for identifier in ["searchInput", "ms-searchux-input", "search_box", "emailSearch"] {
            XCTAssertTrue(isSearch(domIdentifier: identifier), identifier)
        }
    }

    func test_ordinaryFieldsAreNotBlocked() {
        XCTAssertFalse(isSearch(labels: ["Type a message", "Research notes", "Subject", "Para birimi"]))
        XCTAssertFalse(isSearch(domIdentifier: "research-notes"))
        XCTAssertFalse(isSearch(domIdentifier: "q"))
    }

    func test_multiLineFieldsAreNeverSearchBoxes() {
        XCTAssertFalse(isSearch(role: kAXTextAreaRole as String, labels: ["Search the web or ask anything"]))
    }

    func test_browserAddressBarStaysSupported() {
        // Chrome's omnibox: browser chrome, so neither its label nor a search subrole blocks it.
        XCTAssertFalse(isSearch(labels: [nil, "Address and search bar", nil], isBrowserChrome: true))
        XCTAssertFalse(isSearch(subrole: "AXSearchField", isBrowserChrome: true))
    }
}
