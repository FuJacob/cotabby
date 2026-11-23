import SwiftUI

/// File overview:
/// Decorative, self-playing demos shown on the final onboarding screen ("You're all set"). They
/// mimic Cotabby's headline features: inline autocomplete ghost text, green typo autocorrect, the
/// inline `:emoji:` picker, and `/` macros. Every card but the macro one uses hardcoded strings and
/// local state; the macro card computes its examples with the real (pure, offline) `MacroEngine`, so
/// its values are always accurate.
///
/// To keep the onboarding window short with four cards, the macro card is a single cycling row rather
/// than a grid: it rotates through one real example per category so it still conveys breadth.
///
/// Nothing here touches the real suggestion pipeline, settings, Accessibility, the event tap, or the
/// emoji catalog. The cards are inert content, so they can never steal focus or affect a real
/// suggestion. The keycap, correction green and ribbon cell are the real overlay and picker views,
/// so the demos cannot drift from what the features actually draw.
///
/// Lifecycle: each typing card holds one `DemoTypingPhase` and plays its `DemoTypingTimeline` from a
/// `.task`, which SwiftUI cancels automatically when the view leaves the hierarchy. Each card also
/// keeps a *fixed* height so the onboarding window never resizes mid-loop. Continuous looping is
/// skipped when the system Reduce Motion setting is on (or when not animating, see below), in which
/// case the card shows a static resting frame.
///
/// `autoplay`: the one-time onboarding screen passes `true` so the demos play on their own. The
/// persistent Settings Home pane passes `false`, which keeps the loops idle (static resting frame)
/// until the pointer is over the showcase. Without that gate the looping animations would burn CPU
/// the entire time the Settings window sits on Home.
struct OnboardingFeatureShowcase: View {
    var autoplay: Bool = true
    /// Shows a "View all" affordance on the macro card that opens a full reference sheet. Off during
    /// onboarding (keeps that flow uncluttered) and on in Home so users can discover every macro.
    var showsMacroReference: Bool = false

    @State private var isHovering = false

    private var animating: Bool { autoplay || isHovering }

    var body: some View {
        VStack(spacing: 12) {
            GhostTextDemoCard(animating: animating)
            AutocorrectDemoCard(animating: animating)
            EmojiPickerDemoCard(animating: animating)
            MacroDemoCard(animating: animating, showsReferenceButton: showsMacroReference)
        }
        .onHover { isHovering = $0 }
        // Purely decorative looping demo: hide it from VoiceOver so the
        // mid-animation text fragments are never read out to AT users.
        .accessibilityHidden(true)
    }
}

// MARK: - Shared card chrome

/// A captioned "mock text field" panel. Mirrors the `OnboardingPermissionCard` look (regular
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
    let animating: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var phase = DemoTypingPhase.typing(count: 0)

    private let base = "Thanks for the"
    private let ghost = " quick reply!"

    private static let timeline = DemoTypingTimeline(
        emptyHoldMilliseconds: 350,
        perCharacterMilliseconds: 55,
        offerAnimationDuration: 0.18,
        offerHoldMilliseconds: 1300,
        acceptAnimationDuration: 0.22,
        acceptedHoldMilliseconds: 900,
        resetAnimationDuration: 0.30,
        resetHoldMilliseconds: 600
    )

    var body: some View {
        DemoCard(caption: "Autocomplete", contentHeight: 40) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(String(base.prefix(phase.typedCount(outOf: base.count))))
                        .foregroundStyle(.primary)
                    if phase.showsOffer {
                        Text(ghost)
                            .foregroundStyle(phase.isAwaitingAccept ? ghostColor : Color.primary)
                    }
                }
                .font(.system(size: 16))

                if phase.isAwaitingAccept {
                    GhostKeycap(label: "Tab")
                }

                Spacer(minLength: 0)
            }
        }
        .task(id: [reduceMotion, animating]) {
            await runLoop()
        }
    }

    /// The default inline ghost-text color (no user customization in a demo).
    private var ghostColor: Color {
        GhostTextPalette.automaticTextColor(dark: colorScheme == .dark)
    }

    private func runLoop() async {
        // Idle (not animating) shows the same finished frame as reduce-motion, so the card looks
        // complete at rest and only plays the full typing demo while hovered.
        guard animating, !reduceMotion else {
            phase = .accepted
            return
        }
        await DemoTypingPlayer.play(Self.timeline, characterCount: { base.count }, setPhase: { phase = $0 })
    }
}

// MARK: - Demo 2: autocorrect (typo correction)

