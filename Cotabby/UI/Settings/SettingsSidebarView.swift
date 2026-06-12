import SwiftUI

/// File overview:
/// Sidebar of the Settings window. A search field sits at the top with breathing room above it,
/// then the content: with no query, the category rows in visually clustered groups (each row a
/// tinted icon tile plus label, with an optional attention dot); with a query, the individual
/// settings that match, ranked by relevance. Selecting a result reveals that exact setting in its
/// pane (scroll plus pulse) and clears the search.
///
/// Why a hand-rolled search field instead of `.searchable`:
/// `.searchable(placement: .sidebar)` pins its field flush to the top of the column with no way to
/// add padding above it, so it collides with the title bar. A plain field gives full control over
/// the top inset while keeping the same look. Ranking lives in `SettingsSearchRanker`; the catalog
/// in `SettingsItem`.
///
/// Why groups carry no header text: labeled headers were tried and their indentation chrome ate
/// sidebar width until labels like "Engine & Model" truncated. Spacing alone communicates the
/// clusters without costing a point of row width.
struct SettingsSidebarView: View {
    @ObservedObject var navigation: SettingsNavigationModel
    let attentionCategories: Set<SettingsCategory>

    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            appHeader
            searchField

            if trimmedQuery.isEmpty {
                categoryList
            } else {
                searchResultsList
            }
        }
        // `.navigationSplitViewColumnWidth` is only a hint; AppKit's underlying split view ignores
        // it when the window is at or near its minimum, which truncated labels like "Engine &..."
        // and "Permissio..." in earlier small-window screenshots. A direct `.frame()` is a real
        // SwiftUI layout constraint, so the split view has to give the sidebar at least the
        // minWidth. Keep the column-width hint as a paired ideal so a fresh window opens at the
        // right size.
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
                .onSubmit(openTopResult)

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
        // The app header above now provides the clearance from the title bar; keep only a small gap
        // here so the field reads as the head of the same group as the category rows beneath it.
        .padding(.top, 0)
        .padding(.bottom, 4)
    }

    /// "Cotabby" wordmark with the app version in small secondary text beside it, sitting above the
    /// search field. The top padding clears the title bar (the search field used to own that space).
    private var appHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Cotabby")
                .font(.title3.weight(.semibold))
            if let version = appVersionText {
                Text(version)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 24)
        .padding(.bottom, 8)
    }

    /// Short marketing version (e.g. "v1.0"), or nil if the bundle has no version string.
    private var appVersionText: String? {
        Bundle.main.cotabbyDisplayVersion
    }

    private var selectionBinding: Binding<SettingsCategory> {
        Binding(
            get: { navigation.selection },
            set: { navigation.open($0) }
        )
    }

    private var categoryList: some View {
        List(selection: selectionBinding) {
            ForEach(Array(SettingsCategory.sidebarGroups.enumerated()), id: \.offset) { _, group in
                Section {
                    ForEach(group) { row(for: $0) }
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// Single source for the rendered results AND the Return-key action, so the key always opens
    /// exactly what the list shows.
    private var searchResults: [SettingsItem] {
        SettingsItem.results(for: trimmedQuery)
    }

    private var searchResultsList: some View {
        let results = searchResults
        return List {
            if results.isEmpty {
                Text("No settings match \u{201C}\(trimmedQuery)\u{201D}")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(results) { item in
                    Button {
                        open(item)
                    } label: {
                        SettingsSearchResultRow(item: item, style: .compact)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// Return inside the field commits the best match so search works without reaching for the
    /// pointer.
    private func openTopResult() {
        guard let top = searchResults.first else { return }
        open(top)
    }

    private func open(_ item: SettingsItem) {
        navigation.reveal(item)
        searchText = ""
    }

    @ViewBuilder
    private func row(for category: SettingsCategory) -> some View {
        HStack(spacing: 8) {
            SettingsIconTile(systemImage: category.systemImage, tint: category.tint, size: 20)
            Text(category.label)
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
