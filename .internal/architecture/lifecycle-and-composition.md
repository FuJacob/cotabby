# Lifecycle and Composition

## Purpose

This guide explains who creates Cotabby's long-lived objects, who starts and stops them, and why
views do not construct services. It is the first deep dive to read after the root architecture map.

Cotabby integrates with process-wide macOS facilities: Accessibility, global event taps, screen
capture, Sparkle, and an in-process native model runtime. Accidentally constructing two copies of
one of those services can produce duplicate observers, competing event taps, runtime reload races,
or two pieces of UI that disagree about current settings. The composition root exists to prevent
that class of bug.

## Primary Owners

The lifecycle is divided among three files:

1. [CotabbyApp.swift](../../Cotabby/App/Core/CotabbyApp.swift) declares the SwiftUI scene graph and
   bridges the AppKit delegate into the SwiftUI application.
2. [AppDelegate.swift](../../Cotabby/App/Core/AppDelegate.swift) owns process lifecycle callbacks,
   starts and stops services, and wires reactions that are specifically tied to application
   lifecycle.
3. [CotabbyAppEnvironment.swift](../../Cotabby/App/Core/CotabbyAppEnvironment.swift) constructs the
   dependency graph once and retains app-scoped subscriptions between the objects it created.

The split is intentional. Construction answers "which concrete objects satisfy the app's
dependencies?" Lifecycle answers "when may those objects begin side effects?" SwiftUI answers
"which state should be presented?" Keeping those questions separate makes ownership visible.

## Process Startup

CotabbyApp is the process entry point. It creates AppDelegate through NSApplicationDelegateAdaptor
and declares the MenuBarExtra scene. SwiftUI owns insertion and removal of the status item, while
SuggestionSettingsModel remains the durable source of truth for whether the icon is visible.

AppDelegate initialization performs synchronous graph construction:

~~~text
CotabbyApp
  -> AppDelegate.init
       -> CotabbyLogger.bootstrap
       -> CotabbyAppEnvironment.init
       -> expose shared environment objects to SwiftUI
       -> install cross-subsystem closures and subscriptions
~~~

Constructing the graph does not start global event processing. AppDelegate waits for
applicationDidFinishLaunching before it:

1. Applies the one-time Open at Login default.
2. Starts the llama runtime only when the selected engine requires it.
3. Starts focus polling.
4. Starts global input monitoring.
5. Starts the update manager.
6. Starts the suggestion coordinator.
7. Starts the inline-command coordinator.
8. Presents onboarding or permission reminders when needed.
9. Restores a visible Settings surface when the menu bar icon is hidden and launch policy requires
   recovery.

The XCTest host is a special case. App-hosted unit tests launch the real application binary before
loading the test bundle. AppDelegate detects that environment and skips production service startup
so tests do not install global taps, begin polling, launch Sparkle, or load a model as a side effect.

## The Environment Graph

CotabbyAppEnvironment is MainActor-isolated because most graph members publish UI state, call
AppKit, or access Accessibility. It constructs shared services in dependency order:

~~~text
settings and permission state
  -> input/focus services
  -> insertion and presentation services
  -> context services
  -> generation engines and router
  -> suggestion coordinator
  -> emoji and macro controllers
  -> settings/onboarding coordinators
~~~

Important shared instances include:

- PermissionManager and PermissionGuidanceController
- SuggestionSettingsModel
- LlamaRuntimeManager wrapped by RuntimeBootstrapModel
- ModelDownloadManager
- FocusTrackingModel and InputMonitor
- InputSuppressionController and SuggestionInserter
- OverlayController and ActivationIndicatorController
- ClipboardContextProvider and VisualContextCoordinator
- SuggestionEngineRouter with all generation backends
- SuggestionCoordinator, SuggestionInteractionState, and SuggestionWorkController
- EmojiPickerController, MacroController, and InlineCommandCoordinator
- SettingsCoordinator and WelcomeCoordinator

The environment passes narrow protocol-shaped collaborators into SuggestionCoordinator. This keeps
the coordinator testable without turning every concrete service into a global singleton.

## Where Subscriptions Live

Both the environment and AppDelegate retain Combine subscriptions. That is not accidental
duplication; the dividing line is ownership.

CotabbyAppEnvironment retains relationships among objects it constructed:

