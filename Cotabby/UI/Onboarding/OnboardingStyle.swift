import SwiftUI

/// File overview:
/// The shared design system for the first-run onboarding flow: window backdrop, icon tiles, card
/// chrome, entrance choreography, and the step header / navigation / progress components every
/// step composes. Keeping the vocabulary in one file is what keeps the six steps reading as one
/// designed surface instead of six separately-styled screens. The brand palette itself lives in
/// `CotabbyBrand` (shared with Settings' brand moments); the keycap chrome lives in `KeycapView`
/// (shared with the Shortcuts pane).
///
/// Two constraints shape everything here:
///   1. Energy. The backdrop and chrome are static; the only continuous animations in onboarding
///      are the explicitly-looping product demos, and every entrance effect is a one-shot spring.
///   2. Reduce Motion. Each animated component checks `accessibilityReduceMotion` and collapses to
///      its resting frame, mirroring the convention in `OnboardingFeatureShowcase`.
enum OnboardingLayout {
    /// Horizontal content inset shared by every step so text columns line up across transitions.
    static let horizontalPadding: CGFloat = 36
}

// MARK: - Backdrop

/// Window-filling backdrop: the standard translucent material with a soft brand-blue glow washing
/// down from the top edge. Static by design (no `TimelineView`, no looping animation) so the
/// onboarding window costs nothing while it idles.
struct OnboardingBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)

            // Two offset radial washes rather than one centered one: the asymmetry keeps the
            // gradient from reading as a spotlight and gives the titlebar region gentle color.
            RadialGradient(
                colors: [CotabbyBrand.accent.opacity(colorScheme == .dark ? 0.26 : 0.14), .clear],
                center: UnitPoint(x: 0.15, y: -0.1),
                startRadius: 10,
                endRadius: 460
            )

            RadialGradient(
                colors: [CotabbyBrand.accentSoft.opacity(colorScheme == .dark ? 0.16 : 0.10), .clear],
                center: UnitPoint(x: 0.95, y: 0.0),
                startRadius: 10,
                endRadius: 420
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Icon tiles

/// Tinted gradient squircle with a white SF Symbol, the System Settings icon idiom. Used for
/// permission rows, template tiers, and step headers so every icon in the flow shares one shape
/// language. The gradient brightens toward the top to read as lit from above.
struct OnboardingIconTile: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.85), tint],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: tint.opacity(0.35), radius: size * 0.14, y: size * 0.06)

            Image(systemName: systemImage)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Card chrome

/// The standard onboarding card surface: translucent material, continuous corners, a hairline
/// stroke that survives both appearances, and a whisper of depth. One modifier so a future tweak
/// (radius, stroke, shadow) lands on every card at once.
private struct OnboardingCardChrome: ViewModifier {
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.07), radius: 3, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
            )
    }
}

extension View {
    func onboardingCard(cornerRadius: CGFloat = 16) -> some View {
        modifier(OnboardingCardChrome(cornerRadius: cornerRadius))
    }
}

// MARK: - Entrance choreography

/// One-shot staggered entrance: fade in while rising a few points, delayed by the element's index
/// so a step's content settles top-to-bottom. Collapses to the resting frame under Reduce Motion.
///
/// `@State` (not a transition) so the effect plays exactly once per appearance of the step's view
/// tree and never replays on unrelated re-renders such as download-progress ticks.
private struct OnboardingReveal: ViewModifier {
    let index: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    func body(content: Content) -> some View {
        content
            .opacity(revealed ? 1 : 0)
            .offset(y: revealed ? 0 : 14)
            .onAppear {
                guard !reduceMotion else {
                    revealed = true
                    return
                }
                withAnimation(.spring(response: 0.55, dampingFraction: 0.85).delay(Double(index) * 0.07)) {
                    revealed = true
                }
            }
    }
}

extension View {
    /// Staggered entrance for onboarding content. `index` is the element's top-to-bottom position
    /// within its step (0 for the first element), which sets its share of the stagger delay.
    func onboardingReveal(_ index: Int) -> some View {
        modifier(OnboardingReveal(index: index))
    }
}

// MARK: - Step header

/// Centered title block shared by every middle step: optional icon tile, large rounded title,
/// secondary subtitle. One component so typography can never drift between steps.
struct OnboardingStepHeader: View {
    var systemImage: String?
    var tint: Color = CotabbyBrand.accent
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            if let systemImage {
                OnboardingIconTile(systemImage: systemImage, tint: tint, size: 44)
                    .padding(.bottom, 4)
            }

            Text(title)
                .font(.system(size: 26, weight: .bold, design: .rounded))

            Text(subtitle)
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Progress

/// Capsule progress pips for the middle steps. Completed pips fill with the brand color, the
/// current pip stretches into a gradient lozenge, and future pips stay quiet. The textual
/// "Step X of Y" lives only in the accessibility label; sighted users get position from the pips.
struct OnboardingProgressPips: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(1...total, id: \.self) { index in
                Capsule()
                    .fill(fillStyle(for: index))
                    .frame(width: index == current ? 26 : 7, height: 7)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current) of \(total)")
    }

    private func fillStyle(for index: Int) -> AnyShapeStyle {
        if index == current {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [CotabbyBrand.accentSoft, CotabbyBrand.accent],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
        if index < current {
            return AnyShapeStyle(CotabbyBrand.accent.opacity(0.55))
        }
        return AnyShapeStyle(Color.secondary.opacity(0.22))
    }
}

// MARK: - Buttons

/// Primary call-to-action used on the welcome and done steps. Brand-tinted and width-capped so it
/// reads as a deliberate, centered action rather than an edge-to-edge bar.
struct WelcomeButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .frame(maxWidth: 260)
                .padding(.vertical, 2)
        }
        .buttonStyle(.borderedProminent)
        .tint(CotabbyBrand.accent)
        .controlSize(.large)
    }
}

/// Back/Continue navigation bar for the middle wizard steps. The primary button label defaults to
/// "Continue" but can be overridden (the template step shows "Set up later" when no tier is
/// chosen). The button can be disabled with a tooltip hint explaining what's needed.
struct WelcomeNavigation: View {
    var canGoBack: Bool = false
    var canContinue: Bool = true
    var continueTitle: String = "Continue"
    var disabledHint: String?
    var onBack: (() -> Void)?
    let onContinue: () -> Void

    var body: some View {
        HStack {
            if canGoBack, let onBack {
                Button("Back") {
                    onBack()
                }
                .controlSize(.large)
            }

            Spacer(minLength: 0)

            Button(continueTitle) {
                onContinue()
            }
            .buttonStyle(.borderedProminent)
            .tint(CotabbyBrand.accent)
            .controlSize(.large)
            .disabled(!canContinue)
            .help(canContinue ? "" : (disabledHint ?? ""))
        }
    }
}
