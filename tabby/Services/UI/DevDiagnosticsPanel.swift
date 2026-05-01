import AppKit
import Combine
import SwiftUI

/// File overview:
/// Presents Tabby's persistent debug panel as a top-right non-activating AppKit panel backed by
/// SwiftUI content.
///
/// The controller owns window lifetime and anchoring because those are AppKit concerns. The
/// SwiftUI view owns rendering only. This split mirrors the rest of Tabby's UI architecture:
/// services handle side effects, views render observable state.
@MainActor
final class DevDiagnosticsPanelController {
    private let debugMode: DebugModeModel
    private let diagnosticsStore: DiagnosticsStore
    private let permissionManager: PermissionManager
    private let runtimeModel: RuntimeBootstrapModel
    private let focusModel: FocusTrackingModel
    private let suggestionSettings: SuggestionSettingsModel
    private let suggestionCoordinator: SuggestionCoordinator

    private lazy var panel: NSPanel = makePanel()
    private var cancellables = Set<AnyCancellable>()

    init(
        debugMode: DebugModeModel,
        diagnosticsStore: DiagnosticsStore,
        permissionManager: PermissionManager,
        runtimeModel: RuntimeBootstrapModel,
        focusModel: FocusTrackingModel,
        suggestionSettings: SuggestionSettingsModel,
        suggestionCoordinator: SuggestionCoordinator
    ) {
        self.debugMode = debugMode
        self.diagnosticsStore = diagnosticsStore
        self.permissionManager = permissionManager
        self.runtimeModel = runtimeModel
        self.focusModel = focusModel
        self.suggestionSettings = suggestionSettings
        self.suggestionCoordinator = suggestionCoordinator

        debugMode.$state
            .sink { [weak self] state in
                self?.setVisible(state.isEnabled)
            }
            .store(in: &cancellables)
    }

    func start() {
        setVisible(debugMode.isEnabled)
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func setVisible(_ isVisible: Bool) {
        guard isVisible else {
            diagnosticsStore.reset()
            hide()
            return
        }

        panel.contentView = NSHostingView(rootView: DevDiagnosticsPanel(
            debugMode: debugMode,
            diagnosticsStore: diagnosticsStore,
            permissionManager: permissionManager,
            runtimeModel: runtimeModel,
            focusModel: focusModel,
            suggestionSettings: suggestionSettings,
            suggestionCoordinator: suggestionCoordinator
        ))
        anchorPanel()
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 430, height: 560),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }

    private func anchorPanel() {
        let screenFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let panelSize = CGSize(width: 430, height: min(560, screenFrame.height - 32))
        let origin = CGPoint(
            x: screenFrame.maxX - panelSize.width - 16,
            y: screenFrame.maxY - panelSize.height - 16
        )
        panel.setFrame(CGRect(origin: origin, size: panelSize).integral, display: true)
    }
}

