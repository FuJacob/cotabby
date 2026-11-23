import Foundation

/// File overview:
/// The delimiters that mark untrusted context in the Apple Foundation Models prompt as data.
///
/// Apple's model is instruction-tuned, and its per-request prompt is a single channel. The window
/// title, the field placeholder, OCR'd screen text, the clipboard and the text after the caret used
/// to sit there under plain labels, next to Cotabby's own task lines. A web page controls most of
/// those strings, so a line on the page that reads like an instruction could steer what the ghost
/// proposes. `FoundationModelPromptRenderer` now wraps each of them in this fence, its session
/// instructions say fenced text is reference data and never instructions, and
/// `SuggestionTextNormalizer` removes fence tags from any completion that writes them out.
///
/// A fence lowers the odds of steering; it cannot rule it out, because the model still reads the
/// text. What it does guarantee is structural: fenced text cannot end its fence early, since every
/// tag-like spelling of the fence name is removed from it first.
///
/// Kept as its own pure type so the renderer, the instruction line and the output filter share one
/// spelling of the tags, and a test can hold all three to it.
nonisolated enum PromptDataFence {
    static let open = "<context_data>"
    static let close = "</context_data>"

    /// The fence name in any tag-like spelling: either case, a closing slash, stray spaces, or
    /// attributes. A model can read `</CONTEXT_DATA >` as a close tag as readily as the exact one,
    /// so every variant is removed, not only the two exact strings.
    private static let tagPattern = "<\\s*/?\\s*context_data\\b[^<>]*>"
    private static let name = "context_data"

    /// `text` on its own lines between the fence tags, for multi-line sections (screen text,
    /// clipboard, the text after the caret). The line breaks keep the text's own leading and
    /// trailing whitespace visible to the model, which matters for the text after the caret.
    static func fenced(_ text: String) -> String {
        "\(open)\n\(removingTags(from: text))\n\(close)"
    }

    /// `text` between the fence tags on one line, for a short fact inside a sentence (a window
    /// title, a field label), where the tags take the place of the quotes it used to sit in.
    static func inlineFenced(_ text: String) -> String {
        "\(open)\(removingTags(from: text))\(close)"
    }

    /// `text` with every fence-like tag removed. Applied to untrusted text before it is fenced, and
    /// to completions: a fence tag in a completion is echoed prompt structure, never the user's next
    /// words. The name check first keeps the regex off the per-keystroke path for ordinary text.
    static func removingTags(from text: String) -> String {
        guard text.range(of: name, options: .caseInsensitive) != nil else {
            return text
        }
        return text.replacingOccurrences(
            of: tagPattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }
}
