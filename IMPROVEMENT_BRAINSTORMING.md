# 1337 benchmark improvement experiments

This is the working checklist and decision record for improving Cotabby's local autocomplete.
The benchmark runner owns replay and scoring; this document records hypotheses, evidence,
and decisions so experiments do not silently become product defaults.

## Selected result

Applied **P2-H** after comparing 20 alternatives: compact surface labels and a standard repetition
penalty of **1.025** (previously 1.05). Held-out screen next-word accuracy improved from **34.42%
to 37.51%**, a **+3.09 percentage-point** gain; the paired 95% interval is **+2.40 to +3.78 pp**.
No-screen accuracy improved from **28.63% to 31.06%**. The final full-corpus default-command
replay scored **37.50% screen / 31.01% no-screen**.

All 13 acceptance gates passed, including the Release build and 171 focused Swift tests;
52 Python tests also passed. Other working-tree changes were preserved. Results apply to the
tested Qwen model and synthetic corpus; category-level partial-word caveats remain in the report.
The full six-hour window is complete: closed at **04:14:15 PDT**, after **6 hours and 20 seconds**.

- [Results and limitations](benchmarks/phrase-prediction/round1-20260917/summary.md)
- [Comparison charts](benchmarks/phrase-prediction/round1-20260917/reportplots.md)
- [Reproduction instructions](benchmarks/phrase-prediction/round1-20260917/reproduction.md)

## Six-hour round 1

- Start: 2026-09-16 22:13:55 America/Los_Angeles (2026-09-17 05:13:55 UTC).
- Finish: 2026-09-17 04:13:55 America/Los_Angeles (2026-09-17 11:13:55 UTC).
- Starting revision: `342a76d` on `master`; working tree was clean.
- Use the entire window for implementation, comparisons, failure analysis, and validation.
- Run inference experiments sequentially; each run may use the benchmark's three independent workers.
- Keep model, corpus, replay settings, and selected phrase identities fixed within comparisons.
- Model: `Qwen3.5-0.8B-Base.i1-Q6_K.gguf` (existing local file; no downloads).
- Corpus: version 2, paired screen/no-screen scenarios. The primary score is screen next-word
  accuracy; no-screen accuracy and category results are guardrails.
- Existing full baseline: screen 34.50% (2,566/7,437); no-screen 28.47% (2,117/7,437).
- Preserve the corpus, reference matching, denominator, and display eligibility rules.
- Select a candidate using screening data; freeze finalists before examining held-out results.
- Measure benchmark latency separately with one worker because pooled workers contend for GPU time.
  This times prediction and output handling, not live focus tracking, debounce, or overlay rendering.
- A negative or inconclusive experiment is complete when its evidence and decision are recorded.
- Native dependency: the development workspace points at the sibling `cotabbyinference` checkout,
  revision `7574a215`, with existing token-healing edits. Those edits are preserved and frozen for
  this round. The starting patch and hash are recorded in `build/eval/round1-20260917/`.
- After concurrent edits appeared in the main checkout, further experiments moved to the detached
  `build/phrase-round1-checkout` worktree at the starting revision, plus only this round's explicit
  harness changes. The native dependency and model remain the same. Each checkout's build output
  stays in its own `build/DerivedData`; both directories will be removed after testing finishes.
- Native code is also mirrored into `build/phrase-round1-native/cotabbyinference`. All 15 repository
  files match the starting native checkout exactly, including its pre-existing token-healing edits.
  The frozen app workspace references this copy; original native files remain untouched.
- Current execution is outside Documents at
  `/Users/jmcasler/.codex/experiments/cotabby-1337-20260917/cotabby`, after FileProvider-related
  startup stalls. App/native/model bytes and exact screening output equivalence were verified.
  A separate `integration/cotabby` snapshot includes concurrent main-checkout work for matched
  compatibility checks. Each snapshot owns its own `build/DerivedData`; all experiment build
  products will be cleaned after validation. Reports and source prerequisites are retained.

### Decision criteria registered before candidate results

1. Rank screening candidates by screen next-word accuracy, breaking close ties using no-screen
   accuracy and simplicity. Freeze one finalist before opening held-out results. Any additional
   candidates evaluated on those results are exploratory and cannot replace this confirmatory test.