/// Mirrors the inline typo-correction feature: a misspelled last word is offered as a green
/// correction that the user accepts with the word-accept key, turning it solid. The green is
/// the overlay's own correction color (`GhostTextPalette`).
/// Reduce-motion shows the static green-correction state so the feature still reads.
private struct AutocorrectDemoCard: View {
    let animating: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var phase = DemoTypingPhase.typing(count: 0)

    private let leading = "Pass me "
    private let typo = "teh"
    private let correction = "the"
    private var fullTyped: String { leading + typo }

    /// Starts late so the cards do not animate in lockstep, and lingers on the finished typo for a
    /// beat before the correction appears, the way detection follows the end of a word.
    private static let timeline = DemoTypingTimeline(
        startDelayMilliseconds: 1100,
        emptyHoldMilliseconds: 350,
        perCharacterMilliseconds: 55,
        pauseBeforeOfferMilliseconds: 450,
        offerAnimationDuration: 0.20,
        offerHoldMilliseconds: 1300,
        acceptAnimationDuration: 0.22,
        acceptedHoldMilliseconds: 900,
        resetAnimationDuration: 0.30,
        resetHoldMilliseconds: 600
    )

    /// Characters of "<leading><typo>" revealed so far.
    private var typedCount: Int {
        phase.typedCount(outOf: fullTyped.count)
    }

    var body: some View {
        DemoCard(caption: "Autocorrect", contentHeight: 40) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(String(leading.prefix(min(typedCount, leading.count))))
                        .foregroundStyle(.primary)
                    Text(lastWord)
                        .foregroundStyle(lastWordColor)
                }
                .font(.system(size: 16))

                if phase.isAwaitingAccept {
                    GhostKeycap(label: "Tab")
                }

                Spacer(minLength: 0)
            }
        }
        .task(id: [reduceMotion, animating]) {
            await runLoop()
        }
    }

    /// The last word is the typed-so-far typo until a correction is offered, then the corrected word.
    private var lastWord: String {
        if phase.showsOffer { return correction }
        return String(typo.prefix(max(0, typedCount - leading.count)))
    }

    /// Green while the correction is offered, solid once accepted (and during plain typing).
    private var lastWordColor: Color {
        phase.isAwaitingAccept ? GhostTextPalette.correctionColor(dark: colorScheme == .dark) : .primary
    }

    private func runLoop() async {
        // Idle (not animating) and reduce-motion both rest on the offered frame, not the accepted
        // one: the correction keeps its green, so the static card still reads as "typos get a green
        // fix" rather than as ordinary solid text.
        guard animating, !reduceMotion else {
            phase = .offered
            return
        }
        await DemoTypingPlayer.play(Self.timeline, characterCount: { fullTyped.count }, setPhase: { phase = $0 })
    }
}

// MARK: - Demo 3: inline emoji picker

private struct EmojiPickerDemoCard: View {
    let animating: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Typing reveals the trigger (":smi"), the offer is the candidate popup, and accepting
    /// replaces the trigger text with the chosen emoji.
    @State private var phase = DemoTypingPhase.typing(count: 0)

    private let leadIn = "Nice work "
    private let trigger = ":smi"
    private let chosenGlyph = "😄"
    private let candidates: [(glyph: String, alias: String)] = [
        ("😄", "smile"), ("😁", "smiley"), ("😊", "blush"), ("😆", "laughing"), ("😅", "sweat_smile")
    ]

    /// Starts late so the cards do not animate in lockstep.
    private static let timeline = DemoTypingTimeline(
        startDelayMilliseconds: 700,
        emptyHoldMilliseconds: 350,
        perCharacterMilliseconds: 70,
        offerAnimationDuration: 0.16,
        offerHoldMilliseconds: 1500,
        acceptAnimationDuration: 0.20,
        acceptedHoldMilliseconds: 900,
        resetAnimationDuration: 0.30,
        resetHoldMilliseconds: 600
    )

