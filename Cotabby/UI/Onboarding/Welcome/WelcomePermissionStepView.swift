import SwiftUI

/// File overview:
/// Renders the onboarding permission step: a header, one card per permission, and a privacy
/// footnote. Each permission is a card with a tinted icon tile, title, short description, and an
/// Allow button that springs into a green Done state the moment macOS reports the grant. The view
/// stays subscribed to live permission state so cards update in real time as the user grants
/// access through System Settings.
///
/// Navigation (Back/Continue) is owned by `WelcomeView`'s pinned footer rather than this view, so
/// the Continue button can never scroll off-screen behind tall content.
///
/// The list is derived from `CotabbyPermissionKind` (required cards from
/// `isRequiredForAutocomplete`, then optional-enhancement cards from `isOptionalEnhancement`) so
/// the product's permission model and first-run UI cannot drift apart.
struct WelcomePermissionStepView: View {
    @ObservedObject var permissionManager: PermissionManager

    let permissionGuidanceController: PermissionGuidanceController

    /// Permissions that block core autocomplete; the user must grant these to continue.
    private var requiredPermissions: [CotabbyPermissionKind] {
        CotabbyPermissionKind.allCases.filter(\.isRequiredForAutocomplete)
    }

    /// Optional enhancements (Screen Recording today). Shown so visual context is discoverable at
    /// first run, but they never block the Continue button.
    private var optionalPermissions: [CotabbyPermissionKind] {
        CotabbyPermissionKind.allCases.filter(\.isOptionalEnhancement)
    }

    var body: some View {
        VStack(spacing: 24) {
            OnboardingStepHeader(
                systemImage: "lock.shield.fill",
                title: "Two quick permissions",
                subtitle: "Cotabby needs to read the field you're typing in and watch for the accept key.\n"
                    + "The optional one unlocks smarter, screen-aware suggestions."
            )
            .onboardingReveal(0)

            VStack(spacing: 10) {
                ForEach(Array(requiredPermissions.enumerated()), id: \.element) { index, permission in
                    PermissionCard(
                        permission: permission,
                        granted: permissionManager.isGranted(permission),
                        permissionGuidanceController: permissionGuidanceController
                    )
                    .onboardingReveal(1 + index)
                }

                // Optional cards render after the required ones, tagged so the user can skip them
                // without thinking they've left setup unfinished. The Continue gate ignores them.
                ForEach(Array(optionalPermissions.enumerated()), id: \.element) { index, permission in
                    PermissionCard(
                        permission: permission,
                        granted: permissionManager.isGranted(permission),
                        isOptional: true,
                        permissionGuidanceController: permissionGuidanceController
                    )
                    .onboardingReveal(1 + requiredPermissions.count + index)
                }
            }

            // The trust line carries onboarding's core privacy promise; it sits with the
            // permission asks because this is the moment the user is deciding whether to trust us.
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .medium))

                Text("Everything Cotabby reads stays on your Mac. Nothing is ever uploaded.")
                    .font(.system(size: 12, design: .rounded))
            }
            .foregroundStyle(.tertiary)
            .onboardingReveal(2 + requiredPermissions.count + optionalPermissions.count)
        }
        .onDisappear {
            permissionGuidanceController.dismiss()
        }
    }
}

// MARK: - Permission tint

extension CotabbyPermissionKind {
    /// Per-permission tile tint, defined here in the UI layer so `PermissionModels` stays free of
    /// SwiftUI. Distinct hues per row is the System Settings idiom and makes the step scannable.
    var onboardingTint: Color {
        switch self {
        case .accessibility:
            CotabbyBrand.accent
        case .inputMonitoring:
            .indigo
        case .screenRecording:
            .teal
        }
    }
}

// MARK: - Permission Card

/// One permission row rendered as a card with a tinted icon tile.
///
/// The card measures its own button frame in screen coordinates because the permission guidance
/// controller needs a global rect to anchor its drag-helper animation. That screen-space concern
/// stays here in the view rather than leaking into the controller.
private struct PermissionCard: View {
    let permission: CotabbyPermissionKind
    let granted: Bool
    var isOptional = false
    let permissionGuidanceController: PermissionGuidanceController

    @State private var actionButtonFrame = CGRect.zero

    var body: some View {
        HStack(spacing: 14) {
            OnboardingIconTile(systemImage: permission.systemImageName, tint: permission.onboardingTint)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(permission.title)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))

                    if isOptional {
                        Text("Optional")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }

                Text(permission.onboardingSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            // The grant springs in rather than swapping in place: macOS granting a permission is
            // the step's payoff moment, and the bounce makes it land as one.
            if granted {
                PermissionDoneBadge()
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                Button("Allow") {
                    permissionGuidanceController.requestAccess(
                        for: permission,
                        sourceFrameInScreen: actionButtonFrame
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(CotabbyBrand.accent)
                .controlSize(.regular)
                .background(ScreenFrameReader(frameInScreen: $actionButtonFrame))
                .transition(.opacity)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onboardingCard()
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: granted)
    }
}

// MARK: - Small Components

/// Green checkmark with "Done" label shown after a permission is granted. Shared with the
/// permission reminder window so the two surfaces stay visually in lock-step.
struct PermissionDoneBadge: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))

            Text("Done")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.green)
    }
}
