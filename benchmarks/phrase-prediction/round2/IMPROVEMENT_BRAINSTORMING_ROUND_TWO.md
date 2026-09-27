# Cotabby 1337 improvement experiments — round two

This is round two's working checklist, hypothesis register, and decision record. The benchmark
runner owns replay and scoring; this document connects those measurements to a bounded decision.
Round one's completed record remains in `IMPROVEMENT_BRAINSTORMING.md`.

## Window and baseline

- Status: **closing early at the user’s request; retain P2-H**.
- At approximately 08:39 PDT, the user superseded the six-hour requirement with a request to stop
  within ten minutes to conserve ChatGPT usage. No new inference runs were started afterward.
- Start: **2026-09-17 05:21:09 PDT / 12:21:09 UTC**.
- Full six-hour deadline: **2026-09-17 11:21:09 PDT / 18:21:09 UTC**.
- Fresh-data readiness gate: **06:06:09 PDT / 13:06:09 UTC**.
- Finalist freeze deadline: **08:21:09 PDT / 15:21:09 UTC**, preferably earlier.
- Starting app revision: `cd99305b169c714074c6ea1fda33f21e6cd0beda`.
- Baseline behavior: round-one P2-H, compact surface metadata; temperature 0.1,
  repetition penalty 1.025, top-k 20, top-p 0.7, min-p 0.08. Native repetition history is 64 tokens.
- Model remains the existing local `Qwen3.5-0.8B-Base.i1-Q6_K.gguf`.
- Main already contains unrelated/documentation changes. Preserve them. Controlled experiments
  use a byte-verified app/native snapshot outside Documents, with explicit source/model hashes.
- All native token-healing changes present at round start are baseline prerequisites, not round-two gains.
- Raw evidence: `build/eval/round2-20260917/`. No corpus answers or outputs enter production rules.

## Question and registered experiment list

Does changing which tokens receive repetition penalties, and which context facts the model sees,
improve next-word accuracy without harming partial-word behavior or responsiveness?

All candidates retain the same model, sampler strength/filters, output budget, seed, score matching,
display eligibility, and input identities. Changes are experimental until the adoption gates pass.

| ID | Single change from baseline | Status |
| --- | --- | --- |
| H1 | Repetition history: last 16 tokens | Complete: screen 284/770; none 235/770 |
| H2 | Repetition history: last 32 tokens | Complete: screen 286/770; none 235/770 |
| H3 | Repetition history: last 128 tokens | Complete: screen 288/770; none 235/770 |
| H4 | Apply repetition penalties only to sampled tokens, including token-healing replay | Complete: screen 280/770; none 236/770 |
| F1 | Screen label `Context:` | Complete: screen 285/770; none 235/770 |
| F2 | Screen label `Screen context:` | Complete: screen 284/770; none 235/770 |
| F3 | Render the bounded screen reference as a Markdown blockquote | Complete: screen 280/770; none 235/770 |
| F4 | Place screen section before surface metadata; exact caret prefix stays last | Complete: screen 274/770; none 235/770 |
| M1 | Omit only App from compact surface metadata | Complete: screen 281/770; none 237/770 |
| M2 | Omit only Format | Complete: screen 294/770; none 225/770 |
| M3 | Omit only Title | Complete: screen 264/770; none 210/770 |
| M4 | Omit only Field | Complete: screen 282/770; none 241/770 |

Before inference, audit that a prompt variant changes actual screening inputs; a no-op does not
count as a tested alternative. One predeclared replacement for a universally absent metadata field
is existing metadata rendered one field per line. Native windows must change effective history
membership in a targeted check. H4 matches unpenalized sampling at the first sampled token but
can differ after generated tokens accumulate; preserve other sampler state and token healing.

After single variants, select the highest-screen-accuracy nonbaseline candidate in each family,
breaking exact ties by no-screen accuracy and then fixed ID order. A component qualifies only if
its screen correct count exceeds baseline and no-screen correct count is at least baseline.
Eligible combinations are the three family-winner pairs and the triple, at most four total.
Run only those that compose cleanly and fit before the freeze deadline. No second adaptive grid.
Rank the final completed candidate set with the same primary/tie rules and freeze one candidate
before opening fresh validation results. An absence of a qualifying candidate means baseline wins.

## Data and acceptance criteria registered before scores

