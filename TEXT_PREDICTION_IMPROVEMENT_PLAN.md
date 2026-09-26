# Text prediction improvement cycle — execution plan for GPT-5.6 Luna

**Status: PLAN ONLY. No implementation or benchmark execution is authorized by creating this file.**
Execute when the user subsequently asks to start. Use GPT-5.6 Luna for that execution, one agent,
the existing local model, and the existing 1337 scorer. Do not start another six-hour goal.

This file is the handoff boundary: it specifies the hypotheses, experiment order, decisions,
and evidence required so the executing agent does not have to reconstruct the previous conversation.
Production code owns prediction behavior; the benchmark owns scoring; this plan owns neither.

Ten additional hypotheses are specified in
[the experiment backlog](TEXT_PREDICTION_EXPERIMENT_BACKLOG.md). They include screen-text
punctuation fidelity, metadata ordering, selective context, and partial-word sampling/stopping.
That catalog is for explicitly selected later batches; it does not silently expand this cycle's
three-candidate limit or change its gates. No experiments have been started.

## 1. Evidence and priorities

Round two tested twelve alternatives. None passed its qualification rule. The most useful
results on the fixed screening set were:

| Configuration | Screen correct / 770 | No-screen correct / 770 |
| --- | ---: | ---: |
| Retained P2-H baseline | 288 | 235 |
| Remove Format everywhere | 294 | 225 |
| Remove Field everywhere | 282 | 241 |
| Remove Title everywhere | 264 | 210 |

**First priority: make metadata removal conditional on usable screen context.** The two
opposite tradeoffs suggest a small, testable production policy. They do not prove the
conditional policies or their combination work. Preserve Title, App and Domain metadata.

**Second priority: investigate lost partial-word completions.** On the first 50 scenarios per
category, screen-context partial accuracy was 4,883/6,936 (70.401%). Of the 375 suppressed
partial outputs, 371 were attributed to the seam guard; 324 suppressions occurred after four
or more typed characters. Different offsets represent different words, so this is a diagnostic
lead, not proof that the guard is wrong or that longer prefixes cause errors.

**Defer broad sampler, model, and OCR rewrites.** Repetition-history and screen-label variants
did not qualify. Existing data does not establish a reliable production classifier for useful
versus distracting OCR. Corpus annotations must never become production inputs.

References: [round-two results](benchmarks/phrase-prediction/round2/RESULTS.md),
[reproduction notes](benchmarks/phrase-prediction/round2/reproduction-notes.md), and
[round-two checklist](IMPROVEMENT_BRAINSTORMING_ROUND_TWO.md).

## 2. Concrete candidates — maximum three in this cycle

| ID | Change from the frozen baseline | Required screening improvement |
| --- | --- | --- |
| A | Omit Format only when a usable screen excerpt survives prompt budgeting | Screen gains at least 4 correct; no-screen loses none |
| B | Omit Field only when no usable screen excerpt survives prompt budgeting | No-screen gains at least 4 correct; screen loses none |
| AB | Apply A and B together; run only if both singles pass | Both conditions gain at least 4 correct |

Four hits out of 770 is the integer threshold for at least +0.50 percentage points.
Always implement A and B independently from baseline. Never implement B on top of A and call
it a single-change result. No extra parameter grid, replacement hypothesis, or automatic fourth variant.

### Implementation boundary

- `Cotabby/Support/Context/SurfaceContextComposer.swift` owns sanitized facts and stable field
  formatting. Add explicit formatting options with defaults that preserve the existing output;
  do not change `SurfaceContext` data or remove facts upstream.
- `Cotabby/Support/Prompting/BaseCompletionPromptRenderer.swift` owns the conditional choice
  because it knows what context actually survived allocation. `SuggestionRequestFactory`
  supplies its inputs. Keep the renderer pure; do not read settings, focus services, or the runtime here.
- Keep all other backend contracts and callers' default behavior intact. No coordinator, UI,
  model download, native sampler, output-token, or confidence-policy changes in A/B/AB.

Define `hasUsableScreen` from **retained non-whitespace excerpt content**, excluding the
`Nearby on screen:` label. A non-nil input, enabled setting, available screenshot, label-only
section, or corpus condition name is not sufficient.

Use a conservative allocation sequence to avoid a circular rule:

