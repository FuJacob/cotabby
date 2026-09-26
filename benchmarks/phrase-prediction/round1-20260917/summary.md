# Cotabby 1337 improvement round — September 17, 2026

**Decision: Candidate selected by explicit report command.** This report does not modify the application.

Evidence snapshot: 2026-09-17T11:14:18.183500+00:00. Six-hour window: 2026-09-17T05:13:55Z–2026-09-17T11:13:55Z.

Frozen finalist: **screen-P2-H**, compact surface metadata (P2), temperature 0.1, repetition penalty 1.025, top-k 20, top-p 0.7, min-p 0.08. Frozen at 2026-09-17T06:19:21.698237+00:00; no further tuning is part of validation. Production's existing `nil` seed delegates to the fixed native default `0x00C0_FFEE` (12648430); it does not request a random seed. This delegation is unchanged.

The six-hour round is complete. The frozen P2-H candidate was applied to five main files after all 13 registered acceptance gates passed, including the current-main integration comparison and 171 candidate Swift tests/build. All registered inference runs, final source verification, and DerivedData cleanup are complete.

[Round completion](round-completion.json) records the full six-hour window closed at 2026-09-17T11:14:15.288889+00:00 (21620.289 elapsed seconds). Its candidate, acceptance, test, and cleanup counts were checked against the retained evidence.

The guarded application completed at 2026-09-17T10:24:36.096133+00:00: **5 files applied**, 13 registered acceptance gates passed, and no preflight source drift. [Compact adoption evidence](main-adoption-summary.json) retains the file hashes and checks; full source inventories remain local.

[Final source verification](final-source-verification.json) at 2026-09-17T11:02:07.690919+00:00 found no drift across 553 protected files since the adopted, validated state.

## Screening

20/20 alternatives completed. Ranked by exact screen correct count, then no-screen correct count. The isolated repeat baseline is excluded.

| Rank | Candidate | Screen correct / 770 | No screen correct / 770 |
|---:|---|---:|---:|
| — | screen-baseline | 271 | 208 |
| 1 | screen-P2-H | 288 | 235 |
| 2 | screen-P2-B | 287 | 244 |
| 3 | screen-P2-E | 287 | 238 |
| 4 | screen-P2-F | 285 | 237 |
| 5 | screen-P2-C | 284 | 242 |
| 6 | screen-P2 | 283 | 232 |
| 7 | screen-P3 | 282 | 217 |
| 8 | screen-P4 | 280 | 238 |
| 9 | screen-P2-G | 280 | 236 |
| 10 | screen-P2-A | 279 | 241 |
| 11 | screen-P2-D | 279 | 239 |
| 12 | screen-B | 278 | 211 |
| 13 | screen-E | 272 | 209 |
| 14 | screen-H | 271 | 214 |
| 15 | screen-A | 270 | 211 |
| 16 | screen-C | 270 | 201 |
| 17 | screen-D | 267 | 213 |
| 18 | screen-F | 267 | 202 |
| 19 | screen-G | 266 | 217 |
| 20 | screen-P1 | 258 | 198 |

## Completed validation

