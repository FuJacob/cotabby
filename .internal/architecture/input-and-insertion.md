# Input and Insertion

## Purpose

This guide explains how Cotabby observes global input, temporarily intercepts only the keys it owns,
and commits accepted text into another application. This is a process-wide boundary: mistakes can
drop user keystrokes, feed Cotabby's synthetic events back into its own state machine, or disturb the
user's clipboard. The design therefore separates observation, consumption, suppression, policy, and
insertion.

## Main Files

Read these files in order:

1. [InputMonitor.swift](../../Cotabby/Services/Input/InputMonitor.swift)
2. [InputSuppressionController.swift](../../Cotabby/Services/Input/InputSuppressionController.swift)
3. [SuggestionInserter.swift](../../Cotabby/Services/Suggestion/SuggestionInserter.swift)
4. [InsertionStrategySelector.swift](../../Cotabby/Support/Suggestion/InsertionStrategySelector.swift)
5. [InsertionSafetyGate.swift](../../Cotabby/Support/Suggestion/InsertionSafetyGate.swift)

InputMonitor owns event-tap lifetime and converts Core Graphics keyboard events into semantic
CapturedInputEvent values. SuggestionInserter owns the write boundary. The two pure Support policies
decide whether insertion is safe and which mechanism is appropriate without touching global state.

## Three Event-Tap Responsibilities

InputMonitor deliberately does not use one permanently consuming event tap.

~~~text
steady listen-only observer
  -> classify ordinary typing, deletion, navigation, and pointer activity

conditional consuming tap
  -> active only while a suggestion or inline-command capture needs interception
  -> consume only an event the owning coordinator successfully handles

dedicated global-toggle tap
  -> active only when the shortcut is configured
  -> decide the process-wide toggle independently of suggestion visibility
~~~

The observer tap is installed at the head of the event chain with listen-only behavior. It can see
events without delaying the focused application or swallowing a key. This is the steady-state path.

The conditional tap is a default tap because returning nil is the only way to keep an accepted key
from also reaching the host. It is installed only when a visible suggestion claims acceptance keys
or when the emoji picker has an active capture. All unrelated keys pass through unchanged.

The global-toggle shortcut has a separate consuming tap. Its ownership does not depend on an active
suggestion, and separating it prevents suggestion tap lifetime from changing whether the global
shortcut works.

## Fail-Open Consumption

Matching a configured key is not sufficient reason to swallow it. The consuming tap first asks the
current owner to handle the event. It returns nil only when acceptance or capture succeeds. A stale
tap, vanished overlay, changed focus, revoked permission, or rejected session causes the original key
to pass through to the focused application.

Word/phrase acceptance and full-tail acceptance have independent configurable key and modifier
bindings. Full acceptance takes priority if the bindings overlap. The event is classified using the
current settings at event time so changing a shortcut does not require rebuilding all tap behavior.

After a final acceptance hides the overlay, the accept tap lingers for a very short deferred teardown.
The callback that consumed the physical key may still be posting synthetic insertion events. Removing
its mach port immediately can prevent the last accepted chunk from reaching the host. The delayed
teardown rechecks whether a suggestion or capture has re-armed the tap before removing it.

Exhausting a tail also creates a bounded regeneration window in which a rapid follow-up Tab should
not leak into the host and move focus. PostExhaustionAcceptanceState owns the pure arm, queue,
consume, and timeout-generation rules. Repeated presses collapse to one queued accept; the
coordinator owns the timer and interception side effects and returns the key to the host when the
window expires or the session tears down.

## Inline-Command Capture

Emoji capture shares the conditional tap but not suggestion acceptance semantics. While a colon
query is active, the emoji controller decides whether navigation, dismissal, or commit keys are
handled. The listen-only observer still routes the event to the coordinator, and the consuming tap
swallows it only after the emoji path reports success.

This ordering lets Tab remain a configurable suggestion accept key while also committing an emoji
selection during capture. InputMonitor knows which subsystem currently owns interception; it does not
implement emoji query or suggestion-session rules itself.

## Suppressing Cotabby's Own Events

[InputSuppressionController.swift](../../Cotabby/Services/Input/InputSuppressionController.swift)
prevents inserted text from being mistaken for fresh user typing. SuggestionInserter marks every
synthetic Core Graphics event with a Cotabby-specific source value and registers an expected event
burst before posting it.

The marker is the strongest identity check. The bounded suppression countdown is a compatibility
fallback for event transformations that do not preserve every property. It accumulates across rapid
acceptances because global event delivery is asynchronous; overwriting the count could expose the
tail of an earlier insertion as apparent user input.

Suppression is intentionally narrow and expires. It must not hide real typing after an insertion or
become a general pause in focus reconciliation.

