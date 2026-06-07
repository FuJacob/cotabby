import AppKit
import SwiftUI

/// File overview:
/// Root of the redesigned Settings window. A `NavigationSplitView` with a sidebar of categorized
/// rows sits on the left and a switching detail pane fills the right side. The detail body is built
/// from `SettingsCategory`, so adding a new pane is a matter of adding an enum case and a `case` in
/// the switch below.
///
/// Selection is persisted via `@AppStorage` so reopening Settings lands on the last-used pane.
/// `.id(selection)` on the detail body is the documented workaround for the macOS 14 split-view
/// selection bug where the first sidebar pick doesn't always re-render the detail column.
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
    @ObservedObject var systemMetricsStore: SystemMetricsStore

    /// Live router used by the Context pane's "try it" playground so users can see the effect of
    /// Extended Context (and other prompt inputs) without leaving Settings. Threaded through the
    /// container rather than constructed locally so the playground reuses the same router the
    /// autocomplete pipeline uses.
    let suggestionEngine: any SuggestionGenerating
    let configuration: SuggestionConfiguration
    let onShowWelcome: () -> Void
    let clearEmojiHistory: () -> Void

    @AppStorage("cotabbySettingsSelectedCategoryV2")
    private var storedCategoryRawValue: String = SettingsCategory.home.rawValue

    @State private var selection: SettingsCategory = .home
    // Settings should behave like a traditional two-column preferences window: the sidebar is
    // always visible, but SwiftUI can still manage the native navigation/split-view chrome.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SettingsSidebarView(
                selection: $selection,
                attentionCategories: attentionCategories
            )
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detailPane
                .id(selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar(removing: .sidebarToggle)
        }
        // Keep the native split view, but pin the outer Settings window to a practical minimum.
        // The sidebar itself provides a width range, so the default opens readable without forcing
        // an exact column size forever.
        .frame(maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
        .onAppear {
            // Migration: the previous sidebar had two engine sub-rows (`appleIntelligence`,
            // `openSource`). Users whose persisted selection still points to either should land on
            // the unified Engine & Model pane rather than fall back to General.
            selection = Self.restoreSelection(from: storedCategoryRawValue)
            permissionManager.refresh()
            // Set the title unconditionally on open: when the restored selection equals the
            // initial @State value, `.onChange` does not fire and the title would stay blank.
            syncWindowTitle(for: selection)
        }
        .onChange(of: selection) { _, newValue in
            storedCategoryRawValue = newValue.rawValue
            syncWindowTitle(for: newValue)
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
        switch selection {
        case .home:
            HomePaneView()
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
            ContextPaneView(
                suggestionSettings: suggestionSettings,
                suggestionEngine: suggestionEngine,
                configuration: configuration
            )
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

    /// Mirrors the chosen pane into the hosting `NSWindow.title` so the title bar reflects the
    /// current selection. macOS settings windows traditionally use an inline title for the active
    /// pane; this preserves that convention without rendering a duplicate large title inside the
    /// content.
    private func syncWindowTitle(for category: SettingsCategory) {
        // Capture the key window now: between the tap and the async block running, a popover or
        // alert could become key and we would retitle the wrong window.
        let window = NSApp.keyWindow
        DispatchQueue.main.async {
            window?.title = "Settings — \(category.label)"
        }
    }
}
