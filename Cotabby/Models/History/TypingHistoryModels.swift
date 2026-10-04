import Foundation

/// File overview:
/// Value types for Cotabby's typing history: the text the user has written in fields Cotabby was
/// active in (recorded on this Mac, or imported from another autocomplete app), and the user's
/// preferences for collecting and using it.
///
/// Why a separate subsystem: history is the only Cotabby data that outlives the field it came from.
/// Everything else in a request (caret text, clipboard, screen) is ephemeral. Keeping these values
/// apart from `SuggestionSettingsModel` lets the history store own its own storage, encryption, and
/// lifecycle, while the suggestion pipeline only sees a narrow read contract
/// (`SuggestionHistoryProviding`).

/// One field's worth of the user's writing.
///
/// A record is updated in place while the user keeps typing in the same field, so a long email is
/// one record rather than one per keystroke. `text` is already scrubbed of secret-like tokens
/// (`TypingHistoryScrubber`) before it is stored.
nonisolated struct TypingHistoryRecord: Codable, Equatable, Sendable, Identifiable {
    enum Source: String, Codable, Sendable {
        /// Captured by Cotabby while the user typed.
        case recorded
        /// Brought in from another app's export (for example Cotypist).
        case imported
    }

    let id: UUID
    let bundleIdentifier: String
    /// Registrable web domain for browser fields ("claude.ai"), nil for native apps.
    let domain: String?
    let createdAt: Date
    var updatedAt: Date
    var text: String
    let source: Source
    /// How many characters at the start of `text` were before the caret when it was captured.
    /// Text after the caret is usually not the user's: in an email reply it is the quoted thread
    /// other people wrote. Learning only from this part keeps their names and phrasing out of the
    /// user's shortcuts. Nil means the whole text counts (records written before this existed).
    var typedLength: Int?

    /// The part of `text` the user wrote themselves.
    var typedText: String {
        guard let typedLength, typedLength < text.count else { return text }
        return String(text.prefix(typedLength))
    }
}

/// The encrypted file's plaintext payload. Versioned so a future format change can migrate rather
/// than silently dropping the user's history.
nonisolated struct TypingHistoryArchive: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var records: [TypingHistoryRecord]
}

/// The user's typing-history preferences, persisted by `TypingHistoryStore`.
nonisolated struct TypingHistoryPreferences: Equatable, Sendable {
    /// Whether stored history shapes suggestions (prompt examples and phrase shortcuts).
    var isUsingHistory: Bool
    /// Whether new typing is recorded. Off by default: recording keeps the user's writing on disk,
    /// which is a privacy decision the user makes, not a default Cotabby makes for them.
    var isRecording: Bool
    /// Apps whose fields are never recorded, by bundle identifier.
    var excludedBundleIdentifiers: [String]

    static let defaults = TypingHistoryPreferences(
        isUsingHistory: false,
        isRecording: false,
        excludedBundleIdentifiers: []
    )
}
