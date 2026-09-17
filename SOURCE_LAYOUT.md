# Cotabby Source Layout

This document is the canonical placement map for production and test source files. It complements
`ARCHITECTURE.md`, which explains runtime ownership and data flow.

Swift folders do not create namespaces. Every Swift file discovered under `Cotabby/` still compiles
into the application module, and every file under `CotabbyTests/` compiles into the test module.
Folders exist so a maintainer can predict where a responsibility lives before searching.

## Placement Rules

1. Choose the top-level architectural boundary first: `App`, `UI`, `Services`, `Models`, or
   `Support`.
2. Choose the product subsystem next, such as `Suggestion`, `Focus`, `Runtime`, or `Settings`.
3. Keep a small cohesive subsystem flat.
4. Add a child folder only when at least two files form a stable responsibility with a predictable
   name. Do not create one-file folders merely to shorten a file list.
5. Put a direct unit test under the corresponding `CotabbyTests/` responsibility. Cross-cutting
   coordinator tests may remain grouped by the coordinator they exercise.
6. Folder moves must not change Swift access control, runtime ownership, or target membership.
   XcodeGen discovers the new paths; regenerate `Cotabby.xcodeproj` after moving files.

## Production Tree

~~~text
Cotabby/
├── App/
│   ├── Core/                         process entry, composition root, lifecycle
│   └── Coordinators/
│       ├── InlineFeatures/           emoji/macro capture arbitration
│       ├── Suggestion/               autocomplete interaction state machine
│       ├── SettingsCoordinator.swift
│       └── WelcomeCoordinator.swift
├── Models/
│   ├── Context/                      bounded context and visual-context values
│   ├── Emoji/                        picker and usage values
│   ├── Focus/                        focus snapshots and tracking state
│   ├── Input/                        keyboard event values
│   ├── Onboarding/                   onboarding templates
│   ├── Permissions/                  TCC permission values
│   ├── Runtime/
│   │   └── Metrics/                  performance and system metric stores
│   ├── Settings/                     durable and UI-facing settings values
│   ├── Spelling/                     spelling catalog values
│   └── Suggestion/
│       ├── Request/                  immutable request inputs and configuration
│       ├── Result/                   engine result and client error values
│       └── Session/                  active, paused, and presented session values
├── Services/
│   ├── Context/                      live clipboard acquisition
│   ├── Focus/
│   │   ├── Caching/                  field-scoped focus and surface caches
│   │   ├── Chromium/                 Chromium AX enablement and diagnostics
│   │   └── Resolution/               focus snapshots, geometry, bounded AX walks
│   ├── Input/                        event taps and input-source monitoring
│   ├── ModelManagement/              model discovery, download, and validation
│   ├── Permission/
│   │   └── Guidance/                 permission overlay and System Settings guidance
│   ├── Power/                        power-source observation
│   ├── Presentation/                 process-level AppKit panels and indicators
│   ├── Runtime/
│   │   ├── AppleIntelligence/        Foundation Models availability and engine
│   │   ├── Llama/                    llama engine, manager, and native core
│   │   └── OpenAICompatible/         endpoint transport, credentials, and engine
│   ├── Spelling/                     live spell-checking services
│   ├── Suggestion/
│   │   └── State/                    work identity and mutable interaction state
│   ├── Updates/                      Sparkle update integration
│   └── Visual/                       capture, OCR, and visual-context sessions
├── Support/
│   ├── Accessibility/                pure AX and secure-surface policies
│   ├── Context/                      sanitization, relevance, and OCR hygiene
│   ├── Emoji/
│   │   ├── Catalog/                  searchable catalog and synonyms
│   │   ├── Interaction/              query, trigger, picker, and variant rules
│   │   └── Ranking/                  recency and popularity rules
│   ├── Focus/
│   │   ├── Applications/             app, browser, domain, and terminal classification
│   │   └── Capability/               supported-field capability resolution
│   ├── Input/                        composition, key-label, and selection helpers
│   ├── Logging/                      debug options, request IDs, and JSONL handlers
│   ├── Macros/
│   │   └── Evaluators/               deterministic arithmetic/date/unit evaluators
│   ├── Onboarding/                   pure onboarding recommendation rules
│   ├── Presentation/
│   │   ├── Geometry/                 caret, anchor, direction, and overlay layout
│   │   ├── Policy/                   render-mode, fade, and stability decisions
│   │   └── Style/                    ghost text font and color rules
│   ├── Prompting/                    Apple and base-model prompt rendering
│   ├── Runtime/
│   │   ├── Hardware/                 device capability and resource sampling
│   │   ├── BundledRuntimeLocator.swift
│   │   ├── DecodeStopPolicy.swift
│   │   ├── DownloadOutcomeClassifier.swift
│   │   └── TokenHealingBuffer.swift  exact byte replay and lossless streamed UTF-8
│   ├── Settings/                     persistence and settings policies
│   ├── Spelling/                     extraction, language, SymSpell, and typo rules
│   ├── Suggestion/
│   │   ├── Acceptance/               insertion safety and strategy
│   │   ├── Output/                   normalization, confidence, and seam cleanup
│   │   ├── Request/                  availability, debounce, and request construction
│   │   ├── Session/                  tail reconciliation and exhausted-tail state
│   │   └── Streaming/                partial coalescing, monotonic text, presentation timing
│   └── Utilities/                    small cross-subsystem value helpers
└── UI/
    ├── Components/                   application-wide reusable views
    ├── InlineFeatures/               emoji picker and macro reference surfaces
    ├── MenuBar/                      menu-bar status and popover content
    ├── Onboarding/
    │   └── Welcome/                  composed welcome flow and step views
    ├── Overlays/                     SwiftUI overlay content
    └── Settings/
        ├── Components/
        │   ├── Controls/              settings editors, pickers, and previews
        │   └── Structure/             pane scaffolds, rows, cards, and search results
        ├── ModelManagement/           model catalog and browser views
        └── Panes/
            ├── About/                 product and acknowledgement panes
            └── Engine/                engine pane and backend-specific extensions
