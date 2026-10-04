import CoreGraphics
import Foundation

/// File overview:
/// Values for Cotabby's translation feature: translating incoming messages into the user's reading
/// language (shown in an overlay under each message) and offering the user's reply translated into
/// the conversation's language before they send it.
///
/// Languages are carried as minimal BCP-47 codes ("en", "tr", "mk") rather than an enum, because
/// the set comes from Apple's Translation framework (which varies by macOS version) plus the
/// languages Cotabby can translate with its local model.

/// How well one language pair can be translated on this Mac.
nonisolated enum TranslationPairAvailability: Equatable, Sendable {
    /// Apple Translation has the pair installed; translation is fast and offline.
    case ready
    /// Apple Translation supports the pair but its language files are not downloaded yet.
    case needsDownload
    /// Apple Translation does not support the pair; the local model translates it instead.
    case localModel
    /// Neither engine can translate the pair.
    case unavailable
}

/// The user's translation preferences, persisted by `TranslationPreferencesStore`.
nonisolated struct TranslationPreferences: Equatable, Sendable {
    /// Master switch. Off by default: translation reads other people's messages from the screen,
    /// which is a choice the user makes, not one Cotabby makes for them.
    var isEnabled: Bool
    /// The language the user reads; incoming messages are translated into it, and replies written
    /// in it are offered in the conversation's language.
    var readingLanguage: String
    /// Apps whose windows are translated, by bundle identifier.
    var appBundleIdentifiers: [String]
    var translatesIncoming: Bool
    var offersReplyTranslation: Bool
    /// The key that replaces the user's draft with its translation.
    var replaceKeyCode: CGKeyCode
    var replaceKeyModifiers: UInt32
    var replaceKeyLabel: String

    /// Messaging and mail apps offered when the user first turns translation on.
    static let suggestedAppBundleIdentifiers = [
        "net.whatsapp.WhatsApp",
        "com.microsoft.teams2",
        "ru.keepcoder.Telegram",
        "com.tinyspeck.slackmacgap",
        "com.microsoft.Outlook",
        "com.apple.mail",
        "com.apple.MobileSMS"
    ]

    /// ⌃⌥T: free in the suggested apps, and unlike Tab or Return it cannot send a message.
    static let defaultReplaceKeyCode: CGKeyCode = 17
    static let defaultReplaceKeyModifiers: UInt32 = (1 << 2) | (1 << 3)
    static let defaultReplaceKeyLabel = "⌃ ⌥ T"

    static let defaults = TranslationPreferences(
        isEnabled: false,
        readingLanguage: "en",
        appBundleIdentifiers: suggestedAppBundleIdentifiers,
        translatesIncoming: true,
        offersReplyTranslation: true,
        replaceKeyCode: defaultReplaceKeyCode,
        replaceKeyModifiers: defaultReplaceKeyModifiers,
        replaceKeyLabel: defaultReplaceKeyLabel
    )
}

/// One translated piece of text, with the language it was detected in.
nonisolated struct TranslationResult: Equatable, Sendable {
    let sourceText: String
    let sourceLanguage: String
    let targetLanguage: String
    let translatedText: String
}

nonisolated enum TranslationError: Error, Equatable, LocalizedError {
    case unsupportedPair(source: String, target: String)
    case needsDownload(source: String, target: String)
    case noLocalModel
    case emptyResult

    var errorDescription: String? {
        switch self {
        case let .unsupportedPair(source, target):
            return "Translation from \(source) to \(target) isn't available on this Mac."
        case let .needsDownload(source, target):
            return "Download \(source) and \(target) in System Settings › General › Language & Region › Translation Languages."
        case .noLocalModel:
            return "This language needs a downloaded Open Source model, and none is selected."
        case .emptyResult:
            return "The translation came back empty."
        }
    }
}
