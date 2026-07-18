# Context, Privacy, and Permissions

## Purpose

This guide inventories what Cotabby can observe, how each context source is bounded before
generation, which macOS permissions authorize the work, and when data can leave the Mac. Privacy is
an architectural constraint rather than a marketing label: every new context source needs an owner,
a permission boundary, a lifetime, a prompt budget, and a truthful disclosure for the selected
engine.

## Context Flow

One request can combine several independently enabled sources:

~~~text
focused field
  -> bounded preceding and trailing AX text
  -> app, window, domain, placeholder, and surface metadata
  -> optional user-authored rules and extended context
  -> optional relevant clipboard description
  -> optional screenshot-derived OCR excerpt
  -> language and prediction settings
  -> sanitization and per-section budgets
  -> immutable SuggestionRequest
  -> selected generation engine
~~~

[SuggestionRequestFactory.swift](../../Cotabby/Support/Suggestion/SuggestionRequestFactory.swift) is the final
assembly boundary. It receives values already acquired by their owning services; it does not capture
the screen, read the pasteboard, query AX, or open credentials itself.

## Required and Optional Permissions

[PermissionManager.swift](../../Cotabby/Services/Permission/PermissionManager.swift) publishes three
TCC grant states:

- Accessibility is required to discover the focused editable element, read bounded text and
  selection state, resolve geometry, validate acceptance, and perform some insertion fallbacks.
- Input Monitoring is required to observe global keyboard input and intercept accepted keys.
- Screen Recording is optional and used only for screenshot-derived visual context.

Core autocomplete requires Accessibility and Input Monitoring. Missing Screen Recording does not
disable text-only suggestions; visual context reports an explicit unavailable state and the rest of
the pipeline continues.

PermissionManager refreshes when Cotabby becomes active and uses a short polling loop only while a
required grant is missing. Once the required set is granted, it avoids a permanent permission poll.

[PermissionGuidanceController.swift](../../Cotabby/Services/Permission/PermissionGuidanceController.swift)
owns how the user is guided through System Settings. It first invokes the native request API so
macOS registers the current signed application identity, then opens or overlays the relevant privacy
pane. Views ask for guidance; they do not implement TCC flow logic.

The production and development application identities are intentionally distinct. A permission
grant belongs to the code identity macOS sees, so changing target identity, signing, or install path
can legitimately require a new grant.

## Secure and Unsupported Fields

[SecureFieldDetector.swift](../../Cotabby/Support/Accessibility/SecureFieldDetector.swift) centralizes detection
signals across native and non-native AX surfaces. A detected secure field receives blocked capability,
which prevents prediction, prompt construction, presentation, acceptance, and inline emoji or macro
capture. Surface metadata and field-style probes are also skipped.

The current acquisition boundary is less strict than the assistance boundary. FocusSnapshotResolver
reads and bounds the field value, constructs FocusedInputSnapshot, and then returns the blocked
capability with that context still attached. SuggestionAvailabilityEvaluator also calls visual
capture with capability checking disabled; its code explicitly treats secure fields like other
transient blocked states so screenshot/OCR can warm early.

That visual excerpt cannot enter an engine request because prediction remains blocked. However, the
screenshot and OCR still occur when Screen Recording and visual context are enabled, and explicit
debug mode can write the screenshot/OCR pair to disk. Therefore the accurate current guarantee is
"secure fields are never assisted or sent to an engine," not "secure fields are never captured."
Moving the secure check ahead of AX value construction and visual eligibility would be the path to
the stronger privacy invariant.

Read-only, incompatible, explicitly disabled, or terminal surfaces are handled by capability and
availability policy. Disabling an application also prevents expensive compatibility walks where
possible, reducing both observation and the chance of disturbing a fragile AX tree.

## Focused Text

[FocusSnapshotResolver.swift](../../Cotabby/Services/Focus/FocusSnapshotResolver.swift) bounds text on
both sides of the caret before publication. This prevents a large document from propagating through
Combine state, signatures, logs, or request construction. SuggestionRequestFactory applies a smaller
engine-specific prefix budget later.

Trailing text is retained only as much as Cotabby needs to avoid duplicating content after the caret
and to validate that a suggestion still belongs at the same seam. It is not an invitation to copy an
entire document into the prompt.

