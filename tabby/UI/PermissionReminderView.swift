import SwiftUI

/// File overview:
/// Shown on launch when the user previously completed onboarding but one or more required
/// permissions are missing. This happens after a permission-prompted restart or if the user
/// revokes a permission later in System Settings.
///
/// Reuses the same PermissionCard-style layout as onboarding but with contextual copy and a
/// simple dismiss button instead of the full wizard navigation.
struct PermissionReminderView: View {
    @ObservedObject var permissionManager: PermissionManager

    let permissionGuidanceController: PermissionGuidanceController
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)

                Text("Permissions needed")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))

                Text("tabby needs these permissions to work.\nGrant them in System Settings, then come back here.")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 10) {
                ForEach(TabbyPermissionKind.allCases.filter(\.isRequiredForAutocomplete)) { permission in
                    ReminderPermissionCard(
                        permission: permission,
                        granted: permissionManager.isGranted(permission),
                        permissionGuidanceController: permissionGuidanceController
                    )
                }
            }

            WelcomeButton(title: permissionManager.requiredPermissionsGranted ? "Done" : "I'll do this later") {
                onDismiss()
            }
        }
        .padding(36)
        .frame(width: 540)
        .background(.ultraThinMaterial)
    }
}

/// Permission card for the reminder view. Same glass-material style as onboarding but shows
/// "Granted" for already-granted permissions so the user sees their progress.
private struct ReminderPermissionCard: View {
    let permission: TabbyPermissionKind
    let granted: Bool
    let permissionGuidanceController: PermissionGuidanceController

    @State private var actionButtonFrame = CGRect.zero

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(granted ? Color.green.opacity(0.12) : Color.orange.opacity(0.12))

                Image(systemName: permission.systemImageName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(granted ? .green : .orange)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                    .font(.system(size: 14, weight: .medium))

                Text(permission.onboardingSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if granted {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Done")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.green)
            } else {
                Button("Allow") {
                    permissionGuidanceController.requestAccess(
                        for: permission,
                        sourceFrameInScreen: actionButtonFrame
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .background(ScreenFrameReader(frameInScreen: $actionButtonFrame))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 0.5)
        )
    }
}
