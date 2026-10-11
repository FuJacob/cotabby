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
/// Signals, any of which marks a search box:
///   - the AX role or subrole `AXSearchField` (AppKit's `NSSearchField`, and web `<input
///     type="search">` / `role="searchbox"`, which Chromium and WebKit map to that subrole);
///   - a label (title, description, placeholder) naming a search, matched as whole words, since
///     web apps often build their search box from a plain input with only a placeholder to tell;
///   - a DOM id with a word beginning "search" (`searchInput`, `ms-searchux-input`).
///
/// Scope: single-line fields only. A browser's own address bar is excluded even though it
/// searches: it is browser chrome rather than a page field (it vends no DOM attributes), and
/// Cotabby supports it deliberately. Firefox fields vend no DOM attributes either, so a page's
/// search box there is only recognized by role, not by label. Pure: the resolver reads the
/// attributes and asks here.
enum SearchFieldDetector {
    static let blockedReason = "Search fields are left to the app."

    static let searchFieldRole = "AXSearchField"

    /// Words in a field's label that name a search or filter box, matched as whole words in the
    /// lowercased label ("search" matches "Search mail", not "Research notes"). "ara"/"arama" are
    /// Turkish for "search", which Turkish-localized apps put in their placeholders.
    static let labelKeywords: [String] = [
        "search", "look for", "find", "filter", "jump to", "ara", "arama"
    ]

    /// Cheap pre-check so labels are only judged for single-line fields outside browser chrome.
    static func mightBeSearchField(role: String, isBrowserChrome: Bool) -> Bool {
        guard !isBrowserChrome else { return false }
        return role == kAXTextFieldRole as String || role == kAXComboBoxRole as String || role == searchFieldRole
    }

    static func isSearchField(
        role: String,
        subrole: String?,
        labels: [String?],
        domIdentifier: String?,
        isBrowserChrome: Bool
    ) -> Bool {
        guard mightBeSearchField(role: role, isBrowserChrome: isBrowserChrome) else { return false }

        if role == searchFieldRole || subrole == searchFieldRole {
            return true
        }

        for label in labels.compactMap({ $0?.lowercased() }) where !label.isEmpty {
            if labelKeywords.contains(where: { CredentialFieldDetector.containsWord($0, in: label) }) {
                return true
            }
        }

        return identifierNamesSearch(domIdentifier)
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
