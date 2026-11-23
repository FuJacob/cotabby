import SwiftUI

/// File overview:
/// The permission rows shared by first-run onboarding and the launch-time permission reminder.
/// Both windows list the same permissions in the same order with the same card; they differ only
/// in how loudly a missing permission is drawn, which `OnboardingPermissionEmphasis` selects.
///
/// The list is derived from `CotabbyPermissionKind` (required cards from
/// `isRequiredForAutocomplete`, then optional-enhancement cards from `isOptionalEnhancement`) so
/// the product's permission model and these two surfaces cannot drift apart.

/// How a not-yet-granted permission presents itself.
enum OnboardingPermissionEmphasis {
    /// First-run setup: a neutral task, drawn in the permission's own tint with the brand button.
    case setup
    /// Post-onboarding reminder: a missing required permission is something broken, so it goes
    /// orange; optional rows step back to a bordered button so they never compete with it.
    case reminder
}

extension CotabbyPermissionKind {
    /// Per-permission tile tint, defined here in the UI layer so `PermissionModels` stays free of
    /// SwiftUI. Distinct hues per row is the System Settings idiom and makes the step scannable.
    var onboardingTint: Color {
        switch self {
        case .accessibility:
            CotabbyBrand.accent
        case .screenRecording:
            .teal
        }
    }

    /// Permissions that block core autocomplete, in display order.
    static var onboardingRequired: [CotabbyPermissionKind] {
        allCases.filter(\.isRequiredForAutocomplete)
    }

    /// Optional enhancements (Screen Recording today), in display order. Listed so they stay
    /// discoverable, but they never gate a Continue or Done button.
    static var onboardingOptional: [CotabbyPermissionKind] {
        allCases.filter(\.isOptionalEnhancement)
    }
}

/// The stack of permission cards: required first, then optional ones tagged so the user can skip
/// them without thinking setup is unfinished. Cards reveal in order starting at stagger index 1
/// (index 0 belongs to the header above the list); `revealIndexAfterList` is where whatever follows
/// the list continues the stagger.
struct OnboardingPermissionList: View {
    @ObservedObject var permissionManager: PermissionManager
    let emphasis: OnboardingPermissionEmphasis
    let permissionGuidanceController: PermissionGuidanceController

    static var revealIndexAfterList: Int {
        1 + CotabbyPermissionKind.onboardingRequired.count + CotabbyPermissionKind.onboardingOptional.count
    }

    var body: some View {
        let required = CotabbyPermissionKind.onboardingRequired
        let optional = CotabbyPermissionKind.onboardingOptional

        VStack(spacing: 10) {
            ForEach(Array(required.enumerated()), id: \.element) { index, permission in
                card(for: permission, isOptional: false)
                    .onboardingReveal(1 + index)
            }

            ForEach(Array(optional.enumerated()), id: \.element) { index, permission in
                card(for: permission, isOptional: true)
                    .onboardingReveal(1 + required.count + index)
            }
        }
    }

    private func card(for permission: CotabbyPermissionKind, isOptional: Bool) -> some View {
        OnboardingPermissionCard(
            permission: permission,
            granted: permissionManager.isGranted(permission),
            isOptional: isOptional,
            emphasis: emphasis,
            permissionGuidanceController: permissionGuidanceController
        )
    }
}

/// One permission row rendered as a card with a tinted icon tile.
///
/// The card measures its own button frame in screen coordinates because the permission guidance
/// controller needs a global rect to anchor its drag-helper animation. That screen-space concern
/// stays here in the view rather than leaking into the controller.
private struct OnboardingPermissionCard: View {
    let permission: CotabbyPermissionKind
    let granted: Bool
    let isOptional: Bool
    let emphasis: OnboardingPermissionEmphasis
    let permissionGuidanceController: PermissionGuidanceController

    @State private var actionButtonFrame = CGRect.zero

    /// A required permission that is still missing in the reminder window.
    private var isFlaggedAsBroken: Bool {
        emphasis == .reminder && !granted && !isOptional
    }

    var body: some View {
        HStack(spacing: 14) {
            OnboardingIconTile(
                systemImage: permission.systemImageName,
                tint: isFlaggedAsBroken ? .orange : permission.onboardingTint
            )

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
                allowButton
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

    /// Always the verb "Allow" (never a feature-toggle word like Enable); only the weight changes.
    @ViewBuilder
    private var allowButton: some View {
        let button = Button("Allow") {
            permissionGuidanceController.requestAccess(
                for: permission,
                sourceFrameInScreen: actionButtonFrame
            )
        }

        switch emphasis {
        case .setup:
            button
                .buttonStyle(.borderedProminent)
                .tint(CotabbyBrand.accent)
        case .reminder where isOptional:
            button
                .buttonStyle(.bordered)
        case .reminder:
            button
                .buttonStyle(.borderedProminent)
                .tint(.orange)
        }
    }
}

/// Green checkmark with "Done" label shown after a permission is granted.
private struct PermissionDoneBadge: View {
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
