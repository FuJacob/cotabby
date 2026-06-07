import SwiftUI

/// File overview:
/// "Permissions" detail pane of the redesigned Settings window. Renders status rows for the three
/// permissions Cotabby requires (Accessibility, Input Monitoring, Screen Recording) and offers a
/// shortcut into the relevant System Settings pane when one of them is missing.
struct PermissionsPaneView: View {
    @ObservedObject var permissionManager: PermissionManager
    let permissionGuidanceController: PermissionGuidanceController
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        SettingsPaneScaffold(callout: callout) {
            Section("Permissions") {
                Text("Cotabby needs Accessibility and Input Monitoring for autocomplete. " +
                    "Screen Recording is optional and adds on-screen visual context.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                SettingsPermissionRow(
                    permission: .accessibility,
                    description: "Lets Cotabby see which text field has focus and read its contents " +
                        "so it knows what to continue.",
                    systemImage: "accessibility",
                    granted: permissionManager.accessibilityGranted,
                    permissionGuidanceController: permissionGuidanceController
                )

                SettingsPermissionRow(
                    permission: .inputMonitoring,
                    description: "Lets Cotabby see your keystrokes so it can detect when to suggest " +
                        "and which key you used to accept.",
                    systemImage: "keyboard",
                    granted: permissionManager.inputMonitoringGranted,
                    permissionGuidanceController: permissionGuidanceController
                )

                SettingsPermissionRow(
                    permission: .screenRecording,
                    description: "Optional. Lets Cotabby screenshot the focused window for extra " +
                        "context. Without it, Cotabby runs in Fast Mode using only the text you've typed.",
                    systemImage: "camera.viewfinder",
                    granted: permissionManager.screenRecordingGranted,
                    isOptional: true,
                    permissionGuidanceController: permissionGuidanceController
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

}

/// One permission row in the Settings pane. Tracks its own button frame so the shared
/// `PermissionGuidanceController` can anchor its drag-helper overlay near the Enable button
/// (mirroring the onboarding flow) instead of dumping the user into System Settings cold.
private struct SettingsPermissionRow: View {
    let permission: CotabbyPermissionKind
    let description: String
    let systemImage: String
    let granted: Bool
    var isOptional: Bool = false
    let permissionGuidanceController: PermissionGuidanceController

    @State private var actionButtonFrame: CGRect = .zero

    var body: some View {
        HStack(spacing: 10) {
            SettingsRowLabel(title: permission.title, description: description, systemImage: systemImage)
            Spacer(minLength: 0)
            // An ungranted optional permission reads as a neutral "Off" rather than the orange
            // "Needs Access" used for required ones, so it never looks like a broken setup.
            Text(granted ? "Granted" : (isOptional ? "Off" : "Needs Access"))
                .font(.caption.weight(.medium))
                .foregroundStyle(granted ? .green : (isOptional ? .secondary : .orange))

            if !granted {
                Button(isOptional ? "Enable" : "Grant Access") {
                    permissionGuidanceController.requestAccess(
                        for: permission,
                        sourceFrameInScreen: actionButtonFrame
                    )
                }
                .controlSize(.small)
                .background(ScreenFrameReader(frameInScreen: $actionButtonFrame))
            }
        }
    }
}