## Surface Context

[SurfaceContextComposer.swift](../../Cotabby/Support/Context/SurfaceContextComposer.swift) turns optional
application, window, browser-domain, placeholder, role, and surface metadata into a short descriptive
section. [SurfaceContextCache.swift](../../Cotabby/Services/Focus/SurfaceContextCache.swift) avoids
re-querying focus-session invariants on every poll.

Surface metadata helps distinguish an email reply, browser editor, chat field, or document surface
without injecting an AX tree dump. Missing attributes remain absent; Cotabby does not fabricate
semantic certainty from a generic role.

## User Context and Rules

Extended context and custom writing rules are explicitly authored or enabled by the user. They are
sanitized and character-budgeted as optional prompt sections. These sections condition output but do
not outrank the recent caret prefix when prompt space is scarce.

Rules, languages, and settings are durable non-secret preferences stored through
SuggestionSettingsStore. SuggestionSettingsData groups those values by product domain in memory,
while the store preserves the established flat UserDefaults keys for compatibility. Endpoint bearer
tokens are different: they are secrets and live in Keychain.

## Clipboard Context

[ClipboardContextProvider.swift](../../Cotabby/Services/Context/ClipboardContextProvider.swift)
reads a fresh bounded description only when the coordinator is building context. It does not publish
or retain a continuous clipboard history. Text is normalized; images and image files become compact
metadata descriptions rather than raw pixel prompt payloads.

[ClipboardRelevanceFilter.swift](../../Cotabby/Support/Context/ClipboardRelevanceFilter.swift) prevents an
unrelated pre-existing clipboard from entering every request. It tracks pasteboard identity and
recentness, requires meaningful token overlap with the current prefix for longer content, and pins an
accepted relevance verdict to the active field so normal typing does not make context flicker.

[ClipboardContentDistiller.swift](../../Cotabby/Support/Context/ClipboardContentDistiller.swift) keeps short
content intact and extracts overlapping lines from longer content. If no useful line can be found,
it falls back to a bounded head rather than carrying an unbounded clipboard dump.

Clipboard context and clipboard-based insertion are separate concerns. Disabling clipboard prompt
context does not disable the IME-safe insertion fallback, which touches the pasteboard transiently and
restores the user's representations.

## Visual Context Lifecycle

[VisualContextCoordinator.swift](../../Cotabby/Services/Visual/VisualContextCoordinator.swift) owns
one field-scoped visual session. On a supported focus it:

1. Coalesces rapid focus churn so Chromium and Electron settling does not launch duplicate work.
2. Checks whether visual context is enabled and Screen Recording is granted; capability is currently
   ignored here, including secure-field capability.
3. Creates a session ID tied to the focused input.
4. Runs screenshot and OCR work asynchronously.
5. Applies the excerpt only if the session is still current.
6. Keeps the result through ordinary typing in the same field.
7. Cancels and clears it when focus continuity ends.

Status is explicit: disabled, waiting, capturing, extracting text, ready, unavailable, or failed.
Missing optional permission is therefore distinguishable from an OCR failure and from a feature the
user turned off.

## Screenshot to OCR

[WindowScreenshotService.swift](../../Cotabby/Services/Visual/WindowScreenshotService.swift) uses
ScreenCaptureKit to select the visible window belonging to the focused process and capture a compact
region around the input. It excludes desktop windows and converts coordinate systems at the capture
boundary.

[ScreenTextExtractor.swift](../../Cotabby/Services/Visual/ScreenTextExtractor.swift) runs Apple Vision
OCR and carries recognition confidence per line. [OCRTextHygiene.swift](../../Cotabby/Support/Context/OCRTextHygiene.swift)
then removes low-confidence lines, replacement characters, symbol-heavy noise, likely UI chrome,
digit-corrupted prose, and lines that echo the field's own text.

[ScreenshotContextGenerator.swift](../../Cotabby/Services/Visual/ScreenshotContextGenerator.swift)
normalizes, sanitizes, checks meaningful signal, and applies a final excerpt cap. It caches a few raw
OCR extractions by sampled pixel hash, but reruns hygiene and field-text stripping on each use.

There is no model summarization step. The prompt receives cleaned, bounded OCR text. This avoids a
second generation, avoids summary hallucination, and lets a base completion model condition on the
visible language directly. Raw screenshots never enter the suggestion prompt.

