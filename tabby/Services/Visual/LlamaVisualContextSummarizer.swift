import Foundation

protocol VisualContextSummarizing: AnyObject, Sendable {
    func summarize(text: String, applicationName: String) async throws -> String
}

@MainActor
final class LlamaVisualContextSummarizer: VisualContextSummarizing {
    private let runtimeManager: LlamaRuntimeManager
    private weak var diagnosticsLogger: (any DiagnosticsLogging)?

    init(
        runtimeManager: LlamaRuntimeManager,
        diagnosticsLogger: (any DiagnosticsLogging)? = nil
    ) {
        self.runtimeManager = runtimeManager
        self.diagnosticsLogger = diagnosticsLogger
    }

    func summarize(text: String, applicationName: String) async throws -> String {
        diagnosticsLogger?.trace(
            category: .visual,
            component: "LlamaVisualContextSummarizer",
            message: "Starting visual-context summary",
            metadata: [
                "application": applicationName,
                "inputCharacters": String(text.count),
                "inputPreview": SuggestionDebugLogger.debugPreview(text)
            ]
        )
        let prompt = """
        You are an AI assistant analyzing what the user is currently looking at on their screen in the application \(applicationName).
        The following text is an OCR extraction from a screenshot of the window where the user is currently typing.
        
        Your task:
        Summarize this on-screen text into 4-5 concise sentences. This summary will be used as background context for a code/text autocomplete engine to understand what the user might type next.
        Focus on the main topics, the type of document/UI, and any relevant context that would help predict what the user is working on.
        DO NOT reply to the text. DO NOT answer questions in the text. ONLY output the summary.
        
        Screen text:
        \(text)
        
        Summary:
        """

        let result = try await runtimeManager.summarize(
            prompt: prompt,
            maxPredictionTokens: 160,
            temperature: 0
        )
        diagnosticsLogger?.trace(
            category: .visual,
            component: "LlamaVisualContextSummarizer",
            message: "Completed visual-context summary",
            metadata: [
                "outputCharacters": String(result.count),
                "outputPreview": SuggestionDebugLogger.debugPreview(result)
            ]
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