1. The existing 1337 corpus is development/regression data: every old scenario has contributed to
   inspected evidence. Use the same balanced 140-phrase screening subset as round one. A new
   shuffle of the old corpus is not fresh validation.
2. Independently author approximately 600–700 new synthetic validation scenarios, with explicit
   source/template-family identities, useful/distracting/neutral context labels, and a distinct
   fixture version/hash. Keep all related cases in a family together. Freeze the data before
   candidate tuning; candidate selection must not inspect fresh reference examples or results.
   Audit duplication against old data mechanically, not by tuning hypotheses to fresh answers.
3. Preserve the default version-two corpus's exact 1337/191-per-category contract. Supplementary
   data requires its own explicit fixture pathway and validity checks. If checked fresh data and
   that pathway are not ready by minute 45, the round is exploratory and baseline defaults remain.
4. Fresh paired screen-context gain must be at least **+0.50 percentage points**, with a 95%
   category-stratified family-bootstrap lower bound above zero. No-screen change must be at least
   **-0.50 pp**, with its lower bound above **-1.0 pp**. Use 20,000 bootstrap resamples, seed 1337.
   These intervals describe the synthetic scenario families, not population writing quality.
5. No fresh screen category may decline by more than **3 pp**. Report useful/distracting/neutral
   groups separately. Preserve visible category uncertainty and all unfavorable results.
6. Require nonnegative overall word-score changes in both conditions on the unchanged 1337
   matched regression pair. This is historical comparison, not independent confirmation.
7. Overall partial-word accuracy must not decline in either condition on the registered balanced
   character subset (initial plan: first 50 scenarios/category in corpus order). Report boundary
   and partial-only scores separately and retain category intervals.
8. One-worker p95 latency uses matching inputs with no overlapping builds/inference. Investigate
   regression above the larger of **10% or 20 ms** before adoption. Benchmark latency excludes
   focus tracking, debounce, and overlay rendering.
9. Verify the frozen candidate with a matching production-seed baseline (`12648430`) if primary
   comparisons use benchmark seed 42; require positive screen gain and no-screen delta >= -0.50 pp.
   Prefer the production seed for the full current-main integration comparison.
10. Require error-free complete reports, source/model/fixture integrity, focused unit tests and
    build, and current-main integration. Preserve native cache, cancellation, and token-healing
    invariants. Failed or inconclusive protected validation keeps P2-H; no replacement finalist
    may be selected after looking at those results.

## Six-hour allocation

| Elapsed | Work |
| --- | --- |
| 0:00–0:45 | Snapshot, fresh fixture/data readiness, correctness checks, baseline timing |
| 0:45–2:30 | Implement and screen the feasible 12 single alternatives |
| 2:30–3:00 | Eligible combinations and candidate freeze |
| 3:00–4:00 | Fresh validation first, then the old 1337 regression pair |
| 4:00–5:00 | Character/stress checks and isolated one-worker latency |
| 5:00–6:00 | Current-main integration, tests, decision, evidence, and cleanup |

Reserve the final 20 minutes for closure. Admit a run only when its complete comparison and
protected reserve fit the measured remaining time. Run inference experiments sequentially; each
may use three independent workers. If implementation takes longer, record skipped candidates
and protect validation. A complete negative/inconclusive decision still completes the round.

If freezing early leaves additional validation time, use this predeclared priority after the
mandatory comparisons: (1) fresh word-mode seed 1337 pair, (2) expand the old balanced character
comparison to 150 scenarios/category, (3) counterbalance the one-worker latency order with a
second pair. Each optional workload needs a recorded timing estimate and the same closure
reserve. These robustness checks cannot change the frozen finalist or authorize further tuning.

## Progress checklist