1. Build and allocate the unchanged baseline sections first.
2. Determine usable screen presence from that allocation.
3. Re-render only the retained surface section with the selected omissions. Respect its
   original allocated character allowance and, when applicable, estimated-token allowance.
4. Keep every other allocated section and the exact caret prefix byte-identical to that
   baseline allocation. Do not redistribute the freed space or rerun global allocation.

This intentionally isolates metadata wording from increased OCR capacity. A different
allocation policy is a separate hypothesis for another round. If no surface section survives,
the candidate is a no-op for that request.

Focused tests belong in `SurfaceContextComposerTests` and `BaseCompletionPromptRendererTests`.
Cover nil/empty/whitespace screen input, actual retained text, screen dropped by budget,
label-only truncation, absent Field, missing surface context, code/terminal omission, tight
character and token budgets, and exact prefix whitespace. Verify default formatting is unchanged.
Use genuine regression cases and branch invariants, not tests that just restate the implementation.

## 3. Preparation and immutable controls

- [ ] Inspect `AGENTS.md` and both app/native Git status. Preserve all existing user changes.
- [ ] Create an isolated checkout/snapshot and a `codex/` experiment branch. Capture current
  app/native revisions, dirty patches, untracked source prerequisites and dependency locks.
  A clean Git checkout alone can omit required existing token-healing changes.
- [ ] Use `scripts/create-inference-workspace.py` to resolve the chosen local native package.
  Do not change the app's remote package pin. All derived data stays under that checkout's
  `build/DerivedData`.
- [ ] Record a new run directory, for example `build/eval/round3-<UTC timestamp>/`, and a small
  machine-readable run table before scoring. Record these gates and the candidate order verbatim.
- [ ] Freeze model, scorer, corpus, request settings, native cache/reset behavior, and worker
  count. Inspect effective report settings rather than assuming a config field means what it says.

Reference identities, to verify against actual inputs:

```text
1337 corpus SHA256: b41c8089a58ae1e0ee84b95ac9283cf71db4e713e25bd8fed47220be69d8b0f6
GGUF SHA256:        febd85051361ccb34d0925744c819f9ae0724117e8f946a2852dd0edfa90a5a1
Model: Qwen3.5-0.8B-Base.i1-Q6_K.gguf
Temperature 0.1; repetition penalty 1.025; top-k 20; top-p 0.7; min-p 0.08
Native repetition history 64; primary seed 42; production seed 12648430
Screen partition: split seed 1337, 20 scenarios/category, 140 scenarios total
```

Keep the existing output budget and word-count preset. In the previous run the effective
generation cap was 26 tokens; `maxPredictionTokens: 5` was a floor, not the effective cap.
Do not change stopping, spelling, normalization, healing, fallback, or score matching to raise a score.

The default fixture contract remains exactly 1337 scenarios, 191/category. Both the 1337
corpus and round two's supplementary 700 cases are now **known development/regression data**.
A new partition or seed does not make either corpus independent validation.

## 4. Test cycle and decisions

### Stage 0 — reproduce baseline and validate the harness

Run the narrow renderer/composer tests, a successful build, and one seed-42 screening baseline
with paired screen/no-screen conditions and three independent workers. Audit prompt identities
through the real request factory, not a separate Python recreation of the renderer.

Expected historical screen counts are 288/235. Current source changes may justify a new baseline,
but unexplained drift must be investigated before candidates. Allow one exact replay under a new
label for an unexplained mismatch. If it remains unexplained after 15 minutes, stop as INCONCLUSIVE.
Never edit production code or fixtures just to recreate historical totals.

Freeze the freshly verified baseline. It is the control for every later comparison. Require
matching full input identities and complete, error-free reports; old aggregate scores alone
cannot substitute for a current control.

### Stage 1 — screen A, then B, then eligible AB

For each candidate:

1. Save the scoped patch and source hashes before running it.
2. Run focused tests and audit all screening prompts. For A, no-screen prompts must remain
   byte-identical. For B, prompts with usable screen context must remain byte-identical.
   Changes must be confined to the registered surface formatting; all other allocated sections
   and prefix bytes remain unchanged. If a candidate changes no evaluated prompts, mark NO-OP.
3. Run a fresh build and one paired screening benchmark, seed 42, same 140 IDs/770 checkpoints
   per condition as baseline. A source change always requires a new candidate replay.
