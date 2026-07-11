import AppKit
import Combine
import SwiftUI

/// Owns Cotabby's menu-bar status item and popover through stable AppKit APIs.
///
/// SwiftUI still renders `MenuBarView`, but only as the popover's hosted content. AppKit owns the
/// application and window lifecycle, which keeps older macOS releases out of SwiftUI's scene-level
/// `MenuBarExtra` AttributeGraph path. `AppDelegate` creates one controller lazily, starts it after
/// launch, and retains it for the process lifetime.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let permissionManager: PermissionManager
    private let runtimeModel: RuntimeBootstrapModel
    private let modelDownloadManager: ModelDownloadManager
    private let focusModel: FocusTrackingModel
    private let permissionGuidanceController: PermissionGuidanceController
    private let suggestionSettings: SuggestionSettingsModel
    private let foundationModelAvailabilityService: FoundationModelAvailabilityService
    private let powerSourceMonitor: PowerSourceMonitor
    private let suggestionCoordinator: SuggestionCoordinator
    private let appUpdateManager: AppUpdateManager
    private let onOpenSettings: () -> Void
    private let onReportFeedback: () -> Void

    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var isStarted = false

    /// The hosted SwiftUI graph is built lazily after AppKit has finished application launch. It
    /// lives as long as the controller so menu state is preserved between popover openings.
    private lazy var hostingController: NSHostingController<MenuBarView> = {
        let controller = NSHostingController(rootView: makeMenuBarView())
        controller.sizingOptions = [.preferredContentSize]
        return controller
    }()

    private lazy var popover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = hostingController
        return popover
    }()

    init(
        permissionManager: PermissionManager,
        runtimeModel: RuntimeBootstrapModel,
        modelDownloadManager: ModelDownloadManager,
        focusModel: FocusTrackingModel,
        permissionGuidanceController: PermissionGuidanceController,
        suggestionSettings: SuggestionSettingsModel,
        foundationModelAvailabilityService: FoundationModelAvailabilityService,
        powerSourceMonitor: PowerSourceMonitor,
        suggestionCoordinator: SuggestionCoordinator,
        appUpdateManager: AppUpdateManager,
        onOpenSettings: @escaping () -> Void,
        onReportFeedback: @escaping () -> Void
    ) {
        self.permissionManager = permissionManager
        self.runtimeModel = runtimeModel
        self.modelDownloadManager = modelDownloadManager
        self.focusModel = focusModel
        self.permissionGuidanceController = permissionGuidanceController
        self.suggestionSettings = suggestionSettings
        self.foundationModelAvailabilityService = foundationModelAvailabilityService
        self.powerSourceMonitor = powerSourceMonitor
        self.suggestionCoordinator = suggestionCoordinator
        self.appUpdateManager = appUpdateManager
        self.onOpenSettings = onOpenSettings
        self.onReportFeedback = onReportFeedback
        super.init()
    }

    /// Starts the two subscriptions that drive status-item presence and label content. Repeated
    /// calls are harmless, which lets the compatibility smoke path share production setup.
    func start() {
        guard !isStarted else { return }
        isStarted = true

        suggestionSettings.$isMenuBarIconVisible
            .removeDuplicates()
            .sink { [weak self] isVisible in
                self?.setStatusItemVisible(isVisible)
            }
            .store(in: &cancellables)

        Publishers.CombineLatest4(
            suggestionCoordinator.$totalTabAcceptedWordCount,
            suggestionSettings.$isMenuBarWordCountVisible,
            suggestionSettings.$pauseState,
            suggestionSettings.$isGloballyEnabled
        )
        .sink { [weak self] _, _, _, _ in
            self?.updateStatusItemLabel()
        }
        .store(in: &cancellables)
    }

    /// Removes AppKit resources during orderly shutdown. The settings model remains untouched so
    /// the next launch reconstructs the same visible/hidden state.
    func stop() {
        guard isStarted else { return }
        dismissPopover()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        cancellables.removeAll()
        isStarted = false
    }

    /// Forces construction and layout of the status item plus hosted menu without starting global
    /// input, Accessibility, model, or update services. CI uses this on macOS 14 and 15 to catch
    /// launch-time framework/runtime incompatibilities in the actual Xcode 26-built app artifact.
    func prepareForCompatibilitySmokeTest() {
        start()
        // A developer may have hidden the icon in persistent defaults. CI and manual smoke runs
        // must still exercise the actual status-item/popover path regardless of that preference.
        createStatusItemIfNeeded()
        hostingController.loadView()
        hostingController.view.layoutSubtreeIfNeeded()
        _ = hostingController.view.fittingSize

        guard let button = statusItem?.button else {
            preconditionFailure("Compatibility smoke test could not create the status item")
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem?.button?.highlight(false)
    }

    private func makeMenuBarView() -> MenuBarView {
        MenuBarView(
            permissionManager: permissionManager,
            runtimeModel: runtimeModel,
            modelDownloadManager: modelDownloadManager,
            focusModel: focusModel,
            permissionGuidanceController: permissionGuidanceController,
            suggestionSettings: suggestionSettings,
            foundationModelAvailabilityService: foundationModelAvailabilityService,
            powerSourceMonitor: powerSourceMonitor,
            appUpdateManager: appUpdateManager,
            onDismiss: { [weak self] in self?.dismissPopover() },
            onOpenSettings: onOpenSettings,
            onReportFeedback: onReportFeedback
        )
    }

    private func setStatusItemVisible(_ isVisible: Bool) {
        if isVisible {
            createStatusItemIfNeeded()
        } else {
            dismissPopover()
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
            }
            statusItem = nil
        }
    }

    private func createStatusItemIfNeeded() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else {
            NSStatusBar.system.removeStatusItem(item)
            return
        }

        let image = NSImage(named: "MenuBarCatIcon")
            ?? NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Cotabby")
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        button.image = image
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.toolTip = "Cotabby"
        button.setAccessibilityLabel("Cotabby")

        statusItem = item
        updateStatusItemLabel()
    }

    private func updateStatusItemLabel() {
        guard let button = statusItem?.button else { return }

        var components: [String] = []
        let isInactive = suggestionSettings.isTemporarilyPaused
            || !suggestionSettings.isGloballyEnabled
        if isInactive {
            components.append("Ⅱ")
        }
        if suggestionSettings.isMenuBarWordCountVisible,
           let count = WordCountFormatter.compactLabel(
               for: suggestionCoordinator.totalTabAcceptedWordCount
           ) {
            components.append(count)
        }

        button.title = components.isEmpty ? "" : " " + components.joined(separator: " ")
        let stateDescription: String
        if !suggestionSettings.isGloballyEnabled {
            stateDescription = "disabled"
        } else if suggestionSettings.isTemporarilyPaused {
            stateDescription = "paused"
        } else {
            stateDescription = "active"
        }
        button.setAccessibilityValue("Cotabby \(stateDescription)")
    }

    @objc
    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            dismissPopover()
            return
        }

        sender.highlight(true)
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func dismissPopover() {
        guard popover.isShown else {
            statusItem?.button?.highlight(false)
            return
        }
        popover.performClose(nil)
    }
}
