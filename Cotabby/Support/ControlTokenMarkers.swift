import Foundation

/// Centralizes the chat / instruct / control-token scaffolding that base models occasionally leak
/// into their output, and the rule for removing it from a raw completion.
///
/// We ship base (non-instruct) models, but their vocabularies still contain the special tokens of
/// the chat templates they were trained alongside. When the model drifts, it can emit those tokens
/// as literal text, which must never reach the ghost text. Three shapes need different handling:
///
/// - Role-header blocks wrap a role name between two markers (`<|start_header_id|>assistant
///   <|end_header_id|>`). Removing the markers individually would leak the role word, so the whole
///   block is stripped.
/// - Opening / role markers wrap content (`<|im_start|>assistant … `), so the real continuation sits
///   adjacent to them. We remove just the marker token and keep the surrounding text.
/// - Stop / end-of-turn markers mean the model should have stopped; anything after one is a new
///   hallucinated turn. We truncate the completion at the first stop marker so that garbage never
///   leaks (and a genuine prefix before it is preserved).
///
/// These are deliberately limited to unambiguous model control tokens that a human would never type
/// into a text field expecting a completion, so removing them cannot eat legitimate prose or code.
/// `<think>…</think>` reasoning blocks are intentionally not listed here: they are handled separately
/// so the text around them survives.
nonisolated enum ControlTokenMarkers {
    /// A Llama-3 role-header block, e.g. `<|start_header_id|>assistant<|end_header_id|>`. The role
    /// name sits *between* the markers, so removing the markers individually would leak the role word
    /// into the ghost text; this strips the whole block. `|` is escaped because it is a regex
    /// alternation metacharacter.
    private static let roleHeaderBlockPattern = "<\\|start_header_id\\|>.*?<\\|end_header_id\\|>"

    /// Opening / role markers. Removed in place so adjacent content is preserved. The Llama-3 header
    /// markers stay here as a fallback for an unpaired marker that the block regex cannot match.
    static let openingMarkers: [String] = [
        "<|im_start|>",
        "<start_of_turn>",
        "<|user|>",
        "<|assistant|>",
        "<|system|>",
        "<|start_header_id|>",
        "<|end_header_id|>",
        "[INST]",
        "[/INST]"
    ]

    /// Stop / end-of-turn markers. The completion is truncated at the first one that appears.
    ///
    /// `</s>` (the Llama-1/2 / Mistral EOS marker) is deliberately excluded: it is also the closing
    /// tag of the HTML `<s>` strikethrough element, so truncating on it would silently cut HTML
    /// authoring. The base models Cotabby ships use `<|im_end|>` (Qwen / ChatML) and `<end_of_turn>`
    /// (Gemma), so excluding `</s>` loses no coverage for them.
    static let stopMarkers: [String] = [
        "<|im_end|>",
        "<|endoftext|>",
        "<|end|>",
        "<end_of_turn>",
        "<|eot_id|>"
    ]

    /// Removes role-header blocks and opening/role markers, then truncates at the first stop marker,
    /// so chat-template scaffolding never reaches the ghost text while genuine adjacent content is
    /// preserved.
    static func sanitize(_ text: String) -> String {
        // Strip Llama-3 role-header blocks (including the role word between the markers) before the
        // per-marker pass, so the role name does not survive when no stop token precedes it.
        var result = text.replacingOccurrences(
            of: roleHeaderBlockPattern,
            with: "",
            options: .regularExpression
        )

        for marker in openingMarkers {
            result = result.replacingOccurrences(of: marker, with: "")
        }

        if let cut = firstStopMarkerLowerBound(in: result) {
            result = String(result[..<cut])
        }

        return result
    }

    /// The position of the earliest stop marker in `text`, or nil when none appear.
    private static func firstStopMarkerLowerBound(in text: String) -> String.Index? {
        var earliest: String.Index?
        for marker in stopMarkers {
            guard let range = text.range(of: marker) else {
                continue
            }
            if let current = earliest {
                earliest = min(current, range.lowerBound)
            } else {
                earliest = range.lowerBound
            }
        }
        return earliest
    }
}
