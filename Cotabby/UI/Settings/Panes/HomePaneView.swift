import SwiftUI

/// File overview:
/// "Home" detail pane: the landing surface of the Settings window. Unlike every other pane it is
/// not a grouped form; it is a composed page: an identity hero, a prominent search field over the
/// whole settings catalog, an at-a-glance status row (power, engine, permissions), quick links
/// into the most-visited panes, the live feature demos, and a one-line footer with the project
/// links. Search results replace the page body while a query is active so the field behaves like
/// a command surface rather than a filter bolted onto a page.
///
/// The feature demos are inert (they never touch the real suggestion pipeline) and are passed
/// `autoplay: false` so the looping animations stay idle until the pointer is over them, keeping
/// this pane cheap to leave open.
struct HomePaneView: View {
    @ObservedObject var navigation: SettingsNavigationModel
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    @ObservedObject var permissionManager: PermissionManager
    @ObservedObject var foundationModelAvailabilityService: FoundationModelAvailabilityService
    @ObservedObject var runtimeModel: RuntimeBootstrapModel
    let attentionCategories: Set<SettingsCategory>

    @State private var query = ""
    @FocusState private var isSearchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    /// The panes offered as quick links. Power, engine, and permissions already live in the
    /// status row above, so the grid covers the everyday customization surfaces.
    private static let quickLinkCategories: [SettingsCategory] = [
        .appearance, .writing, .shortcuts, .emoji, .apps, .performance
    ]

    private static let maximumSearchResults = 12

