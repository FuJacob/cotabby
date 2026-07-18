# Presentation and Sibling Features

## Purpose

This guide covers Cotabby-owned UI that appears around another application's editor and the features
that share global input infrastructure with suggestions. The presentation layer is a deliberate mix
of SwiftUI and AppKit: SwiftUI describes content, while AppKit owns non-activating panels, window
levels, focus behavior, and geometry that ordinary SwiftUI scenes cannot express reliably.

## Presentation Ownership

The main suggestion presentation path is:

~~~text
SuggestionCoordinator
  -> SuggestionOverlayPresenter
       -> OverlayController
            -> non-activating NSPanel
                 -> SwiftUI ghost or mirror content
~~~

[SuggestionOverlayPresenter.swift](../../Cotabby/Services/Suggestion/SuggestionOverlayPresenter.swift)
adapts coordinator intent into show, move, update, or hide actions and returns diagnostic reasons.
It owns the small state-diff rules, not AppKit window construction.

[OverlayController.swift](../../Cotabby/Services/Presentation/OverlayController.swift) owns the reusable
borderless panel, SwiftUI hosting views, render-mode selection, layout, font and color resolution,
fade behavior, and visible OverlayState. It is the only owner allowed to treat the suggestion as an
AppKit window.

The panel is non-activating, ignores mouse events, joins all Spaces, can appear over full-screen apps,
and does not participate in the window cycle. Showing a suggestion must never take keyboard focus
from the editor Cotabby is assisting.

## Inline and Mirror Modes

[CompletionRenderModePolicy.swift](../../Cotabby/Support/Presentation/CompletionRenderModePolicy.swift) chooses
how to render from user preference and geometry quality.

- Inline mode paints ghost text immediately beside a trusted caret. Exact and derived geometry are
  precise enough for this path under automatic policy.
- Mirror mode presents a Cotabby-owned card near the text line when geometry is estimated,
  layout-estimated, intentionally forced by user preference, or the caret is mid-line where free
  ghost glyphs could overlap existing trailing text.

The mirror card is not pretending to be host text. It trades visual continuity for correctness when
the exact glyph insertion point is unknown. MirrorOverlayLayout uses the reason for promotion to
choose an anchor and keep the card inside the visible screen.

Per-application render-mode overrides are represented as future policy capacity but are not wired in
the current product. Documentation should not claim they ship until the focused bundle identifier is
actually passed to the policy.

## Field-Matched Rendering

Focus resolution can carry a ResolvedFieldStyle with font family, weight, size, and foreground color.
Inline rendering uses that style when available and derives size primarily from caret height. It
falls back to a system font when the host exposes no usable style.

Presentation also supports:

- User-selected ghost color and opacity
- A bounded size multiplier
- Configurable acceptance-key hint
- Optional fade-in duration, respecting Reduce Motion
- Green correction styling for replace-the-word suggestions
- Right-to-left placement
- Bounded multiline layout and wrapping inside the field or screen

These are presentation settings. They do not enter SuggestionRequest or change generated text.

## Stable Partial and Acceptance Updates

Streaming can update many times per second. The coordinator coalesces partials and the presenter
skips identical text/geometry. OverlayController reuses separate typed NSHostingView instances for
inline and mirror roots so token extensions do not allocate a new window or hosting hierarchy.

For a single-line left-to-right inline suggestion, word acceptance and exact type-through can advance
the remaining tail by the measured width of the committed prefix. That keeps the ghost visually
stationary relative to the user's typing instead of waiting for a noisy AX caret refresh.

[SuggestionOverlayStabilityGate.swift](../../Cotabby/Support/Presentation/SuggestionOverlayStabilityGate.swift)
decides whether later reconciliation should hold the existing anchor or re-anchor to fresh geometry.
It tolerates the known pre-insertion AX frame briefly and corrects meaningful drift without allowing
small polling noise to make the tail jitter.

Mirror and multiline cases fall back to fresh layout when a simple horizontal advance is not valid.

