# Additional text-prediction experiments

**Planning only — none of these experiments has been executed.** This catalog supplements
`TEXT_PREDICTION_IMPROVEMENT_PLAN.md`. It adds ten hypotheses beyond A, B and AB; it does not
automatically add ten runs to that plan. Select a batch and freeze its rules before execution.

The hypotheses below have different levels of support. The punctuation experiments come from
specific behavior in current code. Metadata ordering and context selection are plausible model
conditioning experiments. Partial-word sampling/stopping needs its own measurements.

## Batch selection and common rules

- First keep the existing A/B/AB metadata cycle, or explicitly select another batch before its
  baseline. A sensible next independent batch is **E1, E2 and E3**. Do not silently switch batches
  after seeing a finalist fail validation.
- Test each single change against the same frozen baseline, not a growing stack of winners.
  Do not automatically combine new candidates. A combination requires a later registered test.
- Reuse the original plan's isolation, scorer/input identity, error handling, two-seed validation,
  latency, fresh-data and integration requirements. Each batch gets its own selection record.
- Before generation, audit whether the actual model prompt, sampling settings or stopping
  decisions change on the evaluated inputs. Mark unexercised experiments NO-OP or NOT COVERED;
  do not spend a full benchmark proving an unused code path leaves the score unchanged.
- Predeclare the metric and the target condition or its fixed selection rule. For screen-only word experiments, screening needs
  **at least +4 correct / 770 screen checkpoints**, with no loss without screen context. Full1337
  needs **at least +38 / 7,437** in screen at each seed, with no loss without context. Other gates
  in the original plan still apply. Unaffected branches need exact prompt equality.
- For E3/E4/E7, which can affect both conditions, require neither condition to lose, and require
  at least +4 screening hits in one condition. Freeze that target condition with the finalist;
  require at least +38 full1337 hits in that same condition at each seed, not whichever wins later.
  If both qualify at screening, select screen as the target by a fixed tie rule.
- Partial-only experiments E8–E10 use the separate gate below; they cannot be ranked against
  word-score candidates or rejected solely because an intentionally unchanged boundary score ties.
- For conditional sampler/stopping candidates, retain a checkpoint-keyed audit of the effective
  runtime options and stop reasons. A report containing only global default settings cannot prove
  the changed branch executed. Instrumentation must not alter token selection or scoring and must
  be frozen before matched runs; log only the already-local benchmark data.

## E1 — Preserve punctuation inside words in screen context

**Hypothesis:** removing meaningful word punctuation corrupts useful names and vocabulary before
the model sees them. `PromptContextSanitizer.sanitize` currently keeps letters, numbers,
whitespace, `@` and `.`, replacing other characters with spaces.

**One change:** preserve ASCII/curly apostrophes between letters and hyphens between letters
in local llama screen-context text. Keep other sanitization and all size limits unchanged.
Examples of the intended distinction: `don't` versus `don t`, `O'Neil` versus `O Neil`, and
`follow-up` versus `follow up`. These illustrate the rule; they are not a benchmark word allowlist.

**Boundary:** add an OCR-specific policy at `PromptContextSanitizer`, used consistently by
`VisualContextExcerptSelector` and `SuggestionRequestFactory.activeVisualContextSummary`.
Both currently sanitize the excerpt, so changing only one can be erased by the other.
Keep clipboard, user rules, Apple and endpoint behavior outside this experiment; ensure the
production local path and the benchmark adapter use the same policy. Do not bypass hygiene.

**Evidence/coverage:** 267 of the 1337 raw screen scenarios contain the ASCII-letter connector
patterns inspected. This is potential exposure, not 267 affected prompts or recoverable errors.
Count surviving changed excerpts in the actual prompt audit before running inference.

**Pass:** screen-word gate plus all common checks. Test unchanged control/ANSI/markup filtering,
leading/trailing quotation marks, names, contractions, Unicode, deduplication and idempotent
double sanitization. Reject any implementation that preserves arbitrary prompt delimiters.