4. Apply the table's exact count gate. Log PASS, REJECT, NO-OP, or INVALID; never silently
   omit a losing run. Stop work on a rejected variant. One functional fix before the first
   scored run is allowed; do not tune a variant after inspecting its score.

If both singles pass, test AB. If none pass, stop the prediction experiments and retain baseline.
Otherwise freeze **one finalist** from all passing completed candidates: largest sum of screen
and no-screen correct gains; then largest smaller-condition gain; then fewer policy changes;
then fixed order A, B, AB. Save source hashes and the selection before Stage 2.

### Stage 2 — full 1337 regression, two seeds

Run matched baseline/finalist word-mode pairs over all 1337 scenarios for seed 42, then
12648430. This is four complete runs, each 7,437 checkpoints/condition, 14,874 predictions total.
Abort later stages on a failed gate; do not fall back to a different finalist.

**Every requirement must pass:**

- Zero inference errors; no missing/duplicate checkpoints; exact matching input identities.
- Neither condition loses correct predictions at either seed.
- A gains at least +0.50 pp in screen; B gains at least +0.50 pp in no-screen; AB gains at least
  +0.50 pp in both. Apply this at each seed: **at least 38 extra correct out of 7,437**.
- At seed 42, the 95% paired category-stratified phrase-bootstrap lower bound is above zero
  for each required improvement. Use 20,000 resamples, bootstrap seed 1337.
- No category loses more than 2.0 pp in either condition at either seed.

Use `scripts/analyze_phrase_experiments.py` for matching/audits and paired intervals. These
intervals are descriptive evidence on reused data, not correction for selection or proof of
population quality. Compare candidate versus baseline **within each condition**; screen-minus-none
context benefit is a different measurement and cannot satisfy an implementation-gain gate.

### Stage 3 — partial words and correctness invariants

Run one baseline/finalist character-mode pair, seed 42, `--split all --per-category 50`, using
the first 50 scenarios/category in corpus order. Expected: 350 scenarios, 8,830 checkpoints
per condition, of which 6,936 are partial prefixes and 1,894 are word boundaries.

Pass only if partial-only and boundary correct counts do not decrease in either condition,
and no category's partial-only accuracy declines by more than 2.0 pp. Report showing/coverage
and suppression counts separately. Neither increased coverage nor mixed `all` accuracy can
substitute for partial-only correctness.

Partial-only means existing observations with `checkpoint.typedCharacters > 0`. The checked-in
analyzer exposes `nextWord` and `all`, not partial-only. If needed, add a small report-only
counter over the scorer's existing Boolean `correct` flags, with a hand-checked synthetic fixture.
Do not reinterpret raw text, invent matching rules, or count all character checkpoints as partial.

Run existing token-healing, normalization, seam, cache restoration, cancellation and streaming
tests relevant to shared behavior. No new replay-byte leak, malformed UTF-8, duplicate insertion,
abandoned typed fragment, junk run, or stale/cancelled publication is acceptable.

### Stage 4 — isolated latency

Use the same 140-scenario word set, seed 42, **one worker**. Run **baseline, candidate, candidate,
baseline** sequentially; fresh-build the required source before each measured replay. Do not
overlap generation with another build, benchmark, analysis job or known heavy background task.
Record process observations and run intervals. Leave unrelated tasks and backups running;
defer measurement if the machine cannot provide a quiet window.

For each condition, compare both adjacent pairs (B1→C1 and B2→C2, regardless of chronological
order). In each pair, candidate p95 must be no worse than baseline p95 plus the larger of
**10% of baseline p95 or 20 ms**. Also report p50 and errors. Missing or contaminated timing is
INCONCLUSIVE, not a pass; do not use three-worker throughput as a substitute. This measures
generation latency, not focus tracking, debounce, or overlay rendering.

The previous test host was quit through its menu twice. Avoid interacting with that host.
The archived menu-hiding wrapper was never used for inference and its review is incomplete;
do not treat it as a validated dependency. Any necessary harness-only fix must be completed
and checked before baseline capture, then applied identically to baseline and candidate.

## 5. Result classes and production promotion

| Outcome | Required action |
| --- | --- |
| REJECT | A genuine score/correctness/latency gate fails: retain baseline; save the result and patch |
| NO-OP | Candidate changes no exercised inputs: do not count it as a meaningful alternative |
| INVALID | Missing results, errors or identity mismatch: preserve attempt; one infrastructure retry allowed |
| INCONCLUSIVE | Unexplained drift, missing validation, interference, or insufficient remaining budget: retain defaults |
| BENCHMARK-QUALIFIED | All Stages 0–4 pass: keep a tested finalist patch in isolation; do not claim independent validation |
| ADOPTABLE | Benchmark-qualified plus new protected validation and current-main integration both pass |

