import SwiftUI

/// File overview:
/// The welcome step's hero: a self-playing demo of Cotabby's core loop (type, ghost text appears,
/// Tab accepts) staged inside a miniature mock app window. It exists so a brand-new user sees what
/// the product does in the first five seconds, before the flow asks them for permissions.
///
/// Like `OnboardingFeatureShowcase`, the demo is inert content: hardcoded strings and local
/// `@State`, no Accessibility, no event tap, nothing from the real suggestion pipeline. It plays the
/// same `DemoTypingTimeline` loop as the showcase cards from a `.task`, which SwiftUI cancels when
/// the view leaves the hierarchy, and Reduce Motion rests on a completed frame instead of looping. The card keeps a fixed height so the
/// welcome window never resizes mid-animation.
struct WelcomeHeroDemo: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Index into `examples` of the phrase currently playing; advances each loop for breadth.
    @State private var exampleIndex = 0
    @State private var phase = DemoTypingPhase.typing(count: 0)
    /// Insertion-point blink, driven by its own short-period task while the demo is on screen.
    @State private var caretVisible = true

    private struct Example {
        let base: String
        let ghost: String
    }

    /// Rotating phrases so the loop conveys "any writing, anywhere" rather than one canned email.
    private let examples = [
        Example(base: "Thanks for the", ghost: " quick reply!"),
        Example(base: "Let's meet", ghost: " tomorrow at 10."),
        Example(base: "Here's the", ghost: " final draft.")
    ]

    private var example: Example {
        examples[exampleIndex % examples.count]
    }

    /// Slower than the showcase cards and with a beat before the ghost appears: this is the first
    /// thing a new user watches, so each phase gets time to register.
    private static let timeline = DemoTypingTimeline(
        emptyHoldMilliseconds: 450,
        perCharacterMilliseconds: 52,
        pauseBeforeOfferMilliseconds: 280,
        offerAnimationDuration: 0.18,
        offerHoldMilliseconds: 1500,
        acceptAnimationDuration: 0.22,
        acceptedHoldMilliseconds: 1100,
        resetAnimationDuration: 0.3,
        resetHoldMilliseconds: 500
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            windowControlDots
            mockTextField
        }
        .padding(16)
        .onboardingCard(cornerRadius: 14)
        .task(id: reduceMotion) {
            await runLoop()
        }
        .task(id: reduceMotion) {
            await runCaretBlink()
        }
        // Purely decorative: hide from VoiceOver so mid-animation fragments are never read out.
        .accessibilityHidden(true)
    }

    /// Three traffic-light dots that frame the demo as "someone else's app window", which is the
    /// fastest way to say "this works everywhere" without a caption.
    private var windowControlDots: some View {
        HStack(spacing: 6) {
            Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34))
            Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18))
            Circle().fill(Color(red: 0.16, green: 0.78, blue: 0.25))
        }
        .frame(height: 7)
        .opacity(0.85)
    }

    private var mockTextField: some View {
        HStack(alignment: .center, spacing: 6) {
            HStack(alignment: .center, spacing: 0) {
                Text(String(example.base.prefix(phase.typedCount(outOf: example.base.count))))
                    .foregroundStyle(.primary)

                // The insertion point sits between the typed text and the ghost, exactly where the
                // real caret stays while a suggestion is displayed.
                Capsule()
                    .fill(CotabbyBrand.accent)
                    .frame(width: 2, height: 18)
                    .opacity(caretVisible ? 1 : 0)
                    .padding(.horizontal, 1)

                if phase.showsOffer {
                    Text(example.ghost)
                        .foregroundStyle(phase.isAwaitingAccept ? ghostColor : Color.primary)
                }
            }
            .font(.system(size: 16))
            .lineLimit(1)

            if phase.isAwaitingAccept {
                GhostKeycap(label: "Tab")
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        // A focused-field ring: hairline accent border plus a soft outer halo, matching how macOS
        // marks the focused text field. Sells "Cotabby is live in this field right now."
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(CotabbyBrand.accent.opacity(0.65), lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .inset(by: -2.5)
                .strokeBorder(CotabbyBrand.accent.opacity(0.22), lineWidth: 3)
        )
    }

    /// The default inline ghost-text color.
    private var ghostColor: Color {
        GhostTextPalette.automaticTextColor(dark: colorScheme == .dark)
    }

    private func runLoop() async {
        guard !reduceMotion else {
            phase = .accepted
            caretVisible = true
            return
        }
        await DemoTypingPlayer.play(
            Self.timeline,
            characterCount: { example.base.count },
            // The field is empty here, so the next phrase can be swapped in unseen.
            onLoopReset: { exampleIndex += 1 },
            setPhase: { phase = $0 }
        )
    }

    /// Standard insertion-point blink. Separate from the typing loop so the cadence stays steady
    /// across phases; the task dies with the view, and Reduce Motion holds the caret solid.
    private func runCaretBlink() async {
        guard !reduceMotion else {
            caretVisible = true
            return
        }
        while !Task.isCancelled {
            await DemoTypingPlayer.sleep(milliseconds: 520)
            if Task.isCancelled { return }
            withAnimation(.easeInOut(duration: 0.12)) {
                caretVisible.toggle()
            }
        }
    }
}