## E2 — Preserve punctuation in structured facts

**Hypothesis:** screen context loses facts when `12:30`, `09/17`, `$50` or `20%` becomes a
different-looking sequence of tokens. The current sanitizer removes those delimiters/symbols.

**One change:** a separate local-screen policy retains `:` and `/` only between digits,
`$`, `£` or `€` immediately before a digit, and `%` immediately after a digit. Do not include E1
in this candidate. Preserve the original characters; do not infer dates, currencies or units.

**Boundary:** the same two sanitization sites as E1, with identical local-only scope.
Do not broaden URL/path inclusion or add OCR content that existing hygiene rejects.

**Evidence/coverage:** 577 raw scenarios contain at least one of the inspected numeric patterns.
Again, effective coverage must be established after hygiene, selection and final sanitization.

**Pass:** screen-word gate and common checks. Add cases for times, ratios, dates, negative
amounts, decimals, lone symbols, noisy symbol runs and technical strings. The 1337 scorer's
number/word tokenization stays unchanged; better-looking input alone is not a score gain.

## E3 — Put Title first within compact surface metadata

**Hypothesis:** the document/thread title carries more specific topic information than the app
or generic format label. Round two showed that removing Title harmed both conditions; this
experiment changes its position instead of removing it.

**One change:** move the existing `Title:` field to the start of the surface line. Keep the
relative order and values of all other fields, punctuation conventions, screen text and sampler.
Do not also shorten, quote or rewrite titles.

**Boundary:** `SurfaceContextComposer.prefaceLines`, with renderer allocation tests. Freeze
other allocated sections as in the original metadata plan; disclose any changed truncation
within the surface section as part of this registered ordering policy.

**Pass:** the two-condition word gate above. Missing-title inputs must be identical. All 1337
raw scenarios contain a title, although some surfaces may suppress the entire section.

## E4 — Remove redundant App metadata on email/chat surfaces

**Hypothesis:** `Format: email` or `Format: chat` already states the relevant writing mode;
an application brand can add distracting associations. This is narrower than the failed
round-two experiment that removed App everywhere.

**One change:** omit `App:` only when the existing classifier reports `.email` or `.chat`.
Keep Format, Title and Field. Preserve App on browsers and generic applications; do not add
new app classifications or a fixture-specific list of bundle IDs.

**Boundary:** `SurfaceContextComposer` plus renderer tests. Use the original conservative
allocation policy so freed metadata space does not also increase screen context.

**Pass:** the two-condition word gate. Require exact prompt equality for all other surface
classes and report email/chat gains and losses separately, including unfavorable categories.

## E5 — Select only the two nearest useful OCR lines

**Hypothesis:** when all short lines fit the budget, the existing selector keeps everything.
A smaller excerpt may avoid conditioning on unrelated nearby text.

**One change:** after existing hygiene and deduplication, select at most two lines using the
selector's existing geometry score, then restore reading order. Preserve its no-geometry
fallback and character cap. Do not change distance weights, hygiene or screen labels.

**Boundary:** `VisualContextExcerptSelector`. It already prioritizes nearby same-column text;
the new variable is a two-line count limit, not a newly invented proximity algorithm.

**Pass:** screen-word gate. Inputs with no more than two surviving lines must remain unchanged.
If the prompt audit finds no selected excerpt differences, mark NO-OP. Reject if losing useful
context violates the category or fresh-validation gates, even if average prompt length falls.

## E6 — Select OCR lines by topic overlap

**Hypothesis:** lines related to the writer's current text may be more useful than equally
nearby but unrelated text. This is a hypothesis, not a reliable relevance classifier yet.

**One change:** use `PromptContextSanitizer.significantTokens` on already-typed text and cleaned
OCR lines. Rank by the number of shared distinct tokens; ties use the existing geometry/index
order. If no line has positive overlap, preserve the baseline excerpt. Otherwise select up to
two positive-overlap lines and restore reading order, within the existing character budget.

