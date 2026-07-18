# Inference and Prompting

## Purpose

This guide explains how one structured SuggestionRequest becomes a completion through Apple
Intelligence, the in-process llama runtime, or an OpenAI-compatible endpoint. It also describes where
prompt construction, streaming, normalization, cache reuse, credentials, and native resource
ownership belong.

The key boundary is that engines generate from an immutable request. They do not read live focus or
settings state while decoding. Backend-specific transport and prompting stay behind the shared
SuggestionGenerating contract, while backend-independent output cleanup stays in Support.

## Main Files

Start with:

1. [SuggestionEngineRouter.swift](../../Cotabby/Services/Runtime/SuggestionEngineRouter.swift)
2. [SuggestionRequestFactory.swift](../../Cotabby/Support/Suggestion/SuggestionRequestFactory.swift)
3. [BaseCompletionPromptRenderer.swift](../../Cotabby/Support/Prompting/BaseCompletionPromptRenderer.swift)
4. [FoundationModelPromptRenderer.swift](../../Cotabby/Support/Prompting/FoundationModelPromptRenderer.swift)
5. [SuggestionTextNormalizer.swift](../../Cotabby/Support/Suggestion/SuggestionTextNormalizer.swift)

Then follow the selected backend:

- Apple: [FoundationModelSuggestionEngine.swift](../../Cotabby/Services/Runtime/FoundationModelSuggestionEngine.swift)
- In-process llama: [LlamaSuggestionEngine.swift](../../Cotabby/Services/Runtime/LlamaSuggestionEngine.swift),
  [LlamaRuntimeManager.swift](../../Cotabby/Services/Runtime/LlamaRuntimeManager.swift), and
  [LlamaRuntimeCore.swift](../../Cotabby/Services/Runtime/LlamaRuntimeCore.swift)
- Endpoint: [OpenAICompatibleSuggestionEngine.swift](../../Cotabby/Services/Runtime/OpenAICompatibleSuggestionEngine.swift),
  [OpenAICompatibleAPIClient.swift](../../Cotabby/Services/Runtime/OpenAICompatibleAPIClient.swift),
  and [OpenAICompatibleEndpointModels.swift](../../Cotabby/Models/Runtime/OpenAICompatibleEndpointModels.swift)

## Routing

SuggestionEngineRouter owns backend selection, not model lifecycle or endpoint transport. The
settings snapshot selects one of three paths:

~~~text
Apple Intelligence
  -> FoundationModelSuggestionEngine

Open Source
  -> LlamaSuggestionEngine -> LlamaRuntimeManager -> LlamaRuntimeCore -> CotabbyInference

OpenAI-compatible endpoint
  -> OpenAICompatibleSuggestionEngine -> OpenAICompatibleAPIClient -> configured server
~~~

Single-result generation and streaming are both forwarded to the selected backend. Prewarm is sent
only to the selected backend. A context reset is broadcast to all backends because an old continuation
cache must not survive a field or session boundary merely because that backend is temporarily
unselected.

Apple generation falls back to the in-process llama engine only for unsupported locale or language
conditions. A normal Apple generation failure is surfaced rather than silently changing engines and
making behavior difficult to diagnose.

## Request Construction

SuggestionRequestFactory converts a verified focus snapshot and context bundle into an immutable
request. It chooses an engine-appropriate prefix bound, language-aware prediction budget, enabled
context sections, request identifier, and selected-backend prompt payload for explicit developer
debug logging.

Optional context is sanitized and budgeted before it reaches a renderer. The engine receives both
structured fields and a base-completion prompt so Apple can use its first-class instructions channel
while llama and completion-style endpoints can consume ordinary continuation text.

The caret prefix is the most important signal. Optional context can be reduced or omitted to preserve
the recent text immediately before the caret.

## Two Prompt Shapes

The open-source GGUF models are base completion models, not instruction-tuned chat models.
BaseCompletionPromptRenderer therefore builds a text continuation:

- A short conditioning preface can describe language, style, or custom rules.
- Optional surface, clipboard, visual, and extended context are bounded by PromptSectionBudget.
- The actual caret prefix appears last so generation continues from the user's text.
- There is no instruction-conversation wrapper that asks the model to obey commands.

The Apple Foundation Models API supplies a first-class instructions channel. FoundationModelPromptRenderer
keeps instruction-shaped policy separate from the user content instead of pretending the Apple path
is a raw base-model continuation.

OpenAI-compatible endpoints support completion and chat request modes, but both are derived from the
same Cotabby request and its bounded prompt. Mode changes transport shape; they do not authorize the
endpoint engine to reacquire unbounded editor context.

## Apple Intelligence

FoundationModelSuggestionEngine owns Apple framework availability checks, language support, session
creation, prewarm, generation, and streaming. It uses LanguageModelSession.streamResponse for
cumulative partials and retains at most one prepared session for the next compatible request.

The prepared session is an optimization, not shared conversational memory. A request consumes the
compatible prewarmed session once; field or context resets discard state that could contaminate a new
suggestion.

Framework or language unavailability is classified distinctly from cancellation and ordinary
generation failure so the router can apply its narrow fallback policy.

## In-Process llama

LlamaSuggestionEngine converts the request into the base prompt, invokes the runtime manager, maps
runtime errors into suggestion errors, and passes token-stream partials through normalization before
they reach the coordinator.

LlamaRuntimeManager is a MainActor ObservableObject. It publishes model discovery, load, warmup,
generation, and failure state for UI consumers. It does not perform tokenization or decoding on the
MainActor. Heavy calls are dispatched away from UI isolation and delegated to LlamaRuntimeCore.

LlamaRuntimeCore is a lock-protected nonisolated class around mutable native state, not a Swift
actor. Its boundaries are explicit:

