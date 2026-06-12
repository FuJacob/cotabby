import Foundation

/// File overview:
/// Emits high-signal model-boundary logs for the suggestion pipeline when `-cotabby-debug` is
/// enabled. The logger intentionally focuses on the payloads that explain model behavior:
/// the prompt Cotabby sent, the raw model response, and the normalized response Cotabby may display.
///
/// Keeping color and block formatting here avoids leaking console-presentation details into the
/// coordinator or lower-level services. Those services own behavior; this type owns observability.
@MainActor
final class SuggestionDebugLogger {
    private enum ANSIStyle {
        static let reset = "\u{001B}[0m"
        static let cyan = "\u{001B}[36m"
        static let yellow = "\u{001B}[33m"
        static let green = "\u{001B}[32m"
        static let red = "\u{001B}[31m"
    }

    private enum LogBlockKind: String {
        case promptInput = "prompt-input"
        case rawOutput = "raw-output"
        case normalizedOutput = "normalized-output"

        var delimiterTitle: String {
            switch self {
            case .promptInput:
                return "RAW PROMPT INPUT"
            case .rawOutput:
                return "RAW MODEL OUTPUT"
            case .normalizedOutput:
                return "NORMALIZED MODEL OUTPUT"
            }
        }

        var color: String {
            switch self {
            case .promptInput:
                return ANSIStyle.cyan
            case .rawOutput:
                return ANSIStyle.yellow
            case .normalizedOutput:
                return ANSIStyle.green
            }
        }
    }

    private let colorizedOutput: Bool
    private var lastLoggedMessage: String?

    init(colorizedOutput: Bool? = nil) {
        let shouldUseColor = ProcessInfo.processInfo.environment["NO_COLOR"] == nil
        self.colorizedOutput = colorizedOutput ?? shouldUseColor
    }

    // All stored state is thread-safe to release (a Bool and an optional String). The nonisolated
    // deinit prevents Swift from scheduling the teardown through the back-deployment main-actor
    // executor shim, which double-frees in app-hosted tests (see InputSuppressionController).
    nonisolated deinit {}

    /// Emits only the model-boundary artifacts that are useful for debugging suggestion quality.
    ///
    /// Lifecycle stages such as debounce, acceptance, and visual-context session dedup still update
    /// coordinator state elsewhere, but they do not belong in the console stream. The useful
    /// debugging question is: "what text crossed the model boundary, and what changed afterward?"
    func logStage(
        _ stage: String,
        workID: UInt64,
        generation: UInt64? = nil,
        message: String,
        prompt: String? = nil,
        rawOutput: String? = nil,
        normalizedOutput: String? = nil
    ) {
        guard CotabbyDebugOptions.isEnabled else {
            return
        }

        if stage == "generating", let prompt {
            logTextBlock(
                kind: .promptInput,
                stage: stage,
                workID: workID,
                generation: generation,
                text: prompt
            )
            return
        }

        if let rawOutput {
            logTextBlock(
                kind: .rawOutput,
                stage: stage,
                workID: workID,
                generation: generation,
                text: rawOutput
            )

            if let normalizedOutput {
                logTextBlock(
                    kind: .normalizedOutput,
                    stage: stage,
                    workID: workID,
                    generation: generation,
                    text: normalizedOutput
                )
            }
            return
        }

        if stage == "failed" {
            logErrorLine(stage: stage, workID: workID, generation: generation, message: message)
            return
        }
    }

    /// Produces an escaped single-line preview suitable for compact logs and menu summaries.
    static func debugPreview(_ text: String) -> String {
        if text.isEmpty {
            return "<empty>"
        }

        let escaped = text.debugDescription
        if escaped.count <= 160 {
            return escaped
        }

        let index = escaped.index(escaped.startIndex, offsetBy: 160)
        return "\(escaped[..<index])..."
    }

    private func logLine(_ line: String, color: String? = nil) {
        guard line != lastLoggedMessage else {
            return
        }

        lastLoggedMessage = line
        CotabbyDebugOptions.log(styled(line, color: color))
    }

    private func logErrorLine(
        stage: String,
        workID: UInt64,
        generation: UInt64?,
        message: String
    ) {
        let generationSummary = generation.map(String.init) ?? "n/a"
        logLine(
            "[Suggestion error] stage=\(stage) work=\(workID) " +
                "generation=\(generationSummary) message=\(message)",
            color: ANSIStyle.red
        )
    }

    /// Full blocks make prompt debugging inspectable without escaping user text into one line.
    /// Only the header and delimiter lines are colored so copied prompt bodies remain clean.
    private func logTextBlock(
        kind: LogBlockKind,
        stage: String,
        workID: UInt64,
        generation: UInt64?,
        text: String
    ) {
        let generationSummary = generation.map(String.init) ?? "n/a"
        let renderedText = text.isEmpty ? "<empty>" : text
        let header = styled(
            "[Suggestion \(kind.rawValue)] stage=\(stage) work=\(workID) generation=\(generationSummary)",
            color: kind.color
        )
        let begin = styled("----- BEGIN \(kind.delimiterTitle) -----", color: kind.color)
        let end = styled("----- END \(kind.delimiterTitle) -----", color: kind.color)

        CotabbyDebugOptions.log(
            """
            \(header)
            \(begin)
            \(renderedText)
            \(end)
            """
        )
    }

    private func styled(_ text: String, color: String?) -> String {
        guard colorizedOutput, let color else {
            return text
        }

        return "\(color)\(text)\(ANSIStyle.reset)"
    }
}
