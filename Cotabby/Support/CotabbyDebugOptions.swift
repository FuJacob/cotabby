import Foundation
import Logging
import os

/// File overview:
/// Centralizes Cotabby's developer-only runtime switches.
///
/// A single launch argument is easier to reason about than separate feature flags because every
/// privacy-sensitive diagnostic path has one obvious gate. Passing `-cotabby-debug` means the
/// developer intentionally opted into local debugging artifacts such as overlays, detailed service
/// logs, and screenshot/OCR captures.
nonisolated enum CotabbyDebugOptions {
    static let launchArgument = "-cotabby-debug"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// The swift-log floor applied to the always-on `OSLogHandler` and the debug-only file sinks.
    ///
    /// swift-log only skips evaluating a log call's `@autoclosure` message (and building its
    /// metadata) when the handler's `logLevel` is strictly greater than the call's level. The
    /// handlers previously hardcoded `.trace`, so *every* `.debug`/`.trace` call on the hot path
    /// (one per keystroke: focus snapshots, routing, generation boundaries) still built its message
    /// string and metadata dictionary even in release builds where nothing consumed it. That is
    /// wasted CPU and energy, and it quietly inflates any on-device energy measurement. Defaulting
    /// the floor to `.info` makes those hot-path calls genuinely free unless verbose logging is
    /// explicitly requested.
    ///
    /// Precedence, highest first:
    /// 1. `COTABBY_LOG_LEVEL=<trace|debug|info|notice|warning|error|critical>` — explicit override,
    ///    e.g. to get Console `.debug` output without the heavier `-cotabby-debug` file/screenshot
    ///    artifacts. An unrecognized value is ignored.
    /// 2. `-cotabby-debug` — full `.trace` capture to Console and the JSONL sinks.
    /// 3. Default — `.info`.
    static var minimumLogLevel: Logging.Logger.Level {
        if let raw = ProcessInfo.processInfo.environment["COTABBY_LOG_LEVEL"]?.lowercased(),
           let level = Logging.Logger.Level(rawValue: raw) {
            return level
        }
        return isEnabled ? .trace : .info
    }

    /// Writes a diagnostic line only when the explicit debug launch argument is present.
    ///
    /// Keep this for metadata, not raw user content. Full prompts, OCR text, and screenshots are
    /// sensitive enough that call sites should make an intentional artifact decision instead of
    /// accidentally leaking them through normal stdout.
    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else {
            return
        }

        CotabbyLogger.debug.debug("\(message())")
    }
}