2. For adoption, require at least +0.50 percentage points screen improvement on held-out scenarios
   and a paired, category-stratified phrase-bootstrap 95% interval whose lower bound exceeds zero.
   Phrase resampling keeps correlated checkpoints together; these intervals describe this synthetic
   corpus and do not establish general population writing quality.
3. No-screen held-out accuracy must lose no more than 0.50 percentage points, with its 95% lower
   bound above -1.0 percentage point. No category screen loss may exceed 3 percentage points.
4. Recheck the winner against its matching baseline with the production seed `12648430`: require
   positive screen gain and no-screen point estimate at least -0.50 percentage points. Greedy
   configurations still require this check because the baseline is sampled.
5. Compare one-worker p95 latency on matching inputs. Investigate regression above the larger of
   10% or 20 ms before adoption; three-worker measurements are throughput diagnostics, not typing latency.
6. Require error-free complete reports, relevant unit tests, and a successful build. Full-corpus
   scores include screening data and are descriptive confirmation, not a second unseen test.
7. If these conditions are not met, keep product defaults and label any leading candidate provisional.

Validation priorities for the remaining window are: held-out word-mode seed 42; full word-mode
production seed; full word-mode seed 42; broad character-mode baseline/finalist; one-worker latency;
then additional fixed-seed robustness pairs if time permits. Additional seeds, registered before
validation, are 1337, 2026, and 314159 (in that order). These runs assess robustness; they cannot be
used to tune the already-frozen finalist. Confirmatory bootstrap analyses use 20,000 resamples.

## Preparation

- [x] Inspect current repository, benchmark scope, baseline artifacts, and model availability.
- [x] Create this checklist and record the six-hour deadline.
- [x] Verify native greedy decoding, repetition history, filter order, and cache behavior.
- [x] Add validated benchmark-only sampling overrides with actual settings in run metadata.
- [x] Establish reproducible balanced screening (20 scenarios/category) and disjoint held-out sets.
- [x] Validate selection/configuration controls without inference (23 Python tests and native options test).
- [x] Build and run a fresh matching screening baseline; measure runtime and budget remaining work.

## Candidate hypotheses

All unspecified sampling parameters retain the baseline: temperature 0.1, repetition penalty 1.05,
top-k 20, top-p 0.7, min-p 0.08, fixed seed 42. Sampling overrides are confined to the experiment
until validation justifies a product change. Greedy must mean the native greedy path, not merely
a small nonzero temperature.

| ID | Decoding | Repetition penalty | Status / evidence |
| --- | --- | --- | --- |
| baseline | temperature 0.1 | 1.05 | Complete: screen 35.195% (271/770), none 27.013% (208/770) |
| A | greedy | 1.0 | Complete: screen 35.065% (270/770), none 27.403% (211/770) |
| B | greedy | 1.025 | Complete: screen 36.104% (278/770), none 27.403% (211/770) |
| C | greedy | 1.05 | Complete: screen 35.065% (270/770), none 26.104% (201/770) |
| D | temperature 0.05 | 1.0 | Complete: screen 34.675% (267/770), none 27.662% (213/770) |
| E | temperature 0.05 | 1.025 | Complete: screen 35.325% (272/770), none 27.143% (209/770) |
| F | temperature 0.05 | 1.05 | Complete: screen 34.675% (267/770), none 26.234% (202/770) |
| G | temperature 0.1 | 1.0 | Complete: screen 34.545% (266/770), none 28.182% (217/770) |
| H | temperature 0.1 | 1.025 | Complete: screen 35.195% (271/770), none 27.792% (214/770) |

- [x] Compare A–H on the same screening phrases; record independent configurations and reports.
- [x] Test four justified follow-ups (metadata omission, compact labels, title only, draft boundary).
- Adaptive selection after the early sampling results: prompt changes have stronger evidence than
  redundant probability-filter changes. Each P candidate uses the original baseline sampler.

