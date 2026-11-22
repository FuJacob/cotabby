import ApplicationServices
import Foundation

/// File overview:
/// Recognizes search boxes (an app's "Search", "Look for…", "Find" or filter field), where Cotabby
/// stands down.
///
/// Why: what goes into a search box is a query of a word or two, not prose to continue, and the
/// host already offers its own results under it. Measured 2026-10-11 in Microsoft Teams' search
/// box ("Look for people, messages, files, and more."): after "san" the model offered "dbox:
/// https://sandbox.openai.com/", a URL in no part of its context, and the prompt framed the query
/// as a chat message by carrying the open conversation's history. A ghost there is noise at best
/// and, on Tab, a wrong query.
///
/// The hard part is a browser's address bar, which searches too but which Cotabby supports on
/// purpose. It has to stay supported in every browser, including ones no bundle list names
/// (Vivaldi, Opera, Dia, Comet, Atlas, ...), so the rules are ordered to make that the default:
///
///   1. Only single-line fields are judged. A multi-line field is a composer, whatever its label.
///   2. A field whose label names an address or URL is an address bar, never a search box. Every
///      omnibox says so: Chromium's "Address and search bar" / "Ask Google or type a URL" (Chrome,
///      probed 2026-11-22), Firefox's "Search with Google or enter address", Safari's "Search or
///      enter website name".
///   3. A known browser's own UI (a field outside any web page) is browser chrome and never judged,
///      covering chrome fields whose labels rule 2 cannot predict. This does not lean on DOM
///      attributes: Chrome's omnibox vends `AXDOMIdentifier` (`view_1012`, probed 2026-11-22), so
///      "vends no DOM attributes" does not identify chrome.
///   4. The AX role or subrole `AXSearchField` marks a search box anywhere else: AppKit's
///      `NSSearchField`, SwiftUI's `.searchable`, and web `<input type="search">` /
///      `role="searchbox"` in every engine (Firefox page fields included).
///   5. Labels and DOM ids are judged only for fields inside a web page (an `AXWebArea` ancestor):
///      web apps such as Teams build search boxes from plain inputs with only a placeholder or id
///      to tell. A native field's label is not trusted, because an unlisted browser's native
///      address bar is exactly such a field and its label routinely says "search" (localized, so
///      rule 2 can miss it). Native apps' real search boxes are `NSSearchField`s, caught by rule 4.
///
/// Blocking costs the writer their completions, so every ambiguity resolves toward "not a search
/// box". Pure: the resolver reads the attributes (once per focus session) and asks here.
enum SearchFieldDetector {
    static let blockedReason = "Search fields are left to the app."

    static let searchFieldRole = "AXSearchField"

    /// Words that name a search wherever they appear in a label, matched as whole words in the
    /// lowercased label ("search" matches "Type to search", not "Research notes"). "ara"/"arama"
    /// are Turkish for "search"; Turkish puts the verb last ("Kişi ara"), so they cannot be
    /// limited to the start of the label.
    static let labelKeywords: [String] = ["search", "arama", "ara"]

    /// Words that name a search only as the label's opening imperative ("Find people", "Filter
    /// results", "Jump to…"). Anywhere else they are ordinary prose: "How did you find us?",
    /// "Coffee filter size".
    static let leadingLabelKeywords: [String] = ["look for", "find", "filter", "jump to"]

    /// Words that mark a browser's address bar (rule 2). "adres" is Turkish, matching the Turkish
    /// search words above: Chrome's Turkish omnibox is "Adres ve arama çubuğu".
    static let addressLabelKeywords: [String] = ["address", "url", "website", "adres"]

    /// Where a field lives, which decides how much of it is trusted (rules 3 to 5).
    enum Surface: Equatable {
        /// Inside a web page: an `AXWebArea` ancestor (page content, a web app, a web view inside a
        /// native app). Every signal is judged.
        case webPage
        /// A known browser's own UI, outside any web page. Never judged.
        case browserChrome
        /// Any other native control, including an unlisted browser's UI. Judged by role only.
        case nativeControl

        init(isInWebPage: Bool, isBrowser: Bool) {
            self = isInWebPage ? .webPage : (isBrowser ? .browserChrome : .nativeControl)
        }
    }

    /// Cheap pre-check so labels are only read for single-line fields.
    static func mightBeSearchField(role: String) -> Bool {
        role == kAXTextFieldRole as String || role == kAXComboBoxRole as String || role == searchFieldRole
    }

    static func isSearchField(
        role: String,
        subrole: String?,
        labels: [String?],
        domIdentifier: String?,
        surface: Surface
    ) -> Bool {
        guard mightBeSearchField(role: role) else { return false }

        let loweredLabels = labels.compactMap { $0?.lowercased() }.filter { !$0.isEmpty }
        let namesAddress = loweredLabels.contains { label in
            addressLabelKeywords.contains { CredentialFieldDetector.containsWord($0, in: label) }
        }
        if namesAddress {
            return false
        }

        if surface == .browserChrome {
            return false
        }

        if role == searchFieldRole || subrole == searchFieldRole {
            return true
        }

        guard surface == .webPage else { return false }

        for label in loweredLabels {
            if labelKeywords.contains(where: { CredentialFieldDetector.containsWord($0, in: label) })
                || leadingLabelKeywords.contains(where: { startsWithWord($0, label) }) {
                return true
            }
        }

        return identifierNamesSearch(domIdentifier)
    }

    /// `keyword` opens `label` (after any leading spaces or symbols such as "🔍") and is followed
    /// by no letter or digit, so "find" matches "Find in page" but not "Finder" or "How did you
    /// find us?".
    static func startsWithWord(_ keyword: String, _ label: String) -> Bool {
        guard let start = label.firstIndex(where: { $0.isLetter || $0.isNumber }) else { return false }
        let rest = label[start...]
        guard rest.hasPrefix(keyword) else { return false }
        let after = rest.dropFirst(keyword.count).first
        return after.map { !$0.isLetter && !$0.isNumber } ?? true
    }

    /// True when one of the id's words starts with "search". Words split at punctuation and at
    /// camel-case humps, so `searchInput` and `ms-searchux-input` match while `research-notes`
    /// does not.
    static func identifierNamesSearch(_ identifier: String?) -> Bool {
        guard let identifier, !identifier.isEmpty else { return false }
        var words: [String] = []
        var current = ""
        var previousWasLowercase = false
        for character in identifier {
            if !character.isLetter && !character.isNumber {
                words.append(current)
                current = ""
                previousWasLowercase = false
                continue
            }
            if character.isUppercase && previousWasLowercase {
                words.append(current)
                current = ""
            }
            current.append(character)
            previousWasLowercase = character.isLowercase
        }
        words.append(current)
        return words.contains { $0.lowercased().hasPrefix("search") }
    }
}
