# RFC 0001: Compose Mode

Status: Draft  
Related issues: [#66](https://github.com/FuJacob/tabby/issues/66), [#67](https://github.com/FuJacob/tabby/issues/67), [#68](https://github.com/FuJacob/tabby/issues/68), [#69](https://github.com/FuJacob/tabby/issues/69), [#70](https://github.com/FuJacob/tabby/issues/70)

## Summary

Tabby should support two explicit writing modes:

- Autocomplete Mode: the current behavior. Tabby predicts a short inline continuation and shows ghost text near the caret.
- Compose Mode: a new deliberate mode where Tabby gathers broader screen and text context, generates a complete draft, and manually types the full response into the focused field when the user accepts it.

The first motivating case is a pull request comment. Instead of only completing the next few words, the user focuses the GitHub comment box, presses `Tab`, and Tabby drafts the full comment based on the surrounding page context and the text already typed in the field.

The core architectural proposal is to model Compose as first-class interaction state, not as a scattered set of booleans inside the existing autocomplete path. Mode selection should live in shared settings, request construction should branch through explicit request/prompt types, and acceptance should use Compose-specific typing rules.

## Goals

- Add a persisted interaction mode: `autocomplete` or `compose`.
- Keep Autocomplete Mode as the default and preserve current behavior.
- Give runtime code an immutable mode value through `SuggestionSettingsSnapshot`.
- Add UI in the menu bar and Settings so the active mode is visible and changeable.
- Add Compose-specific context gathering from Accessibility tree traversal.
- Add Compose-specific prompt construction for full comments, replies, and text blocks.
- Require the local `tabby-depth-1` model for Compose Mode.
- Prevent users from editing the model choice while Compose Mode is active.
- Manually type the generated Compose draft only when focus and context are still valid.

## Non-Goals

- Do not replace the existing autocomplete pipeline.
- Do not add hosted API dependencies.
- Do not accept, persist, log, or commit provider API keys or other secrets as part of Compose Mode.
- Do not build a chat interface or multi-turn agent workflow.
- Do not support rewrite/edit workflows in the first implementation.
- Do not send raw screenshots or unbounded AX tree text directly to the model.
- Do not make Compose work in every possible macOS text surface in the first slice.

## Privacy And Secret Handling

Compose Mode must preserve Tabby's local-first contract. The first implementation should use only on-device runtimes and local context sources.

Operational guardrails:

- Do not add OpenAI, Anthropic, or other hosted-provider clients for this RFC.
- Do not store API keys in source, fixtures, markdown, `UserDefaults`, debug logs, prompt previews, or crash diagnostics.
- If a future RFC adds hosted providers, secrets must be stored in Keychain, must be opt-in per provider, and must not be mixed into the Compose Mode implementation proposed here.
- Compose prompt previews and diagnostics should be bounded summaries. Full surrounding AX context can include sensitive page text and should not be retained longer than the active generation flow needs it.

## Current System

Tabby's current pipeline is optimized around short inline continuations:

1. `FocusTracker` polls the active AX focus and produces a `FocusSnapshot`.
2. `SuggestionCoordinator` decides whether focus, permissions, settings, and input events allow prediction.
3. `SuggestionRequestFactory` builds one `SuggestionRequest`.
4. `LlamaPromptRenderer` or `FoundationModelPromptRenderer` formats an autocomplete prompt.
5. `SuggestionEngineRouter` routes the request to Apple Intelligence or llama.
6. `SuggestionTextNormalizer` reduces raw model output into a short continuation.
7. `SuggestionInteractionState` stores the active suggestion tail.
8. `SuggestionInserter` commits accepted chunks when the user presses `Tab`.

That design is correct for autocomplete because it minimizes prompt size, latency, and insertion risk. Compose Mode needs a different contract because it intentionally produces larger output from broader context.

Two current ownership boundaries matter for implementation:

- `SuggestionSettingsModel` owns durable product preferences such as engine, word-count preset, clipboard context, profile, and the proposed interaction mode.
- `RuntimeBootstrapModel` and `LlamaRuntimeManager` own local model selection and loading. Compose should coordinate with them; it should not move model persistence into `SuggestionSettingsModel`.

## Proposed Product Behavior

Compose Mode should be a global mode in the first implementation.

When Compose Mode is active:

1. The menu bar and Settings UI show "Compose" as the selected mode.
2. The local model selection UI is locked to `tabby-depth-1`.
3. Pressing `Tab` in a supported empty or partially typed text field starts Compose generation.
4. Tabby gathers the focused field context plus nearby readable page context.
5. Tabby generates one full draft.
6. Tabby shows a preview state before typing starts.
7. Pressing `Tab` again accepts the full draft if focus is still valid.
8. Tabby types the accepted draft into the field with a visible manual typing effect.
9. `Esc`, focus change, mode change, disabled app state, or global disable cancels the draft.

This two-step Tab behavior is recommended for safety: first `Tab` generates, second `Tab` starts manual typing. A single `Tab` that immediately types a multi-sentence draft would be fast, but it makes accidental long output too easy and conflicts with the current product expectation that `Tab` accepts only visible ghost text.

## Mode Model

Add a new value type in `tabby/Models/`, likely next to `SuggestionEngineKind`:

```swift
enum SuggestionInteractionMode: String, CaseIterable, Equatable, Hashable, Sendable, Identifiable {
    case autocomplete
    case compose
}
```

Add this to `SuggestionSettingsModel`:

- `@Published private(set) var selectedInteractionMode: SuggestionInteractionMode`
- `private static let selectedInteractionModeDefaultsKey = "tabbySelectedInteractionMode"`
- `func selectInteractionMode(_ mode: SuggestionInteractionMode)`

Add this to `SuggestionSettingsSnapshot`:

- `let selectedInteractionMode: SuggestionInteractionMode`

Implementation notes:

- Put the enum near `SuggestionEngineKind` in `SuggestionEngineModels.swift` so engine, mode, and snapshot values stay together.
- Default to `.autocomplete` when no persisted value exists. There is no legacy Compose state to migrate.
- Update both `SuggestionSettingsModel.snapshot` and `snapshotPublisher`. Prefer a private `makeSnapshot(...)` helper so the direct snapshot and Combine publisher cannot drift when future settings are added.
- `handleSuggestionSettingsChange(_:)` must treat mode changes like engine changes: cancel work, reset cached generation context, clear active sessions, and hide stale UI before scheduling new work.

Why this belongs in settings:

- The selected mode must persist across restart.
- The coordinator should react to mode changes, not own preference storage.
- Prompt construction and runtime routing need the same immutable setting value.
- Tests can assert snapshot emission without driving UI.

## Runtime Model Requirement

Compose Mode should require `tabby-depth-1`, currently mapped to:

```swift
gemma-3n-E4B-it-Q4_K_M.gguf
```

Recommended behavior:

- Entering Compose Mode selects `tabby-depth-1` if installed.
- If not installed, Compose Mode enters an unavailable state with a CTA to download it.
- While Compose Mode is active, model selection controls are disabled and explain that Compose requires `tabby-depth-1`.
- Switching back to Autocomplete restores the user's previous local model selection.
- The required model should be identified by filename or capability, not by display label. Display labels are product copy and should not drive runtime behavior.

Tradeoff:

- Forcing one model reduces user control, but it protects Compose quality and simplifies evals.
- Allowing every local model would be more flexible, but smaller models are more likely to produce incomplete or unsafe full drafts.

Implementation notes:

- Add a canonical runtime capability such as `RuntimeModelCapability.compose` or constants/helpers such as `RuntimeModelCatalog.composeRequiredFilename` and `RuntimeModelCatalog.supportsCompose(filename:)`.
- Keep the user's previous autocomplete model selection in the runtime-selection layer, not in `SuggestionSettingsModel`. The mode setting says what interaction the user wants; the runtime model layer says which GGUF file is selected.
- Do not silently switch to an arbitrary custom model if `tabby-depth-1` is missing. Surface Compose as unavailable and offer the download action.
- Avoid a reload loop: mode changes can request a model switch, and model switches already call `prepareForRuntimeModelSwitch()`. The implementation should make one owner responsible for this transition so cancellation and UI messaging happen once.

## Mode-Aware Availability

`SuggestionAvailabilityEvaluator` currently gates autocomplete on Accessibility, Input Monitoring, Screen Recording, app blocklist, global enablement, and focus support. Compose needs mode-aware gating because the first AX-tree slice can work without screenshot/OCR context.

Recommended behavior:

- Both modes require Accessibility-derived focused text support and Input Monitoring.
- Autocomplete keeps the current Screen Recording gate while visual context is part of the active autocomplete prompt path.
- Compose should require Screen Recording only if Compose uses screenshot/OCR visual context in that generation. AX-only Compose context should not be blocked by missing Screen Recording permission.
- The disabled reason should name the active mode so users understand whether Tabby is waiting on autocomplete visual context or Compose context.

Implementation note: extend `SuggestionAvailabilityEvaluator` to accept `SuggestionSettingsSnapshot` or `SuggestionInteractionMode` instead of passing separate booleans indefinitely. This keeps the permission matrix in one pure place as modes diverge.

## Compose Context Gathering

Add a new service boundary:

```text
tabby/Services/Context/ComposeContextCollector.swift
```

Responsibility:

- Reacquire or receive the current focused AX element on the main actor.
- Validate that the AX element still matches the active `FocusedInputContext` before using collected context.
- Walk up to the parent window or nearest stable container.
- Walk down the subtree with bounded depth-first traversal.
- Extract readable text only from allowlisted roles.
- Normalize, deduplicate, and bound the text before prompt construction.

This should not live inside `SuggestionCoordinator` because tree traversal is side-effectful, app-specific, and independently testable through pure normalization helpers.

### Tree Walk Algorithm

Initial algorithm:

1. Start with the current `FocusedInputContext` value created from `FocusSnapshot.context`.
2. On the main actor, reacquire the focused AX element through the focus subsystem or `AXHelper.focusedElement()`.
3. Validate process identity, role/subrole, and focus identity before collecting. Do not store raw `AXUIElement` references in `FocusedInputContext`; those values are not `Sendable` and can become stale across async boundaries.
4. Resolve the parent chain until reaching `AXWindow` or a max ancestor depth.
5. Run bounded DFS from that root.
6. Visit at most `maxNodes` nodes and `maxDepth` levels.
7. Read `AXRole`, `AXValue`, `AXTitle`, `AXDescription`, and `AXChildren` through `AXHelper` so Core Foundation ownership and casting stay centralized.
8. Keep text only for allowed readable roles:

```swift
let allowedRoles: Set<String> = [
    "AXStaticText",
    "AXTextArea",
    "AXTextField",
    "AXDocument"
]
```

9. Skip known noisy or unsafe roles:

```swift
let blockedRoles: Set<String> = [
    "AXButton",
    "AXCheckBox",
    "AXRadioButton",
    "AXScrollBar",
    "AXMenuItem",
    "AXImage"
]
```

10. Join extracted strings using newlines, not only spaces, so document structure survives.
11. Normalize whitespace, repeated symbols, navigation noise, and duplicate lines.
12. Bound the final context by characters and approximate tokens.
13. Check cancellation between traversal batches so a focus change or mode change can stop slow AX work quickly.

Why bounded DFS matters:

- AX trees can be huge in browsers and Electron apps.
- Some nodes are slow or unreliable to query.
- A hard node/depth budget prevents UI stalls and protects local generation latency.

Recommended first limits:

- `maxAncestorDepth = 8`
- `maxDFSDepth = 12`
- `maxNodes = 500`
- `maxRawContextCharacters = 30_000`
- `maxNormalizedContextCharacters = 8_000`

These are starting values and should be tuned with real GitHub, Gmail, Slack, Discord, and Notes examples.

The collector API should be `async` even if the first implementation performs AX calls on the main actor. That gives the coordinator a cancellation point, lets the implementation yield between traversal batches, and preserves the option to move pure normalization work off the main actor later.

### Context Normalization

Add pure helpers in `tabby/Support/ComposeContextNormalizer.swift`.

The normalizer should:

- Trim leading and trailing whitespace.
- Collapse runs of spaces and tabs.
- Preserve meaningful newlines between extracted text blocks.
- Drop lines with only punctuation or repeated symbols.
- Drop obvious repeated navigation/action labels.
- Deduplicate exact repeated lines while preserving first occurrence.
- Bound individual lines to avoid one massive AX value dominating the prompt.
- Bound the final normalized context.

This split follows the project change strategy: pure `Support/` rules first, service boundary second.

## Request Model

The current `SuggestionRequest` encodes an autocomplete request. Compose should not overload all fields with mode-specific meaning.

Recommended approach:

```swift
enum GenerationRequest: Equatable, Sendable {
    case autocomplete(SuggestionRequest)
    case compose(ComposeRequest)
}
```

Add:

```swift
struct ComposeRequest: Equatable, Sendable {
    let context: FocusedInputContext
    let typedPrefix: String
    let trailingText: String
    let surroundingContext: String
    let visualContextSummary: String?
    let clipboardContext: String?
    let applicationName: String
    let generation: UInt64
    let maxPredictionTokens: Int
    let temperature: Double
    let topK: Int
    let topP: Double
    let minP: Double
    let repetitionPenalty: Double
    let randomSeed: UInt32?
    let userName: String?
    let userTags: [String]?
}
```

Why a separate request type:

- Autocomplete wants a short continuation; Compose wants a full draft.
- Autocomplete normalizes aggressively to one fragment; Compose must preserve paragraphs.
- Compose will need larger token budgets and possibly different sampling values.
- Compose may combine AX, optional screenshot/OCR summary, and optional clipboard context, while autocomplete keeps those as small prompt augmentations.
- Tests can validate each prompt contract independently.

Alternative: add `mode` and optional fields to `SuggestionRequest`.

- Pros: smaller diff and fewer protocol changes.
- Cons: many fields become invalid depending on mode, which creates weaker invariants and more defensive code.

Recommendation: use a sum type (`GenerationRequest`) or parallel protocol methods. The extra type cost is worth the stronger model.

Protocol migration options:

- Replace `SuggestionGenerating.generateSuggestion(for:)` with `generate(for request: GenerationRequest)` and make unsupported combinations explicit in the router.
- Or add a parallel `generateCompose(for:)` path first and keep autocomplete signatures unchanged until Compose is proven.

The lower-risk first slice is the parallel method because it avoids forcing Apple Intelligence, llama autocomplete, and tests to understand a request case they do not support yet. A later cleanup can collapse both into `GenerationRequest` once both modes are stable.

## Prompt Design

Add `ComposePromptRenderer` in `tabby/Support/`.

The prompt should make the output contract explicit:

- Draft the complete text that should be typed at the caret.
- Use the user's typed prefix as the start or intent signal.
- Use surrounding AX context to infer the situation.
- For PR comments, write the actual comment, not analysis about the comment.
- Return only the typeable text.
- No labels, markdown fences, explanations, or quoted prompt text.
- Match the tone and language of the context.
- Keep output bounded.

Example prompt shape:

```text
Task:
- Write the complete text the user wants typed at the caret.
- This is Compose Mode, not autocomplete and not chat.
- Return only the final typeable draft.
- Do not include labels, explanations, or quote the surrounding context.
- If the context is insufficient, write a concise useful draft based on the typed prefix.

User profile:
...

App:
GitHub

Text already typed in the focused field:
...

Relevant surrounding context:
...

Final instruction:
Write the full comment now.
```

Compose should have its own output normalizer, likely `ComposeTextNormalizer`, because the existing `SuggestionTextNormalizer` intentionally truncates to a short inline continuation.

`ComposeTextNormalizer` should preserve paragraph boundaries while still removing non-typeable wrapper text. It should strip labels such as `Final answer:`, markdown fences, surrounding quotes that wrap the entire response, and repeated prompt fragments, but it should not collapse multiline drafts into one sentence.

## Engine Routing

`SuggestionEngineRouter` currently routes by engine kind. Compose adds a second routing dimension:

- Interaction mode: autocomplete vs compose.
- Engine backend: Apple Intelligence vs llama.

For the first implementation, Compose should route only to llama with `tabby-depth-1`.

Recommended behavior:

- `Autocomplete + Apple Intelligence`: supported.
- `Autocomplete + llama`: supported.
- `Compose + llama + tabby-depth-1`: supported.
- `Compose + Apple Intelligence`: unavailable in first slice.
- `Compose + llama + other model`: unavailable or auto-switch to `tabby-depth-1`.

This keeps Compose local-first while avoiding a partial Apple prompt path before the product behavior is proven.

Routing should reject unsupported combinations before calling a backend. For example, `Compose + Apple Intelligence` should produce a user-facing unavailable state rather than sending a Compose prompt through `FoundationModelSuggestionEngine` and hoping the backend behaves.

## Acceptance Flow

Autocomplete currently supports partial chunk acceptance. Compose should not.

Compose acceptance should use a separate active session type:

```swift
enum ActiveGenerationSession: Equatable, Sendable {
    case autocomplete(ActiveSuggestionSession)
    case compose(ActiveComposeSession)
}

struct ActiveComposeSession: Equatable, Sendable {
    let baseContext: FocusedInputContext
    let fullText: String
    let latency: TimeInterval
}
```

Compose acceptance rules:

- Type the full draft through a controlled manual typing effect instead of inserting it instantly.
- Require current focus process, `FocusedInputIdentity`, and compatible content signature to still match the base context. Process-only validation is acceptable for autocomplete's short chunks, but Compose's larger writes need a stricter guard.
- Require selection state to be compatible with the generated request.
- Pass `Tab` through when no Compose draft is ready.
- Cancel on mode changes, focus changes, app-disabled state, permission loss, or global disable.
- Do not keep a remaining tail after typing.

Manual typing behavior:

- Use synthetic Unicode keyboard events in small chunks so the host app receives normal text input.
- Type at a bounded cadence that feels deliberate but does not take too long for a full comment.
- Register synthetic input with `InputSuppressionController` so Tabby does not treat its own typing as user edits.
- Extend suppression for multi-event insertion. The current autocomplete inserter suppresses one synthetic keydown for one accepted chunk; Compose typing needs either per-chunk rearming or a counted suppression window sized to the number of posted keydown events.
- Keep cancellation explicit: `Esc`, focus change, mode change, disabled app state, or permission loss should stop any remaining queued typing.
- Preserve generation/focus validation before starting, and re-check focus between chunks for longer drafts.

Typing strategy tradeoff:

- Synthetic Unicode event input is already used and can be extended into a chunked typing effect.
- Pasteboard-based insertion is more reliable for long multiline text, but temporarily touches user clipboard state.
- AX value mutation can be precise, but app support is inconsistent and higher risk.

Recommendation for first implementation: build a `ComposeTypingController` or insertion strategy that sends chunked synthetic Unicode input at a controlled cadence. This preserves the desired "Tabby is typing this out" product feel while reusing the same macOS input primitive as autocomplete acceptance. Pasteboard insertion should remain a fallback to evaluate only if multiline synthetic typing is unreliable in target apps.

State ownership: replace `SuggestionInteractionState.activeSession: ActiveSuggestionSession?` with one active sum type rather than adding a parallel `activeComposeSession` property. A single active-session slot prevents autocomplete and Compose sessions from both appearing valid after a mode switch or focus race.

## UI

Menu bar:

- Add a segmented picker or compact menu row for "Autocomplete" and "Compose".
- Show current mode in the status area.
- Disable model picker in Compose Mode and show `tabby-depth-1`.
- If `tabby-depth-1` is missing, show a download action.

Settings:

- Add an "Interaction Mode" control near engine/model settings.
- Explain in one concise sentence that Compose writes a full draft while Autocomplete predicts a short continuation.
- Keep deeper implementation language out of user-facing UI.

Overlay:

- Autocomplete keeps current ghost text.
- Compose should use a distinct preview surface, probably a compact multiline preview near the field.
- The preview must make acceptance deliberate. A collapsed preview plus "Tab to type" state is safer than rendering a long ghost paragraph inline.

## Implementation Plan

### Phase 1: Mode Foundation

- Add `SuggestionInteractionMode`.
- Persist mode in `SuggestionSettingsModel`.
- Include mode in `SuggestionSettingsSnapshot`.
- Add snapshot publisher coverage.
- Add UI controls in Menu Bar and Settings.
- On mode changes, cancel active work, clear overlay, and reset active sessions.
- Keep Autocomplete Mode behavior unchanged.

Validation:

- Unit tests for default mode.
- Unit tests for persistence.
- Unit tests for snapshot emission.
- Build with `xcodebuild -project tabby.xcodeproj -scheme tabby -destination 'platform=macOS' build`.

### Phase 2: Blinder-Equipped Tree Walker

- Add `ComposeContextNormalizer`.
- Add `ComposeContextCollector`.
- Add role allowlist and blocked-role filters.
- Add bounded ancestor walk and DFS.
- Add debug diagnostics for visited nodes, retained text count, and dropped text count.
- Do not feed raw context directly to the model.

Validation:

- Unit tests for context normalization.
- Unit tests for context bounding and duplicate-line removal.
- Manual AX tests in GitHub PR comments, Gmail reply, Slack/Discord message fields, and Notes.
- Confirm traversal budget prevents stalls on large browser pages.

### Phase 3: Compose Request And Prompt

- Add `ComposeRequest`.
- Add `ComposePromptRenderer`.
- Add `ComposeTextNormalizer`.
- Add Compose token/sampling defaults.
- Route Compose requests to llama only.
- Require `tabby-depth-1`.
- Add mode-aware availability for required model, engine, and optional Screen Recording usage.

Validation:

- Unit tests for PR comment, email reply, empty prefix, and selected text cases.
- Prompt snapshots for stable output shape.
- Normalizer tests for multiline drafts, labels, markdown fences, and quoted whole-response wrappers.
- Tests that autocomplete prompt output remains unchanged.

### Phase 4: Compose Generation And Preview

- Add active Compose session state.
- Generate on first `Tab` when Compose Mode has no ready draft.
- Show preview state instead of inline ghost tail.
- Cancel stale work with the existing work ID and generation checks.
- Preserve existing autocomplete debounce behavior separately.

Validation:

- Tests for stale generation drop.
- Tests for mode-change cancellation.
- Tests for disabled-app and permission cancellation.

### Phase 5: Manual Draft Typing

- Type the whole Compose draft on explicit accept.
- Keep focus and context validation before typing starts.
- Add a typing controller that emits bounded synthetic text chunks.
- Stop queued typing on cancellation or stale focus.
- Add insertion strategy abstraction if multiline synthetic typing proves unreliable.
- Clear session after successful typing.
- Pass `Tab` through when no valid Compose draft exists.

Validation:

- Unit tests for valid typing path.
- Unit tests for stale focus prevention.
- Unit tests for pass-through behavior.
- Manual multiline typing tests in browser comments and native AppKit text fields.

## Testing Strategy

Prioritize pure logic first:

- `SuggestionSettingsModel` mode persistence and snapshots.
- `ComposeContextNormalizer`.
- `ComposePromptRenderer`.
- `ComposeTextNormalizer`.
- Request factory branching.
- Session acceptance rules.

Then test orchestration:

- Mode change cancels active autocomplete.
- Mode change cancels active compose.
- Compose unavailable state when required model is missing.
- Compose result is dropped if generation changes.
- Compose result is dropped if focus changes.
- Compose does not require Screen Recording for AX-only context.
- Compose requires Screen Recording only when optional screenshot/OCR context is enabled for that request.

Manual QA scenarios:

- GitHub PR comment with visible diff and previous comments.
- GitHub issue reply.
- Gmail reply.
- Slack or Discord thread reply.
- Notes app text field.
- Empty focused field with insufficient context.
- Secure/password fields remain blocked.
- Disabled app remains disabled.

## Risks

- AX traversal can collect irrelevant page chrome.
- AX traversal can be slow in large browser trees.
- Large prompts can exceed the llama context window.
- Full draft typing has higher user-visible risk than short autocomplete.
- Synthetic keyboard insertion may be unreliable for long multiline text.
- Forcing `tabby-depth-1` may surprise users who intentionally selected a faster model.

Mitigations:

- Use strict role filtering and context budgets.
- Keep Compose behind explicit mode selection.
- Require preview before typing starts.
- Use stale-focus checks before accepting.
- Add diagnostics for prompt size and context source.
- Preserve the user's prior autocomplete model selection when leaving Compose Mode.

## Open Questions

- Should Compose Mode eventually support a temporary one-shot command in addition to global mode?
- Should first `Tab` generate and second `Tab` type, or should generation happen proactively after typing?
- Should Compose support selected text as an instruction target in v1, or block selection like autocomplete?
- What is the maximum draft length before stronger confirmation or slower typing cancellation controls are needed?
- Should Compose be limited to known writing apps at first?
- Should Apple Intelligence support Compose later, or should Compose remain local llama-only?
- How much GitHub-specific structure should the context normalizer preserve?

## Recommended First Slice

Implement Phase 1 and Phase 2 first.

Why:

- Issue #67 needs shared mode state before any prompt or typing work can stay clean.
- The AX tree walker is the highest-uncertainty technical risk.
- Building the mode foundation and context collector first gives real data for prompt design without touching typing behavior yet.

After that, Phase 3 can define the Compose prompt and evaluate `tabby-depth-1` output quality before enabling manual draft typing.

