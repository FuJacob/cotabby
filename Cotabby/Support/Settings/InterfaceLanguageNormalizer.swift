import Foundation

/// Maps stored BCP-47-ish identifiers to Cotabby's supported menu choices without changing the
/// stored value. Region variants collapse to the app's available base locale where that is clear.
nonisolated enum InterfaceLanguageNormalizer {
    static func selection(forStoredIdentifier identifier: String) -> InterfaceLanguageSelection {
        let pieces = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .map { $0.lowercased() }

        guard let languageCode = pieces.first else {
            return .preservedUnsupported(identifier)
        }

        let language: InterfaceLanguage? = switch languageCode {
        case "zh": chineseLanguage(in: pieces)
        case "pt": pieces.contains("br") ? .brazilianPortuguese : nil
        default: InterfaceLanguage(rawValue: languageCode)
        }

        guard let language else {
            return .preservedUnsupported(identifier)
        }
        return .language(language)
    }

    private static func chineseLanguage(in pieces: [String]) -> InterfaceLanguage? {
        // An explicit script is the user's precise preference. Region is only a useful proxy when
        // the stored tag omits Hans/Hant, since multilingual regions and migrated tags can conflict.
        if pieces.contains("hans") {
            return .simplifiedChinese
        }
        if pieces.contains("hant") {
            return .traditionalChinese
        }

        if pieces.contains("cn") || pieces.contains("sg") || pieces.contains("my") {
            return .simplifiedChinese
        }
        if pieces.contains("tw") || pieces.contains("hk") || pieces.contains("mo") {
            return .traditionalChinese
        }
        // A bare `zh` does not say whether the writer wants Simplified or Traditional Chinese.
        return nil
    }
}
