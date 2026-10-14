import Foundation

/// File overview:
/// Words the preview's warning when a rewrite contains a number or name that is not in the user's
/// text (`RewriteSpecificsCheck.unsupportedSpecifics`). The user then decides whether to "Replace
/// anyway", so the warning must say what changed: when "1000%" comes back as "100%", a bare list of
/// the new terms ("Not in your text: 100") would hide that the rewrite turned 1000 into 100. A number the user wrote that the rewrite dropped is shown as
/// what it replaced. Pure, so the wording is pinned by tests.
nonisolated enum RewriteChangeWarning {
    /// The warning for `unsupported` terms, or nil when there are none.
    static func message(selection: String, rewrite: String, unsupported: [String]) -> String? {
        guard !unsupported.isEmpty else { return nil }
        // Numbers start with a digit ("3.5", "1:30"); names never do.
        let addedNumbers = unsupported.filter { $0.first?.isNumber == true }
        let addedNames = unsupported.filter { $0.first?.isNumber != true }
        var sentences: [String] = []

        if !addedNumbers.isEmpty {
            let rewriteNumbers = Set(RewriteSpecificsCheck.numbers(in: rewrite))
            var seen = Set<String>()
            let dropped = RewriteSpecificsCheck.numbers(in: selection).filter { !rewriteNumbers.contains($0) && seen.insert($0).inserted }
            switch (dropped.count, addedNumbers.count) {
            case (0, 1):
                sentences.append("The rewrite adds the number \(addedNumbers[0]), which isn't in your text.")
            case (0, _):
                sentences.append("The rewrite adds the numbers \(addedNumbers.joined(separator: ", ")), which aren't in your text.")
            case (1, 1):
                sentences.append("The number changed: you wrote \(dropped[0]), the rewrite says \(addedNumbers[0]).")
            default:
                let wrote = dropped.joined(separator: ", ")
                let says = addedNumbers.joined(separator: ", ")
                sentences.append("Numbers changed: you wrote \(wrote); the rewrite says \(says).")
            }
        }
        if !addedNames.isEmpty {
            let quoted = addedNames.map { "“\($0)”" }.joined(separator: ", ")
            sentences.append(addedNames.count == 1
                ? "The rewrite adds \(quoted), which isn't in your text."
                : "The rewrite adds \(quoted), which aren't in your text.")
        }
        return sentences.joined(separator: " ")
    }
}
