import SwiftUI

/// File overview:
/// Renders the sidebar list of the redesigned Settings window. Sections drive visual grouping;
/// `selection` is the binding the container view uses to decide which detail pane to show.
/// `attentionCategories` is the set returned by `SettingsAttentionEvaluator` and decides which
/// rows show a small orange attention dot at the trailing edge.
///
/// Why this lives in its own file:
/// the sidebar's row ordering, section headers, indentation, and attention rendering are all
/// sidebar concerns. Keeping them out of the container view leaves the container as a small
/// `NavigationSplitView` shell that is easy to skim.
struct SettingsSidebarView: View {
    @Binding var selection: SettingsCategory
    let attentionCategories: Set<SettingsCategory>

    var body: some View {
        List(selection: $selection) {
            // First row would otherwise sit flush against the window title bar. A clear-color
            // sentinel that is excluded from selection gives the sidebar the same top breathing
            // room as the detail pane without fighting `.listStyle(.sidebar)`.
            Color.clear
                .frame(height: 8)
                .listRowBackground(Color.clear)
                .selectionDisabled()

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
        // Wider min/ideal so labels like "Apple Intelligence" do not truncate to "Apple I...".
        .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 320)
    }

    @ViewBuilder
    private func row(for category: SettingsCategory) -> some View {
        HStack(spacing: 6) {
            Label(category.label, systemImage: category.systemImage)
            Spacer(minLength: 0)
            if attentionCategories.contains(category) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel("Needs attention")
            }
        }
        .padding(.leading, category.isSubRow ? 16 : 0)
        .tag(category)
    }
}
