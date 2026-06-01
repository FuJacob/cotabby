# Polling, Debounce, and Hardcoded Delay Inventory

A living catalog of every hardcoded timing value in Cotabby: poll intervals,
debounce/throttle windows, sleeps, timeouts, and animation durations. The goal
is to make it cheap to audit CPU-hot loops and tune values without grepping
the whole tree.

Update this file whenever you add, remove, or change a timing constant.

## Focus and Accessibility

| Location | Value | Purpose |
|----------|-------|---------|
| `Cotabby/Services/Focus/FocusTracker.swift:41` (default from `SuggestionModels.swift:125`) | 50 ms | Base focus poll interval (AX tree walk). Backed off automatically by `FocusPollBackoff` up to ~800 ms during idle. Persisted values are capped at this default on load (`SuggestionSettingsModel.swift:231`) so anyone still on the old 80 ms default gets the speedup; the stepper is hidden from the UI today, so any persisted value is a previous default rather than a user choice. |
| `Cotabby/Services/Focus/FocusSnapshotResolver.swift:16` | 100 ms | Deep-walk throttle. Caps the expensive caret BFS used in Chromium-style contenteditable trees. |
| `Cotabby/App/Coordinators/SuggestionCoordinator+Input.swift:180` | 400 ms | Chromium AX-publish wait ceiling. Maximum time we wait for the host app to publish its updated contenteditable text after a keystroke before giving up on this prediction cycle. |
| `Cotabby/App/Coordinators/SuggestionCoordinator+Input.swift:185` | 30 ms | Host-publish poll interval (steady cadence). AX is requeried at this interval while waiting up to the 400 ms ceiling above. |
| `Cotabby/App/Coordinators/SuggestionCoordinator+Input.swift:191` | 10 ms | Host-publish first-retry interval. The immediate poll always misses (it runs before the host processes the key), so the first retry is short to catch fast native-app publishes; later retries use the 30 ms steady cadence. |
| `Cotabby/Support/FocusPollBackoff.swift:17` | 60 ticks | Idle capture cap for focus poll backoff. After this many unchanged polls the stride saturates. |

## Suggestion Pipeline

| Location | Value | Purpose |
|----------|-------|---------|
| `Cotabby/Models/SuggestionModels.swift:103` | 20 ms | Default suggestion debounce. Persisted values are capped to this default on load (`SuggestionSettingsModel.swift:222`) so a default lowering reaches existing installs; the stepper is hidden from the UI today, so any persisted value is a previous default rather than a user choice. Clamped to [10, 500]. |
| `Cotabby/Services/Suggestion/SuggestionWorkController.swift:32` | (configured) | Converts the user debounce setting from ms to nanoseconds for `Task.sleep`. |

## Acceptance and Input

| Location | Value | Purpose |
|----------|-------|---------|
| `Cotabby/App/Coordinators/SuggestionCoordinator+Acceptance.swift:354` | 30 ms | Post-insertion refresh delay. Gives the host app time to process the synthetic keystroke before we snap the overlay caret to the new position. |
| `Cotabby/Services/Input/InputMonitor.swift:137` | 50 ms | Accept-tap teardown delay. Defers mach-port invalidation so a final-chunk accept's synthetic keystroke can drain before the tap is removed. |

## Visual Context

| Location | Value | Purpose |
|----------|-------|---------|
| `Cotabby/Services/Visual/VisualContextCoordinator.swift:29` | 250 ms | Session-start settle delay. Debounces visual context capture on focus change so a flapping Chromium focus doesn't retrigger screenshots and OCR. |

## Permissions

| Location | Value | Purpose |
|----------|-------|---------|
| `Cotabby/Services/Permission/PermissionManager.swift:24` | 2.0 s | Permission polling interval. Periodic refresh of system permission state (Accessibility, screen recording, input monitoring) since macOS doesn't notify on grant. |
| `Cotabby/Services/Permission/PermissionGuidanceController.swift:105` | 300 ms | Overlay tracking timer. Polls overlay window position during the guided permission flow. |
| `Cotabby/Services/Permission/PermissionOverlayWindowController.swift:14-15` | 720 ms / 0.72 | Permission overlay launch animation duration and response curve parameter. |

## Networking, Runtime, Utilities

| Location | Value | Purpose |
|----------|-------|---------|
| `Cotabby/Services/Utilities/HuggingFaceAPIClient.swift:74` | 15 s | HuggingFace API request timeout (model search/fetch). |
| `Cotabby/App/Core/AppDelegate.swift:161` | 1.5 s | Llama runtime graceful shutdown timeout before force-kill. |
| `Cotabby/Support/ClipboardRelevanceFilter.swift:23` | 5 min | Clipboard staleness threshold. Clipboard content older than this is not injected into the prompt. |

## Tuning Notes

The hottest loops, ordered by CPU impact:

1. **Host-publish poll** inside the 400 ms Chromium ceiling: a 10 ms first
   retry (the immediate poll always misses, so this catches fast native-app
   publishes) then a 30 ms steady cadence. Raising the steady interval to
   50 to 60 ms roughly halves AX queries during the wait with minimal added
   latency; leave the short first retry alone.
2. **50 ms focus poll base** in `FocusTracker`. Already protected by
   `FocusPollBackoff` once idle, so this is the active-typing cadence.
3. **400 ms Chromium ceiling**. Raising it reduces the rate at which we give
   up on slow Chromium publishes, at the cost of longer worst-case latency
   when the host genuinely never publishes.
4. **100 ms deep-walk throttle**. Protects the expensive caret BFS in
   contenteditable trees. Safe to raise to ~150 ms.

When changing any of these, update both the constant and this table in the
same commit so the inventory stays accurate.