## Pre-Insertion Safety

The coordinator validates the active session, overlay, focus, and current text before asking for a
write. InsertionSafetyGate provides the pure final checks for the proposed chunk. Invalid or unsafe
text is rejected before an event is posted.

This boundary does not assume that generation success authorizes insertion. The user may have moved
the caret, selected text, switched applications, or edited the field after the suggestion became
visible.

## Default Unicode Keystroke Path

For the common short, single-line continuation, SuggestionInserter posts a Unicode key-down/key-up
pair through Core Graphics. This path is app-agnostic and does not touch the clipboard. It also avoids
relying on an application's support for direct Accessibility value mutation.

The events use a placeholder virtual key because the committed payload is carried as Unicode text.
That detail is why the synthetic marker matters: a user could bind acceptance to the same key code,
and Cotabby must never consume its own insertion as another acceptance.

## IME-Safe and Optional Paste Paths

Synthetic Unicode events can be intercepted as composing input while an input method editor is
active. In that state, SuggestionInserter commits through a clipboard paste so accepted Japanese,
Chinese, or other composed text lands as final text rather than being fed back into composition.

There is also a default-off paste strategy for long or multiline suggestions. When enabled,
InsertionStrategySelector chooses paste for multiline text or chunks at least 80 characters long.
Short ordinary completions remain on the clipboard-free Unicode path.

The paste path:

1. Snapshots every representation of every item on the general pasteboard.
2. Replaces the pasteboard temporarily with the accepted plain text.
3. Tries the target application's Accessibility Edit > Paste menu action first.
4. Falls back to a synthetic Command-V when the menu item cannot be pressed.
5. Restores the saved clipboard after the host has had time to service the paste.

Pressing the actual Paste menu item is important for applications such as Chrome, where a synthetic
Command-V posted from the global tap callback can fail while a physical accept key is still down.
The menu item is cached per process only after its AXPress result is validated.

Clipboard restoration is change-count aware. If the user or another application changes the
clipboard before restoration, Cotabby leaves the newer contents alone. Overlapping paste insertions
reuse the one saved user clipboard instead of accidentally snapshotting Cotabby's previous completion
and restoring that to the user.

## Replacement Writes

A normal suggestion inserts a continuation at the caret. A spelling-correction or inline-command
session can instead replace a known literal run. The inserter posts the required deletion burst and
then the replacement text under the same suppression boundary.

Replacement length is derived from the validated session, not from a new untrusted scan at write
time. The coordinator still reconciles the host's later AX publication because posting events proves
only that Cotabby requested the mutation, not that every application applied it exactly as expected.

## Permissions and Recovery

Input Monitoring permission governs global event observation. Accessibility is also required for
focus validation and for the preferred paste-menu action. If taps are disabled by timeout or user
input, InputMonitor re-enables them where safe. If permission is revoked, the consuming tap is torn
down and later recreated only after the permission state allows it.

No recovery path may leave a dead consuming tap installed. A tap that cannot confidently handle an
event must pass it through.

## Invariants

- Steady-state observation is listen-only.
- A key is consumed only after the owning feature reports success.
- Post-exhaustion Tab ownership is bounded, generation-keyed, and can queue at most one accept.
- The consuming suggestion/capture tap exists only while interception is needed.
- Global toggle ownership is independent of suggestion visibility.
- Every synthetic event is tagged and covered by bounded self-event suppression.
- Short ordinary completions use the clipboard-free Unicode path.
- IME-active insertion uses a commit mechanism that bypasses composition.
- Paste restores all saved pasteboard representations unless newer clipboard activity wins.
- Insertion never trusts a generation result without revalidating the live session.
- Host publication after insertion is reconciled rather than assumed.

## Failure-Oriented Reading

- Acceptance key is swallowed with no visible suggestion: fail-open authorization in InputMonitor.
- Accepted text triggers another prediction as typing: synthetic marker and suppression accounting.
- Final accepted chunk disappears: deferred accept-tap teardown and event posting.
- Rapid Tab moves host focus after the visible tail ends: post-exhaustion acceptance window and
  backstop generation.
- Tab commits the suggestion instead of emoji: capture ownership and accept-tap resolution order.
- IME acceptance regenerates or enters composition: active-input-source detection and paste path.
- Clipboard contains a completion afterward: snapshot, overlap, change-count, and restore logic.
- Chrome ignores paste: AX Paste menu lookup before Command-V fallback.
- Correction removes the wrong characters: replacement session validation and deletion count.

## Update This Guide When

Update this document when an event tap gains a new ownership reason, acceptance bindings change
semantics, suppression identity changes, a new insertion strategy is added, clipboard restoration
policy changes, or another inline feature begins consuming global input.
