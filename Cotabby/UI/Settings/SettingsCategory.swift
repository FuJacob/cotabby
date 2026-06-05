import Foundation

/// File overview:
/// The catalog of sidebar rows in the Settings window. The sidebar is intentionally a flat list
/// with no section headers: System Settings-style grouping was tried earlier but the extra header
/// chrome ate sidebar width and pushed labels into truncation. Engine-specific content (Apple
/// Intelligence vs. Open Source) lives inside the single Engine & Model pane and is switched via the
/// engine dropdown at the top of that pane.
///
/// Order reflects a top-down reading: core behavior, how suggestions look, the emoji feature, what
/// the model is told (writing then context), the model itself, input bindings, then system and info.
enum SettingsCategory: String, CaseIterable, Hashable, Identifiable {
    case home
    case general
    case appearance
    case emoji
    case writing
    case context
    case engineAndModel
    case shortcuts
    case apps
    case permissions
    case performance
    case about

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return "Home"
        case .general: return "General"
        case .appearance: return "Appearance"
        case .emoji: return "Emoji"
        case .writing: return "Writing"
        case .context: return "Context"
        case .engineAndModel: return "Engine & Model"
        case .shortcuts: return "Shortcuts"
        case .apps: return "Apps"
        case .permissions: return "Permissions"
        case .performance: return "Performance"
        case .about: return "About"
        }
    }

    /// SF Symbol displayed at the left of each sidebar row.
    var systemImage: String {
        switch self {
        case .home: return "house.fill"
        case .general: return "gearshape.fill"
        case .appearance: return "paintbrush.fill"
        case .emoji: return "face.smiling"
        case .writing: return "square.and.pencil"
        case .context: return "doc.text"
        case .engineAndModel: return "cpu.fill"
        case .shortcuts: return "keyboard.fill"
        case .apps: return "app.badge.fill"
        case .permissions: return "lock.shield.fill"
        case .performance: return "speedometer"
        case .about: return "info.circle.fill"
        }
    }
}
