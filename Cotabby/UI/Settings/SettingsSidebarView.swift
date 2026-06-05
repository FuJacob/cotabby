import SwiftUI

/// File overview:
/// Sidebar of the Settings window. A search field sits at the top with breathing room above it,
/// then the content: with no query the flat list of category rows (each with an optional attention
/// dot); with a query the individual settings that match, grouped by their owning pane. Selecting a
/// result navigates to that pane and clears the search.
///
/// Why a hand-rolled search field instead of `.searchable`:
/// `.searchable(placement: .sidebar)` pins its field flush to the top of the column with no way to
/// add padding above it, so it collides with the title bar. A plain field gives full control over
/// the top inset while keeping the same look. The search index itself lives in `SettingsItem`.
struct SettingsSidebarView: View {
    @Binding var selection: SettingsCategory
    let attentionCategories: Set<SettingsCategory>

    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            searchField

            if trimmedQuery.isEmpty {
                categoryList
            } else {
                searchResultsList
            }
        }
        // `.navigationSplitViewColumnWidth` is only a hint — AppKit's underlying split view ignores
        // it when the window is at or near its minimum, which truncated labels like "Engine &..." and
        // "Permissio..." in earlier small-window screenshots. A direct `.frame()` is a real SwiftUI
        // layout constraint, so the split view has to give the sidebar at least the minWidth. Keep
        // the column-width hint as a paired ideal so a fresh window opens at the right size.
        .frame(minWidth: 300, idealWidth: 340)
        .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 420)
    }

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Search field with deliberate top padding so it clears the title bar instead of butting
    /// against it.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search settings", text: $searchText)
                .textFieldStyle(.plain)

            if !trimmedQuery.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private var categoryList: some View {
        List(selection: $selection) {
            ForEach(SettingsCategory.allCases) { row(for: $0) }
        }
        .listStyle(.sidebar)
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