| ID | Prompt change | Hypothesis | Status |
| --- | --- | --- | --- |
| P1 | Omit surface section | App/window descriptions distract from the draft | Complete: screen 33.506%, none 25.714% |
| P2 | Compact format/app/title/field labels | Preserve cues without prose UI narration | Complete: screen 36.753%, none 30.130% |
| P3 | Sanitized title only | Topic cues help; role/app/field boilerplate distracts | Complete: screen 36.623%, none 28.182% |
| P4 | Explicit reference/draft boundary | Separate background information from text being continued | Complete: screen 36.364%, none 30.909% |

- [x] If independent prompt and sampler changes help, benchmark their combination before freezing a finalist.
  Both effects now have screening evidence. Registered interaction follow-up: select the best P1–P4
  prompt by screen accuracy (then no-screen accuracy), then repeat the eight original nonbaseline
  sampler configurations with that single prompt. This finite eight-run extension fits the six-hour
  window and checks whether prompt-token history changes the preferred repetition penalty. It uses
  only screening data; no held-out results have been opened. Do not add another tuning round afterward.
- [x] Audit whether normalization/seam suppression loses correct words before proposing changes.
- [x] Validate character-mode partial-word behavior on the registered balanced subset.
- [x] Consider shorter output budgets as an efficiency experiment if time and evidence warrant it.
  Deferred to keep the round focused on prompt/sampler changes. The configuration value of five
  tokens is a floor, not the request ceiling: the fixed 12–20-word preset and 1.3 tokens/word
  produce a 26-token request budget here. Preserve that budget across all comparisons.


### Frozen interaction winner

All eight interactions use P2 compact metadata with the original A–H sampler definitions above.

| ID | Screen correct / 770 | No-screen correct / 770 | Screen accuracy |
| --- | ---: | ---: | ---: |
| P2-A | 279 | 241 | 36.234% |
| P2-B | 287 | 244 | 37.273% |
| P2-C | 284 | 242 | 36.883% |
| P2-D | 279 | 239 | 36.234% |
| P2-E | 287 | 238 | 37.273% |
| P2-F | 285 | 237 | 37.013% |
| P2-G | 280 | 236 | 36.364% |
| P2-H | 288 | 235 | 37.403% |

**Finalist: P2-H**, frozen at 23:19 PDT before held-out replay. Temperature 0.1, repetition
penalty 1.025, top-k 20, top-p 0.7, min-p 0.08. The exact primary score selected H; its one-checkpoint
lead over B/E is small, so validation—not screening rank alone—determines adoption. Twenty
alternatives are complete. No more candidate tuning is permitted in this round.

Reviewed P2 comments and focused tests preserve executable prompt behavior. The surface composer
retains sanitization, omissions, browser-only domain inputs, and bounded fields; the renderer still
prioritizes and ends with the exact caret prefix. This base prompt is shared with configured
OpenAI-compatible endpoints, whose quality is not measured here. No metadata or transmission
scope is added; Apple Intelligence's own renderer is unaffected.

## Validation and decision

- [x] Rank complete, error-free screening runs; count paired gains/losses and category changes.
- [x] Freeze one finalist and validation criteria before opening held-out candidate results.
- [x] Compare baseline and the frozen finalist on disjoint held-out phrases.
- [x] Validate the strongest candidate on all 1,337 scenarios if supported by held-out evidence.
- [x] Check repeatability and/or additional paired seeds where material.
  Screening and historical full baseline reproduce exactly; the production-seed pair also passes.
  Additional seeds remain optional robustness checks within the remaining window.
- [x] Validate word boundaries and partial-word completions separately in character-mode replay.
- [x] Measure baseline/finalist latency with matching one-worker runs.
- [x] Run relevant unit tests and build checks for retained code changes.
- [x] Retain a supported winner or explicitly keep baseline defaults.
- [x] Preserve compact result artifacts and exact reproduction commands.
- [x] Review diff, finish this document, and remove `build/DerivedData` after all testing ends.
- [x] Complete the full six-hour window and report results and remaining limitations.

## Broader brainstorming backlog

For a future iteration, define completion as a finite comparison and a recorded decision, rather
than a promised score increase. Register the candidate list, protected validation data, acceptance
criteria, and wall-clock deadline before results. Time the first baseline, reserve validation and
cleanup time, and admit another experiment only when its complete comparison fits that reserve.
Freeze the winner before validation; a failed gate means keeping the baseline. This round's
inspected validation failures should inform hypotheses, but a later tuned winner needs newly
protected validation data.