- [x] Start the six-hour goal and record the deadline.
- [x] Create this separate round-two brainstorming and decision file.
- [x] Register candidates, combination rule, data policy, and acceptance gates before scores.
- [x] Freeze and verify current app/native/model inputs in an isolated execution directory.
- [x] Prepare, audit, and hash fresh validation data without exposing it to candidate selection.
- [x] Add and validate the supplementary-fixture pathway; preserve the 1337 contract.
- [x] Validate native-history feasibility, cache restoration, and token healing.
- [x] Audit prompt variants for actual input changes.
- [x] Run a fresh matching screening baseline and measure runtime.
- [x] Benchmark each feasible single candidate; update the table with results or skip reasons.
- [x] Apply the combination rule: no family winner qualifies, so no eligible combinations exist.
- [x] Freeze one finalist or retain baseline by the three-hour deadline.
- [x] Complete fresh and historical word characterization after baseline retention.
- [x] Complete the registered first-50/category partial-word characterization after an exact retry.
- [ ] Broader historical/supplementary partial-word checks — deferred at the user’s early-stop request.
- [ ] Repeated isolated one-worker latency — deferred; failed preflight evidence retained, no valid timing claim.
- [x] Complete production-seed/current-main integration and focused tests/build.
- [x] Retain P2-H: none of the 12 alternatives qualified; no replacement after fresh results.
- [x] Preserve compact results, source prerequisites, and reproduction commands.
- [x] Review changes and remove experiment `build/DerivedData` after all testing finishes.
- [ ] Full six-hour window — superseded by the user’s early-stop instruction.
- [ ] Close within ten minutes of that instruction and summarize results and limitations.

## Experiment log

- 05:21 PDT: Round two started. The app has advanced to `cd99305` since round one; a new baseline
  snapshot is required. Main documentation/untracked results and pre-existing native edits remain
  untouched. Fresh-data authorship, supplementary harness support, and native-history review are
  separate parallel tasks; controlled inference will run sequentially.
- 05:22 PDT: User requested a separate round-two Markdown file. Created this document as the
  active checklist; the original six-hour start/deadline remain unchanged.
- 05:25 PDT: Snapshot ready outside Documents: 658 app files and 15 native files verified against
  current source bytes and modes; model SHA-256 matches round one. Controlled execution lives in
  `/Users/jmcasler/.codex/experiments/cotabby-1337-round2-20260917/`. Fresh-data authorship,
  supplementary fixture support, and native-history variants are proceeding independently.
- 05:32 PDT: All baseline/H1–H4 native sources pass strict C++17 syntax checks. Actual llama
  sampler checks cover history expiry, selective reset, other sampler state, and RNG preservation;
  eight temporary-fixture source-selector checks also pass. H4's sampled history includes native
  token-healing replay, even when already-typed bytes are hidden from displayed output. The full
  sampler still accepts prompt tokens; only the penalty child resets its history afterward.
  App-level cache/token-healing tests remain required before candidate inference.
- Prompt variants are frozen as explicit source files. F3 uses a Markdown blockquote so truncation
  cannot leave an unmatched closing quotation delimiter. A model-free XCTest audits all 1,540
  old-screening prompt inputs through the actual request factory before benchmark inference.
- 05:36 PDT: Fresh baseline Release build and 108 Swift tests passed, including native cache,
  token-healing, supplementary-fixture contracts, and all 1,540 screening prompt inputs. The
  changed harness/analyzer area also passes 48 Python tests. Started the baseline word replay;
  fresh validation references remain hidden from candidate selection.
- 05:40 PDT: Screening baseline completed in 135.6 seconds after its correctness checks:
  screen **288/770 (37.403%)**, no-screen **235/770 (30.519%)**, zero inference errors.
  This matches round one's selected configuration's screening counts. Three-worker timings
  remain throughput diagnostics; one-worker latency will be measured separately.
- 05:43 PDT: Mechanical fresh-data and actual Swift fixture-contract checks passed: 700 cases,
  140 five-case families, 100 cases/category, and 2,890 word checkpoints/condition. No exact
  reference or five-word sequence overlaps the old corpus. Useful/distracting/neutral counts are
  235/235/230; independent semantic review is still pending before final data freeze. Ten prefix
  analyzer tests also passed, bringing the checked Python suites to 58 tests.

- 05:53 PDT: Fresh data frozen after independent semantic QA and final Python/Swift/CLI checks,
  ahead of the 06:06 readiness gate. Final fixture has 700 cases, 140 families and **2,892 word
  checkpoints/condition** (the earlier draft had 2,890). Protected SHA-256:
  `2529c17f21b276eecafe7859853b1aafeba967346f205fa9f378631aa2dda828`. The custodian reviewed every family;
  no exact old-data overlap or complete-answer leakage was found. This is AI-authored synthetic
  convenience data; family members and shared prose patterns are dependent. Duplicated OCR/UI
  noise does not establish retained long-context performance. Raw fresh examples remain withheld
  from candidate selection.