- Settings changes update the focus poll interval.
- Binding or clearing the global-toggle shortcut installs or removes its dedicated event tap.
- Power-source and profile changes select the appropriate engine and model.
- Selecting the endpoint engine triggers model discovery.
- Endpoint identity or credential changes invalidate connection state.

AppDelegate retains process-lifecycle reactions:

- Permission changes refresh input monitoring.
- Engine changes start or release the in-process llama runtime.
- Focus changes update activation and debug overlays.
- Settings changes hide the activation indicator when Cotabby becomes disabled or paused.
- Model-directory changes refresh available runtime models.
- Visual-context state is mirrored into the debug overlay.

CotabbyAppEnvironment itself must therefore be retained for the whole process. If it were a
temporary local variable in AppDelegate.init, its cancellables would deallocate and settings-driven
behavior would silently stop.

## Runtime Selection and Memory Ownership

The in-process llama runtime is warmed only when the selected engine is Open Source. Selecting Apple
Intelligence or an OpenAI-compatible endpoint stops the local runtime so mapped model weights and
Metal buffers are released. Model downloads or manual file changes trigger a rescan, followed by a
warmup only if the current engine needs llama.

Power-based profiles are applied in the environment. A profile can select Apple Intelligence,
an installed GGUF model, or an endpoint model. Applying a profile is idempotent so repeated
publisher emissions do not cause unnecessary model reloads.

## Shutdown

applicationWillTerminate reverses process-wide side effects:

1. Hide activation and debug overlays.
2. Stop suggestion and inline-command coordination.
3. Stop input monitoring.
4. Stop focus polling.
5. Synchronously release the native llama runtime with a bounded wait.

The synchronous native shutdown is a correctness requirement. Exiting while llama/Metal resources
remain alive can collide with C++ static destruction. At the same time, shutdown cannot defer
application termination indefinitely because macOS permission flows rely on a prompt quit and
relaunch to observe a new TCC grant.

## Settings and Presentation Ownership

SuggestionSettingsStore persists durable non-secret values in UserDefaults.
SuggestionSettingsModel keeps individually `@Published` properties for SwiftUI and source
compatibility. Its `domainSettings` projection builds a `SuggestionSettingsData` value grouped into
general, engine, completion, context, correction, presentation, inline-feature, and shortcut
domains. The projection does not duplicate storage or change publication timing.

SuggestionSettingsSnapshot is derived from those domains and remains the immutable behavior input
for the suggestion pipeline. SuggestionSettingsStore deliberately maps the domain values back to
the existing flat UserDefaults keys so the refactor does not migrate or invalidate persisted user
preferences. OpenAI-compatible credentials are kept in Keychain rather than UserDefaults.

Views observe shared models or receive callbacks from coordinators. They do not instantiate focus,
input, runtime, permission, download, or update services. AppKit window controllers are likewise
constructed at app scope when their lifetime must outlive a SwiftUI view redraw.

## Invariants

- There is one production instance of each process-wide observer, tap, coordinator, and runtime.
- Construction does not imply startup; AppDelegate controls when side effects begin.
- SwiftUI view reconstruction must not reconstruct services.
- The environment remains retained as long as its subscriptions are needed.
- Heavy model, OCR, download, and file-copy work must not block the MainActor.
- Domain settings are projections over one durable source, not a second mutable settings graph.
- Switching away from llama releases native runtime resources.
- Production services do not start inside the XCTest host.
- Shutdown stops new work before releasing native state.

## Failure-Oriented Reading

- Duplicate taps or observers: start in CotabbyAppEnvironment and AppDelegate initialization.
- A setting changes but behavior does not: inspect the environment's retained cancellables.
- Runtime remains loaded on another engine: inspect AppDelegate engine switching.
- Hidden menu bar icon makes the app unreachable: inspect MenuBarRecoveryPolicy and reopen handling.
- Permission relaunch loops or termination crashes: inspect AppDelegate termination and permission
  guidance.
- A view appears to own a service: trace construction back to CotabbyAppEnvironment before changing
  view lifetime.

## Update This Guide When

Update this document when a new app-lifetime service is added, startup or shutdown order changes,
ownership moves between AppDelegate and CotabbyAppEnvironment, a new engine affects runtime memory
policy, or a SwiftUI scene begins owning behavior instead of presentation.