- [ ] Compare models/quantization under an explicit future model-comparison round.
- [ ] Improve screen-context selection or conditioning using generic failure classes, not fixture answers.
- [ ] Explore complete-word likelihood versus greedy token choice if sampling changes plateau.
- [ ] Validate on independently authored unseen writing beyond the synthetic 1337 corpus.
- [ ] Keep typing, cancellation, acceptance-tail, and overlay evaluation separate from final-word accuracy.

## Experiment log

- 22:13 PDT: Round started. Current corpus includes screen context, unlike the earlier conversation's
  version-1 assumptions. Existing full results provide context; new comparisons will use matching
  code, selections, model, and worker counts. No unrelated user changes were present.
- Native audit: temperature <= 0 selects greedy after token masks and repetition penalties; greedy
  skips probability filters. Penalties use the last 64 prompt/generated tokens, so they can penalize
  facts already visible in screen context. Each prompt resets the sampler and repopulates its history.
- Existing full screen baseline has 100% coverage and no raw-to-shown modifications; broad suppression
  changes have no headroom there. The current production fallback seed is 12648430, versus eval seed 42.
- 22:22 PDT: Started fresh screening baseline build. Registered screening set has 140 scenarios /
  1,540 paired predictions; its disjoint complement has 1,197 scenarios / 13,334 predictions.
  Eight alternatives will follow the baseline sequentially with verified build reuse. The test-only
  options snapshot flows through the request factory to the sampler; saved user preferences remain
  unchanged. The offline analysis tool owns uncertainty/diagnostics separately from Swift scoring.
- 22:26 PDT: Fresh screening baseline completed without inference errors: screen 35.195%, none
  27.013%, both 100% coverage. The full build/launch/replay took 213 seconds; replay throughput was
  approximately 17 predictions/second. First build exposed a Swift type-checker timeout in the
  partition expression; an explicitly typed tuple array and separate sorting steps fixed compilation.
  Failed-build logs are preserved separately. Candidate A (greedy, no repetition penalty) is running.
- Screening miss audit: 49 of 499 screen misses start with a UI-related word, and concrete examples
  continue the surface description (message being typed, window title, field label). No raw-to-shown
  changes occurred. Context still helps overall (94 gains, 31 losses), so the follow-ups test metadata
  wording and draft separation while preserving screen facts, rather than stripping all context.
- 22:40 PDT: All eight sampling alternatives finished. B (greedy, penalty 1.025) leads screening at
  36.104% screen / 27.403% none, versus 35.195% / 27.013% baseline. Its screen net +7 checkpoints
  comes from 20 gains and 13 losses; phrase-bootstrap 95% interval is [-0.522, +2.308] pp, so this
  is provisional. All 26 targeted Swift tests passed, including sampled cache/RNG restoration,
  partition agreement, scoring, and all-scenario request adaptation. Twelve offline-analysis tests
  also passed. P1–P4 prompt experiments now rebuild independently after every source change.
- 22:47 PDT: Fresh screening baseline exactly matches the same 140 scenarios in the historical
  full baseline: zero prompt, displayed-output, or correctness differences across all 1,540 paired
  predictions, despite the earlier run using one worker and the new run using three.
- Prompt screening so far: omitting surface metadata loses accuracy in both conditions (33.506%
  screen / 25.714% none); title-only improves both (36.623% / 28.182%); compact labels improve both
  (36.753% / 30.130%). The remaining reference/draft boundary experiment is running. These results
  support preserving useful metadata while testing its representation, rather than assuming all
  UI-context references are harmful.
- 22:53 PDT: P4 completed at 36.364% screen / 30.909% none. P2 compact metadata remains the prompt
  leader on the registered primary score (36.753% screen / 30.130% none). The finite eight-candidate
  P2 × sampler interaction grid is starting; it is the last tuning stage before freezing a finalist.
- 22:56 PDT: Build fingerprint guard detected concurrent spelling/seam edits in the main checkout
  before P2-A inference began. Those edits are unrelated to this round and are preserved. Restored
  only our experimental prompt files in main, created an isolated worktree at the original revision,
  and copied only our harness changes there. A new isolated screening baseline will verify exact
  agreement before the interaction grid resumes. The failed setup's build log is retained separately.
