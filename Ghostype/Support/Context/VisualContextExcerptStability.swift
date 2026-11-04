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
/// when any unpaired line is a real line of text (three words or more), when a pairing is a short
/// line that became a real one by gaining a word at its end, or when the paired and leftover
/// differences add up to more than a small share of the excerpt. A new message, a
/// different conversation, or text streaming into view therefore still counts, while flicker does
/// not. Comparing against the excerpt in use, not the previous capture, keeps slow drift from
/// accumulating unnoticed.
///
/// Known cost: a change confined to digits (a counter, an amount), to a new line of one or two
/// words, or to one word added to a line that already was a real line is absorbed until something
/// larger changes.
nonisolated enum VisualContextExcerptStability {
    /// Beyond this many unmatched lines on either side the excerpt is treated as new without
    /// pairing.
    private static let maximumUnmatchedLines = 40

    /// Edit-table cells one call may fill in total. The rule runs on the main actor at every
    /// refresh. Real refreshes stay far below this: no pair of excerpts from a dev-log run of a busy
    /// Claude window needed more than about 2,000 cells. A screen of many similar lines (repeated
    /// code, a table) makes every pairing attempt fill most of its band instead; this caps such a
    /// refresh at a few milliseconds. Past the budget the change counts as material, so that refresh
    /// resets the suggestion, as every refresh did before this rule existed.
    static let defaultComparisonBudget = 200_000

    /// One excerpt line, prepared once per call: its key words, and those words joined into the
    /// Unicode scalars that character distances are counted in. Scalars compare as integers, where
    /// `Character` equality goes through grapheme comparison on every table cell.
    private struct Line {
        let words: [String]
        let scalars: [Unicode.Scalar]
    }

    /// Exact key matches cancel out as a multiset, so reordered lines cost nothing. Returns the
    /// lines of each side left without an identical partner.
    private static func unmatchedLines(_ current: [Line], _ candidate: [Line]) -> (current: [Line], candidate: [Line]) {
        var unmatchedCurrent = current
        var unmatchedCandidate: [Line] = []
        for line in candidate {
            if let index = unmatchedCurrent.firstIndex(where: { $0.words == line.words }) {
                unmatchedCurrent.remove(at: index)
            } else {
                unmatchedCandidate.append(line)
            }
        }
        return (unmatchedCurrent, unmatchedCandidate)
    }

    /// True when `candidate` should replace `current` (and count as navigation); false when it is
    /// the same screen as far as OCR can tell. `comparisonBudget` exists for tests.
    static func isMaterialChange(
        from current: String, to candidate: String, comparisonBudget: Int = defaultComparisonBudget
    ) -> Bool {
        guard current != candidate else {
            return false
        }
        let currentLines = lines(current)
        guard !currentLines.isEmpty else {
            return !lines(candidate).isEmpty
        }

        var (unmatchedCurrent, unmatchedCandidate) = unmatchedLines(currentLines, lines(candidate))
        guard unmatchedCurrent.count <= maximumUnmatchedLines, unmatchedCandidate.count <= maximumUnmatchedLines else {
            return true
        }

        // The old lines this refresh changed, before pairing consumes any of them.
        let changedCurrent = unmatchedCurrent
        var budget = comparisonBudget
        var difference = 0
        var leftover: [Line] = []
        for line in unmatchedCandidate {
            // The cheapest pairing wins, the earliest on a tie. Each comparison only needs to beat
            // the best found so far, which lets the edit tables stop sooner.
            var best: (index: Int, cost: Int)?
            for index in unmatchedCurrent.indices {
                let ceiling = best?.cost ?? Int.max
                if let cost = rereadCost(line, unmatchedCurrent[index], below: ceiling, budget: &budget) {
                    best = (index, cost)
                }
                if budget < 0 {
                    return true
                }
            }
            if let best {
                if grewIntoRealLine(line, from: unmatchedCurrent[best.index], changedLines: changedCurrent) {
                    return true
                }
                unmatchedCurrent.remove(at: best.index)
                difference += best.cost
            } else {
                leftover.append(line)
            }
        }
        leftover += unmatchedCurrent

        if leftover.contains(where: { isRealLine($0.words) }) {
            return true
        }
        difference += leftover.reduce(0) { $0 + $1.scalars.count }
        return difference > max(40, current.count / 20)
    }

    /// One key per line: lowercased words with digits removed, keeping only words that still have
    /// at least two letters. Lines with no such word (digit runs, icons, single letters) vanish.
    /// Only decimal digits go: `Character.isNumber` would also strip CJK numerals such as 一 and 十.
    private static func lines(_ text: String) -> [Line] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let words = line.lowercased()
                .split(whereSeparator: \.isWhitespace)
                .map { String($0.filter { $0.unicodeScalars.first?.properties.numericType != .decimal }) }
                .filter { $0.filter(\.isLetter).count >= 2 }
            return words.isEmpty ? nil : Line(words: words, scalars: Array(words.joined(separator: " ").unicodeScalars))
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

    /// True when `candidate` is `current` with one more word at its end and that word is what made
    /// it a real line ("Error saving" -> "Error saving draft"). The pair still reads as the same
    /// line, but the leftover check never sees the new line, so text being written there would be
    /// absorbed. Misreads change words inside a line ("OpenAI t 1 Chromium" / "OpenAI tEN
    /// Chromium"), so only growth at the end counts. The exception is a word that only moved across
    /// a split OCR made inside one visual line: it rejoined ("Opus Extra" and "Auto" -> "Opus Extra
    /// Auto") or split at the next word instead ("Error saving" and "Draft note" -> "Error saving
    /// draft" and "note"). Either way the added word began one of `changedLines`, the old lines this
    /// refresh did not reproduce exactly.
    private static func grewIntoRealLine(_ candidate: Line, from current: Line, changedLines: [Line]) -> Bool {
        guard candidate.words.count == current.words.count + 1, candidate.words.starts(with: current.words),
              isRealLine(candidate.words), !isRealLine(current.words), let added = candidate.words.last
        else {
            return false
        }
        return !changedLines.contains { $0.words.first == added }
    }

    private static func isSpacelessScript(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else {
            return false
        }
        // Han ideographs, then Hiragana and Katakana.
        return scalar.properties.isIdeographic || (0x3040...0x30FF).contains(scalar.value)
    }

    /// The character difference between two lines when they are the same line read twice and it is
    /// below `ceiling`, or nil.
    private static func rereadCost(_ lhs: Line, _ rhs: Line, below ceiling: Int, budget: inout Int) -> Int? {
        let left = lhs.scalars, right = rhs.scalars
        let longer = max(left.count, right.count), shorter = min(left.count, right.count)
        // A truncated title whose cut point moves by a few characters.
        if left.starts(with: right) || right.starts(with: left), longer - shorter <= max(3, shorter / 4) {
            return longer - shorter < ceiling ? longer - shorter : nil
        }
        let characterLimit = min(max(2, longer / 5), ceiling - 1)
        if let distance = editDistance(left, right, limit: characterLimit, budget: &budget) {
            return distance
        }
        // One misread, inserted or dropped word ("OpenAI tEN Chromium" / "OpenAI Chromium"). The
        // cost is still the character distance; when the ceiling is already below the limit above,
        // that distance was just found to be too large.
        let wordLimit = min(longer, ceiling - 1)
        if wordLimit > characterLimit, min(lhs.words.count, rhs.words.count) >= 2,
           editDistance(lhs.words, rhs.words, limit: 1, budget: &budget) != nil {
            return editDistance(left, right, limit: wordLimit, budget: &budget)
        }
        return nil
    }

    /// Levenshtein distance, or nil when it exceeds `limit`. Only cells within `limit` of the
    /// diagonal can lie on a path that cheap (Ukkonen's cutoff), so a row fills at most
    /// 2 * limit + 1 cells, and a row whose minimum already exceeds the limit ends the comparison.
    /// Cells outside the band hold `limit + 1`, which is as good as infinite here. Every filled cell
    /// is charged to `budget`; the caller checks it.
    private static func editDistance<Element: Equatable>(
        _ lhs: [Element], _ rhs: [Element], limit: Int, budget: inout Int
    ) -> Int? {
        guard limit >= 0, abs(lhs.count - rhs.count) <= limit else {
            return nil
        }
        let unreachable = limit + 1
        var previous = (0...rhs.count).map { min($0, unreachable) }
        var current = Array(repeating: unreachable, count: rhs.count + 1)
        for (row, left) in lhs.enumerated() {
            let tableRow = row + 1
            let first = max(1, tableRow - limit), last = min(rhs.count, tableRow + limit)
            current[first - 1] = first == 1 ? min(tableRow, unreachable) : unreachable
            var rowMinimum = current[first - 1]
            if first <= last {
                budget -= last - first + 1
                for column in first...last {
                    let cell = min(
                        previous[column - 1] + (left == rhs[column - 1] ? 0 : 1),
                        previous[column] + 1,
                        current[column - 1] + 1,
                        unreachable
                    )
                    current[column] = cell
                    rowMinimum = min(rowMinimum, cell)
                }
            }
            // The next row reads one cell past this row's band; it must not see a stale value.
            if last < rhs.count {
                current[last + 1] = unreachable
            }
            guard rowMinimum <= limit, budget >= 0 else {
                return nil
            }
            swap(&previous, &current)
        }
        return previous[rhs.count] <= limit ? previous[rhs.count] : nil
    }
}
