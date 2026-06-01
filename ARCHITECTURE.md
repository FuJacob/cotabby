# Cotabby Architecture

This document is the maintainer map for Cotabby. Read this before making changes to the suggestion
pipeline, Accessibility integration, or runtime lifecycle.

If you are new to Swift or macOS APIs, treat this file as the system-level map and follow the
linked source files in order rather than hunting through the project tree at random.

## System Shape

Cotabby is a macOS menu bar app with one long-lived dependency graph and one main product loop:

1. Resolve the currently focused editable field through Accessibility.
2. Watch keyboard input globally.
3. Decide whether a suggestion should be requested.
4. Ask the local llama runtime for a continuation.
5. Render ghost text near the caret.
6. Reconcile live typing against the active suggestion session.
7. Insert accepted text back into the host app when the user presses `Tab`.

The key design rule is separation by responsibility:

- `Cotabby/App/`: lifecycle owners and composition root.
- `Cotabby/UI/`: SwiftUI presentation only.
- `Cotabby/Services/`: side effects, async work, and OS/runtime boundaries.
- `Cotabby/Models/`: shared value types and contracts.
- `Cotabby/Support/`: pure rules and low-level bridging helpers.

## Lifecycle Ownership

Start with these files in order:

1. `Cotabby/App/Core/CotabbyApp.swift`
2. `Cotabby/App/Core/AppDelegate.swift`
3. `Cotabby/App/Core/CotabbyAppEnvironment.swift`

`CotabbyAppEnvironment` builds the long-lived object graph once. `AppDelegate` owns app lifecycle and cross-subsystem subscriptions. SwiftUI views observe those objects; they do not create them.

This is similar to a React app with a root provider tree plus a small top-level controller that wires subscriptions and startup behavior.

## Suggestion Pipeline

The suggestion subsystem is centered on `SuggestionCoordinator`, but it is no longer intended to be read as one giant file.

Read the coordinator in this order:

1. `Cotabby/App/Coordinators/SuggestionCoordinator.swift`
2. `Cotabby/App/Coordinators/SuggestionCoordinator+Lifecycle.swift`
3. `Cotabby/App/Coordinators/SuggestionCoordinator+Input.swift`
4. `Cotabby/App/Coordinators/SuggestionCoordinator+Prediction.swift`
5. `Cotabby/App/Coordinators/SuggestionCoordinator+Acceptance.swift`

The coordinator owns:

- published UI/debug state
- top-level orchestration
- debounce/generation task ownership through `SuggestionWorkController`
- active suggestion session ownership through `SuggestionInteractionState`
- overlay/insertion/logging decisions

The coordinator should not own pure decision rules or low-level OS logic. Those live elsewhere:

- `Cotabby/Support/SuggestionRequestFactory.swift`: pure request building
- `Cotabby/Support/SuggestionSessionReconciler.swift`: pure session and acceptance rules
- `Cotabby/Support/SuggestionAvailabilityEvaluator.swift`: pure gating logic
- `Cotabby/Services/Visual/VisualContextCoordinator.swift`: screenshot/OCR lifecycle; OCR text is cleaned by the pure `OCRTextHygiene` filters (no model-summarization step)
- `Cotabby/Services/Runtime/LlamaSuggestionEngine.swift`: prompt/result normalization over the runtime

## Focus And Accessibility

Focus detection is a small pipeline of its own:

1. `FocusTracker` polls on a timer.
2. `FocusSnapshotResolver` walks the AX tree and validates field capability.
3. `AXTextGeometryResolver` computes caret and text geometry.
4. `AXHelper` contains the low-level Core Foundation / Accessibility bridging.

If the issue is “Cotabby does not recognize this field” or “the ghost text is in the wrong place,” start in those files before touching the coordinator.

## Runtime And Models

The local model runtime is intentionally split:

- `LlamaRuntimeManager`: published bootstrap state and user-facing control flow
- `LlamaRuntimeCore`: serialized low-level runtime work
- `LlamaSuggestionEngine`: suggestion-specific normalization and error mapping

That split matters because runtime lifecycle concerns change at a different rate than prompt strategy or output cleanup.

## Safe Change Order

If you need to change behavior, prefer this order:

1. Pure logic in `Support/`
2. Service boundary behavior in `Services/`
3. Coordinator orchestration in `App/`
4. SwiftUI presentation in `UI/`

That order minimizes regression risk because the most deterministic code changes first and the most stateful code changes last.