## Activation and Debug Overlays

[ActivationIndicatorController.swift](../../Cotabby/Services/Presentation/ActivationIndicatorController.swift)
owns the optional caret or field-edge availability indicator. It follows supported focus and is
hidden when Cotabby is disabled, paused, missing required permissions, or not eligible.

[FocusDebugOverlayController.swift](../../Cotabby/Services/Presentation/FocusDebugOverlayController.swift)
shows lightweight polling sequence/capability, caret and field geometry, build identity, and
visual-context status for development. The old detailed FocusInspectionSnapshot and published
suggestion-diagnostics surface are not part of this path. It is gated by -cotabby-debug and must not
become normal user-facing settings state.

These controllers use their own non-activating panels because their visibility and layout lifetimes
are independent from suggestion text.

## Inline Command Ownership

[InlineCommandCoordinator.swift](../../Cotabby/App/Coordinators/InlineCommandCoordinator.swift) fans
captured input to the emoji and macro controllers. InputMonitor exposes one capture-decision slot and
one capture-interception flag; the coordinator prevents the two features from competing for those
shared resources.

Emoji and macro sigils are disjoint, so at most one capture should be active. The coordinator routes
the consuming-tap decision to the current owner and reports whether either feature was involved so
SuggestionCoordinator can stand down for that event.

Both features:

- Check live settings before triggering.
- Require a supported, non-secure focus context.
- Pin capture to a focus-change sequence.
- Cancel on incompatible navigation, focus change, timeout, or dismissal.
- Replace the literal typed run through SuggestionInserter.
- Use pure Support state machines for keystroke-to-action rules.

## Emoji Picker

[EmojiPickerController.swift](../../Cotabby/App/Coordinators/EmojiPickerController.swift) owns one
colon-query capture. [EmojiTriggerStateMachine.swift](../../Cotabby/Support/Emoji/EmojiTriggerStateMachine.swift)
decides when a colon may open a query and how typing, deletion, navigation, closing colon, acceptance,
and dismissal change the capture.

[EmojiCatalog.swift](../../Cotabby/Support/Emoji/EmojiCatalog.swift) lazily loads the bundled resource.
[EmojiMatcher.swift](../../Cotabby/Support/Emoji/EmojiMatcher.swift) ranks query matches using names,
keywords, synonyms, popularity, recency, and usage without owning UI.

[EmojiPickerPanelController.swift](../../Cotabby/Services/Presentation/EmojiPickerPanelController.swift) owns the
non-activating picker panel and SwiftUI content. Arrow keys move selection, the configured word-accept
key commits a match, and a supported closing-colon form can commit the best match. The controller then
replaces the literal colon query and records recency/frequency in EmojiUsageStore.

Catalog and matcher initialization are lazy so users who never type an emoji query do not pay the
resource and index cost at launch.

## Macros

[MacroController.swift](../../Cotabby/App/Coordinators/MacroController.swift) owns slash-query capture
and one-row preview presentation. [MacroTriggerStateMachine.swift](../../Cotabby/Support/Macros/MacroTriggerStateMachine.swift)
defines capture semantics, including guards that prevent ordinary URL fragments, fractions, and
mid-word slashes from triggering.

[MacroEngine.swift](../../Cotabby/Support/Macros/MacroEngine.swift) tries deterministic evaluator
families in priority order:

- Date and time expressions
- Random values
- Unit conversion
- Currency conversion
- Arithmetic

Clock, calendar, locale, and random source are injectable, so the engine remains deterministic under
test. A successful result carries preview text and replacement text; accepting it replaces the typed
slash query rather than invoking any language model.

## Settings

[SettingsCoordinator.swift](../../Cotabby/App/Coordinators/SettingsCoordinator.swift) owns the single
AppKit settings window and hosts [SettingsContainerView.swift](../../Cotabby/UI/Settings/SettingsContainerView.swift).
The window survives SwiftUI view reconstruction, remembers placement through AppKit, and routes
permission actions to PermissionGuidanceController.

