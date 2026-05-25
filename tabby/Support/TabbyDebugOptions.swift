import Foundation
import Logging
import os

/// File overview:
/// Centralizes Tabby's developer-only runtime switches and the shared logger factory.
///
/// A single launch argument is easier to reason about than separate feature flags because every
/// privacy-sensitive diagnostic path has one obvious gate. Passing `-tabby-debug` means the
/// developer intentionally opted into local debugging artifacts such as overlays, detailed service
/// logs, and screenshot/OCR captures.
enum TabbyDebugOptions {
    static let launchArgument = "-tabby-debug"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
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

        TabbyLogger.debug.debug("\(message())")
    }
}

/// Provides subsystem-scoped loggers for the entire app.
///
/// All loggers route through `OSLogHandler`, so messages appear in Console.app
/// with the subsystem as a filterable column. Open Console.app and filter by
/// process "tabby" or subsystem "com.tabby.*" to see structured output.
enum TabbyLogger {
    private static let bootstrapOnce: Void = {
        LoggingSystem.bootstrap { label in
            OSLogHandler(label: label)
        }
    }()

    /// Call once at app startup (e.g. in AppDelegate.init) before any logger is used.
    static func bootstrap() {
        _ = bootstrapOnce
    }

    static let app = Logger(label: "com.tabby.app")
    static let debug = Logger(label: "com.tabby.debug")
    static let runtime = Logger(label: "com.tabby.runtime")
    static let focus = Logger(label: "com.tabby.focus")
    static let updates = Logger(label: "com.tabby.updates")
    static let models = Logger(label: "com.tabby.models")
    static let suggestion = Logger(label: "com.tabby.suggestion")
}

/// Bridges swift-log into Apple's Unified Logging so every log line appears in Console.app
/// with the correct subsystem, category, and native log level.
struct OSLogHandler: LogHandler {
    var metadata: Logging.Logger.Metadata = [:]
    var logLevel: Logging.Logger.Level = .trace

    private let osLogger: os.Logger

    /// Apple's convention: `subsystem` is the app-wide identifier (constant for all loggers),
    /// `category` is the per-component label. This way Console.app can filter all Tabby output
    /// with one subsystem while still distinguishing components by category.
    private static let subsystem = "com.tabby.app"

    init(label: String) {
        let parts = label.split(separator: ".", maxSplits: 2)
        let category = parts.count > 2 ? String(parts[2]) : label
        osLogger = os.Logger(subsystem: Self.subsystem, category: category)
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logging.Logger.Level,
        message: Logging.Logger.Message,
        metadata: Logging.Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        let text = "\(message)"
        switch level {
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
