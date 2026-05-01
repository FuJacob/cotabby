import Foundation
import OSLog

/// Logging capability consumed by services that should not know how diagnostics are stored.
///
/// Depending on this protocol instead of `DiagnosticsLogger` itself keeps services easier to test:
/// a unit test can inject a lightweight recorder without creating an AppKit panel or OSLog sink.
@MainActor
protocol DiagnosticsLogging: AnyObject {
    func log(
        _ level: DiagnosticLevel,
        category: DiagnosticCategory,
        component: String,
        message: String,
        metadata: [String: String]
    )
}

extension DiagnosticsLogging {
    func trace(
        category: DiagnosticCategory,
        component: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        log(.trace, category: category, component: component, message: message, metadata: metadata)
    }

    func info(
        category: DiagnosticCategory,
        component: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        log(.info, category: category, component: component, message: message, metadata: metadata)
    }

    func warning(
        category: DiagnosticCategory,
        component: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        log(.warning, category: category, component: component, message: message, metadata: metadata)
    }

    func error(
        category: DiagnosticCategory,
        component: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        log(.error, category: category, component: component, message: message, metadata: metadata)
    }
}

/// Central structured logger for Tabby's app-session diagnostics.
///
/// This facade performs two jobs:
/// 1. It records events into `DiagnosticsStore` so the in-app panel can update immediately.
/// 2. It mirrors only high-signal events to Apple's unified logging.
///
/// Services should inject and call this type instead of using `print`, because `print` has no
/// severity, category, timestamp, bounded retention, or UI observation path.
@MainActor
final class DiagnosticsLogger: DiagnosticsLogging {
    private let debugMode: DebugModeModel
    private let store: DiagnosticsStore
    private let subsystem: String

    init(
        debugMode: DebugModeModel,
        store: DiagnosticsStore,
        subsystem: String = Bundle.main.bundleIdentifier ?? "com.tabby.app"
    ) {
        self.debugMode = debugMode
        self.store = store
        self.subsystem = subsystem
    }

    func log(
        _ level: DiagnosticLevel,
        category: DiagnosticCategory,
        component: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        guard debugMode.isEnabled else {
            return
        }

        let event = DiagnosticEvent(
            level: level,
            category: category,
            component: component,
            message: message,
            metadata: metadata
        )
        store.record(event)
        if shouldMirrorToUnifiedLogging(event) {
            mirrorToUnifiedLogging(event)
        }
    }

    private func shouldMirrorToUnifiedLogging(_ event: DiagnosticEvent) -> Bool {
        if event.level == .warning || event.level == .error {
            return true
        }

        return event.metadata["_console"] == "true"
    }

    private func mirrorToUnifiedLogging(_ event: DiagnosticEvent) {
        let logger = Logger(subsystem: subsystem, category: event.category.rawValue)
        let line = event.formattedLine

        switch event.level {
        case .trace:
            logger.trace("\(line, privacy: .public)")
        case .info:
            logger.info("\(line, privacy: .public)")
        case .warning:
            logger.warning("\(line, privacy: .public)")
        case .error:
            logger.error("\(line, privacy: .public)")
        }
    }
}