| Pair / metric | Condition | Baseline | Candidate | Change | 95% phrase interval |
|---|---|---:|---:|---:|---:|
| character150-all / all | screen | 16069/27366 (58.719%) | 17078/27366 (62.406%) | +3.687 pp | [+3.194, +4.182] pp |
| character150-all / all | none | 13770/27366 (50.318%) | 14725/27366 (53.808%) | +3.490 pp | [+2.893, +4.102] pp |
| character150-word / nextWord | screen | 2013/5782 (34.815%) | 2199/5782 (38.032%) | +3.217 pp | [+2.483, +3.949] pp |
| character150-word / nextWord | none | 1664/5782 (28.779%) | 1800/5782 (31.131%) | +2.352 pp | [+1.583, +3.128] pp |
| full42 / nextWord | screen | 2566/7437 (34.503%) | 2789/7437 (37.502%) | +2.999 pp | [+2.362, +3.646] pp |
| full42 / nextWord | none | 2117/7437 (28.466%) | 2306/7437 (31.007%) | +2.541 pp | [+1.856, +3.221] pp |
| heldout42 / nextWord | screen | 2295/6667 (34.423%) | 2501/6667 (37.513%) | +3.090 pp | [+2.404, +3.778] pp |
| heldout42 / nextWord | none | 1909/6667 (28.634%) | 2071/6667 (31.063%) | +2.430 pp | [+1.715, +3.131] pp |
| integration / nextWord | screen | 2586/7437 (34.772%) | 2813/7437 (37.824%) | +3.052 pp | [+2.409, +3.693] pp |
| integration / nextWord | none | 2120/7437 (28.506%) | 2322/7437 (31.222%) | +2.716 pp | [+2.051, +3.382] pp |
| latency / nextWord | screen | 267/770 (34.675%) | 289/770 (37.532%) | +2.857 pp | [+0.896, +4.916] pp |
| latency / nextWord | none | 204/770 (26.494%) | 244/770 (31.688%) | +5.195 pp | [+3.075, +7.345] pp |
| productionseed / nextWord | screen | 2586/7437 (34.772%) | 2813/7437 (37.824%) | +3.052 pp | [+2.409, +3.693] pp |
| productionseed / nextWord | none | 2120/7437 (28.506%) | 2322/7437 (31.222%) | +2.716 pp | [+2.051, +3.382] pp |
| seed1337-150 / nextWord | screen | 2036/5782 (35.213%) | 2217/5782 (38.343%) | +3.130 pp | [+2.396, +3.865] pp |
| seed1337-150 / nextWord | none | 1665/5782 (28.796%) | 1819/5782 (31.460%) | +2.663 pp | [+1.904, +3.438] pp |

Counts and deltas above were checked against the source report JSON. Confidence intervals are retained from the paired analysis and its recorded bootstrap settings. Category scores, coverage, latency, seeds, workers, and build/report hashes are in `report.json`.

The [frozen/integration pointwise comparison](integration-frozen-parity.md) verified 29,748 matched observations across baseline/candidate and screen/no-screen: 0 differences in the recorded checkpoint, prompt/excerpt, raw/display output, visibility, predicted word, correctness, or suppression fields. Latency is excluded. This is evidence for these inputs and seed, not general source-policy equivalence.

## Single-worker benchmark latency

Observed p95 values from the matched single-worker evidence in `acceptance-final.json`. The timer begins after request construction and includes prediction, normalization, and presentation policy; live focus, debounce, and overlay time are excluded. These point estimates have no latency confidence interval and do not establish a causal or end-to-end speedup.

| Condition | Baseline p95 (ms) | Candidate p95 (ms) | Observed change (ms) |
|---|---:|---:|---:|
| screen | 151.3 | 143.5 | -7.8 |
| none | 197.1 | 188.0 | -9.1 |

## Integrated defaults: descriptive replay

The completed [default confirmation](integrated-default-confirmation.json) used no sampler or seed CLI flags. Its implicit benchmark seed is **42**, distinct from production’s nil-to-native seed **12648430**. These unpaired scores use the integrated candidate and current-main policies; no cross-seed or cross-pipeline paired gain is inferred.

| Condition | Next word correct / checkpoints | Accuracy |
|---|---:|---:|
| screen | 2789/7437 | 37.502% |
| none | 2306/7437 | 31.007% |

## Remaining checks

No outstanding checks were found in the latest acceptance snapshot and registered validation inventory. This does not automatically change the explicit decision.

Latest runner record: `seed1337-150-finalist` (final report present). This record alone does not confirm the process has completed.

## Tests and provenance

- `finalist-unit-validation.log`: largest recorded Swift suite 103 tests; 0 failures; successful test execution recorded; successful build recorded.
- `initial-validation.log`: largest recorded Swift suite 26 tests; 0 failures; successful test execution recorded; build result not included in this log.
- `integration-baseline-unit-validation.log`: largest recorded Swift suite 166 tests; 0 failures; successful test execution recorded; successful build recorded.
- `integration-candidate-unit-validation.log`: largest recorded Swift suite 171 tests; 0 failures; successful test execution recorded; successful build recorded.
- `python-validation-final.log`: 52 Python tests recorded; successful test execution recorded.
- Starting app revision: `342a76d002b534d13d3a9689768d13fda12f8609`; current main revision at export: `342a76d002b534d13d3a9689768d13fda12f8609`.
- Native revision: `7574a21516c65fc31f5cf8ef7380a03412eed480`; pre-existing native patch SHA-256: `814a139320af2bcbfb57751508511c4a2f0e62ef8e4f56fbb951fedbf74d4bd5`.
- Model: `Qwen3.5-0.8B-Base.i1-Q6_K.gguf`; SHA-256 `febd85051361ccb34d0925744c819f9ae0724117e8f946a2852dd0edfa90a5a1`.
- Corpus SHA-256: `b41c8089a58ae1e0ee84b95ac9283cf71db4e713e25bd8fed47220be69d8b0f6`.
- Frozen source/native file hashes, finalist source identity, criteria, path-migration checks, and compact analysis snapshots accompany this report.

