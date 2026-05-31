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
        // `.navigationSplitViewColumnWidth` is only a hint — AppKit's underlying split view ignores
        // it when the window is at or near its minimum, which is what truncated labels like
        // "Engine &..." and "Permissio..." in the small-window screenshots. A direct `.frame()` is a
        // real SwiftUI layout constraint, so the split view has to give the sidebar at least the
        // minWidth. Keep the column-width hint as a paired ideal so a fresh window opens at the
        // right size before the user resizes.
        .frame(minWidth: 300, idealWidth: 340)
        .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 420)
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