- 23:01 PDT: Isolated app baseline matched all 1,540 original observations exactly, excluding timing.
  Created the native source mirror as well. SwiftPM requires its directory basename to remain
  `cotabbyinference`; corrected that setup-only identity error before inference. P2's domain field
  was also restricted to browsers, matching the original input scope. None of the 1,540 recorded
  P2 screening prompts contains a domain field, so this scope correction does not alter those inputs.

- 23:19 PDT: Completed all 20 alternatives and froze P2-H. Finalist screen gain is +2.208 pp
  (288 vs 271 correct), no-screen gain +3.506 pp (235 vs 208). Focused tests now include the
  request-factory boundary as well as composer/renderer budgets and runtime/eval invariants.
- Supplemental P2-only screening diagnostic: mean correct-prefix words screen 0.494→0.529;
  eligible two-word lexical matches 78/630→88/630; three-word matches 24/490→30/490. This
  preserves authoritative first-word scoring and censors text after reference endings; it is
  neither a semantic-quality judgment nor an estimate of saved keystrokes.

- 23:21 PDT: Focused Release build and 103 Swift tests passed with zero failures. Python control
  and analysis suites also pass (45 tests total). Started held-out seed-42 baseline/finalist pair
  on 1,197 scenarios / 13,334 paired predictions each. P2-H's 20,000-resample screening comparison
  gives screen +2.208 pp, 95% interval [+0.255,+4.275], 35 gains/18 losses; no-screen +3.506 pp,
  interval [+1.175,+5.867], 50 gains/23 losses. Selection across 20 candidates still requires the
  separately frozen held-out check. Detailed ranking is in the round's screening-ranking.md/json.

- 23:24 PDT: Held-out test-host startup paused for about 2.5 minutes before replay began. A
  process sample showed macOS dyld waiting while opening dependencies, before test execution.
  The host then progressed without intervention; no run was discarded or restarted. Startup
  overhead remains in wall-clock duration and is excluded from per-prediction latency.

- Screening prompt audit: all 1,540 baseline→P2-H input differences are confined to the first
  surface-metadata line. Everything after that line is byte-identical, including screen excerpt
  and caret prefix. Compact formatting removes 41.57 characters per prompt on average here;
  extra retained OCR or altered draft context does not explain this screening comparison.

- Character validation workload registered from timing estimates before any character results:
  first 150 scenarios/category in corpus order (1,050 scenarios, 54,732 paired checkpoints/run),
  seed 42, three workers, matching baseline/finalist. This broad subset reserves time for matched
  one-worker screening latency (production seed) and a separately labeled integration comparison
  alongside concurrent main-checkout changes. It cannot change the frozen finalist.

- 23:38 PDT: Held-out baseline completed without errors: screen 2,295/6,667 (34.423%),
  no-screen 1,909/6,667 (28.634%). Every prompt, shown output, and correctness flag matches the
  corresponding historical full baseline across all 13,334 observations. Together with screening,
  this reproduces all 14,874 baseline observations. The frozen finalist's held-out run is building.

- 23:45 PDT: The finalist's test host remained blocked before main/model loading for nearly
  five minutes. Independent filesystem reads also blocked while iCloud FileProvider reported
  update errors; this supports filesystem contention, without proving the exact blocked image.
  Cancelled only this round's stalled test processes before any prediction (no journal/report).
  Its failed launch logs are preserved under heldout42-finalist; no result was discarded.
- Moved execution to `/Users/jmcasler/.codex/experiments/cotabby-1337-20260917/cotabby`, outside
  Documents, with its own `build/DerivedData`, frozen native checkout, and identical model copy.
  Changed source bytes, all 15 native files, and model SHA-256 were verified. This is a path-only
  infrastructure adjustment; prompt/sampler/scoring and the frozen finalist stay unchanged.
  Replaying the screening baseline there before resuming held-out candidate validation.

- 23:51 PDT: The local-path screening baseline matched all 1,540 original prompts, shown outputs,
  checkpoints, and correctness flags exactly, with zero inference errors. Its test host launched
  promptly. The first clean build had generated its workspace dependency lockfile, so the input
  guard required a setup-only retry; remote dependency revisions were verified unchanged, and the
  native workspace reference still points to the byte-identical frozen source. Resumed candidate
  held-out validation as heldout42-local-finalist; the pre-main stalled attempt remains archived.