    var body: some View {
        ZStack(alignment: .top) {
            heroBackdrop
            ScrollView {
                VStack(spacing: 28) {
                    hero
                    searchField

                    if trimmedQuery.isEmpty {
                        statusRow
                        quickLinksSection
                        showcaseSection
                        footer
                    } else {
                        searchResultsCard
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 28)
                .padding(.bottom, 32)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            guard !hasAppeared else { return }
            if reduceMotion {
                hasAppeared = true
            } else {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                    hasAppeared = true
                }
            }
        }
        // Cmd-F routes here from the container. `initial: true` covers the cross-pane case where
        // Home is rebuilt because of the shortcut and the publish happens before this view exists.
        .onChange(of: navigation.pendingSearchFocus, initial: true) { _, pending in
            guard pending else { return }
            isSearchFocused = true
            Task { navigation.consumeSearchFocusRequest() }
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Hero

    /// A soft accent wash behind the top of the page. Static (it does not scroll) so it reads as
    /// room lighting rather than content.
    private var heroBackdrop: some View {
        LinearGradient(
            colors: [Color.accentColor.opacity(0.12), Color.accentColor.opacity(0)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 260)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var hero: some View {
        VStack(spacing: 10) {
            Image("CotabbyLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                .scaleEffect(hasAppeared ? 1 : 0.9)
                .opacity(hasAppeared ? 1 : 0)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Cotabby")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                if let version = appVersionText {
                    Text(version)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.7), in: Capsule())
                }
            }

            // The tagline demos the product in one line: the trailing half renders like the ghost
            // text Cotabby draws at the caret.
            (Text("Write faster, ").foregroundColor(.primary)
                + Text("everywhere you type").foregroundColor(ghostTextColor))
                .font(.system(size: 15, design: .rounded))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// Matches the overlay's adaptive ghost gray so the tagline previews the real feature color.
    private var ghostTextColor: Color {
        colorScheme == .dark ? Color(white: 0.65) : Color(white: 0.45)
    }

    private var appVersionText: String? {
        Bundle.main.cotabbyDisplayVersion
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search every setting", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($isSearchFocused)
                .onSubmit(openTopResult)

            if trimmedQuery.isEmpty {
                Text("⌘F")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .accessibilityHidden(true)
            } else {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isSearchFocused ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.10),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.07), radius: 5, y: 2)
        .accessibilityLabel("Search settings")
    }

    private var searchResults: [SettingsItem] {
        Array(SettingsItem.results(for: trimmedQuery).prefix(Self.maximumSearchResults))
    }

    private var searchResultsCard: some View {
        let results = searchResults
        return VStack(spacing: 0) {
            if results.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                    Text("No settings match \u{201C}\(trimmedQuery)\u{201D}")
                        .foregroundStyle(.secondary)
                    Text("Try \u{201C}color\u{201D}, \u{201C}shortcut\u{201D}, \u{201C}battery\u{201D}, or \u{201C}privacy\u{201D}.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                    HomeSearchResultButton(item: item) {
                        open(item)
                    }
                    if index < results.count - 1 {
                        Divider().padding(.leading, 50)
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private func openTopResult() {
        guard let top = searchResults.first else { return }
        open(top)
    }

    private func open(_ item: SettingsItem) {
        navigation.reveal(item)
        query = ""
    }

    // MARK: - Status row

    private var statusRow: some View {
        HStack(spacing: 12) {
            powerCard
            engineCard
            permissionsCard
        }
    }

    private var powerCard: some View {
        HomeStatusCard(
            systemImage: "power",
            tint: suggestionSettings.isGloballyEnabled ? .green : .gray,
            title: "Cotabby",
            caption: suggestionSettings.isGloballyEnabled ? "Active" : "Paused"
        ) {
            Toggle("", isOn: globallyEnabledBinding)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .tint(.green)
                .accessibilityLabel("Enable Cotabby globally")
        }
    }

    private var engineCard: some View {
        Button {
            navigation.open(.engineAndModel)
        } label: {
            HomeStatusCard(
                systemImage: engineSystemImage,
                tint: engineNeedsAttention ? .orange : SettingsCategory.engineAndModel.tint,
                title: suggestionSettings.selectedEngine.displayLabel,
                caption: engineCaption,
                captionStyle: engineNeedsAttention ? .warning : .normal
            ) {
                HomeStatusChevron()
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Engine: \(suggestionSettings.selectedEngine.displayLabel), \(engineCaption)")
        .accessibilityHint("Opens Engine & Model settings")
    }

    private var permissionsCard: some View {
        Button {
            navigation.open(.permissions)
        } label: {
            HomeStatusCard(
                systemImage: permissionManager.requiredPermissionsGranted ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
                tint: permissionManager.requiredPermissionsGranted ? SettingsCategory.permissions.tint : .orange,
                title: "Permissions",
                caption: permissionManager.requiredPermissionsGranted ? "All set" : "Needs attention",
                captionStyle: permissionManager.requiredPermissionsGranted ? .normal : .warning
            ) {
                HomeStatusChevron()
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "Permissions: \(permissionManager.requiredPermissionsGranted ? "all set" : "needs attention")"
        )
        .accessibilityHint("Opens Permissions settings")
    }

    private var engineNeedsAttention: Bool {
        attentionCategories.contains(.engineAndModel)
    }

    private var engineSystemImage: String {
        switch suggestionSettings.selectedEngine {
        case .appleIntelligence: return "apple.logo"
        case .llamaOpenSource: return "cpu.fill"
        }
    }

    private var engineCaption: String {
        switch suggestionSettings.selectedEngine {
        case .appleIntelligence:
            return foundationModelAvailabilityService.isAvailable ? "Ready on this Mac" : "Unavailable"
        case .llamaOpenSource:
            let selected = runtimeModel.availableModels
                .first { $0.filename == runtimeModel.selectedModelFilename }
            return selected?.displayName ?? "No model selected"
        }
    }

    private var globallyEnabledBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.isGloballyEnabled },
            set: { suggestionSettings.setGloballyEnabled($0) }
        )
    }

    // MARK: - Quick links

    private var quickLinksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                "Quick settings",
                caption: "Jump straight to the controls you reach for most."
            )

            // Two columns at the default window width: three fit, but the captions truncate,
            // and a quick link whose caption is cut loses the point of having one.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 260), spacing: 12)],
                spacing: 12
            ) {
                ForEach(Self.quickLinkCategories) { category in
                    SettingsQuickLinkCard(category: category) {
                        navigation.open(category)
                    }
                }
            }
        }
    }

    // MARK: - Showcase

    private var showcaseSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                "See it in action",
                caption: "Hover a card to watch it play."
            )
            OnboardingFeatureShowcase(autoplay: false, showsMacroReference: true)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Text("Free & open source")
            footerDot
            if let repoURL = URL(string: "https://github.com/FuJacob/Cotabby") {
                Link("GitHub", destination: repoURL)
            }
            footerDot
            if let supportURL = URL(string: "https://ko-fi.com/cotabby") {
                Link(destination: supportURL) {
                    Label("Support", systemImage: "heart.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.pink)
                }
            }
            footerDot
            if let wikiURL = URL(string: "https://github.com/FuJacob/Cotabby/wiki") {
                Link("Wiki", destination: wikiURL)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var footerDot: some View {
        Text("\u{00B7}")
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    // MARK: - Shared bits

    private func sectionHeader(_ title: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Status card chrome

/// Shared chrome for one at-a-glance status card: tile, two text lines, and a trailing accessory
/// (a switch or a chevron). The card itself stays passive; interactive cards wrap it in a Button.
private struct HomeStatusCard<Accessory: View>: View {
    enum CaptionStyle {
        case normal
        case warning
    }

    let systemImage: String
    let tint: Color
    let title: String
    let caption: String
    var captionStyle: CaptionStyle = .normal
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 10) {
            SettingsIconTile(systemImage: systemImage, tint: tint, size: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(captionStyle == .warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            accessory()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }
}

private struct HomeStatusChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

// MARK: - Search result row button

/// One hero search hit with its own hover highlight. Split out so each row owns a single
/// `@State` instead of the page tracking hover indices.
private struct HomeSearchResultButton: View {
    let item: SettingsItem
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            SettingsSearchResultRow(item: item, style: .full)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isHovering ? Color.primary.opacity(0.06) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
