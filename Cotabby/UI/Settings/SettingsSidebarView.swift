import SwiftUI

/// File overview:
/// Renders the sidebar list of the redesigned Settings window as a flat list of rows.
/// `attentionCategories` is the set returned by `SettingsAttentionEvaluator` and decides which
/// rows show a small orange attention dot at the trailing edge.
///
/// Why this lives in its own file:
/// keeping row ordering and attention rendering out of the container leaves the container as a
/// small `NavigationSplitView` shell that is easy to skim.
struct SettingsSidebarView: View {
    @Binding var selection: SettingsCategory
    let attentionCategories: Set<SettingsCategory>

    var body: some View {
        List(selection: $selection) {
            ForEach(SettingsCategory.allCases) { row(for: $0) }
        }
        .listStyle(.sidebar)
        // Restores the breathing room the previous clear-color top spacer used to provide. Without
        // it, the first sidebar row snaps to the toolbar baseline while the detail pane's grouped
        // `Form` keeps its own top inset, so the two columns visually disagree about where content
        // begins. Insetting from the safe area keeps the inset out of scroll content so it never
        // overlaps a row mid-scroll.
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: 12)
        }
        // A single fixed width (not a min/ideal/max range) so `.balanced` can't squeeze the column
        // down to where labels truncate — the exact failure mode of the previous ranged width.
        // 260pt comfortably fits the longest label ("Engine & Model") with room to spare.
        .navigationSplitViewColumnWidth(260)
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
        .tag(category)
    }
}
