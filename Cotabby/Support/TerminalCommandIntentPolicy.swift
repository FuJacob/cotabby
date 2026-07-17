import Foundation

/// Recognizes the narrow shell-buffer shape that should be translated rather than continued.
///
/// This is deliberately a deterministic preflight, not an LLM classification request. Cotabby only
/// enters replacement mode when the whole line starts with a plain-English imperative that is not a
/// normal macOS executable. Ordinary commands such as `git status`, paths, flags, pipes, redirects,
/// and partially typed command names remain on the existing continuation path.
nonisolated enum TerminalCommandIntentPolicy {
    private static let naturalLanguageVerbs: Set<String> = [
        "change", "compress", "copy", "count", "create", "delete", "display", "download",
        "extract", "go", "install", "list", "make", "move", "remove", "rename", "search",
        "show", "start", "stop", "uninstall"
    ]

    private static let shellSyntaxFragments = ["&&", "||", "|", ";", ">", "<", "$(", "`"]

    static func isReplacementIntent(_ text: String) -> Bool {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
              candidate.count <= 240,
              !candidate.contains("\n"),
              !candidate.contains("\0"),
              !shellSyntaxFragments.contains(where: candidate.contains)
        else { return false }

        let words = candidate.split(whereSeparator: \.isWhitespace)
        guard words.count >= 2, words.count <= 24,
              let first = words.first?.lowercased(),
              naturalLanguageVerbs.contains(first)
        else { return false }

        let commandLikePrefixes = ["./", "../", "/", "~/", "-", "$", "."]
        return !commandLikePrefixes.contains(where: { candidate.hasPrefix($0) })
    }
}
