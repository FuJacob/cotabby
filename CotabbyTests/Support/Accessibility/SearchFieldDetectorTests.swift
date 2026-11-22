import ApplicationServices
import XCTest
@testable import Cotabby

final class SearchFieldDetectorTests: XCTestCase {
    private let textField = kAXTextFieldRole as String
    private let comboBox = kAXComboBoxRole as String

    /// Defaults to a page field in a non-browser host (a web app such as Teams), the shape where
    /// every signal is judged.
    private func isSearch(
        role: String? = nil,
        subrole: String? = nil,
        labels: [String?] = [],
        domIdentifier: String? = nil,
        isInWebPage: Bool = true,
        isBrowser: Bool = false
    ) -> Bool {
        SearchFieldDetector.isSearchField(
            role: role ?? textField,
            subrole: subrole,
            labels: labels,
            domIdentifier: domIdentifier,
            surface: SearchFieldDetector.Surface(isInWebPage: isInWebPage, isBrowser: isBrowser)
        )
    }

    func test_searchRoleOrSubroleIsBlockedWithoutALabel() {
        XCTAssertTrue(isSearch(role: "AXSearchField"))
        XCTAssertTrue(isSearch(subrole: "AXSearchField"))
    }

    func test_teamsSearchPlaceholderIsBlocked() {
        XCTAssertTrue(isSearch(role: comboBox, labels: [nil, nil, "Look for people, messages, files, and more."]))
        XCTAssertTrue(isSearch(role: comboBox, labels: [nil, nil, "Search (⌘ E)"]))
    }

    func test_commonSearchLabelsAreBlocked() {
        for label in ["Search", "Search mail", "Type to search", "Find in page", "Filter results", "Jump to…",
                      "🔍 Find people", "Kişi ara", "Arama"] {
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

    func test_findAndFilterOnlyCountAsTheLabelsOpeningWord() {
        // Forms use these words in ordinary questions; only a leading imperative names a search.
        for label in ["How did you find us?", "Where did you find this job?", "Coffee filter size", "Finder tag"] {
            XCTAssertFalse(isSearch(labels: [label]), label)
        }
    }

    func test_multiLineFieldsAreNeverSearchBoxes() {
        XCTAssertFalse(isSearch(role: kAXTextAreaRole as String, labels: ["Search the web or ask anything"]))
    }

    func test_listedBrowsersAddressBarStaysSupported() {
        // Chrome's omnibox as probed: it vends a DOM id but sits outside any web area.
        XCTAssertFalse(isSearch(
            labels: ["Address and search bar", "Address and search bar", "Ask Google or type a URL"],
            domIdentifier: "view_1012", isInWebPage: false, isBrowser: true
        ))
        // A listed browser's chrome stays exempt even when its label is unforeseen or it reports
        // the search subrole (Safari's own UI is AppKit).
        XCTAssertFalse(isSearch(subrole: "AXSearchField", isInWebPage: false, isBrowser: true))
        XCTAssertFalse(isSearch(labels: [nil, "Smart Search Field", nil], isInWebPage: false, isBrowser: true))
    }

    func test_unlistedBrowsersAddressBarStaysSupported() {
        // Vivaldi, Opera, Dia, Comet, Atlas: not in BrowserAppDetector. A native omnibox is never
        // judged by its label, even a localized one with no address word in it.
        XCTAssertFalse(isSearch(labels: ["Address and search bar"], isInWebPage: false))
        XCTAssertFalse(isSearch(labels: [nil, nil, "Search or ask anything"], isInWebPage: false))
        // A label naming an address exempts the field even when the browser draws its UI as a web
        // page (Vivaldi) or reports the search subrole.
        XCTAssertFalse(isSearch(labels: [nil, nil, "Search or enter an address"]))
        XCTAssertFalse(isSearch(subrole: "AXSearchField", labels: [nil, nil, "Search or type a URL"], isInWebPage: false))
        XCTAssertFalse(isSearch(labels: ["Adres ve arama çubuğu"]))
    }

    func test_browserPageSearchBoxesAreBlocked() {
        // A page field in any browser, Firefox included: it sits inside the page's web area.
        XCTAssertTrue(isSearch(subrole: "AXSearchField", isBrowser: true))
        XCTAssertTrue(isSearch(role: comboBox, labels: ["Search issues", nil, "Search issues"], isBrowser: true))
    }

    func test_nativeFieldsAreJudgedByRoleOnly() {
        // NSSearchField and SwiftUI `.searchable` report the subrole; a plain native field's label
        // is not trusted, since an unlisted browser's address bar looks exactly like one.
        XCTAssertTrue(isSearch(subrole: "AXSearchField", isInWebPage: false))
        XCTAssertFalse(isSearch(labels: [nil, nil, "Search"], isInWebPage: false))
        XCTAssertFalse(isSearch(domIdentifier: "searchInput", isInWebPage: false))
    }
}
