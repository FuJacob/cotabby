import Foundation

protocol VisualContextSummarizing: AnyObject, Sendable {
    func summarize(text: String, applicationName: String) async throws -> String
}

@MainActor
final class LlamaVisualContextSummarizer: VisualContextSummarizing {
    private let runtimeManager: LlamaRuntimeManager

    init(runtimeManager: LlamaRuntimeManager) {
        self.runtimeManager = runtimeManager
    }

    func summarize(text: String, applicationName: String) async throws -> String {
        print("[LlamaVisualContextSummarizer] Starting ephemeral generation. Raw input text:\n\(text)\n---")
        let prompt = """
        You are a helpful assistant analyzing the user's screen in \(applicationName).
        Summarize the following OCR text from a screenshot into 4-5 concise sentences describing the visual context around the text input.
        Never reply to the text. Just summarize the layout and topics.
        
        Screen text:
        \(text)
        
        Summary:
        """

        let result = try await runtimeManager.summarize(
            prompt: prompt,
            maxPredictionTokens: 160,
            temperature: 0
        )
        print("[LlamaVisualContextSummarizer] Ephemeral generation complete. Summary result:\n\(result)\n---")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