- Documentation correction: `maxPredictionTokens: 5` in reflected configuration metadata is the
  request-budget floor. The fixed 12–20-word setting flows through the production request factory
  and produces a 26-token single-line budget (20 × 1.3), with normal early stopping. No generation
  setting changed. The earlier five-token-ceiling note was incorrect and has been replaced.

- 00:05 PDT: Held-out P2-H completed without inference errors. Screen 2,295→2,501/6,667
  (34.423%→37.513%), +3.090 pp; paired 20,000-resample 95% interval [+2.404,+3.778]. No-screen
  1,909→2,071/6,667 (28.634%→31.063%), +2.430 pp; interval [+1.715,+3.131]. Every category
  improves in both conditions. All registered held-out gates pass; production-seed and
  one-worker latency gates remain pending, so adoption is not yet final.

- Held-out supplemental prefix diagnostic also improves: screen mean correct-prefix words
  0.485→0.541, eligible two-word matches 668→783/5,470 (12.212%→14.314%), three-word matches
  191→226/4,273 (4.470%→5.289%). No-screen mean 0.377→0.422, two-word 451→550/5,470,
  three-word 110→142/4,273. These strict lexical comparisons support, but do not replace, the
  next-word result and do not measure human acceptance or semantic correctness.

- 00:23 PDT: Full production-seed baseline completed: screen 2,586/7,437 (34.772%),
  no-screen 2,120/7,437 (28.506%), zero inference errors. Matching P2-H replay is underway
  with seed 12648430 and the same 1,337 scenarios / 14,874 paired checkpoints.

- 00:39 PDT: Full production-seed comparison passed. Screen 2,586→2,813/7,437
  (34.772%→37.824%), +3.052 pp, 95% interval [+2.409,+3.693]. No-screen 2,120→2,322/7,437
  (28.506%→31.222%), +2.716 pp, interval [+2.051,+3.382]. Both complete reports are error-free.
  Production-seed guardrails pass; one-worker latency remains the last acceptance gate. Started
  the separately registered full seed-42 pair. Source/prompt/sampler stay frozen.

- 00:47 PDT: Python benchmark and analysis checks now pass 51 tests, including dependency-resolution
  provenance. A clean build may create canonical package lockfiles before compilation inputs are
  frozen; concurrent app/test/native/config edits still reject the run, and build reuse never
  resolves dependencies. The active frozen runner remains unchanged. Preparing a separately
  verified snapshot of current main for integration without disturbing concurrent edits.

- 00:52 PDT: Verified a separate current-main integration snapshot outside Documents: 611 app
  inputs and 15 native files match stable before/after source hashes. It includes the concurrent
  spelling, seam, coordinator, and benchmark policy work. No integration build or inference yet.
  The app keeps `randomSeed: nil`, which delegates to the native runtime's fixed 12648430 default;
  it does not enable randomized seeds. The stale source comment will be corrected with adoption.

- 00:55 PDT: Full seed-42 baseline reproduced the historical aggregate exactly: screen
  2,566/7,437 (34.503%), no-screen 2,117/7,437 (28.466%), zero inference errors.
  Its matching frozen finalist is now running.
- Post-freeze diagnostic memo saved as `benchmarks/phrase-prediction/round1-20260917/failure-review.md`.
  Remaining word-boundary misses are overwhelmingly shown reference mismatches; approximate
  raw-correct/display-wrong losses are zero. Future priorities are general word-selection quality,
  context relevance, and independent continuation-utility evaluation, using newly protected data.
  These diagnostics do not authorize another tuning cycle in this round.

- 01:01 PDT: Current-main baseline integration snapshot builds successfully and passes 166
  model-free tests with zero failures. Prompt/request, typo, seam, caret-word, streaming,
  dismissal/cadence, coordinator prediction, and word-completion checks are included. All
  625 checked non-lock app/native inputs remain unchanged across resolution/build/test.
  The candidate will get the same checks after its separate matched integration comparison.