- 05:55 PDT: Before any alternative score, clarified the conservative finalist rule: a selected
  nonbaseline result must exceed baseline screen accuracy and meet baseline no-screen accuracy,
  as required for combination components. Exact ties use the table order H1–H4, F1–F4, M1–M4,
  followed by eligible pairs H+F, H+M, F+M, then the triple. No qualifier retains baseline.

- 06:04 PDT: All four native-history alternatives completed required cache/cancellation/healing
  checks and error-free screening. Screen/no-screen counts: H1 **284/235**, H2 **286/235**,
  H3 **288/235**, H4 **280/236**, each out of 770 per condition. Baseline is **288/235**.
  No history component qualifies, so no history combination will be proposed. Formatting
  and metadata alternatives continue under the same frozen screening inputs.

- 06:25 PDT: All **12** alternatives completed error-free screening. No candidate exceeded
  baseline screen accuracy while meeting baseline no-screen accuracy. M2 (omit Format) gained
  screen points **294/770**, but fell to **225/770** without screen context. M4 (omit Field)
  improved no-screen to **241/770**, but fell to **282/770** with screen context. M3 (omit Title)
  fell to **264/210**. The registered family rule yields **zero eligible combinations**.
  Retain P2-H as the selection result; the full six-hour window remains active for broader
  baseline characterization, robustness checks, integration, evidence, and next-round hypotheses.

- 06:26 PDT: Baseline selection frozen before any supplementary replay. The independent decision
  assessor verifies **retained-baseline**. Remaining tests are descriptive baseline characterization,
  not a search for another winner: fresh word seeds 42/1337/12648430, historical word checks,
  partial-word coverage, repeated uncontended latency, and current-main compatibility. Optional
  larger character cohorts require a measured timing admission and the same 20-minute closure
  reserve. The protected fixture/score rules stay fixed, and the full six-hour deadline remains.

- 06:36 PDT: Fresh baseline seed42 completed **5,784 predictions with zero errors** in 299.0
  replay seconds after checks. Screen **982/2,892 (33.956%)**; no-screen **936/2,892 (32.365%)**.
  The paired context difference is **+1.591 pp**, not an implementation gain. Family-cluster
  uncertainty and context-kind breakdowns are pending. Full historical1337 seed42 replay started.

- 06:40 PDT: Fresh seed42 descriptive analysis passed all evidence checks. The **+1.591 pp**
  screen-minus-none difference has a 95% category-stratified family-bootstrap interval of
  **[+0.613, +2.613] pp** (20,000 resamples, seed1337;140families). Useful context:
  **+5.344 pp [+3.371, +7.411]**; distracting **0.000 pp [−1.035, +1.034]**; neutral
  **−0.639 pp [−1.816, +0.620]**. Category intervals remain in the full report. These are
  descriptive synthetic-corpus effects of context on the retained baseline, not a round-two
  implementation improvement or a real-user population estimate.

- 06:47 PDT: Historical1337 seed42 replay passed halfway without reported errors. Current-main
  compatibility preparation preserves the concurrent Codex bundle-classification edit and its
  focused test. The integration snapshot records that exact difference from the frozen baseline;
  neither corpus contains the affected bundle identity. No round-two production change is adopted.

- 06:55 PDT: Full historical1337 seed42 completed **14,874 predictions with zero errors**
  in 1,114.5 replay seconds after checks. Screen **2,789/7,437 (37.502%)**; no-screen
  **2,306/7,437 (31.007%)**. These correct counts match round one's recorded P2-H baseline;
  that aggregate match is not a claim of identical historical source bytes. The balanced
  character subset (350 scenarios, 17,660 paired predictions) is now running.

- 06:58 PDT: Historical seed42 descriptive context difference is **+6.495 pp**, with a
  95% category-stratified phrase-bootstrap interval **[+5.613, +7.366] pp**. Context helped
  813 checkpoints and harmed 330. This historical diagnostic is not independent fresh-data
  confirmation; its larger effect than the fresh corpus reflects different scenario populations.
  An independent guard review also confirmed the optional all700 fresh-character pathway after
  tightening corpus-hash checks before and after replay. No extended workload has started yet.