Settings panes under Cotabby/UI/Settings/Panes remain presentation-focused. They bind to shared
models and call narrow mutation methods. Search indexing, attention callouts, hardware recommendations,
and validation rules belong in Support or Models so the view hierarchy does not become the source of
product behavior.

SuggestionSettingsModel retains individually published properties for existing SwiftUI bindings.
Its domainSettings projection groups the same values by the subsystem that owns each decision, and
SuggestionSettingsSnapshot supplies the smaller immutable behavior surface used by the pipeline.
SuggestionSettingsStore remains the sole UserDefaults owner and keeps persisted keys flat for
compatibility.

ContextLivePreviewField is the one Cotabby-owned editable field permitted through focus capability
for live preview. The exception is identified explicitly; general Cotabby windows remain blocked from
autocomplete to prevent the app from assisting itself.

## Onboarding

[WelcomeCoordinator.swift](../../Cotabby/App/Coordinators/WelcomeCoordinator.swift) owns the onboarding
and required-permission reminder windows. It restores incomplete progress, presents the correct step,
resizes the AppKit window to SwiftUI content, and keeps permission guidance attached to the active
surface.

Onboarding templates recommend a settings configuration; they do not create a separate runtime or
coordinator graph. Applying a template mutates the shared settings model so the same lifecycle
subscriptions and validation rules run as they would for manual changes.

Input Monitoring can require a quit/relaunch before the new TCC state is effective. WelcomeCoordinator
persists progress and returns the user to the permission step rather than treating that process exit
as abandoned onboarding.

## Menu Bar and Reachability

[CotabbyApp.swift](../../Cotabby/App/Core/CotabbyApp.swift) declares the SwiftUI MenuBarExtra. Status
item visibility is persisted in shared settings. Because hiding the status item can make an agent app
hard to reach, AppDelegate and MenuBarRecoveryPolicy restore a settings surface under defined launch
or reopen conditions.

This is a lifecycle rule, not merely a view preference: any new way to hide the menu icon must retain
a reliable path back into Settings.

## Invariants

- Cotabby-owned panels never steal focus from the assisted editor.
- SuggestionOverlayPresenter decides presentation actions; OverlayController owns AppKit mechanics.
- Automatic mode uses inline only when geometry and editing position make it safe.
- Streaming updates reuse presentation objects and avoid redundant renders.
- Partial acceptance updates the remaining tail synchronously.
- Debug presentation remains behind the explicit debug launch gate.
- Emoji and macro capture never compete for the one consuming-tap slot.
- Inline commands require a supported non-secure field and stay pinned to one focus sequence.
- Pure query and evaluation rules remain outside AppKit controllers.
- Settings and onboarding observe the app-scoped graph rather than constructing services.
- Hiding the menu bar item never permanently removes access to settings.

## Failure-Oriented Reading

- Ghost steals application focus: OverlayPanel configuration and show calls.
- Ghost overlaps host text mid-line: completion render-mode policy and geometry flags.
- Card appears despite exact caret: user mirror preference and quality passed into policy.
- Tail jitters after acceptance: advanceInline and SuggestionOverlayStabilityGate.
- Wrong font or color: resolved field style capture and overlay fallback.
- Emoji and suggestion both accept Tab: InlineCommandCoordinator capture ownership.
- Colon in a URL opens the picker: EmojiTriggerStateMachine boundary rules.
- Slash in a fraction opens macros: MacroTriggerStateMachine boundary rules.
- Settings opens duplicate windows: SettingsCoordinator lifetime.
- Onboarding restarts from the wrong step: WelcomeCoordinator persisted progress.
- Hidden icon leaves no entry point: MenuBarRecoveryPolicy and application reopen handling.

## Update This Guide When

Update this document when a render mode, panel, inline feature, settings surface, onboarding step, or
menu-bar reachability rule is added or changes ownership.
