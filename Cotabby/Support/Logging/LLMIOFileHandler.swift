import Foundation
import Logging

/// File overview:
/// Dedicated JSONL sink for full LLM prompts and completions.
///
/// Kept separate from `cotabby.jsonl` so the main event stream stays readable: a single generation
/// can carry several KB of prompt text, and inlining that into every other log line would drown
/// the orchestration signal an AI debugger actually wants to follow.
///
/// One record per generation, written to `~/Library/Logs/Cotabby/llm-io.jsonl`. Records share a
/// `request_id` with the main log so a debugger can join across files.
///
/// Like `FileLogHandler`, this handler is only installed when `-cotabby-debug` is set, so a release
/// build never touches the user's disk with prompt or completion text.

/// swift-log handler that mirrors `FileLogHandler` but writes to the separate LLM I/O file. The
/// caller is expected to pass the full prompt and completion text via `Logger.Metadata`; the
/// handler does not inspect log levels because every event routed to `CotabbyLogger.llmIO` is
/// intentional.
struct LLMIOFileHandler: LogHandler {
    var metadata: Logging.Logger.Metadata = [:]
    var logLevel: Logging.Logger.Level = .trace

    private let label: String
    private let writer: JSONLFileWriter

    init(label: String, writer: JSONLFileWriter = .llmIO) {
        self.label = label
        self.writer = writer
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: borrowing Logging.LogEvent) {
        // The category is fixed rather than derived from the label: everything routed to this
        // sink is LLM I/O regardless of which logger emitted it.
        guard let line = JSONLRecord.render(
            level: event.level,
            message: event.message,
            eventMetadata: event.metadata,
            handlerMetadata: metadata,
            category: "llm-io"
        ) else {
            return
        }
        writer.write(line)
    }
}
