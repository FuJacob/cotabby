import AppKit
import SwiftUI

/// File overview:
/// Root of the redesigned Settings window. A `NavigationSplitView` with a sidebar of categorized
/// rows on the left and a switching detail pane on the right. The detail body is built from
/// `SettingsCategory`, so adding a new pane is a matter of adding an enum case and a `case` in the
/// switch below.
///
/// Selection is persisted via `@AppStorage` so reopening Settings lands on the last-used pane.
/// `.id(selection)` on the detail body is the documented workaround for the macOS 14 split-view
/// selection bug where the first sidebar pick doesn't always re-render the detail column.
///
/// The view takes the same observable graph as the legacy `SettingsView` so the coordinator can
/// swap hosting controllers behind a feature flag without rewiring dependencies.
struct SettingsContainerView: View {
    let appUpdateManager: AppUpdateManager

    @ObservedObject var launchAtLoginService: LaunchAtLoginService
    @ObservedObject var permissionManager: PermissionManager
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    @ObservedObject var foundationModelAvailabilityService: FoundationModelAvailabilityService
    @ObservedObject var runtimeModel: RuntimeBootstrapModel
    @ObservedObject var modelDownloadManager: ModelDownloadManager
    @ObservedObject var huggingFaceSearchService: HuggingFaceSearchService

    let onShowWelcome: () -> Void

    @AppStorage("cotabbySettingsSelectedCategoryV2")
    private var storedCategoryRawValue: String = SettingsCategory.general.rawValue

    @State private var selection: SettingsCategory = .general
    // Pinning visibility to `.all` and binding it as constant tells NavigationSplitView the user
    // is never allowed to collapse the sidebar. That removes the default toggle button from the
    // title bar (which otherwise teleports between the sidebar header and the content header as
    // the column collapses) and keeps the sidebar always present, which is what users expect from
    // a Settings window.
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
        .navigationSplitViewStyle(.balanced)
        // Sized so the sidebar's `ideal` width (240) plus a detail pane that comfortably holds the
        // grouped Form (~500pt) fits without forcing `.balanced` to squeeze the sidebar below the
        // longest label. The previous 1180pt floor came from an earlier sidebar experiment that
        // doubled column widths; with the sidebar tightened back down, that floor leaves the
        // detail pane oversized for the actual content.
        // Sidebar grew (min 260 / ideal 280) to fit the longest sub-row label without truncation.
        // Bump the container floor in step so the detail pane keeps a comfortable working width
        // (sidebar 260 + detail ~560 ≈ 820pt).
        .frame(minWidth: 820, minHeight: 560)
        .onChange(of: columnVisibility) { _, newValue in
            // Snap back to `.all` if something tries to collapse the sidebar. Cheaper than wiring
            // a custom binding and reads as the same intent: the sidebar is never optional here.
            if newValue != .all {
                columnVisibility = .all
            }
        }
        .onAppear {
            selection = SettingsCategory(rawValue: storedCategoryRawValue) ?? .general
            launchAtLoginService.refresh()
            permissionManager.refresh()
            // Set the title unconditionally on open: when the restored selection equals the
            // initial @State value, `.onChange` does not fire and the title would stay blank.
            syncWindowTitle(for: selection)
        }
        .onChange(of: selection) { _, newValue in
            storedCategoryRawValue = newValue.rawValue
            syncWindowTitle(for: newValue)
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
        case .general:
            GeneralPaneView(
                suggestionSettings: suggestionSettings,
                onShowWelcome: onShowWelcome
            )
        case .engineAndModel:
            EngineAndModelPaneView(
                suggestionSettings: suggestionSettings,
                foundationModelAvailabilityService: foundationModelAvailabilityService,
                runtimeModel: runtimeModel
            )
        case .appleIntelligence:
            AppleIntelligencePaneView(
                suggestionSettings: suggestionSettings,
                foundationModelAvailabilityService: foundationModelAvailabilityService
            )
        case .openSource:
            OpenSourcePaneView(
                suggestionSettings: suggestionSettings,
                runtimeModel: runtimeModel,
                modelDownloadManager: modelDownloadManager,
                huggingFaceSearchService: huggingFaceSearchService
            )
        case .writing:
            WritingPaneView(suggestionSettings: suggestionSettings)
        case .shortcuts:
            ShortcutsPaneView(suggestionSettings: suggestionSettings)
        case .apps:
            AppsPaneView(suggestionSettings: suggestionSettings)
        case .permissions:
            PermissionsPaneView(permissionManager: permissionManager)
        case .about:
            AboutPaneView(appUpdateManager: appUpdateManager)
        }
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