- 01:10 PDT: Full seed-42 comparison completed with zero errors. Screen 2,566→2,789/7,437
  (34.503%→37.502%), +2.999 pp, 95% interval [+2.362,+3.646]. No-screen
  2,117→2,306/7,437 (28.466%→31.007%), +2.541 pp, interval [+1.856,+3.221].
  Every observation (including prompt, raw/shown output, prediction, correctness, and checkpoint;
  excluding timing) exactly matches concatenated screening + held-out data for both configurations:
  14,874/14,874 each. Full-corpus scores remain descriptive, not a new unseen validation set.
- Started registered character150 baseline/finalist pair: 1,050 scenarios, 54,732 paired
  checkpoints per run, seed 42, three workers. No further candidate tuning.

- 01:42 PDT: Removed and verified absence of the obsolete Documents-isolated worktree's
  `build/DerivedData`. Its reports, source snapshot, and source-prerequisite patches remain.
  The active frozen and integration build directories are retained until their final checks finish.

- 01:59 PDT: Character150 baseline completed all 54,732 paired checkpoints without errors.
  Its word-boundary subset has 5,782 checkpoints per condition: screen 2,013 (34.815%),
  no-screen 1,664 (28.779%). The identical frozen finalist comparison is building.
  Supplemental diagnostics will separately report all, boundary, and partial-only checkpoints
  and check word-boundary output identity against full42; none can retune the frozen candidate.

- 02:24 PDT: Character finalist passed halfway (27,953/54,732 checkpoints), with no inference errors.
  Integration/adoption guards now inventory newly added or ignored source files as well as existing
  files, bind benchmark and unit evidence to exact compiler inputs, and journal atomic main-file
  replacement. Seven temporary-fixture checks passed independently; main adoption remains pending.
  Prepared a separately labeled, unpaired full-corpus replay of actual integrated defaults: no sampler
  or seed command-line overrides; expected benchmark seed 42, distinct from native production seed.

- 02:46 PDT: Character150 pair completed, 54,732 paired checkpoints per configuration, zero errors.
  Boundary screen 2,013→2,199/5,782 (+3.217 pp; 95% [+2.483,+3.949]); no-screen
  1,664→1,800 (+2.352 pp; [+1.583,+3.128]). Partial-only screen 14,056→14,879/21,584
  (+3.813 pp; [+3.247,+4.382]); no-screen 12,106→12,925 (+3.794 pp; [+3.087,+4.515]).
  No-screen technology partial accuracy falls 1.681 pp (95% [-3.620,+0.214]); screen science
  partial accuracy is effectively flat (-0.083 pp). These descriptive subsets remain visible.
  Comparing each configuration with its own full42 word run finds identical prompts and correctness
  at all 23,128 overlapping boundaries; eight raw-output differences occur only at later boundaries
  and do not change correctness, visibility, or suppression. One also changes the recorded predicted
  word, so they are not all tail-only differences. This does not establish a cache bug.
- 02:47 PDT: Started the matching one-worker latency pair on 140 screening scenarios, using
  production seed 12648430. No other inference or build runs overlap this measurement.

- 02:53 PDT: One-worker paired latency check passed on 140 screening scenarios, production seed.
  Screen p95 151.3→143.5 ms; no-screen 197.1→188.0 ms, both below the registered
  investigation threshold. Zero errors. These benchmark timings exclude focus/debounce/overlay.
  All held-out, production-seed, and latency gates now pass; final integrated build/unit evidence
  remains pending. Started strict full-corpus current-main integration baseline/candidate pair,
  using actual sampler defaults with only the production seed explicitly selected.

- 03:23 PDT: Strict full-corpus integration pair completed with actual sampler defaults and
  production seed, zero errors. Screen 2,586→2,813/7,437 (34.772%→37.824%, +3.052 pp);
  no-screen 2,120→2,322 (28.506%→31.222%, +2.716 pp). Aggregate scores match the frozen
  production-seed pair. The integration includes the concurrent main-checkout policy changes,
  and verifies complete compiler inputs around both builds. Candidate model-free tests are running.

