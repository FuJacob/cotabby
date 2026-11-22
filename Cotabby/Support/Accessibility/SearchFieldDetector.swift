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
/// box". Pure: the resolver reads the attributes (once per focus session) and asks here, in two
/// steps (`signal`, then `isSearchField`) so the costly "inside a web page?" read is made only for
/// a field whose own attributes already point at a search.
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

    /// What a field's own attributes say, before anything is known about where it lives.
    enum Signal: Equatable {
        /// The AX role or subrole is `AXSearchField` (rule 4).
        case searchRole
        /// A label or DOM id names a search, trusted only inside a web page (rule 5).
        case searchLabel
    }

    /// Cheap pre-check so labels are only read for single-line fields.
    static func mightBeSearchField(role: String) -> Bool {
        role == kAXTextFieldRole as String || role == kAXComboBoxRole as String || role == searchFieldRole
    }

    /// Rules 1, 2 and the matching half of 4 and 5, from attributes the resolver already holds.
    /// Nil means "not a search box" whatever the field's surface, which is the answer for nearly
    /// every field, so `isSearchField` never needs to ask where it lives.
    static func signal(
        role: String,
        subrole: String?,
        labels: [String?],
        domIdentifier: String?
    ) -> Signal? {
        guard mightBeSearchField(role: role) else { return nil }

        let loweredLabels = labels.compactMap { $0?.lowercased() }.filter { !$0.isEmpty }
        let namesAddress = loweredLabels.contains { label in
            addressLabelKeywords.contains { CredentialFieldDetector.containsWord($0, in: label) }
        }
        if namesAddress {
            return nil
        }

        if role == searchFieldRole || subrole == searchFieldRole {
            return .searchRole
        }

        for label in loweredLabels {
            if labelKeywords.contains(where: { CredentialFieldDetector.containsWord($0, in: label) })
                || leadingLabelKeywords.contains(where: { startsWithWord($0, label) }) {
                return .searchLabel
            }
        }

        return identifierNamesSearch(domIdentifier) ? .searchLabel : nil
    }

    /// Rules 3 to 5: whether a field with `signal` is a search box, given where it lives.
    ///
    /// `isInWebPage` (an `AXWebArea` ancestor) is a climb up the AX tree, two cross-process reads
    /// per level and ~30 levels in a web app, each bounded only by the AX messaging timeout. It is
    /// a closure so it runs only when its answer can change the outcome: never without a signal
    /// (every ordinary form input), never for a search role in a non-browser (blocked either way),
    /// and otherwise once, for a field that already looks like a search box.
    static func isSearchField(signal: Signal?, isBrowser: Bool, isInWebPage: () -> Bool) -> Bool {
        switch signal {
        case nil:
            return false
        case .searchRole:
            // Outside a browser a search role blocks on any surface. In a listed browser it blocks
            // only on a page, so the browser's own UI (rule 3) keeps working.
            return !isBrowser || isInWebPage()
        case .searchLabel:
            return isInWebPage()
        }
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
