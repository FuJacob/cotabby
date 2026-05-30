import Foundation

/// File overview:
/// The catalog of sidebar rows in the redesigned Settings window. The sidebar is intentionally a
/// flat list with no section headers — System Settings-style grouping was tried earlier but the
/// extra header chrome ate sidebar width and pushed labels into truncation. Engine-specific
/// content (Apple Intelligence vs. Open Source) lives inside the single Engine & Model pane and
/// is switched via the engine dropdown at the top of that pane.
enum SettingsCategory: String, CaseIterable, Hashable, Identifiable {
    case general
    case engineAndModel
    case writing
    case shortcuts
    case apps
    case permissions
    case about

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: return "General"
        case .engineAndModel: return "Engine & Model"
        case .writing: return "Writing"
        case .shortcuts: return "Shortcuts"
        case .apps: return "Apps"
        case .permissions: return "Permissions"
        case .about: return "About"
        }
    }

    /// SF Symbol displayed at the left of each sidebar row.
    var systemImage: String {
        switch self {
        case .general: return "gearshape.fill"
        case .engineAndModel: return "cpu.fill"
        case .writing: return "square.and.pencil"
        case .shortcuts: return "keyboard.fill"
        case .apps: return "app.badge.fill"
        case .permissions: return "lock.shield.fill"
        case .about: return "info.circle.fill"
        }
    }
}
