import Foundation

/// File overview:
/// The language Cotabby should write completions in. Default is English, which emits no extra
/// prompt line (models already continue in the input's language). Any other choice injects an
/// explicit directive so smaller open-source models don't drift back to English mid-completion.
///
/// Raw values are BCP-47-ish codes for stable persistence; `displayLabel` shows the native name
/// (so a speaker recognizes their own language) alongside the English name.
enum SuggestionLanguage: String, CaseIterable, Equatable, Hashable, Sendable, Identifiable {
    case english = "en"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case portuguese = "pt"
    case dutch = "nl"
    case russian = "ru"
    case chineseSimplified = "zh-Hans"
    case japanese = "ja"
    case korean = "ko"
    case hindi = "hi"
    case arabic = "ar"

    var id: String { rawValue }

    static var `default`: SuggestionLanguage { .english }

    /// English name used inside the prompt directive (e.g. "Spanish").
    var promptName: String {
        switch self {
        case .english: return "English"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .german: return "German"
        case .italian: return "Italian"
        case .portuguese: return "Portuguese"
        case .dutch: return "Dutch"
        case .russian: return "Russian"
        case .chineseSimplified: return "Simplified Chinese"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .hindi: return "Hindi"
        case .arabic: return "Arabic"
        }
    }

    /// Dropdown label: native name with the English name in parentheses where they differ.
    var displayLabel: String {
        switch self {
        case .english: return "English"
        case .spanish: return "Español (Spanish)"
        case .french: return "Français (French)"
        case .german: return "Deutsch (German)"
        case .italian: return "Italiano (Italian)"
        case .portuguese: return "Português (Portuguese)"
        case .dutch: return "Nederlands (Dutch)"
        case .russian: return "Русский (Russian)"
        case .chineseSimplified: return "简体中文 (Simplified Chinese)"
        case .japanese: return "日本語 (Japanese)"
        case .korean: return "한국어 (Korean)"
        case .hindi: return "हिन्दी (Hindi)"
        case .arabic: return "العربية (Arabic)"
        }
    }

    /// Prompt line forcing the output language. `nil` for English so we don't spend tokens (or risk
    /// confusing the model) when no override is needed — the base "match the existing language" rule
    /// already covers the common case.
    var promptInstruction: String? {
        guard self != .english else { return nil }
        return "Always write the continuation in \(promptName), regardless of the language of the surrounding text."
    }
}
