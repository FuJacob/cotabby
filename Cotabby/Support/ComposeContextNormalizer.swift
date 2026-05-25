import Foundation

/// Pure cleanup for readable Accessibility text collected for Compose Mode.
///
/// The collector is allowed to be app-specific and side-effectful; this normalizer is not. Keeping
/// whitespace, dedupe, and prompt-size rules here makes the sensitive AX text boundary testable
/// before any model sees it.
enum ComposeContextNormalizer {
    struct Limits: Equatable, Sendable {
        let maxLineCharacters: Int
        let maxContextCharacters: Int

        static let standard = Limits(
            maxLineCharacters: 400,
            maxContextCharacters: 8_000
        )
    }

    private static let obviousNavigationLines: Set<String> = [
        "back",
        "cancel",
        "close",
        "copy",
        "delete",
        "edit",
        "forward",
        "menu",
        "more",
        "next",
        "open",
        "previous",
        "save",
        "search",
        "share",
        "skip to content",
        "submit"
    ]

    static func normalize(
        _ rawContext: String,
        limits: Limits = .standard
    ) -> String {
        var seenLines = Set<String>()
        var retainedLines: [String] = []
        var retainedCharacterCount = 0

        for rawLine in rawContext.replacingOccurrences(of: "\r", with: "\n").components(separatedBy: .newlines) {
            var line = collapseHorizontalWhitespace(in: rawLine)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !line.isEmpty,
                  !isSymbolNoise(line),
                  !isObviousNavigationLine(line)
            else {
                continue
            }

            if line.count > limits.maxLineCharacters {
                line = String(line.prefix(limits.maxLineCharacters)).trimmingCharacters(in: .whitespaces) + "..."
            }

            guard seenLines.insert(line).inserted else {
                continue
            }

            let separatorCost = retainedLines.isEmpty ? 0 : 1
            if retainedCharacterCount + separatorCost + line.count > limits.maxContextCharacters {
                let remaining = limits.maxContextCharacters - retainedCharacterCount - separatorCost
                if remaining > 0 {
                    retainedLines.append(String(line.prefix(remaining)))
                }
                break
            }

            retainedLines.append(line)
            retainedCharacterCount += separatorCost + line.count
        }

        return retainedLines.joined(separator: "\n")
    }

    private static func collapseHorizontalWhitespace(in text: String) -> String {
        var result = ""
        var previousWasWhitespace = false

        for scalar in text.unicodeScalars {
            if CharacterSet.whitespaces.contains(scalar) {
                if !previousWasWhitespace {
                    result.append(" ")
                }
                previousWasWhitespace = true
            } else {
                result.unicodeScalars.append(scalar)
                previousWasWhitespace = false
            }
        }

        return result
    }

    private static func isSymbolNoise(_ line: String) -> Bool {
        let scalars = line.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        guard scalars.count >= 2 else {
            return false
        }

        let noiseCharacters = CharacterSet.punctuationCharacters.union(.symbols)
        guard scalars.allSatisfy({ noiseCharacters.contains($0) }) else {
            return false
        }

        return Set(scalars).count <= 2
    }

    private static func isObviousNavigationLine(_ line: String) -> Bool {
        obviousNavigationLines.contains(line.lowercased())
    }
}
