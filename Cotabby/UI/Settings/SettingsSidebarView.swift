import SwiftUI

/// File overview:
/// Sidebar of the Settings window. With no search query it shows the flat list of category rows,
/// each with an optional attention dot. With a query it shows the individual settings that match,
/// grouped by their owning pane; selecting a result navigates to that pane and clears the search.
///
/// Why this lives in its own file:
/// keeping row ordering, search, and attention rendering out of the container leaves the container
/// as a small `NavigationSplitView` shell that is easy to skim. The search index itself lives in
/// `SettingsItem` so coverage is maintained in one place.
struct SettingsSidebarView: View {
    @Binding var selection: SettingsCategory
    let attentionCategories: Set<SettingsCategory>

    @State private var searchText = ""

    var body: some View {
        Group {
            if trimmedQuery.isEmpty {
                categoryList
            } else {
                searchResultsList
            }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search settings")
        // `.navigationSplitViewColumnWidth` is only a hint — AppKit's underlying split view ignores
        // it when the window is at or near its minimum, which is what truncated labels like
        // "Engine &..." and "Permissio..." in the small-window screenshots. A direct `.frame()` is a
        // real SwiftUI layout constraint, so the split view has to give the sidebar at least the
        // minWidth. Keep the column-width hint as a paired ideal so a fresh window opens at the
        // right size before the user resizes.
        .frame(minWidth: 300, idealWidth: 340)
        .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 420)
    }

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var categoryList: some View {
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
    }

    private var searchResultsList: some View {
        let groups = groupedResults(SettingsItem.results(for: trimmedQuery))
        return List {
            if groups.isEmpty {
                Text("No settings match \u{201C}\(trimmedQuery)\u{201D}")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(groups) { group in
                    Section(group.category.label) {
                        ForEach(group.items) { item in
                            Button {
                                selection = item.category
                                searchText = ""
                            } label: {
                                Label(item.title, systemImage: item.systemImage)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func groupedResults(_ items: [SettingsItem]) -> [SettingsSearchGroup] {
        SettingsCategory.allCases.compactMap { category in
            let matching = items.filter { $0.category == category }
            return matching.isEmpty ? nil : SettingsSearchGroup(category: category, items: matching)
        }
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

/// One pane's worth of search results. Identified by its category so the grouped result list has a
/// stable identity for `ForEach`.
private struct SettingsSearchGroup: Identifiable {
    let category: SettingsCategory
    let items: [SettingsItem]

    var id: SettingsCategory { category }
}