## Scope and limitations

- The corpus is synthetic English writing. Exact lexical agreement is not semantic quality or representative real-world typing utility.
- The benchmark covers synthetic OCR cleanup, request/prompt construction, local llama generation, normalization, and display gating; not actual capture, Accessibility, keyboard events, acceptance, or overlays.
- Scenario apps are Messages (573), Safari (382), Notes (191), and Mail (191). None of the 1,337 scenarios supplies a URL field, so browser-domain formatting has unit coverage but no domain-valued benchmark input.
- Sampling and prompt screening used 140 phrases. The frozen finalist was selected before its 1,197 held-out phrases were evaluated. Full-corpus runs overlap screening and do not replace held-out evidence.
- Phrase-cluster intervals describe fixture uncertainty. Screening intervals are not corrected for selecting among 20 alternatives; seed checks and latency evidence are separate.
- Parallel-worker timings include contention. Matched single-worker runs measure benchmark latency from after request construction through prediction, normalization, and presentation policy; live focus, debounce, and overlay latency are excluded.
- The fixed native dependency already contained uncommitted token-healing work when the round began. Its revision, patch hash, and frozen file hashes are prerequisites, not improvements attributed to this round.
- P2 changes shared base-prompt metadata formatting and therefore can affect configured OpenAI-compatible endpoints, which were not benchmarked. No new metadata fields or transmission scope are authorized by these results. Apple prompt rendering is unaffected; repetition penalty is llama-specific.
- Only Qwen3.5-0.8B-Base.i1-Q6_K was benchmarked. The shared llama default also changes other local model configurations, whose quality was not measured.
- Controlled comparisons use frozen app/harness/native inputs. Concurrent current-main typo, seam, word-completion, coordinator, and benchmark-policy edits are preserved and require separately labeled integration evidence.
- maxPredictionTokens=5 is a configured floor, not the output ceiling: the 12–20-word preset and 1.3 factor produce a 26-token request. This budget was unchanged across experiments.
- Execution moved outside Documents after pre-main dyld/getxattr stalls. Source/native/model identities and screening repeatability were checked; failed attempts remain local and are not scored as completed comparisons.

## Local evidence

Raw reports, prompts, completions, journals, logs, and failed attempts remain local under `/Users/jmcasler/Documents/GitHub/mchamster/cotabby/build/eval/round1-20260917`. Compact source-prerequisite patches and portable commands are retained in [reproduction.md](reproduction.md).

The [comparison charts](reportplots.md) show screening trade-offs and completed word-validation intervals. The [failure review](failure-review.md) records aggregate diagnostics for planning a later round.

The registered [character diagnostic workflow](character-diagnostics.md) retains its helper, plan, and source rationale.

This directory contains compact aggregates, source prerequisites, and provenance. Existing `baseline-v1` and other historical benchmark folders were not modified. Rerun the round-local `write_round_report.py --decision pending|candidate|baseline` to refresh this snapshot; its default is pending.

[Cleanup evidence](cleanup.json) records 3 removed DerivedData directories and 1 already absent directory. Raw benchmark evidence and source prerequisites remain retained.

Completed [character subset and boundary-identity diagnostics](character150-subsets.md) are retained with their [aggregate JSON](character150-subsets.json). These supplemental diagnostics preserve the original score denominators and do not authorize retuning.

[Partial-word category caveats](character150-subsets.md#partial-word-uncertainty): technology/none -1.681 pp (95% interval [-3.620, +0.214]); science/screen -0.083 pp (95% interval [-1.133, +0.915]). Overall gains do not imply every category improved; these category estimates are descriptive.
