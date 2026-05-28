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
        // Doubled column width so every label fits without truncation and the sidebar reads as a
        // real navigation column. The earlier clear-color top spacer is gone: it was pushing the
        // first row well below where the detail pane's first card starts, breaking visual
        // alignment between sidebar and content. The grouped form's own top inset on the detail
        // side handles breathing room; the sidebar lines up with it naturally.
        .navigationSplitViewColumnWidth(min: 480, ideal: 520, max: 640)
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
