import Foundation

/// Errors shared by suggestion backends and coordinator-facing normalization.

/// Errors specific to suggestion generation and normalization.
enum SuggestionClientError: LocalizedError {
    case unavailable(String)
    case unsupportedLanguageOrLocale(String)
    case generationFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .unavailable(message),
            let .unsupportedLanguageOrLocale(message),
            let .generationFailed(message):
            return message
        case .cancelled:
            return "Generation was cancelled."
        }
    }
}