- A lifecycle condition coordinates load, active operations, and bounded shutdown.
- An autocomplete lock serializes prompt-cache and decode state.
- Native pointers and CotabbyInference calls remain private to the core.
- Cancellation is checked through an abort callback while native decoding is running.
- Shutdown prevents new operations, waits for in-flight work, then releases model and context state.

CotabbyInference is an external SwiftPM wrapper around llama.cpp. It is consumed as a package rather
than vendored in this repository. Pointer ownership, Metal buffers, token buffers, and llama context
correctness stay below the manager boundary.

## Prompt Cache and Sampling

The llama core tokenizes the rendered prompt, compares it with the previously evaluated token
sequence, reuses the longest safe common prefix in the KV cache, prefills the remaining prompt, and
then samples new tokens. Token callbacks make partial output available while decode continues.

Cache reuse is a latency optimization constrained by request continuity. Resetting backend context,
loading another model, or changing to an incompatible prompt invalidates reuse. The cache must never
turn one field's text into hidden context for another field.

Sampling and stop decisions live inside the native runtime boundary. Output safety still does not:
every backend passes text through the same normalizer before Cotabby presents or inserts it.

## Runtime Memory Lifecycle

The local runtime is started only when the selected engine is Open Source. Switching to Apple or an
endpoint stops it so mapped GGUF weights and Metal buffers are released. A model selection change,
download completion, or model-directory refresh can trigger a reload followed by warmup when the
active engine needs it.

This policy prevents an unused local model from consuming memory while another backend is active.
The manager publishes lifecycle state; AppDelegate decides when engine selection permits the process
to own native resources.

## OpenAI-Compatible Endpoints

The endpoint backend supports completion-style and chat-style OpenAI-compatible APIs, including SSE
stream parsing. The configured endpoint may be:

- Loopback, such as the default Ollama address at http://127.0.0.1:11434/v1
- A server on the local network
- A public HTTPS service

Public insecure HTTP is rejected. Configuration models classify endpoint privacy and surface a
warning when text may leave the device. API credentials are stored in Keychain through
OpenAICompatibleCredentialStore rather than in UserDefaults.

Ollama model discovery and preload are endpoint-specific conveniences. Preload work is coalesced so
repeated settings or warmup events do not launch redundant load requests. Endpoint connection state
is invalidated when URL, model identity, request mode, or credential changes.

The endpoint path means Cotabby is local-first, not unconditionally offline. Privacy documentation
and UI must distinguish on-device engines from a user-configured remote server.

## Streaming Contract

Engines emit cumulative partial text. Each partial is normalized before the coordinator sees it, and
the coordinator accepts only monotonic extensions suitable for replacing the currently visible ghost
tail. UI rendering is coalesced independently of backend token cadence.

Cancellation is expected when the user types or switches focus. It is not logged or presented as a
runtime failure. A final result is authoritative even after partials were shown; final normalization
or seam checks can replace or suppress the provisional text.

## Backend-Independent Normalization

SuggestionTextNormalizer is intentionally outside all engines. It handles:

- Control and special-token residue
- Reasoning blocks and model scaffolding
- Prompt or prefix echo
- Leading-whitespace reconciliation
- Single-line versus bounded multiline policy
- Text already present after the caret
- Repeated trailing-prefix material
- Empty, unsafe, or non-insertable results

A new backend must satisfy this same output contract. Backend-specific code should not create a
parallel set of cleanup semantics unless the shared normalizer first receives a genuine domain rule.

## Diagnostics

Every request carries a request ID through coordinator, router, engine, runtime, and LLM-I/O logs.
The debug prompt payload comes from the same request factory used for generation, so developer logs
show the actual selected-backend context shape without engines reaching into UI state. It is not
part of the Settings UI or normal user-facing state.

OSLog metadata is available in normal operation. Full prompts and completions are written to the
debug JSONL sink only when the application is launched with -cotabby-debug. That switch is important
because prompt content can include user text and optional screen or clipboard context.

## Invariants

- Routing selects an engine; it does not let engines read live editor state.
- The request is immutable once asynchronous generation starts.
- Base GGUF prompts are continuation-shaped; Apple prompts use its instructions channel.
- The caret prefix is preserved ahead of optional context under budget pressure.
- Heavy llama work never runs on the MainActor.
- Llama native state is serialized under the core's explicit locks and lifecycle condition.
- Context reset prevents cache data from crossing interaction boundaries.
- Switching away from Open Source releases local runtime resources.
- Endpoint secrets live in Keychain and insecure public HTTP is rejected.
- All backends share normalization and streaming semantics.
- Cancellation is a normal lifecycle outcome, not automatically a generation error.

## Failure-Oriented Reading

- Wrong engine runs: router selection and settings/profile snapshot.
- Apple unexpectedly falls back: language-support classification in the foundation engine.
- First suggestion is slow: selected-backend prewarm and llama prompt prefill/KV reuse.
- Memory stays high on endpoint mode: AppDelegate runtime stop and manager shutdown.
- Output includes instructions or prompt text: renderer choice and shared normalizer.
- Old field text influences a new field: reset broadcast and llama cache continuity.
- Endpoint never streams: request mode, SSE parsing, and cumulative-partial contract.
- Local endpoint warning looks remote or vice versa: endpoint privacy classification.
- UI freezes during generation: manager-to-core dispatch and synchronous work on MainActor.
- Shutdown crashes in native code: core lifecycle condition and process termination order.

## Update This Guide When

Update this document when a backend is added, router fallback policy changes, request fields or
budgets change, prompt shape changes, runtime serialization changes, endpoint privacy rules change,
or streaming and normalization acquire a new cross-backend contract.
