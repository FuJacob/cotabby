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
        // Restores the breathing room the previous clear-color top spacer used to provide. Without
        // it, the first sidebar row snaps to the toolbar baseline while the detail pane's grouped
        // `Form` keeps its own ~20pt top inset, so the two columns visually disagree about where
        // content begins. Insetting from the safe area keeps the inset out of scroll content so it
        // never overlaps a row mid-scroll.
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: 12)
        }
        // Previously bumped to 480/520/640, but with the window's overall `minWidth` the
        // `.balanced` split style had to shrink the sidebar back below 240pt to keep the detail
        // pane usable — which still truncated "Apple Intelligence" to "Apple Intell…". The
        // tighter range here matches the longest user-facing label and lines up with the
        // matching `minWidth` reduction on the container so the detail pane keeps its own room.
        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
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