/// Provides subsystem-scoped loggers for the entire app.
///
/// All loggers route through `OSLogHandler` so messages appear in Console.app with the
/// subsystem as a filterable column. When the `-cotabby-debug` launch argument is set we
/// additionally fan out to `FileLogHandler`, which writes JSONL to
/// `~/Library/Logs/Cotabby/cotabby.jsonl` for AI-assisted debugging without copy-paste.
nonisolated enum CotabbyLogger {
    /// Reserved label that routes only to the dedicated LLM I/O sink, never to OSLog or the main
    /// JSONL file. Kept out of OSLog because full prompts/completions can be many KB per request
    /// and would dominate Console.app; kept out of `cotabby.jsonl` because it would drown the
    /// orchestration signal an AI debugger wants to skim.
    static let llmIOLabel = "com.cotabby.llm-io"

    private static let bootstrapOnce: Void = {
        // The debug-flag check happens once, at bootstrap time. Toggling it requires a relaunch,
        // which matches how every other launch-arg in the app behaves.
        let installFileHandler = CotabbyDebugOptions.isEnabled
        LoggingSystem.bootstrap { label in
            if label == llmIOLabel {
                // LLM I/O records are debug-only by design — installing the handler unconditionally
                // would let release builds write full prompts to disk.
                guard installFileHandler else { return SwiftLogNoOpLogHandler() }
                return LLMIOFileHandler(label: label)
            }
            let osHandler = OSLogHandler(label: label)
            guard installFileHandler else { return osHandler }
            return MultiplexLogHandler([osHandler, FileLogHandler(label: label)])
        }
        announceConfiguration(fileSinksInstalled: installFileHandler)
    }()

    /// Call once at app startup (e.g. in AppDelegate.init) before any logger is used.
    static func bootstrap() {
        _ = bootstrapOnce
    }

    /// Emits a single startup line recording the active logging configuration: whether debug mode
    /// is on, the effective verbosity floor, and where the JSONL sinks live. Logged at `.info` so it
    /// survives even the default quiet configuration — it is the first thing a developer (or an AI
    /// debugging agent reading the logs) needs before interpreting anything else, and it makes a
    /// misconfigured verbosity obvious instead of looking like "nothing is being logged".
    private static func announceConfiguration(fileSinksInstalled: Bool) {
        var metadata: Logging.Logger.Metadata = [
            "debug_mode": .stringConvertible(CotabbyDebugOptions.isEnabled),
            "min_log_level": .string(CotabbyDebugOptions.minimumLogLevel.rawValue),
            "file_sinks": .stringConvertible(fileSinksInstalled)
        ]
        // Only touch the file writers when sinks are actually installed: referencing `.shared` opens
        // the on-disk handle, which must never happen in the default (no-sink) configuration.
        if fileSinksInstalled {
            if let path = FileLogWriter.shared.fileURL?.path {
                metadata["event_log"] = .string(path)
            }
            if let path = LLMIOFileWriter.shared.fileURL?.path {
                metadata["llm_io_log"] = .string(path)
            }
        }
        app.info("Logging initialized", metadata: metadata)
    }

    static let app = Logger(label: "com.cotabby.app")
    static let debug = Logger(label: "com.cotabby.debug")
    static let runtime = Logger(label: "com.cotabby.runtime")
    static let focus = Logger(label: "com.cotabby.focus")
    static let updates = Logger(label: "com.cotabby.updates")
    static let models = Logger(label: "com.cotabby.models")
    static let suggestion = Logger(label: "com.cotabby.suggestion")
    /// Full prompts and completions, one structured JSON record per generation. Writes to
    /// `~/Library/Logs/Cotabby/llm-io.jsonl` only when `-cotabby-debug` is set.
    static let llmIO = Logger(label: llmIOLabel)
}

/// Bridges swift-log into Apple's Unified Logging so every log line appears in Console.app
/// with the correct subsystem, category, and native log level.
struct OSLogHandler: LogHandler {
    var metadata: Logging.Logger.Metadata = [:]
    var logLevel: Logging.Logger.Level

    private let osLogger: os.Logger

    /// Apple's convention: `subsystem` is the app-wide identifier (constant for all loggers),
    /// `category` is the per-component label. This way Console.app can filter all Tabby output
    /// with one subsystem while still distinguishing components by category.
    private static let subsystem = "com.cotabby.app"

    /// `logLevel` defaults to `CotabbyDebugOptions.minimumLogLevel` so the always-on Console sink is
    /// quiet (`.info`) in normal runs and fully verbose (`.trace`) under `-cotabby-debug`. The floor
    /// is what lets swift-log skip per-keystroke `.debug`/`.trace` calls before they allocate.
    init(label: String, logLevel: Logging.Logger.Level = CotabbyDebugOptions.minimumLogLevel) {
        self.logLevel = logLevel
        let parts = label.split(separator: ".", maxSplits: 2)
        let category = parts.count > 2 ? String(parts[2]) : label
        osLogger = os.Logger(subsystem: Self.subsystem, category: category)
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: borrowing Logging.LogEvent) {
        let text = "\(event.message)"
        switch event.level {
        case .trace:
            osLogger.trace("\(text, privacy: .public)")
        case .debug:
            osLogger.debug("\(text, privacy: .public)")
        case .info, .notice:
            osLogger.info("\(text, privacy: .public)")
        case .warning:
            osLogger.warning("\(text, privacy: .public)")
        case .error:
            osLogger.error("\(text, privacy: .public)")
        case .critical:
            osLogger.critical("\(text, privacy: .public)")
        }
    }
}
