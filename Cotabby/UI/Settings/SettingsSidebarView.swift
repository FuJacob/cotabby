import SwiftUI

/// File overview:
/// Renders the sidebar list of the redesigned Settings window. Sections drive visual grouping;
/// `selection` is the binding the container view uses to decide which detail pane to show.
///
/// Why this lives in its own file:
/// the sidebar's row ordering, section headers, and indentation rules are sidebar concerns. Keeping
/// them out of the container view leaves the container as a small `NavigationSplitView` shell that
/// is easy to skim.
struct SettingsSidebarView: View {
    @Binding var selection: SettingsCategory

    var body: some View {
        List(selection: $selection) {
            ForEach(SettingsSidebarSection.allCases, id: \.self) { section in
                let rows = SettingsCategory.allCases.filter { $0.section == section }
                if !rows.isEmpty {
                    if let title = section.title {
                        Section(title) {
                            ForEach(rows) { row(for: $0) }
                        }
                    } else {
                        Section { ForEach(rows) { row(for: $0) } }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
    }

    @ViewBuilder
    private func row(for category: SettingsCategory) -> some View {
        Label(category.label, systemImage: category.systemImage)
            .padding(.leading, category.isSubRow ? 16 : 0)
            .tag(category)
    }
}
