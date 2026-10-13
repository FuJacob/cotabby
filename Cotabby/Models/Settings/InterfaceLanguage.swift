import Foundation

/// The finite set of interface locales Cotabby can explicitly select. Native names stay in their
/// own writing systems so this menu remains understandable before a restart applies the new UI.
nonisolated enum InterfaceLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case brazilianPortuguese = "pt-BR"
    case italian = "it"
    case russian = "ru"
    case arabic = "ar"
    case hindi = "hi"
    case indonesian = "id"
    case turkish = "tr"

    var id: String { rawValue }

    var nativeName: String {
        switch self {
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .french: "Français"
        case .german: "Deutsch"
        case .spanish: "Español"
        case .brazilianPortuguese: "Português (Brasil)"
        case .italian: "Italiano"
        case .russian: "Русский"
        case .arabic: "العربية"
        case .hindi: "हिन्दी"
        case .indonesian: "Bahasa Indonesia"
        case .turkish: "Türkçe"
        }
    }
}

/// The interface choice is independent of generation settings. The extra case is shown only when
/// Cotabby finds an existing app-only override it does not offer; retaining that selection lets a
/// user deliberately move to Follow System without the app rewriting it during startup.
nonisolated enum InterfaceLanguageSelection: Hashable {
    case followSystem
    case language(InterfaceLanguage)
    case preservedUnsupported(String)
}