**Fresh validation is required for default promotion, not for completing this 1337 cycle.**
To keep Luna's work bounded, do not spend this cycle generating hundreds of new examples or
building a new evaluation framework. If a new, audited protected corpus is not available,
deliver the benchmark-qualified patch and stop with defaults unchanged.

If new protected data is supplied, freeze its bytes, family identities and scoring pathway
before candidate screening, keep references/results unopened during selection, and use
matched baseline/finalist runs at both seeds. Require the same +0.50 pp improvements for the
finalist's target condition(s), no negative point change in either condition, a seed-42 95%
category-stratified **family** bootstrap lower bound above zero for required gains, and no
category decline beyond 3.0 pp. Use 20,000 resamples/seed 1337; keep related examples together.
Fresh failure retains baseline with no replacement finalist or edits based on those results.

The checked-in `scripts/phrase_eval.py` currently has no `--corpus` option; round two's
supplementary pathway lives in its archived evaluation harness. Do not paste unsupported flags
or loosen the default 1337 fixture contract. Reuse only that tested pathway after inspecting
and validating the minimal harness differences, then freeze it for both sides. New family data
also needs family-aware analysis; the checked-in phrase bootstrap is insufficient for that purpose.

For an adoptable change, integrate only the finalist production files and their tests into
current main while preserving user edits. Re-run focused tests/build and the full production-seed
1337 suite. Require checkpoint-by-checkpoint parity with the validated finalist, including raw
output, shown text and suppression flags; investigate differences instead of comparing totals only.
Remove experimental switches and do not ship corpus IDs, references, evaluator metadata or new
network transmission. Keep the baseline patch available for reversal. No automatic push/release.

## 6. Strong follow-on target: partial-word loss diagnosis

This is a **separate follow-on cycle**, not an extra candidate allowed after finalist validation.
Its first iteration is a maximum 20-minute diagnostic using existing character-run records.

Inspect a fixed deterministic sample of up to 30 suppressed development checkpoints across
prefix-length bins and categories. The runtime order is sampled bytes → healing replay removal
and UTF-8 assembly → runtime output → normalization → seam decision. The report's `raw` field
is already runtime output; it does not retain the original sampled/replayed token bytes.
Reproduce normalization and the seam decision from those records; investigate earlier healing
with existing byte-level tests or actual traces, never invented token histories. The trace must
explain the transformations rather than treating the scorer's coarse suppression label as a root cause.
Review names, connectors/apostrophes, Unicode, legitimate existing words, and repeated fragments.

Primary files: `SuggestionTextNormalizer.swift`, `CompletionSeamGuard.swift`, `CaretWordContext`,
`TokenHealingBuffer.swift`, and their existing tests. Most shown reference mismatches are model
quality problems, not recoverable suppressed text; keep those categories separate.

The diagnostic succeeds only when it produces a small, deterministic regression case showing
a valid continuation corrupted or incorrectly rejected by a specific rule. If none is found,
record NO PROVEN DEFECT and stop. Never weaken dictionary/seam protections or re-expose failed
healing to turn suppressions into visible output.

Only after that gate may a later iteration register **one minimal fix** before benchmarking.
For that fix, require at least +0.50 pp partial-only accuracy in its predeclared affected
condition, no partial or word-boundary regression in either condition, the full-word and latency
non-regression gates, and the correctness invariants above. Use the same fresh-data/default-
promotion separation. Native pointer/cache changes or a sampler redesign exceed this iteration.

## 7. Commands and a small execution ledger

The following commands are templates for the later execution, not instructions to run now.
Set `EVAL_MODEL`, `EVAL_WORKSPACE`, and `EVAL_OUT` to verified absolute paths in the isolated
checkout. Run each command from that checkout. Every output directory/label must be new.

