import Foundation

/// File overview:
/// Decides whether a refreshed screen excerpt carries new content or is the same screen read again.
///
/// Vision does not read unchanged pixels the same way twice. Between two captures of a still
/// window it flips a truncated sidebar title between "sessi" and "sessic", reads a spinner as "8"
/// then "88", splits "Opus Extra Auto" into two lines, and lets short labels and digit runs appear
/// and vanish; live timers ("Thinking 13s") tick on their own. `SuggestionCoordinator` treats any
/// change of excerpt as navigation (retire the suggestion, and the new prompt head forces a full
/// llama re-prefill), so this jitter made a suggestion vanish and come back every refresh even
/// while the user was not typing. `VisualContextCoordinator` asks this rule whether a refresh is
/// material and, when it is not, keeps the excerpt already in use byte-identical.
///
/// The comparison is line-based, on a key that ignores what OCR gets wrong most: case, digits, and
/// fragments with fewer than two letters. Lines whose keys match exactly cancel out; each remaining
/// new line may pair with one remaining old line when they are evidently the same line read twice
/// (one truncates the other, a few characters differ, or one word differs). A change is material
/// when any unpaired line is a real line of text (three words or more), or when the paired and
/// leftover differences add up to more than a small share of the excerpt. A new message, a
/// different conversation, or text streaming into view therefore still counts, while flicker does
/// not. Comparing against the excerpt in use, not the previous capture, keeps slow drift from
/// accumulating unnoticed.
///
/// Known cost: a change confined to digits (a counter, an amount) or to a new line of one or two
/// words is absorbed until something larger changes.
nonisolated enum VisualContextExcerptStability {
    /// Beyond this many unmatched lines on either side the excerpt is treated as new without
    /// pairing, which also bounds the quadratic pairing work done on the main actor.
    private static let maximumUnmatchedLines = 40

    /// True when `candidate` should replace `current` (and count as navigation); false when it is
    /// the same screen as far as OCR can tell.
    static func isMaterialChange(from current: String, to candidate: String) -> Bool {
        guard current != candidate else {
            return false
        }
        let currentLines = lineKeys(current)
        guard !currentLines.isEmpty else {
            return !lineKeys(candidate).isEmpty
        }

        // Exact key matches cancel out as a multiset, so reordered lines cost nothing.
        var unmatchedCurrent = currentLines
        var unmatchedCandidate: [[String]] = []
        for line in lineKeys(candidate) {
            if let index = unmatchedCurrent.firstIndex(of: line) {
                unmatchedCurrent.remove(at: index)
            } else {
                unmatchedCandidate.append(line)
            }
        }
        guard unmatchedCurrent.count <= maximumUnmatchedLines, unmatchedCandidate.count <= maximumUnmatchedLines else {
            return true
        }

        var difference = 0
        var leftover: [[String]] = []
        for line in unmatchedCandidate {
            let best = unmatchedCurrent.indices
                .compactMap { index in rereadCost(line, unmatchedCurrent[index]).map { (index, $0) } }
                .min { $0.1 < $1.1 }
            if let (index, cost) = best {
                unmatchedCurrent.remove(at: index)
                difference += cost
            } else {
                leftover.append(line)
            }
        }
        leftover += unmatchedCurrent

        if leftover.contains(where: isRealLine) {
            return true
        }
        difference += leftover.reduce(0) { $0 + joined($1).count }
        return difference > max(40, current.count / 20)
    }

    /// One key per line: lowercased words with digits removed, keeping only words that still have
    /// at least two letters. Lines with no such word (digit runs, icons, single letters) vanish.
    /// Only decimal digits go: `Character.isNumber` would also strip CJK numerals such as 一 and 十.
    private static func lineKeys(_ text: String) -> [[String]] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let words = line.lowercased()
                .split(whereSeparator: \.isWhitespace)
                .map { String($0.filter { $0.unicodeScalars.first?.properties.numericType != .decimal }) }
                .filter { $0.filter(\.isLetter).count >= 2 }
            return words.isEmpty ? nil : words
        }
    }

    /// A leftover line this long is content (a message, a sentence), not a label or a fragment:
    /// three words and twelve characters. Chinese and Japanese are written without spaces, so there
    /// each ideograph or kana counts as a word and, being double width, as two characters;
    /// otherwise a new message in those scripts would read as one short word and be absorbed.
    private static func isRealLine(_ words: [String]) -> Bool {
        var wordCount = 0
        var width = words.count - 1
        for word in words {
            let spaceless = word.filter(isSpacelessScript).count
            wordCount += spaceless > 0 ? spaceless : 1
            width += word.count + spaceless
        }
        return wordCount >= 3 && width >= 12
    }

    private static func isSpacelessScript(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else {
            return false
        }
        // Han ideographs, then Hiragana and Katakana.
        return scalar.properties.isIdeographic || (0x3040...0x30FF).contains(scalar.value)
    }

    /// The character difference between two lines when they are the same line read twice, or nil.
    private static func rereadCost(_ lhs: [String], _ rhs: [String]) -> Int? {
        let left = Array(joined(lhs)), right = Array(joined(rhs))
        let longer = max(left.count, right.count), shorter = min(left.count, right.count)
        // A truncated title whose cut point moves by a few characters.
        if left.starts(with: right) || right.starts(with: left), longer - shorter <= max(3, shorter / 4) {
            return longer - shorter
        }
        let characterLimit = max(2, longer / 5)
        if let distance = editDistance(left, right, limit: characterLimit) {
            return distance
        }
        // One misread, inserted or dropped word ("OpenAI tEN Chromium" / "OpenAI Chromium").
        if min(lhs.count, rhs.count) >= 2, editDistance(lhs, rhs, limit: 1) != nil {
            return editDistance(left, right, limit: longer)
        }
        return nil
    }

    private static func joined(_ words: [String]) -> String {
        words.joined(separator: " ")
    }

    /// Levenshtein distance, or nil once it must exceed `limit` (checked per row, so unrelated
    /// lines are rejected after a few rows instead of filling the whole table).
    private static func editDistance<Element: Equatable>(_ lhs: [Element], _ rhs: [Element], limit: Int) -> Int? {
        guard abs(lhs.count - rhs.count) <= limit else {
            return nil
        }
        var previous = Array(0...rhs.count)
        var current = previous
        for (row, left) in lhs.enumerated() {
            current[0] = row + 1
            var rowMinimum = current[0]
            for (column, right) in rhs.enumerated() {
                current[column + 1] = min(
                    previous[column + 1] + 1,
                    current[column] + 1,
                    previous[column] + (left == right ? 0 : 1)
                )
                rowMinimum = min(rowMinimum, current[column + 1])
            }
            guard rowMinimum <= limit else {
                return nil
            }
            swap(&previous, &current)
        }
        return previous[rhs.count] <= limit ? previous[rhs.count] : nil
    }
}