~~~

Files left directly inside a subsystem are intentionally its root owners or a small cohesive set.
For example, `SuggestionEngineRouter.swift` remains at `Services/Runtime/` because it coordinates all
three backend folders, while `FocusTracker.swift` remains at `Services/Focus/` because it owns the
whole focus lifecycle rather than one resolution or caching technique.

## Test Tree

`CotabbyTests/` mirrors the production responsibility after removing the leading `Cotabby/`. For
example:

~~~text
Cotabby/Support/Suggestion/Output/SuggestionTextNormalizer.swift
CotabbyTests/Support/Suggestion/Output/SuggestionTextNormalizerTests.swift

Cotabby/Services/Runtime/Llama/LlamaSuggestionEngine.swift
CotabbyTests/Services/Runtime/Llama/LlamaSuggestionEngineStreamingTests.swift

Cotabby/App/Coordinators/Suggestion/SuggestionCoordinator.swift
CotabbyTests/App/Coordinators/Suggestion/SuggestionCoordinatorPredictionTests.swift
~~~

Tests that exercise several production values may stay at the nearest shared subsystem root. Evals
remain under `CotabbyTests/Evals`, and shared fixtures remain under `CotabbyTests/TestSupport`.

## Unfinished-Word Interaction

- `Support/Suggestion/Request/CaretWordContext.swift` distinguishes a still-typed token from a
  delimiter-committed word. `TypoGate` and the correction replacement planner consume this value;
  pausing alone never makes correction eligible.
- `Support/Suggestion/Output/CompletionSeamGuard.swift` returns the same presentation decision for
  streamed and final output: wait for the first word, reject a malformed join, show a word ending,
  or show a phrase. Dictionary membership is evidence, not a requirement for names and jargon.
- `Support/Spelling/WordPrefixIndex.swift` supplies immutable exact-prefix candidates and bounded
  document/glossary vocabulary. `SymSpellCorrector` builds its index on the existing background
  dictionary queue; fallback never uses spelling edit distance or changes typed letters.
- `Support/Suggestion/Streaming/TypingCadence.swift` measures recent inter-letter intervals and
  controls presentation timing independently of generation debounce. `SuggestionStreamingState`
  memoizes exact-word checks and closes the stream when a final result arrives.
- `Support/Suggestion/Session/SuggestionDismissalMemory.swift` remembers explicit dismissal for at
  most 15 seconds in the same field and text context. It is bounded and never persisted.
- `App/Coordinators/Suggestion/SuggestionCoordinator+WordCompletion.swift` adapts these pure values
  to the existing spell checker, dictionaries, settings, and cancellable presentation work.

Direct tests mirror those folders. `SuggestionCoordinatorWordCompletionTests` replays pauses after
individual letters, malformed streams, fallback acceptance, dismissal/cache behavior, and cancellation
against the actual coordinator with synthetic OS and engine boundaries. The phrase accuracy replay
uses the committed typo gate and final display policy, but deliberately excludes local fallback so
its score remains attributable to the model. Timing replay and coordinator interaction tests cover
presentation and acceptance separately; model-only scores do not represent the complete experience.

## Adding Or Moving A File

1. Identify its single dominant responsibility using the map above.
2. Place or move its direct tests with it conceptually.
3. Update tracked Markdown links and any scripts containing physical paths.
4. Run `xcodegen generate` and commit the regenerated project.
5. Run SwiftLint, a build, and `build-for-testing` before opening a pull request.

When a file seems to fit several folders, that usually signals either a cross-subsystem contract
that belongs in `Models`, a root orchestrator that should remain above its collaborators, or a type
that owns too many responsibilities and should be split by behavior rather than hidden by nesting.
