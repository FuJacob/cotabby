import Foundation

/// Builds the prompt that lets a base (non-chat) language model translate, and cleans its output.
///
/// A base model cannot follow "translate this"; it continues text. Showing it a few labeled
/// sentence pairs and ending with the source sentence plus the target label makes the most likely
/// continuation the translation itself. The examples are everyday chat lines so the register
/// matches messages, and each pair is one line so decoding stops at the line break.
nonisolated enum FewShotTranslationPrompt {
    /// Parallel example sentences, keyed by language code. Every language listed here has the
    /// same sentences in the same order.
    private static let examples: [String: [String]] = [
        "en": [
            "I will call you after the meeting.",
            "Can you send me the document today?",
            "Thank you, see you tomorrow."
        ],
        "mk": [
            "Ќе ти се јавам после состанокот.",
            "Можеш ли да ми го испратиш документот денес?",
            "Ти благодарам, се гледаме утре."
        ],
        "tr": [
            "Toplantıdan sonra seni arayacağım.",
            "Belgeyi bana bugün gönderebilir misin?",
            "Teşekkürler, yarın görüşürüz."
        ]
    ]

    /// Languages this prompt can translate between (both sides need examples).
    static func supports(source: String, target: String) -> Bool {
        examples[TranslationLanguagePolicy.baseCode(source)] != nil
            && examples[TranslationLanguagePolicy.baseCode(target)] != nil
    }

    static func prompt(for text: String, source: String, target: String) -> String? {
        let sourceCode = TranslationLanguagePolicy.baseCode(source)
        let targetCode = TranslationLanguagePolicy.baseCode(target)
        guard let sourceExamples = examples[sourceCode], let targetExamples = examples[targetCode] else { return nil }
        let sourceLabel = label(sourceCode)
        let targetLabel = label(targetCode)
        var lines: [String] = []
        for (source, target) in zip(sourceExamples, targetExamples) {
            lines.append("\(sourceLabel): \(source)")
            lines.append("\(targetLabel): \(target)")
            lines.append("")
        }
        // One line per message: the model stops at the line break, and a multi-line message would
        // otherwise end the translation after its first line.
        let singleLine = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        lines.append("\(sourceLabel): \(singleLine)")
        lines.append("\(targetLabel):")
        return lines.joined(separator: "\n")
    }

    /// The translation from the model's raw continuation: the first line, without any label the
    /// model started repeating.
    static func cleanedOutput(_ raw: String) -> String {
        var line = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        for code in examples.keys {
            let marker = " \(label(code)):"
            if let range = line.range(of: marker) { line = String(line[..<range.lowerBound]) }
        }
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func label(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }
}
