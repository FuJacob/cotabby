import SwiftUI

/// File overview:
/// Root of the redesigned Settings window. A `NavigationSplitView` with a sidebar of clustered
/// category rows sits on the left and a switching detail pane fills the right side. The detail body
/// is built from `SettingsCategory`, so adding a new pane is a matter of adding an enum case and a
/// `case` in the switch below.
///
/// Navigation flows through `SettingsNavigationModel` so the sidebar, the Home pane's search and
/// quick links, and the window-level Cmd-F shortcut all drive one source of truth. Selection is
/// persisted via `@AppStorage` so reopening Settings lands on the last-used pane. `.id(selection)`
/// on the detail body is the documented workaround for the macOS 14 split-view selection bug where
/// the first sidebar pick doesn't always re-render the detail column.
struct SettingsContainerView: View {
    let appUpdateManager: AppUpdateManager

    @ObservedObject var permissionManager: PermissionManager
    let permissionGuidanceController: PermissionGuidanceController
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    @ObservedObject var foundationModelAvailabilityService: FoundationModelAvailabilityService
    @ObservedObject var runtimeModel: RuntimeBootstrapModel
    @ObservedObject var modelDownloadManager: ModelDownloadManager
    @ObservedObject var huggingFaceSearchService: HuggingFaceSearchService
    @ObservedObject var performanceMetricsStore: PerformanceMetricsStore
    @ObservedObject var qualityMetricsStore: SuggestionQualityMetricsStore
    @ObservedObject var systemMetricsStore: SystemMetricsStore

    let onShowWelcome: () -> Void
    let clearEmojiHistory: () -> Void

    @AppStorage("cotabbySettingsSelectedCategoryV2")
    private var storedCategoryRawValue: String = SettingsCategory.home.rawValue

    @StateObject private var navigation = SettingsNavigationModel()
    // Settings should behave like a traditional two-column preferences window: the sidebar is
    // always visible, but SwiftUI can still manage the native navigation/split-view chrome.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SettingsSidebarView(
                navigation: navigation,
                attentionCategories: attentionCategories
            )
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detailPane
                .id(navigation.selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar(removing: .sidebarToggle)
                // SwiftUI owns the hosting window's title once a navigation stack is involved, so
                // the title must be declared here rather than written to `NSWindow.title` (any
                // AppKit-side write gets stomped on the next navigation update). Home is the
                // landing surface rather than a pane of controls, so it titles the window with
                // the app-wide name instead of the literal "Home".
                .navigationTitle(navigation.selection == .home ? "Cotabby Settings" : navigation.selection.label)
        }
        .environment(\.settingsHighlightedItem, navigation.highlightedItem)
        // Window-level Cmd-F: jump to the search surface from any pane. The button renders
        // nothing; it exists to host the keyboard shortcut inside this window's responder chain.
        .background(
            Button("") { navigation.requestSearchFocus() }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
        // Keep the native split view, but pin the outer Settings window to a practical minimum.
        // The sidebar itself provides a width range, so the default opens readable without forcing
        // an exact column size forever.
        .frame(maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
        .onAppear {
            // Migration: the previous sidebar had two engine sub-rows (`appleIntelligence`,
            // `openSource`). Users whose persisted selection still points to either should land on
            // the unified Engine & Model pane rather than fall back to General.
            navigation.selection = Self.restoreSelection(from: storedCategoryRawValue)
            permissionManager.refresh()
        }
        .onChange(of: navigation.selection) { _, newValue in
            storedCategoryRawValue = newValue.rawValue
        }
        .onChange(of: columnVisibility) { _, newValue in
            if newValue != .all {
                columnVisibility = .all
            }
        }
    }

    /// Snapshot driven by the live observable graph. Recomputes whenever the underlying state
    /// publishes, so a permission grant or a runtime recovery clears the sidebar dot without any
    /// manual refresh.
    private var attentionCategories: Set<SettingsCategory> {
        SettingsAttentionEvaluator.categoriesNeedingAttention(
            SettingsAttentionEvaluator.Inputs(
                permissionsGranted: permissionManager.requiredPermissionsGranted,
                selectedEngine: suggestionSettings.selectedEngine,
                foundationModelAvailable: foundationModelAvailabilityService.isAvailable,
                foundationModelMessage: foundationModelAvailabilityService.userVisibleMessage,
                llamaRuntimeFailedReason: runtimeModel.state.failureDetail
            )
        )
    }

    @ViewBuilder
    private var detailPane: some View {
        switch navigation.selection {
        case .home:
            HomePaneView(
                navigation: navigation,
                suggestionSettings: suggestionSettings,
                permissionManager: permissionManager,
                foundationModelAvailabilityService: foundationModelAvailabilityService,
                runtimeModel: runtimeModel,
                attentionCategories: attentionCategories
            )
        case .general:
            GeneralPaneView(
                suggestionSettings: suggestionSettings,
                permissionManager: permissionManager,
                onShowWelcome: onShowWelcome
            )
        case .appearance:
            AppearancePaneView(suggestionSettings: suggestionSettings)
        case .emoji:
            EmojiPaneView(
                suggestionSettings: suggestionSettings,
                clearEmojiHistory: clearEmojiHistory
            )
        case .engineAndModel:
            EngineAndModelPaneView(
                suggestionSettings: suggestionSettings,
                foundationModelAvailabilityService: foundationModelAvailabilityService,
                runtimeModel: runtimeModel,
                modelDownloadManager: modelDownloadManager,
                huggingFaceSearchService: huggingFaceSearchService
            )
        case .writing:
            WritingPaneView(suggestionSettings: suggestionSettings)
        case .context:
            ContextPaneView(suggestionSettings: suggestionSettings)
        case .shortcuts:
            ShortcutsPaneView(suggestionSettings: suggestionSettings)
        case .apps:
            AppsPaneView(suggestionSettings: suggestionSettings)
        case .permissions:
            PermissionsPaneView(
                permissionManager: permissionManager,
                permissionGuidanceController: permissionGuidanceController
            )
        case .performance:
            PerformancePaneView(
                suggestionSettings: suggestionSettings,
                performanceMetricsStore: performanceMetricsStore,
                qualityMetricsStore: qualityMetricsStore,
                systemMetricsStore: systemMetricsStore
            )
        case .about:
            AboutPaneView(appUpdateManager: appUpdateManager)
        }
    }

    private static func restoreSelection(from rawValue: String) -> SettingsCategory {
        if let category = SettingsCategory(rawValue: rawValue) {
            return category
        }
        // Legacy sub-row raw values from the prior nested layout.
        if rawValue == "appleIntelligence" || rawValue == "openSource" {
            return .engineAndModel
        }
        // The Advanced pane was renamed to Context; keep returning users on the same pane.
        if rawValue == "advanced" {
            return .context
        }
        return .general
    }
}
