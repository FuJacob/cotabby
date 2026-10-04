import Foundation

/// A Cotabby feature the field icon can turn on or off for one app or one window.
nonisolated enum ScopedFeature: String, Codable, CaseIterable, Sendable {
    case autocomplete
    case translation
}

/// File overview:
/// Pure rules for "this app" versus "this window" feature choices made from the field icon.
///
/// The app-level answer already has an owner per feature: the disabled-apps list for autocomplete
/// and the translation app list for translation. This type only adds the window layer on top: a
/// window is identified by its app plus its normalized title (a Teams or WhatsApp chat title names
/// the conversation), and a window choice, when one exists, wins over the app's. Keeping the rule
/// here, with no storage or AppKit, means the suggestion gate, the translation gate, the indicator,
/// and the popup can never disagree about what a window choice means.
nonisolated enum WindowFeatureScope {
    /// Longest title kept in a key. Titles longer than this are document paths or page titles that
    /// change constantly; truncating keeps keys bounded without losing the chat-name prefix.
    static let maximumTitleCharacters = 160

    /// The storage key for one window, or nil when the window cannot be told apart from the app's
    /// other windows (no bundle identifier, or an empty title). A nil key means "app scope only".
    static func windowKey(bundleIdentifier: String?, windowTitle: String?) -> String? {
        guard let bundleIdentifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleIdentifier.isEmpty,
              let title = normalizedTitle(windowTitle)
        else { return nil }
        // U+001F (unit separator) cannot appear in a bundle identifier, so the split is unambiguous.
        return bundleIdentifier + "\u{1F}" + title
    }

    /// The window title as a stable identity: whitespace collapsed, and a leading unread badge such
    /// as "(3) " dropped, because chat apps prefix the count and would otherwise turn one chat into
    /// a new window every time a message arrives.
    static func normalizedTitle(_ title: String?) -> String? {
        guard var title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        if let badge = title.range(of: #"^\(\d+\+?\)\s*"#, options: .regularExpression) {
            title.removeSubrange(badge)
        }
        let collapsed = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maximumTitleCharacters))
    }

    /// The feature's effective state in a window: its own choice when it has one, else the app's.
    static func resolve(appEnabled: Bool, windowOverride: Bool?) -> Bool {
        windowOverride ?? appEnabled
    }

    /// The disabled-apps set the suggestion availability gate should use for the focused window.
    ///
    /// Every autocomplete gate already asks "is this bundle in the disabled set?". Adjusting the set
    /// for the focused window (adding the app when the window is off, removing it when the window is
    /// forced on) lets all of those gates honor window choices without each one learning about
    /// windows, which is the regression-safe way to add a scope to a rule that has many readers.
    static func effectiveDisabledApps(
        _ disabledApps: Set<String>,
        bundleIdentifier: String?,
        windowOverride: Bool?
    ) -> Set<String> {
        guard let bundleIdentifier, let windowOverride else { return disabledApps }
        var adjusted = disabledApps
        if windowOverride {
            adjusted.remove(bundleIdentifier)
        } else {
            adjusted.insert(bundleIdentifier)
        }
        return adjusted
    }
}

/// The app and window the field icon's popup acts on, captured when the icon is clicked so the
/// popup keeps editing that window even if focus moves while it is open.
nonisolated struct FieldScopeTarget: Equatable, Sendable {
    let bundleIdentifier: String
    let applicationName: String
    /// The window's title as shown to the user (nil when the app exposes none).
    let windowTitle: String?
    /// Storage key for window choices; nil means the window cannot be told apart, so the popup
    /// offers app-level switches only.
    let windowKey: String?

    init(bundleIdentifier: String, applicationName: String, windowTitle: String?) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.windowTitle = WindowFeatureScope.normalizedTitle(windowTitle)
        self.windowKey = WindowFeatureScope.windowKey(bundleIdentifier: bundleIdentifier, windowTitle: windowTitle)
    }
}