    var body: some View {
        DemoCard(caption: "Inline emoji", contentHeight: 124) {
            ZStack(alignment: .topLeading) {
                Text(fieldText)
                    .font(.system(size: 16))
                    .foregroundStyle(.primary)

                if phase.isAwaitingAccept {
                    DemoEmojiPopup(query: "smi", candidates: candidates)
                        .offset(x: 84, y: 26)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task(id: [reduceMotion, animating]) {
            await runLoop()
        }
    }

    private var fieldText: String {
        if phase == .accepted {
            return leadIn + chosenGlyph
        }
        return leadIn + String(trigger.prefix(phase.typedCount(outOf: trigger.count)))
    }

    private func runLoop() async {
        guard animating, !reduceMotion else {
            phase = .accepted
            return
        }
        await DemoTypingPlayer.play(Self.timeline, characterCount: { trigger.count }, setPhase: { phase = $0 })
    }
}

/// Scaled-down replica of the real inline emoji popup (`EmojiPickerView`): the committed-dark HUD
/// with a monospaced query row above a horizontal ribbon of ranked glyphs, the first selected.
private struct DemoEmojiPopup: View {
    let query: String
    let candidates: [(glyph: String, alias: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 1) {
                Text(":").foregroundStyle(PopupTheme.secondaryText)
                Text(query).foregroundStyle(PopupTheme.primaryText)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .padding(.horizontal, 8)
            .frame(height: 22)

            HStack(spacing: 2) {
                ForEach(Array(candidates.enumerated()), id: \.element.alias) { index, candidate in
                    EmojiRibbonCell(glyph: candidate.glyph, isSelected: index == 0)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 40)
        }
        .frame(width: 174)
        .popupHUDChrome()
        .shadow(color: .black.opacity(0.28), radius: 8, y: 4)
    }
}

// MARK: - Demo 4: inline `/` macros

/// A compact, cycling one-row tour of the `/` macro feature. Each tick advances to the next real
/// example, rotating across categories (math, unit conversion, currency, date), so a single short line
/// still conveys the breadth of what `/` can do. Collapsed from the former four-row grid specifically
/// to keep the onboarding window short now that there is a fourth (autocorrect) card.
///
/// Results come from the real `MacroEngine` (a pure, offline value type), so every example shows
/// exactly what the feature would insert: arithmetic and unit conversions are deterministic, currency
/// uses the bundled offline rate table, and dates evaluate against the current clock so `/today` and
/// friends are never stale. Inert (no AX, event tap, or insertion); reduce-motion shows one static
/// example with no cycling.
private struct MacroDemoCard: View {
    let animating: Bool
    var showsReferenceButton: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Index of the currently shown example; advances round-robin while visible.
    @State private var index = 0
    /// Real, engine-computed examples, one per (category, input). Built once when the card is created
    /// (rather than in `.task`) so the card is never momentarily empty before its first render.
    @State private var examples: [Example] = MacroDemoCard.buildExamples()
    @State private var isShowingReference = false

    private struct Example: Identifiable {
        let category: String
        /// What the user types after `/`.
        let input: String
        /// What the macro inserts, as computed by the real engine.
        let result: String
        var id: String { category + input }
    }

    var body: some View {
        DemoCard(caption: "Inline macros", contentHeight: 30) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let example = currentExample {
                    Text(example.category)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .leading)

                    Text("/\(example.input)")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.primary)
                        .contentTransition(.opacity)

                    Text("→")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)

                    Text(example.result)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary)
                        .contentTransition(.opacity)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)

                if showsReferenceButton {
                    Button {
                        isShowingReference = true
                    } label: {
                        Label("All macros", systemImage: "list.bullet.rectangle")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                    }
                    .buttonStyle(.borderless)
                    .help("See every inline macro and what it does")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: [reduceMotion, animating]) {
            await run()
        }
        .sheet(isPresented: $isShowingReference) {
            MacroReferenceSheet(onDismiss: { isShowingReference = false })
        }
    }

    private var currentExample: Example? {
        guard !examples.isEmpty else { return nil }
        return examples[index % examples.count]
    }

    private func run() async {
        // Idle (not animating) and reduce-motion rest on the first example; only hover/onboarding cycles.
        guard animating, !reduceMotion, !examples.isEmpty else { return }
        // Offset so this card does not advance in lockstep with the others.
        await DemoTypingPlayer.sleep(milliseconds: 500)
        while !Task.isCancelled {
            await DemoTypingPlayer.sleep(milliseconds: 1400)
            if Task.isCancelled { return }
            withAnimation(.easeInOut(duration: 0.35)) {
                index = (index + 1) % examples.count
            }
        }
    }

    /// One example per category, interleaved, each computed by the real (pure, offline) macro engine so
    /// the showcase can never drift from the feature's actual output. Inputs the engine does not resolve
    /// are dropped, so a future macro-grammar change degrades gracefully instead of showing a blank row.
    private static func buildExamples() -> [Example] {
        let engine = MacroEngine.standard()
        func example(_ category: String, _ input: String) -> Example? {
            engine.evaluate(input).map { Example(category: category, input: input, result: $0.insertionText) }
        }
        return [
            example("Math", "5+5="),
            example("Convert", "10km->mi"),
            example("Currency", "100usd->eur"),
            example("Date", "today"),
            example("Math", "2^10="),
            example("Convert", "100f->c"),
            example("Currency", "50gbp->jpy"),
            example("Date", "next-fri")
        ].compactMap { $0 }
    }
}