/// Dense operator view for runtime triage.
///
/// The panel favors small, stable rows over explanatory text because it is meant to be scanned
/// while Tabby is running inside another app. Longer teaching comments live in code; the UI keeps
/// only operational labels.
private struct DevDiagnosticsPanel: View {
    @ObservedObject var debugMode: DebugModeModel
    @ObservedObject var diagnosticsStore: DiagnosticsStore
    @ObservedObject var permissionManager: PermissionManager
    @ObservedObject var runtimeModel: RuntimeBootstrapModel
    @ObservedObject var focusModel: FocusTrackingModel
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    @ObservedObject var suggestionCoordinator: SuggestionCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    flagsSection
                    pipelineSection
                    axSection
                    logSection
                }
                .padding(12)
            }
        }
        .frame(width: 430)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Tabby Diagnostics")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))

            Spacer(minLength: 0)

            Text(debugMode.state.launchArgument)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var flagsSection: some View {
        DiagnosticsSection(title: "Configuration") {
            DiagnosticsGrid(rows: [
                ("Debug", debugMode.state.statusLabel),
                ("Global", suggestionSettings.isGloballyEnabled ? "Enabled" : "Disabled"),
                ("Engine", suggestionSettings.selectedEngine.displayLabel),
                ("Length", suggestionSettings.selectedWordCountPreset.displayLabel),
                ("Indicator", suggestionSettings.selectedIndicatorMode.displayLabel),
                ("AX Perm", permissionManager.accessibilityGranted ? "Granted" : "Missing"),
                ("Input Perm", permissionManager.inputMonitoringGranted ? "Granted" : "Missing")
            ])
        }
    }

    private var pipelineSection: some View {
        DiagnosticsSection(title: "Runtime State") {
            DiagnosticsGrid(rows: [
                ("Runtime", runtimeModel.state.summary),
                ("Load", runtimeModel.diagnostics.lastLoadStatus ?? "n/a"),
                ("Backend", runtimeModel.diagnostics.backendName ?? "n/a"),
                ("Model", runtimeModel.selectedModelFilename ?? "n/a"),
                ("Focus", focusModel.snapshot.capability.shortLabel),
                ("Suggest", suggestionCoordinator.state.shortLabel),
                ("OCR", visualStatusLabel),
                ("Overlay", suggestionCoordinator.overlayState.shortLabel)
            ])

            if let detail = primaryDetail {
                Text(detail)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
        }
    }

    private var axSection: some View {
        DiagnosticsSection(title: "AX Notifications") {
            if diagnosticsStore.recentAXNotifications.isEmpty {
                EmptyDiagnosticsRow(text: "No AX notifications recorded.")
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(diagnosticsStore.recentAXNotifications.reversed()), id: \.sequence) { event in
                        HStack(spacing: 6) {
                            Text("#\(event.sequence)")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .leading)

                            Text(event.displayName)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .lineLimit(1)

                            Spacer(minLength: 0)

                            Text(Self.timeFormatter.string(from: event.occurredAt))
                                .font(.system(size: 10, weight: .regular, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var logSection: some View {
        DiagnosticsSection(title: "Recent Events") {
            if diagnosticsStore.recentEvents.isEmpty {
                EmptyDiagnosticsRow(text: "No structured log events recorded.")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(diagnosticsStore.recentEvents.reversed())) { event in
                        DiagnosticEventRow(event: event)
                    }
                }
            }
        }
    }

    private var visualStatusLabel: String {
        switch suggestionCoordinator.visualContextStatus {
        case .idle:
            return "Idle"
        case .capturing:
            return "Capturing"
        case .extractingText:
            return "Extracting"
        case .summarizingText:
            return "Summarizing"
        case .ready:
            return "Ready"
        case .unavailable:
            return "Unavailable"
        case .failed:
            return "Failed"
        }
    }

    private var primaryDetail: String? {
        if let detail = suggestionCoordinator.state.detail {
            return detail
        }

        if suggestionCoordinator.visualContextStatus != .idle {
            return suggestionCoordinator.visualContextStatus.detail
        }

        return focusModel.snapshot.capability.summary
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

private struct DiagnosticsSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DiagnosticsGrid: View {
    let rows: [(String, String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
            ForEach(rows, id: \.0) { key, value in
                GridRow {
                    Text(key)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .leading)

                    Text(value)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct DiagnosticEventRow: View {
    let event: DiagnosticEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(event.level.displayLabel)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(event.level.panelColor)
                    .frame(width: 42, alignment: .leading)

                Text(event.category.displayLabel)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(event.category.panelColor)
                    .frame(width: 54, alignment: .leading)

                Text(event.component)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Text(Self.timeFormatter.string(from: event.timestamp))
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Text(event.message)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .lineLimit(2)

            if !event.metadata.isEmpty {
                Text(metadataSummary)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(8)
        .background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
    }

    private var metadataSummary: String {
        event.metadata.keys.sorted().compactMap { key in
            event.metadata[key].map { "\(key)=\($0)" }
        }
        .joined(separator: " ")
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

private struct EmptyDiagnosticsRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .regular, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }
}

private extension DiagnosticLevel {
    var panelColor: Color {
        switch self {
        case .trace:
            return .cyan
        case .info:
            return .green
        case .warning:
            return .yellow
        case .error:
            return .red
        }
    }
}

private extension DiagnosticCategory {
    var panelColor: Color {
        switch self {
        case .app:
            return .white
        case .accessibility:
            return .cyan
        case .suggestion:
            return .green
        case .visual:
            return .purple
        case .runtime:
            return .orange
        case .permissions:
            return .yellow
        case .updates:
            return .blue
        }
    }
}
