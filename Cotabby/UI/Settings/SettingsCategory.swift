import Foundation

/// File overview:
/// The catalog of sidebar rows in the redesigned Settings window.
///
/// Each case is one selectable row. `section` drives the visual grouping in the sidebar (rows in
/// the same section render under the same header). `engineAndModel` is intentionally also a row
/// the user can land on: when neither sub-row is selected we show a parent overview pane that owns
/// the engine picker, so the user has a single place to switch engines. The two sub-cases
/// (`appleIntelligence`, `openSource`) host the engine-specific content.
enum SettingsCategory: String, CaseIterable, Hashable, Identifiable {
    case general
    case engineAndModel
    case appleIntelligence
    case openSource
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
        case .appleIntelligence: return "Apple Intelligence"
        case .openSource: return "Open Source"
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
        case .appleIntelligence: return "apple.logo"
        case .openSource: return "shippingbox.fill"
        case .writing: return "square.and.pencil"
        case .shortcuts: return "keyboard.fill"
        case .apps: return "app.badge.fill"
        case .permissions: return "lock.shield.fill"
        case .about: return "info.circle.fill"
        }
    }

    var section: SettingsSidebarSection {
        switch self {
        case .general: return .top
        case .engineAndModel, .appleIntelligence, .openSource: return .engineModel
        case .writing, .shortcuts, .apps: return .customize
        case .permissions: return .system
        case .about: return .meta
        }
    }

    /// Rows that nest visually beneath their parent in the sidebar render with extra indentation.
    /// Today only the two engine sub-rows count; everything else sits at the top level.
    var isSubRow: Bool {
        switch self {
        case .appleIntelligence, .openSource: return true
        default: return false
        }
    }
}

/// Visual groups used to render section headers in the sidebar. Cases without a `title` render
/// without a header so the sidebar stays compact; cases with one show a small uppercase label
/// above the rows in that group.
enum SettingsSidebarSection: CaseIterable {
    case top
    case engineModel
    case customize
    case system
    case meta

    var title: String? {
        switch self {
        case .top: return nil
        case .engineModel: return "Engine & Model"
        case .customize: return "Customize"
        case .system: return "System"
        // SwiftUI's grouped sidebar still inserts inter-section spacing for header-less groups, so
        // leaving `meta` headerless reads as an unexplained gap between Permissions and About.
        // Naming the group avoids that visual hiccup without merging About into System (which would
        // overload "System" with two unrelated concepts: permissions and app-info).
        case .meta: return "Info"
        }
    }
}
