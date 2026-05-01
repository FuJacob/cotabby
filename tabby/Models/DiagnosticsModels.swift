import Foundation

/// File overview:
/// Shared diagnostics value types for Tabby's in-app observability system.
///
/// These types intentionally live in `Models` because they describe data contracts, not where
/// the data is rendered or stored. Services emit `DiagnosticEvent` values, the diagnostics store
/// retains recent events, and SwiftUI panels decide how to present them.

/// The single switch that controls Tabby's debug-only behavior.
///
/// One flag matters because "show the panel" and "collect logs" are two views of the same intent:
/// the operator is actively debugging this app session. Keeping that as one state prevents the
/// confusing case where logs are being collected but the panel is hidden, or the panel is visible
/// with no live diagnostic feed behind it.
struct DebugModeState: Equatable, Sendable {
    let isEnabled: Bool
    let launchArgument: String

    var statusLabel: String {
        isEnabled ? "Enabled" : "Disabled"
    }
}

/// Coarse severity for diagnostic events.
///
/// The levels deliberately mirror the mental model used by Apple's unified logging while keeping
/// names simple enough for the in-app panel.
enum DiagnosticLevel: String, CaseIterable, Equatable, Sendable, Identifiable {
    case trace
    case info
    case warning
    case error

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .trace:
            return "TRACE"
        case .info:
            return "INFO"
        case .warning:
            return "WARN"
        case .error:
            return "ERROR"
        }
    }
}

/// Subsystem bucket for log filtering and color-coding.
///
/// Categories are intentionally broader than individual Swift types. A useful debug panel lets you
/// scan "accessibility" or "suggestion" behavior quickly without memorizing every class name.
enum DiagnosticCategory: String, CaseIterable, Equatable, Sendable, Identifiable {
    case app
    case accessibility
    case suggestion
    case visual
    case runtime
    case permissions
    case updates

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .app:
            return "App"
        case .accessibility:
            return "AX"
        case .suggestion:
            return "Suggestion"
        case .visual:
            return "Visual"
        case .runtime:
            return "Runtime"
        case .permissions:
            return "Permissions"
        case .updates:
            return "Updates"
        }
    }
}

/// One structured log entry emitted by a Tabby subsystem.
///
/// The schema is intentionally small:
/// - `category` answers "which subsystem?"
/// - `component` answers "which type emitted this?"
/// - `message` is the human-readable event
/// - `metadata` holds machine-scannable context without forcing every event into custom structs
struct DiagnosticEvent: Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let level: DiagnosticLevel
    let category: DiagnosticCategory
    let component: String
    let message: String
    let metadata: [String: String]

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: DiagnosticLevel,
        category: DiagnosticCategory,
        component: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.component = component
        self.message = message
        self.metadata = metadata
    }
}

extension DiagnosticEvent {
    /// Compact string for console-style sinks. The in-app panel uses the structured fields
    /// directly, but unified logging benefits from one stable line.
    var formattedLine: String {
        var parts = [
            "[\(category.displayLabel)]",
            "level=\(level.displayLabel)",
            "component=\(component)",
            "message=\(message)"
        ]

        for key in metadata.keys.sorted() {
            guard !key.hasPrefix("_") else {
                continue
            }

            guard let value = metadata[key], !value.isEmpty else {
                continue
            }

            parts.append("\(key)=\(value)")
        }

        return parts.joined(separator: " ")
    }
}