- 07:10 PDT: The first character50 attempt ended incomplete near 84%. Its stack enters
  `NSApplication.terminate` through the menu's Quit action before a Metal resource-cleanup
  assertion; Xcode returned test-execution failure. Preserve the failed attempt and partial raw
  output, and do not score it as a complete result. This is evidence of a host interruption,
  not proof that ordinary model generation spontaneously failed.
- 07:12 PDT: Registered and started `character50-baseline-retry1` with the same 350 scenarios,
  frozen sources/model/scorer, seed42 and three workers. The original failure stays visible.
  The new recovery queue then continues the already registered fresh1337, fresh production-seed,
  and historical production-seed runs. The six-hour deadline and closure reserve are unchanged.

- 07:27 PDT: Exact character50 retry completed **17,660 predictions with zero errors** in
  **887.2 replay seconds**. Partial-only screen **4,883/6,936 (70.401%)**; no-screen
  **4,205/6,936 (60.626%)**. Boundary-only screen **764/1,894 (40.338%)**; no-screen
  **626/1,894 (33.052%)**. Combined scores are 63.952% / 54.711%; the combined denominator
  must not replace the separate partial and boundary results. Fresh seed1337 replay started.
- 07:29 PDT: Registered optional character expansion using measured retry throughput,
  a 1.3 safety multiplier, 120 seconds setup allowance and rounding upward: old150/category
  (1,050 scenarios; 54,732 predictions), **3,720 seconds**; all700 fresh character mode
  (28,210 predictions), **1,980 seconds**. These are baseline-only descriptive checks, queued
  after required core/integration/latency work and subject to time admission when launched.
  A separate hashed guard exception authorizes complete fresh-character coverage without
  changing the frozen fixture, scorer, source, model, sampling or selection decision.

- 07:32 PDT: Fresh seed1337 completed **5,784 predictions with zero errors** in 302.6 replay
  seconds. Screen **986/2,892 (34.094%)**; no-screen **932/2,892 (32.227%)**. Each condition
  differs from seed42 by four correct predictions; this is repeated sampling on the same data,
  not another independent corpus. Fresh production-seed replay is running.
- 07:32 PDT: Main advanced to `585179bd2fcc34d0147861ecc479ca4020731acb`, committing the already
  captured Codex-detection edit. Complete verification found all 658 app and 15 native source
  entries unchanged from the prepared integration snapshot, including file modes. Integration
  preparation now records that revision-only change while preserving the original snapshot.

- 07:38 PDT: Fresh production seed12648430 completed **5,784 predictions with zero errors**
  in 306.4 replay seconds. Screen **986/2,892 (34.094%)**; no-screen **937/2,892 (32.400%)**.
  Across the three fresh word seeds, screen correct counts span 982–986 and no-screen 932–937.
  The observed range is small, but three seeds do not characterize all sampling randomness.
  Historical full1337 production-seed replay is now running.

- 07:44 PDT: Descriptive character50 offset analysis used only recorded correctness/showing
  flags and matched the authoritative totals. Screen-context accuracy gains by typed prefix:
  one character **+12.26 pp**; two **+11.46**; three **+10.08**; four–five **+7.22**; six-plus
  **+5.13**. Different words/scenarios contribute to each bin, so this is not a causal offset
  effect. Screen partial mismatches comprise **1,678 shown reference mismatches** and
  **375 suppressed outputs** (371 seam guard; four normalizer). Four-plus-character bins hold
  **2,299/6,936** partial checkpoints but **324/375** screen suppressions. No guard was changed.

- 07:56 PDT: Historical full1337 production seed completed **14,874 predictions with zero
  errors** in **1,060.8 replay seconds**. Screen **2,813/7,437 (37.824%)**; no-screen
  **2,322/7,437 (31.222%)**, matching round one's recorded production-seed counts. Required
  fresh and historical word characterization is complete. Current-main integration started
  with a fresh build and 114 expected focused test methods, followed by matching full1337 replay.

- 08:00 PDT: Current-main integration's fresh build and **114 focused XCTest methods passed**,
  including the preserved Codex-detection test. The 1,540-input prompt audit matches baseline
  exactly. Full production-seed replay is active; exact output parity and final before/after
  preservation checks remain pending.

- 08:15 PDT: Current-main integration passed with **zero mismatches across all 14,874
  checkpoints**: prompt, raw completion, displayed text, predicted word, suppression, showing
  and correctness flags all match the production-seed control. All working source files and
  reviewed revision evidence passed preservation checks. Integration replay took 859.2 seconds;
  this three-worker duration is not a controlled latency result.