**Boundary:** a pure selection rule in `VisualContextExcerptSelector`; compare this complete
rule independently against baseline, not against E5. No learned model, reference answer,
expected next word, corpus annotation, new stop-word tuning or title input is added.

**Pass:** screen-word gate. Record losses where useful context introduces new vocabulary rather
than echoing the prefix. Preserve names, dates and numbers within selected lines. If a candidate
passes the 1337 development set but fails fresh contexts, reject it rather than retuning overlap.

## E7 — Use only the current paragraph as the model's typed prefix

**Hypothesis:** older field history can distract a small base model from a new paragraph's topic.

**One change:** when the existing bounded prefix contains a blank-line paragraph separator and
non-whitespace text after the last separator, send only the exact suffix after that separator.
Otherwise preserve baseline. Do not strip spaces inside the retained suffix or change the
actual editor text, request context used for insertion, or the benchmark checkpoint/reference.

**Boundary:** a pure local llama prefix-window policy in `SuggestionRequestFactory`. Keep other
backends and the screen excerpt policy unchanged. Account for any subsequent budget effects in
the audit; no claim of an isolated metadata effect applies to this prefix experiment.

**Coverage risk:** only 256 scenarios have nonempty `documentPrefix`, all at most 28 characters;
not all contain paragraph separators. Audit before spending inference. If there is no material
coverage, defer to a separate long-document fixture rather than modifying 1337 to manufacture it.

**Pass:** the two-condition word gate, plus unchanged word-boundary insertion/whitespace tests.
This can harm references to earlier paragraphs; those regressions remain part of the score.

## E8 — Greedy sampling only inside an unfinished word

**Hypothesis:** completing the word already being typed may benefit from less sampling variation,
while choosing the next word can retain the current baseline sampler.

**One change:** use the existing native greedy path (`temperature == 0`) only when production
`CaretWordContext` identifies an unfinished word. All other requests retain temperature 0.1.
Keep penalty strength/history, output cap, healing constraints and stopping unchanged. Do not
use the scorer's `typedCharacters` field to control production behavior.

**Boundary:** the local request-to-generation-options policy, with a per-request value rather
than a shared mutable setting. Native greedy must remain the already-tested implementation.
Global greedy was tested in round one; this conditional policy is a distinct hypothesis.

**Pass:** partial-only gate below. First audit the production predicate on both word and
character cohorts; apparent end-of-word text can be ambiguous. Do not assume every real-world
letter-ending prefix is an unfinished word, or that every word-boundary fixture is unaffected.

## E9 — Disable repetition penalty only inside an unfinished word

**Hypothesis:** penalizing prompt tokens may interfere with spelling a word whose initial
characters already occur in the prompt. A conditional neutral penalty could help completions
without increasing repetition at ordinary next-word boundaries.

**One change:** penalty 1.0 instead of 1.025 under the same production unfinished-word predicate;
all other requests stay at 1.025. Keep temperature 0.1, history length 64 and all other filters.
Test independently from E8. Do not change which healing bytes belong to the editor.

**Boundary:** per-request local generation options. Exercise sampler/cache restoration when
the setting switches between neighboring requests; never let the previous request's option leak.

**Pass:** partial-only gate, with repetition, duplicate-fragment, cache and cancellation checks.
Earlier global penalty/history experiments do not establish the result of this conditional policy.

## E10 — Give an unfinished first word a bounded argmax-stop grace period

**Hypothesis:** the extra “most likely token is end-of-generation” stop can discard a sampled
non-EOS token before a useful partial-word completion becomes available. This is distinct from
the model actually sampling EOS, which must still stop immediately.

**Diagnostic prerequisite:** find existing or newly instrumented development cases where the
recorded stop reason is `argmax_eog` before a complete first visible word on an unfinished-word
request. The current phrase report does not contain this stop reason. Do not infer it from
an empty completion or a seam-suppression label. If it cannot be demonstrated within 20 minutes,
defer this candidate instead of changing the stop rule speculatively.

