import Foundation
import NaturalLanguage

/// File overview:
/// Names the language a selection is written in, so the rewrite prompt can require it. Apple's
/// on-device model follows "write in the same language as the draft" poorly when the instructions
/// are English and the draft mixes in English words: such a draft can come back in English, and
/// naming its language in the prompt keeps it in that language.
///
/// Recognition is limited to the languages the user declared in Settings → Writing, because
/// unconstrained recognition can misname a short draft typed without accents. A language outside
/// the declared set is never named (a guess would force a wrong language); with nothing declared, a
/// confident guess is. Pure apart from `NLLanguageRecognizer`, which is deterministic and on-device.
nonisolated enum RewriteLanguageDetector {
    /// Below this the selection is too short or mixed to say; the prompt then keeps the generic
    /// "same language as the draft" rule.
    static let minimumConfidence = 0.6

    /// The English name of `text`'s language among `languageNames` (as stored, e.g. "Turkish"), or nil.
    static func language(of text: String, among languageNames: [String]) -> String? {
        let candidates = languageNames.compactMap { name in
            code(forLanguageName: name).map { (name: name, language: NLLanguage(rawValue: $0)) }
        }
        let recognizer = NLLanguageRecognizer()
        if candidates.count >= 2 {
            recognizer.languageConstraints = candidates.map(\.language)
        }
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).max(by: { $0.value < $1.value }),
              best.value >= minimumConfidence
        else { return nil }
        if let match = candidates.first(where: { $0.language == best.key }) {
            return match.name
        }
        guard candidates.isEmpty else { return nil }
        return Locale(identifier: "en").localizedString(forLanguageCode: best.key.rawValue)
    }

    /// The ISO language code for an English language name, from the built-in palette or, for a
    /// free-text entry such as "Turkish", from the system's English names of every ISO language.
    static func code(forLanguageName name: String) -> String? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return nil }
        if let option = LanguageCatalog.commonLanguages.first(where: { $0.name.lowercased() == wanted }) {
            return option.code
        }
        return codesByEnglishName[wanted]
    }

    private static let codesByEnglishName: [String: String] = {
        let english = Locale(identifier: "en")
        var map: [String: String] = [:]
        for code in Locale.LanguageCode.isoLanguageCodes.map(\.identifier) where code.count == 2 {
            if let name = english.localizedString(forLanguageCode: code)?.lowercased(), map[name] == nil {
                map[name] = code
            }
        }
        return map
    }()
}
