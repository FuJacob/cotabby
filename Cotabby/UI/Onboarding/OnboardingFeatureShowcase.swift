import SwiftUI

/// File overview:
/// Decorative, self-playing demos shown on the final onboarding screen ("You're all set"). They
/// mimic Cotabby's two flagship features, inline autocomplete ghost text and the inline `:emoji:`
/// picker, using hardcoded strings and local state only.
///
/// Nothing here touches the real suggestion pipeline, settings, Accessibility, the event tap, or the
/// emoji catalog. The cards are inert content, so they can never steal focus or affect a real
/// suggestion. The keycap and popup styling is replicated (not shared) from `OverlayController` and
/// `EmojiPickerView`, whose own keycap views are `private`.
///
/// Lifecycle: each card owns its `@State` and drives a looping animation from a `.task`, which
/// SwiftUI cancels automatically when the view leaves the hierarchy. Each card also keeps a *fixed*
/// height so the onboarding window never resizes mid-loop. Continuous looping is skipped when the
/// system Reduce Motion setting is on, in which case the card shows a static accepted state.
struct OnboardingFeatureShowcase: View {
    var body: some View {
        VStack(spacing: 12) {
            GhostTextDemoCard()
            EmojiPickerDemoCard()
        }
        // Purely decorative looping demo: hide it from VoiceOver so the
        // mid-animation text fragments are never read out to AT users.
        .accessibilityHidden(true)
    }
}

/// One millisecond expressed in nanoseconds, so the demo timings below read in milliseconds.
private let nsPerMillisecond: UInt64 = 1_000_000

// MARK: - Shared card chrome

/// A captioned "mock text field" panel. Mirrors the onboarding `PermissionCard` look (regular
/// material plus a hairline stroke) at a tighter corner radius. The content area is pinned to a fixed
/// height so a card whose inner popup appears and disappears never changes the window's height.
private struct DemoCard<Content: View>: View {
    let caption: String
    let contentHeight: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            content
                .frame(maxWidth: .infinity, minHeight: contentHeight, maxHeight: contentHeight, alignment: .topLeading)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.regularMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(0.08), lineWidth: 0.5)
                )
        }
    }
}

// MARK: - Demo 1: inline autocomplete ghost text

private struct GhostTextDemoCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Number of base characters revealed so far (the "typed" portion).
    @State private var typedCount = 0
    /// Whether the gray ghost continuation and its keycap are visible.
    @State private var showGhost = false
    /// Whether the ghost has been "accepted" and turned solid.
    @State private var accepted = false

    private let base = "Thanks for the"
    private let ghost = " quick reply!"

    var body: some View {
        DemoCard(caption: "Autocomplete", contentHeight: 40) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(String(base.prefix(typedCount)))
                        .foregroundStyle(.primary)
                    if showGhost {
                        Text(ghost)
                            .foregroundStyle(accepted ? Color.primary : ghostColor)
                    }
                }
                .font(.system(size: 16))

                if showGhost && !accepted {
                    DemoGhostKeycap(label: "Tab")
                }

                Spacer(minLength: 0)
            }
        }
        .task(id: reduceMotion) {
            await runLoop()
        }
    }

    /// The default inline ghost-text color (no user customization in a demo): `Color(white:)` gated
    /// on the color scheme, matching `GhostSuggestionView`'s fallback in `OverlayController`.
    private var ghostColor: Color {
        colorScheme == .dark ? Color(white: 0.65) : Color(white: 0.45)
    }

    private func runLoop() async {
        guard !reduceMotion else {
            typedCount = base.count
            showGhost = true
            accepted = true
            return
        }

        while !Task.isCancelled {
            typedCount = 0
            showGhost = false
            accepted = false
            try? await Task.sleep(nanoseconds: 350 * nsPerMillisecond)
            if Task.isCancelled { return }

            for index in 1...base.count {
                typedCount = index
                try? await Task.sleep(nanoseconds: 55 * nsPerMillisecond)
                if Task.isCancelled { return }
            }

            withAnimation(.easeInOut(duration: 0.18)) { showGhost = true }
            try? await Task.sleep(nanoseconds: 1300 * nsPerMillisecond)
            if Task.isCancelled { return }

            withAnimation(.easeInOut(duration: 0.22)) { accepted = true }
            try? await Task.sleep(nanoseconds: 900 * nsPerMillisecond)
            if Task.isCancelled { return }

            withAnimation(.easeInOut(duration: 0.30)) {
                showGhost = false
                accepted = false
                typedCount = 0
            }
            try? await Task.sleep(nanoseconds: 600 * nsPerMillisecond)
        }
    }
}

