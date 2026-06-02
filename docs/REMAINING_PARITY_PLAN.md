# Remaining Parity Work: Implementation Plan

The constrained-decoder and prompting parity work shipped over a run of PRs (see
the constrained decoder, beam search, FIM, required-prefix admissibility, and the
per-site matching core). This file is the execution-ready design for the items
that remain, all of which live in delicate, system-interacting paths (Accessibility
capture, the clipboard, input timing). Per the repo's working rules, those are
built narrowly and verified on device rather than guessed at — so each item below
separates the part that is pure and already provable from the part that needs the
app running.

Already done, for the record: cross-keystroke completion **reuse** is not a gap.
`SuggestionCoordinator+Input.handleInputEvent(_:with:)` calls
`advanceActiveSessionIfTypedCharactersMatch`, which on a matching keystroke
advances the shown ghost locally and returns *without* scheduling a regeneration.
The only unbuilt increment is multi-branch promotion on the (off-by-default) beam —
a niche, high-risk hot-path change for marginal gain.

## 1. Per-site disable (matching shipped; capture + wiring remain)

`BrowserDomain` already turns a URL into a normalized host and matches it against a
disabled list (exact + subdomain, lookalike-safe), and `SuggestionAvailabilityEvaluator`
already has the per-site branch behind inert-by-default parameters. Three pieces
remain, behind a `cotabbyPerDomainDisableEnabled` flag (default off):

- **Settings list.** Add `disabledDomainRules` to `SuggestionSettingsModel`,
  mirroring `disabledAppRules`, and derive `settingsSnapshot.disabledDomains:
  Set<String>` (see `SuggestionSettingsModel.swift:400`). A bare `defaults`-backed
  array (`cotabbyDisabledDomains`) is the zero-UI dogfood version; a settings pane
  mirroring per-app disable is the productized version.
- **URL capture (the delicate part).** Add `focusedURLString: String?` to
  `FocusedInputSnapshot` (`FocusModels.swift:110`; only two construction sites) and
  populate it in `FocusSnapshotResolver` next to the existing context build
  (`:203`) via a new fail-safe `AXHelper.webURL(near:)` that walks up from the
  focused element reading `kAXURLAttribute`. Gate it behind the flag and restrict
  to browser bundles, and cache per focus-change so it adds no AX round-trips to
  the non-browser hot path.
- **Wire-up.** Have `disabledReason` read `focusSnapshot.context?.focusedURLString`
  (it already receives the snapshot), and pass `disabledDomains:
  settingsSnapshot.disabledDomains` at the ~6 `disabledReason` call sites, exactly
  alongside the existing `disabledAppBundleIdentifiers`.

Fail-safe: a nil URL (read failed, non-browser, or flag off) leaves the gate inert,
so there is no regression path. **Needs on device:** that the URL read actually
resolves in Chrome (OOPIF), Safari, and Arc, and that the walk-up + caching add no
measurable focus-capture latency.

## 2. Paste / match-style insertion

`SuggestionInserter.insert(_:)` already posts a whole chunk in one Unicode keydown,
so this is about *reliability* in apps that mishandle synthetic Unicode strings, and
match-style paste into rich-text fields — not raw speed.

- **Pure, provable now:** an `InsertionStrategy` enum and a pure
  `InsertionStrategySelector.strategy(forChunk:)` (decide keystroke vs. paste from
  length / newline content), fully unit-tested.
- **Behind `cotabbyPasteInsertionEnabled` (default off):** a paste path in
  `SuggestionInserter` that snapshots `NSPasteboard` items, writes the chunk, marks
  the synthetic `Cmd-V` through `InputSuppressionController`, posts it, and restores
  the pasteboard after the host publishes.

**Needs on device:** `InputSuppressionController` counts synthetic *keydowns*; a
paste inserts N characters from one `Cmd-V`, so the suppression/observation
accounting must be verified not to re-observe the pasted text as user typing (a
regeneration loop), and the clipboard save/restore timing must be validated so it
never loses the user's clipboard. On any failure the path falls back to the existing
keystroke insert.

## 3. Token-accurate prompt budgeting

The runtime already tokenizes every prompt, logs the true `prompt_tokens`, and
truncates to the context window. The gap is only that the *section* budgets in the
prompt factory are counted in characters.

- **Measure first.** Before building anything, read the already-logged
  `prompt_tokens` against the context window to confirm char-budgeting actually
  overflows in practice. It may not be worth changing.
- **Option A (accurate, costly):** tokenize sections via the runtime tokenizer on
  the main-actor prompt path — a real per-keystroke latency cost to measure against
  the typing-latency budget, right after the lag fix.
- **Option B (cheap, approximate):** a pure, tested `TokenCountEstimator` heuristic
  for section budgeting, with the quality delta validated on device.

## Sequencing

Per-site disable is the most advanced (matching shipped) and the safest to finish
(fail-safe, flag-gated). Paste is self-contained but its risk is the clipboard and
suppression interaction. Token budgeting should not start until the measurement
step shows it is needed. Each lands behind a default-off flag so it can be dogfooded
without touching shipped behavior, the same way the constrained decoder did.