- 08:15 PDT: `latency-baseline-1` was refused at preflight before any build/inference because
  Time Machine's `backupd` process was observed at 63.9–64.9% CPU. Preserve the failed isolation
  proof; it has no score or timing sample. Keep the backup running and use the available window
  for the registered old150/category accuracy expansion. Isolated timing will be retried under
  a new registered label when quiet; this changes workload order, not the benchmark or selection.

- 08:18 PDT: The first old150/category attempt also ended incomplete shortly after launch.
  Its stack again shows menu Quit → `NSApplication.terminate` → exit-time Metal cleanup
  assertion. Preserve this failed attempt without scoring. Asked whether another Cotabby task
  or manual testing is closing the shared test host; the input's origin is unknown. The frozen
  benchmark code and selection are unchanged, and remaining independent analysis continues.

- 08:31 PDT: Registered distinct old150 and first-latency retries; original interrupted and
  failed-preflight evidence stays intact. The existing menu visibility preference can be supplied
  through Xcode's documented host launch arguments. A standalone Foundation/SwiftUI probe
  confirms `@AppStorage` reads the icon as hidden with `-cotabbyMenuBarIconVisible NO`, with
  no persistent-domain writes. A separate hash-bound launch wrapper is being reviewed; no
  benchmark/scorer/model/production source is changed by this operational isolation.
- 08:31 PDT: Seed-stability diagnostic joins only existing Swift correctness flags on the same
  fresh word checkpoints. Across seeds 42, 1337 and production, **64/2,892 screen** and
  **43/2,892 no-screen** checkpoints change correctness. Context helps **102** checkpoints
  in all three seeds and harms **52** in all three; its correctness difference varies for **100**.
  Repeated seeds remain the same synthetic cases, not independent extra validation data.

- 08:39 PDT: User requested a reasonable stopping point within ten minutes because ChatGPT
  usage was running low. Stopped new launches and optional agent work immediately. All twelve
  alternatives have complete screening results; none qualifies, so no production performance
  change is justified. Core word, first-50/category partial-word, production-seed and current-main
  parity checks are complete. Larger character retries and isolated latency repeats are deferred.
  The host-menu wrapper remains unexecuted experimental tooling with incomplete final peer review.
  Archive the failed attempts, planned-but-unstarted retries, completed results and source prerequisites.

- 08:43 PDT: Final descriptive refresh passed with seven complete characterization runs and all
  incomplete/unstarted attempts visible. Across screening and characterization, **20 completed
  runs contain 99,654 predictions with zero inference errors**. Current main/native production
  inventory still matches the completed integration snapshot. Removed both isolated DerivedData
  directories (2,921,996 KiB allocated); main’s build directory and user edits were untouched.

## Prospective next-round hypotheses — not tested in this round

- [ ] Omit Format only when usable screen context is present. M2 improved the screen development
  score but hurt no-screen, so a conditional rule is a hypothesis, not a demonstrated combined gain.
- [ ] Omit Field only when screen context is absent. M4 showed the opposite tradeoff. The
  conditional implementation and its behavior on new data still require independent measurement.
- [ ] If both conditional single policies qualify in a new round, test their combination:
  omit Format with usable screen context; omit Field without it. This combination was not
  eligible under round two's registered family rule and is not a result of this round.
- [ ] Keep title metadata unless stronger evidence supports a narrower policy. Removing it hurt
  both development conditions substantially in M3.
- [ ] Investigate longer-prefix suppression using matched word/scenario groups. Determine why
  generated continuations fail the existing seam guard before proposing any behavior change;
  the aggregate offset pattern does not justify weakening a protection on already-typed text.
- [ ] Use new protected data for any next-round selection after inspecting this round’s fresh
  outcomes. Reusing these 700 cases would make them development data.

For those conditional hypotheses, “screen context present” must mean a cleaned, nonempty
excerpt that actually survives prompt budgeting. A settings toggle or the synthetic corpus's
useful/distracting/neutral labels are not valid production gates. A bounded iteration would
finish with a prompt audit of the affected and unaffected branches, one matched development
replay, focused tests for absent/blank/truncated context, and a keep/reject decision. Any apparent
gain still needs new protected data, partial-word checks, and a production-seed replay.
