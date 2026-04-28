import Foundation

/// Converts a growing normalized model response into the stable prefix Tabby may show or accept.
///
/// Runtime token boundaries are model implementation details, not user-facing word boundaries.
/// This helper waits until normalized text reaches a word or punctuation boundary before exposing
/// it to the overlay, so streaming never renders broken fragments such as "autocom".
enum SuggestionStreamChunker {
    static func stablePrefix(from normalizedText: String, isFinal: Bool) -> String {
        if isFinal {
            return normalizedText
        }

        var lastStableBoundary: String.Index?
        var hasVisibleTextInCurrentToken = false

        var index = normalizedText.startIndex
        while index < normalizedText.endIndex {
            let character = normalizedText[index]

            if character.isWhitespace {
                if hasVisibleTextInCurrentToken {
                    lastStableBoundary = index
                }
                hasVisibleTextInCurrentToken = false
            } else {
                hasVisibleTextInCurrentToken = true

                if character.isStablePhrasePunctuation {
                    lastStableBoundary = normalizedText.index(after: index)
                }
            }

            index = normalizedText.index(after: index)
        }

        guard let lastStableBoundary else {
            return ""
        }

        let stablePrefix = String(normalizedText[..<lastStableBoundary])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard stablePrefix.containsVisibleSuggestionContent else {
            return ""
        }

        if normalizedText.first?.isWhitespace == true,
           !stablePrefix.firstIsWhitespace
        {
            return " " + stablePrefix
        }

        return stablePrefix
    }
}

private extension Character {
    var isStablePhrasePunctuation: Bool {
        guard unicodeScalars.count == 1, let scalar = unicodeScalars.first else {
            return false
        }

        return CharacterSet(charactersIn: ".,!?;:)]}").contains(scalar)
    }
}

private extension String {
    var firstIsWhitespace: Bool {
        first?.isWhitespace == true
    }

    var containsVisibleSuggestionContent: Bool {
        unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
}