## Prompt Sanitization and Budgets

[PromptContextSanitizer.swift](../../Cotabby/Support/Context/PromptContextSanitizer.swift) normalizes optional
context and caps it before rendering. BaseCompletionPromptRenderer applies per-section budgets again
when assembling the final continuation prompt.

The two layers serve different purposes: acquisition boundaries prevent oversized values from
circulating through the app, while prompt budgets decide which already-safe sections fit in this
particular request. No context source should rely only on a last-minute total-string truncation.

## Where Data Is Processed

Apple Intelligence and the in-process llama engine perform suggestion generation on the Mac. The
visual pipeline also uses local ScreenCaptureKit and Vision APIs.

The OpenAI-compatible engine sends the constructed request to the endpoint the user configured. A
loopback Ollama address stays on the Mac, a LAN address sends it across the local network, and a
public HTTPS address sends it to that remote service. Endpoint privacy classification and settings UI
must communicate that distinction. Insecure public HTTP is rejected.

Model discovery/downloads and update checks can use the network, but those operations are separate
from sending focused text for generation. Adding any hosted generation dependency or telemetry path
requires an explicit product decision and documentation update.

## Secrets and Persistence

- Non-secret settings persist in UserDefaults through SuggestionSettingsStore.
- Endpoint bearer tokens persist in the user's Keychain.
- Focus snapshots, clipboard context, visual excerpts, and active requests are memory-scoped values.
- Visual OCR cache entries are small in-memory extractions bounded to a few pixel hashes.
- No normal product path maintains a document, clipboard, screenshot, or prompt history database.

## Diagnostics Are a Privacy Mode

Normal operation sends structured events to Apple's unified logging. Launching with
-cotabby-debug intentionally enables privacy-sensitive local artifacts for development:

- ~/Library/Logs/Cotabby/cotabby.jsonl for structured events
- ~/Library/Logs/Cotabby/llm-io.jsonl for full prompts and completions
- ~/Desktop/cotabby-ax-dump.txt for the latest Chrome AX tree snapshot
- ~/Desktop/cotabby-debug-screenshots/ for bounded retained screenshot/OCR pairs

The LLM-I/O records share request IDs with the main stream. Visual debug captures are retained only
under the explicit debug gate and pruned per application. Anyone collecting a bug report must treat
these artifacts as potentially containing user text and screen content.

## Invariants

- Secure fields never schedule generation, presentation, acceptance, or inline-command capture.
- Current AX and visual acquisition can still run before/around the secure capability block; this is
  a documented privacy limitation, not a no-capture guarantee.
- Accessibility and Input Monitoring gate core autocomplete; Screen Recording remains optional.
- Every text source is bounded before request assembly.
- Optional sections are sanitized and budgeted independently.
- Clipboard context is relevance-filtered and is not a continuous history.
- A visual excerpt belongs to one field-scoped session and stale work cannot apply.
- Visual context uses cleaned OCR, never raw screenshots or model-generated summaries.
- On-device and configured-endpoint generation are disclosed as different privacy scopes.
- Endpoint secrets live in Keychain.
- Privacy-sensitive files exist only when the developer explicitly launches debug mode.

## Failure-Oriented Reading

- Suggestions run with a missing required grant: PermissionManager and availability evaluation.
- Password field receives a ghost, generation request, or command capture: secure detection and
  focus capability.
- Requirement is that secure fields are never captured at all: current focus-value and visual-context
  acquisition must be changed; the existing block applies later.
- Clipboard text appears unrelated: relevance identity, overlap, and field pinning.
- Visual context follows the previous field: session ID and focus-scoped apply guard.
- Screenshot context is noisy: OCR confidence, hygiene order, and prompt sanitizer.
- Screen Recording denial disables all suggestions: required-versus-optional permission policy.
- Public endpoint has no warning: endpoint scope classification and settings presentation.
- Prompt content appears on disk unexpectedly: CotabbyDebugOptions bootstrap and launch arguments.

## Update This Guide When

Update this document whenever Cotabby observes a new data source, changes a permission requirement,
changes secure-field policy, adds a persistent cache, changes endpoint behavior, writes a new debug
artifact, or alters a context budget or lifetime.