/// Replicates the private `GhostKeycap` from `OverlayController` (the small "Tab" pill after ghost
/// text). Colors are `Color(white:)` gated on the color scheme, byte-for-byte with the original.
private struct DemoGhostKeycap: View {
    let label: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(textColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(borderColor, lineWidth: 1)
            )
            .fixedSize()
    }

    private var textColor: Color { colorScheme == .dark ? Color(white: 0.65) : Color(white: 0.45) }
    private var backgroundColor: Color { colorScheme == .dark ? Color(white: 0.18) : Color(white: 0.95) }
    private var borderColor: Color { colorScheme == .dark ? Color(white: 0.3) : Color(white: 0.8) }
}

// MARK: - Demo 2: inline emoji picker

private struct EmojiPickerDemoCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Number of trigger characters (":smi") revealed so far.
    @State private var triggerCount = 0
    /// Whether the candidate popup is open.
    @State private var showPopup = false
    /// Whether the chosen emoji has replaced the trigger text.
    @State private var committed = false

    private let leadIn = "Nice work "
    private let trigger = ":smi"
    private let chosenGlyph = "😄"
    private let candidates: [(glyph: String, alias: String)] = [("😄", "smile"), ("😁", "smiley")]

    var body: some View {
        DemoCard(caption: "Inline emoji", contentHeight: 124) {
            ZStack(alignment: .topLeading) {
                Text(fieldText)
                    .font(.system(size: 16))
                    .foregroundStyle(.primary)

                if showPopup {
                    DemoEmojiPopup(query: "smi", candidates: candidates)
                        .offset(x: 84, y: 26)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task(id: reduceMotion) {
            await runLoop()
        }
    }

    private var fieldText: String {
        if committed {
            return leadIn + chosenGlyph
        }
        return leadIn + String(trigger.prefix(triggerCount))
    }

    private func runLoop() async {
        guard !reduceMotion else {
            triggerCount = trigger.count
            committed = true
            showPopup = false
            return
        }

        // Offset the first iteration so the two demos do not animate in lockstep.
        try? await Task.sleep(nanoseconds: 700 * nsPerMillisecond)
        if Task.isCancelled { return }

        while !Task.isCancelled {
            triggerCount = 0
            committed = false
            showPopup = false
            try? await Task.sleep(nanoseconds: 350 * nsPerMillisecond)
            if Task.isCancelled { return }

            for index in 1...trigger.count {
                triggerCount = index
                try? await Task.sleep(nanoseconds: 70 * nsPerMillisecond)
                if Task.isCancelled { return }
            }

            withAnimation(.easeInOut(duration: 0.16)) { showPopup = true }
            try? await Task.sleep(nanoseconds: 1500 * nsPerMillisecond)
            if Task.isCancelled { return }

            withAnimation(.easeInOut(duration: 0.20)) {
                showPopup = false
                committed = true
            }
            try? await Task.sleep(nanoseconds: 900 * nsPerMillisecond)
            if Task.isCancelled { return }

            withAnimation(.easeInOut(duration: 0.30)) {
                committed = false
                triggerCount = 0
            }
            try? await Task.sleep(nanoseconds: 600 * nsPerMillisecond)
        }
    }
}

/// Scaled-down replica of the real inline emoji popup (`EmojiPickerView`): a `.regularMaterial`
/// panel with a monospaced query header, a divider, and the candidate rows.
private struct DemoEmojiPopup: View {
    let query: String
    let candidates: [(glyph: String, alias: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(":").foregroundStyle(.secondary)
                Text(query).foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .padding(.horizontal, 10)
            .frame(height: 26)

            Divider()

            VStack(spacing: 0) {
                ForEach(Array(candidates.enumerated()), id: \.element.alias) { index, candidate in
                    DemoEmojiRow(glyph: candidate.glyph, alias: candidate.alias, isSelected: index == 0)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: 210)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
    }
}

private struct DemoEmojiRow: View {
    let glyph: String
    let alias: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(glyph).font(.system(size: 18))
            Text(":\(alias):")
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if isSelected {
                DemoEmojiKeycap(label: "Tab")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .padding(.horizontal, 4)
    }
}

/// The on-accent keycap variant from `EmojiPickerView` (shown only on the highlighted row).
private struct DemoEmojiKeycap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.22))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.white.opacity(0.35), lineWidth: 1)
            )
            .fixedSize()
    }
}
