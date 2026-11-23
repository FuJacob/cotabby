import SwiftUI

/// File overview:
/// Sidebar of the Settings window. The app name and version sit at the top, then a search field,
/// then the content: with no query, the category rows in visually clustered groups (each row a
/// tinted icon tile plus label, with an optional attention dot); with a query, the individual
/// settings that match, ranked by relevance. Selecting a result reveals that exact setting in its
/// pane (scroll plus pulse) and clears the search.
///
/// Why a hand-rolled search field instead of `.searchable`:
/// `.searchable(placement: .sidebar)` pins its field flush to the top of the column, leaving no
/// room for the app header above it. A plain field can sit anywhere in the column while keeping
/// the same look. Ranking lives in `SettingsSearchRanker`; the catalog
/// in `SettingsItem`.
///
/// Why groups carry no header text: labeled headers were tried and their indentation chrome ate
/// sidebar width until labels like "Engine & Model" truncated. Spacing alone communicates the
/// clusters without costing a point of row width.
struct SettingsSidebarView: View {
    @ObservedObject var navigation: SettingsNavigationModel
    let attentionCategories: Set<SettingsCategory>
    let onQuit: () -> Void

    @State private var search = SettingsSearchQuery()

    var body: some View {
        VStack(spacing: 0) {
            appHeader
            searchField

            if search.isBlank {
                categoryList
            } else {
                searchResultsList
            }

            appActionsFooter
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

    /// No top padding: the app header above provides the clearance from the title bar, and a tight
    /// gap makes the field read as the head of the same group as the category rows beneath it.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search settings", text: $search.text)
                .textFieldStyle(.plain)
                .onSubmit(openTopResult)

            if !search.isBlank {
                Button {
                    search.text = ""
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
        .padding(.bottom, 4)
    }

    /// "Cotabby" wordmark with the app version in small secondary text beside it, sitting above the
    /// search field. The top padding clears the title bar.
    private var appHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Cotabby")
                .font(.title3.weight(.semibold))
            if let version = Bundle.main.cotabbyDisplayVersion {
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

    /// Keeps process-level recovery actions available even when the menu bar icon is hidden. The
    /// coordinator supplies the lifecycle behavior so this view remains presentation-focused.
    private var appActionsFooter: some View {
        VStack(spacing: 0) {
            Divider()

            Button(action: onQuit) {
                Label("Quit Cotabby", systemImage: "power")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("q")
            .padding(12)
        }
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

    private var searchResultsList: some View {
        let results = search.results()
        return List {
            if results.isEmpty {
                Text("No settings match \u{201C}\(search.trimmed)\u{201D}")
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
        guard let top = search.results().first else { return }
        open(top)
    }

    private func open(_ item: SettingsItem) {
        navigation.reveal(item)
        search.text = ""
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
