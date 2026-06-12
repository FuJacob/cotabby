import SwiftUI

/// File overview:
/// The welcome step's hero: a self-playing demo of Cotabby's core loop (type, ghost text appears,
/// Tab accepts) staged inside a miniature mock app window. It exists so a brand-new user sees what
/// the product does in the first five seconds, before the flow asks them for permissions.
///
/// Like `OnboardingFeatureShowcase`, the demo is inert content: hardcoded strings and local
/// `@State`, no Accessibility, no event tap, nothing from the real suggestion pipeline. The loop is
/// driven from a `.task`, which SwiftUI cancels when the view leaves the hierarchy, and Reduce
/// Motion rests on a completed frame instead of looping. The card keeps a fixed height so the
/// welcome window never resizes mid-animation.
struct WelcomeHeroDemo: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Index into `examples` of the phrase currently playing; advances each loop for breadth.
    @State private var exampleIndex = 0
    /// Number of base characters revealed so far (the "typed" portion).
    @State private var typedCount = 0
    /// Whether the gray ghost continuation and its keycap are visible.
    @State private var showGhost = false
    /// Whether the ghost has been "accepted" and turned solid.
    @State private var accepted = false
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
                Text(String(example.base.prefix(typedCount)))
                    .foregroundStyle(.primary)

                // The insertion point sits between the typed text and the ghost, exactly where the
                // real caret stays while a suggestion is displayed.
                Capsule()
                    .fill(CotabbyBrand.accent)
                    .frame(width: 2, height: 18)
                    .opacity(caretVisible ? 1 : 0)
                    .padding(.horizontal, 1)

                if showGhost {
                    Text(example.ghost)
                        .foregroundStyle(accepted ? Color.primary : ghostColor)
                }
            }
            .font(.system(size: 16))
            .lineLimit(1)

            if showGhost && !accepted {
                HeroTabKeycap()
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

    /// The default inline ghost-text color, matching `GhostSuggestionView`'s fallback (replicated
    /// the same way `OnboardingFeatureShowcase` does, since the original is private).
    private var ghostColor: Color {
        colorScheme == .dark ? Color(white: 0.65) : Color(white: 0.45)
    }

    private func runLoop() async {
        guard !reduceMotion else {
            typedCount = example.base.count
            showGhost = true
            accepted = true
            caretVisible = true
            return
        }

        while !Task.isCancelled {
            typedCount = 0
            showGhost = false
            accepted = false
            try? await Task.sleep(nanoseconds: 450 * nsPerMillisecond)
            if Task.isCancelled { return }

            for index in 1...example.base.count {
                typedCount = index
                try? await Task.sleep(nanoseconds: 52 * nsPerMillisecond)
                if Task.isCancelled { return }
            }

            try? await Task.sleep(nanoseconds: 280 * nsPerMillisecond)
            if Task.isCancelled { return }

            withAnimation(.easeInOut(duration: 0.18)) { showGhost = true }
            try? await Task.sleep(nanoseconds: 1500 * nsPerMillisecond)
            if Task.isCancelled { return }

            withAnimation(.easeInOut(duration: 0.22)) { accepted = true }
            try? await Task.sleep(nanoseconds: 1100 * nsPerMillisecond)
            if Task.isCancelled { return }

            withAnimation(.easeInOut(duration: 0.3)) {
                showGhost = false
                accepted = false
                typedCount = 0
            }
            exampleIndex += 1
            try? await Task.sleep(nanoseconds: 500 * nsPerMillisecond)
        }
    }

    /// Standard insertion-point blink. Separate from the typing loop so the cadence stays steady
    /// across phases; the task dies with the view, and Reduce Motion holds the caret solid.
    private func runCaretBlink() async {
        guard !reduceMotion else {
            caretVisible = true
            return
        }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 520 * nsPerMillisecond)
            if Task.isCancelled { return }
            withAnimation(.easeInOut(duration: 0.12)) {
                caretVisible.toggle()
            }
        }
    }
}

/// One millisecond in nanoseconds, so the demo timings above read in milliseconds.
private let nsPerMillisecond: UInt64 = 1_000_000

/// Replica of the inline overlay's "Tab" keycap (the original in `OverlayController` is private),
/// color-matched to the ghost text exactly like `OnboardingFeatureShowcase`'s copy.
private struct HeroTabKeycap: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text("Tab")
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(colorScheme == .dark ? Color(white: 0.65) : Color(white: 0.45))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(colorScheme == .dark ? Color(white: 0.18) : Color(white: 0.95))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(colorScheme == .dark ? Color(white: 0.3) : Color(white: 0.8), lineWidth: 1)
            )
            .fixedSize()
    }
}