**One later registered change:** on those production unfinished-word requests only, defer the
argmax-EOG shortcut for at most two additional sampling steps while the first visible word is
incomplete. Actual EOS, cancellation, healing mismatch and the original total token cap still
terminate immediately. Recheck the ordinary shortcut on subsequent steps; do not disable it globally.

**Boundary:** `LlamaRuntimeCore.runEngineSampledDecode`, with deterministic fake-token sequence
tests before any real-model comparison. This is the highest-risk candidate in this catalog;
do not include it in Luna's first low-cost batch or alter native pointer ownership.

**Pass:** partial-only gate, all stream/final/cache invariants, and isolated latency. Repeated
punctuation, longer rambling or a latency regression rejects the change even if coverage rises.

## Partial-only gate for E8–E10

Register these in a separate cycle with partial accuracy as the primary metric. Use the fixed
first 50 scenarios/category, paired character mode, seed 42: 6,936 partial checkpoints per
condition and 1,894 word boundaries. The screening requirement is **at least +35 correct
partial checkpoints in one condition (+0.50 pp), with no loss in either condition's partial or
boundary counts**. Freeze the successful target condition (screen on ties) before validation.

For the selected finalist, repeat the same matched pair at production seed 12648430; require
at least +35 partial hits in the frozen target and no loss elsewhere. Require a seed-42 95%
paired phrase-cluster bootstrap lower bound above zero for that partial improvement, computed
from existing scorer flags with 20,000 resamples/seed 1337. Do not use the all-checkpoint metric.

Full1337 word runs at both seeds must have no accuracy decline in either condition; they need
not gain +38 word hits because that is not this cycle's hypothesis. Category limits, malformed
output protections, isolated latency and fresh validation remain required. New protected
character-mode data must show at least +0.50 pp in the frozen target at both seeds, no negative
partial or boundary change in either condition, and a positive seed-42 family-bootstrap lower
bound before default promotion. Freeze that data and its character-scoring pathway before tuning.

## Important coverage gaps — valuable ideas that 1337 alone cannot establish

| Future experiment | Why this suite needs supplementary inputs first |
| --- | --- |
| Larger/shorter long-document history windows | Current scenario history is at most 28 characters; the 2,500-character cap is generally not exercised |
| Better use of text after the caret | The replay adapter explicitly supplies empty `trailingText` |
| OCR confidence threshold or spatial/sidebar robustness | Fixture OCR confidence is fixed at 0.99 and geometry is synthetic |
| Browser-domain-specific metadata | The replay adapter does not supply a focused URL |
| Faster first suggestion, prewarming or cancellation behavior | Completed static phrase replay does not reproduce the live typing/focus lifecycle |

Do not rerun generic temperature sweeps, repetition-history lengths, screen-label spelling,
or blanket Title deletion as if they were new ideas. The earlier rounds already measured them.
Do not enable a global confidence filter merely to show fewer suggestions; the current code
documents severe real-use over-suppression from that earlier approach.

## Initial priority order

1. Existing A/B/AB: strongest direct score evidence; small, pure changes.
2. E1/E2: concrete input-fidelity defects worth measuring; moderate implementation scope because
   both sanitizer passes and the local-only routing must agree.
3. E3/E4: low implementation cost, unproven prompt-conditioning benefit.
4. E5/E6: potentially useful context selection, but higher risk of throwing away needed facts.
5. E8/E9 and the existing suppression-defect investigation: use a separately budgeted partial-word cycle.
6. E7 only if input audit shows meaningful paragraph coverage; otherwise await longer fixtures.
7. E10 only after its diagnostic prerequisite and enough budget for decoder correctness checks.

There is no promise that ten hypotheses yield ten improvements. Each useful outcome is either
a reproducible gain with a tested patch, or a recorded rejection that prevents repeated work.
