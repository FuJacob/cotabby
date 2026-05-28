import SwiftUI

/// File overview:
/// "Permissions" detail pane of the redesigned Settings window. Renders status rows for the three
/// permissions Cotabby requires (Accessibility, Input Monitoring, Screen Recording) and offers a
/// shortcut into the relevant System Settings pane when one of them is missing.
struct PermissionsPaneView: View {
    @ObservedObject var permissionManager: PermissionManager
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        SettingsPaneScaffold(callout: callout) {
            Section("Permissions") {
                Text("Cotabby needs Accessibility, Input Monitoring, and Screen Recording for autocomplete.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                permissionRow(
                    title: "Accessibility",
                    granted: permissionManager.accessibilityGranted,
                    action: permissionManager.openAccessibilitySettings
                )

                permissionRow(
                    title: "Input Monitoring",
                    granted: permissionManager.inputMonitoringGranted,
                    action: permissionManager.openInputMonitoringSettings
                )

                permissionRow(
                    title: "Screen Recording",
                    granted: permissionManager.screenRecordingGranted,
                    action: permissionManager.openScreenRecordingSettings
                )
            }
        }
        .onAppear { permissionManager.refresh() }
        // Re-check on scene activation: .onAppear does not fire when returning from
        // System Settings, so permission status would otherwise stay stale.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                permissionManager.refresh()
            }
        }
    }

    /// Top-of-pane callout when any required permission is still missing. The full picture stays
    /// in the rows below; this just surfaces the broken state without making the user read each row
    /// in turn.
    private var callout: SettingsPaneCallout? {
        guard !permissionManager.requiredPermissionsGranted else {
            return nil
        }
        return SettingsPaneCallout(
            tone: .warning,
            message: "Cotabby needs more access to run. Grant the permissions below to enable autocomplete."
        )
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
            Spacer(minLength: 0)
            Text(granted ? "Granted" : "Needs Access")
                .font(.caption.weight(.medium))
                .foregroundStyle(granted ? .green : .orange)

            if !granted {
                Button("Open Settings") {
                    action()
                }
                .controlSize(.small)
            }
        }
    }
}