```sh
python3 scripts/phrase_eval.py run \
  --model "$EVAL_MODEL" --workspace "$EVAL_WORKSPACE" \
  --output "$EVAL_OUT/baseline-screen42" --label baseline-screen42 \
  --mode word --context paired --workers 3 \
  --split screen --split-seed 1337 --screen-per-category 20 \
  --seed 42 --temperature 0.1 --repetition-penalty 1.025 \
  --top-k 20 --top-p 0.7 --min-p 0.08

python3 scripts/analyze_phrase_experiments.py \
  "$EVAL_OUT/baseline-screen42/report.json" "$EVAL_OUT/A-screen42/report.json" \
  --metric nextWord --bootstrap-samples 20000 --seed 1337 --markdown
```

Adapt only the declared source selection, label/output and these stage-specific flags:

| Stage | Flags differing from the screen template |
| --- | --- |
| Full 1337 | `--split all`; seed `42` or `12648430` |
| Character subset | `--split all --mode character --per-category 50`; seed `42` |
| Latency | `--workers 1`; otherwise the identical screen template |

Never use `--skip-build` after an implementation change. Source and binary identity must
match the exact recorded candidate. Pre-existing successful runs are reusable only if every
required source, harness, model, fixture, seed, cohort, setting and measurement-scope identity matches.
Expired round-two orchestration drivers are historical evidence, not a scheduler to restart.

Use one small JSON ledger plus a readable results Markdown file. Each row records candidate,
baseline reference, seed, mode, cohort, worker count, source/model/corpus/scorer hashes, build/test
status, start/end, correct/total per condition, category deltas, gate verdict and artifact paths.
Never truncate or overwrite a failed attempt; an exact retry gets a distinct label and reason.
Record the actual checkpoint IDs or their stable hash, not just the row count.

## 8. Cost and stopping rules

- No subagents, parallel benchmark processes, ongoing brainstorming, or requirement to fill time.
  Multiple independent workers inside one accuracy replay are allowed; latency always uses one.
- Maximum three candidate implementations, one infrastructure retry per failed stage, and one
  finalist. Cap implementation at 20 minutes per single candidate; skip an unfinished candidate
  with an explanation rather than weakening tests or rushing shared architecture changes.
- A passing path uses at most **14 scored runs through Stage 4**: baseline screen, A, B,
  optional AB, four full-word runs, two character runs and four latency runs. Fresh validation
  and final integration are additional and must be budgeted before starting them.
- Default maximum wall-clock window: **four hours**, ending earlier on rejection or a clear
  completed outcome. Reserve the last 20 minutes for evidence, preservation review and cleanup.
  At launch, use measured runtimes to check that the next complete required stage fits. Otherwise
  stop as INCONCLUSIVE; do not launch a partial pair or extend the window automatically.
- Reuse existing test/analysis tools; do not build another orchestration framework. An external
  queue can run fixed commands sequentially and stop on nonzero exit. Keep output in files;
  inspect compact counts/statuses and only targeted failing examples, not full raw reports in chat.
- Stop after any genuine finalist failure. No rerolling seeds, repeated scoring to find a favorable
  result, threshold changes, denominator changes, or post-validation fallback selection.
- Final deliverables: completed ledger, kept/rejected patches, test/build evidence, explicit
  outcome class, results summary and next unproven hypothesis. Remove only this run's isolated
  `build/DerivedData` after evidence is preserved; leave user changes and unrelated builds intact.

## Execution checklist — leave unchecked until the later run

- [ ] User starts execution; confirm this plan and cost limits in the run record.
- [ ] Preserve inputs and reproduce baseline; freeze controls.
- [ ] Implement, test and screen A from baseline.
- [ ] Implement, test and screen B from baseline.
- [ ] Test AB only if eligible; freeze one finalist or retain baseline.
- [ ] Complete full1337 pairs at seed 42 and production seed.
- [ ] Complete partial-word pair and correctness checks.
- [ ] Complete uncontended latency comparisons or mark inconclusive.
- [ ] Record benchmark qualification; apply the fresh-validation gate before any default promotion.
- [ ] If adoptable, integrate and verify current-main parity.
- [ ] Preserve results, clean isolated build artifacts, and stop.

## Suggested later handoff

> Execute TEXT_PREDICTION_IMPROVEMENT_PLAN.md using GPT-5.6 Luna, one agent. Follow the fixed
> candidate order, gates and stopping rules. Implement candidates only in an isolated checkout.
> Do not expand the experiment or tune after validation. If fresh protected data is unavailable,
> finish with the tested patch and a benchmark-qualified/rejected/inconclusive report; keep
> production defaults unchanged. Preserve user edits and provide concise results and artifact links.