- 03:24 PDT: Candidate Release build and all 171 focused Swift tests passed; source identity
  remained stable. All 13 registered acceptance gates pass. Guarded adoption changed exactly
  five reviewed files in main, preserving every other source file and file mode; journal:
  `build/eval/round1-20260917/main-adoption.json`. Main diff whitespace check passed.
  `SurfaceContextComposer` remains the pure boundary from sanitized focus facts to the base
  prompt: its compact labels reduce UI-description prose while retaining the same facts and
  omissions. `SuggestionConfiguration.standard` supplies immutable request defaults and now
  uses repetition penalty 1.025; nil seed delegation remains unchanged. Composer, renderer, and
  request-factory tests cover the data path. No coordinator, UI, or network scope was added.
- Started the separately labeled full-corpus integrated-default replay after adoption, with no
  sampler or seed flags. Its benchmark fallback seed is 42. This is descriptive default-command
  confirmation, not a new paired gain estimate or another tuning round.

- Integration pointwise audit: 29,748 matched word-boundary observations (baseline/candidate ×
  screen/no-screen × 7,437) exactly match their frozen production-seed counterparts in checkpoint,
  prompt, screen excerpt, raw/shown output, visibility, predicted word, correctness, suppression,
  and optional-field presence. Build/source identities differ as expected. This confirms parity
  for these recorded inputs and fields, not all interactive behavior. Compact evidence is retained
  as `integration-frozen-parity.json` and `.md`; no raw prompt/output excerpts are exported.

- 03:38 PDT: Actual integrated-default confirmation completed with zero errors: no sampler
  or seed CLI flags, manifest overrides `{}`, effective sampler 0.1/1.025/20/0.7/0.08 and
  benchmark seed 42. Screen 2,789/7,437 (37.502%); no-screen 2,306/7,437 (31.007%).
  This unpaired descriptive run confirms the default command; it is not a cross-seed gain estimate.
- Registered the final seed-1337 robustness pair before its predictions: first 150 corpus-order
  scenarios/category, 1,050 total, paired word mode, three workers. Measured runtimes support
  fitting this workload into the remaining window with an estimated 1,500-second pair
  and a 600-second completion reserve. Selection depends on timing only; the finalist stays frozen.
  Main remains on the adopted configuration; only the separate frozen experiment swaps baseline
  and candidate source for this matched pair. Seeds 2026 and 314159 remain optional and will be
  omitted if they cannot fit the same reserve.

- 03:42 PDT: Removed the completed integration checkout’s 1.4 GB `build/DerivedData` after
  verifying no integration build/test process remained and all 38 required evidence dependencies
  lived elsewhere with matching hashes. Workspace/package lock, source/native/model snapshots,
  reports, and logs are retained. The active frozen checkout’s build directory stays until its
  final seed pair finishes.

- 04:02 PDT: Final seed-1337 pair completed without errors: screen 2,036→2,217/5,782
  (35.213%→38.343%, +3.130 pp; 95% [+2.396,+3.866]); no-screen 1,665→1,819
  (28.796%→31.460%, +2.663 pp; [+1.904,+3.438]). All inference is complete.
  Optional seeds 2026 and 314159 cannot fit the same 600-second reserve and are deferred.
  Final source verification finds all 553 protected main files unchanged since validated adoption.
- 04:03 PDT: Removed the final frozen checkout’s 1.3 GB `build/DerivedData` after verifying
  all experiment build/test processes exited. Main, old Documents-isolated, frozen, and integration
  DerivedData paths are all absent. Reports, logs, source snapshots, and model remain available.
  The remaining six-hour window is reserved for final artifact and source review.

- 04:08 PDT: Final artifact review passed independently. Compact results contain eight metric
  records across seven matched validation pairs, plus the separately labeled default-command
  confirmation. Both comparison charts are readable; reproduction commands retain exact source,
  native, corpus, and model prerequisites. All 13 acceptance gates, 171 candidate Swift tests,
  52 Python tests, and the Release build passed. All four DerivedData paths are absent. The
  broader brainstorming backlog remains future work, not unfinished work in this round.

- 04:14 PDT: Closed the round after 21,620.289 seconds (six hours and 20 seconds). The final
  report validates and links `round-completion.json`, records the adopted P2-H decision, and has
  zero pending registered checks. All round-one checklist items are complete; future hypotheses
  remain unchecked in the separate backlog. No commit or push was performed.
