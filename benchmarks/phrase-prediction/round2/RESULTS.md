# Cotabby 1337 — round two results

**Final decision: retain P2-H.** All twelve registered alternatives completed screening,
but none improved screen-context accuracy while preserving the no-screen score. Selection
was frozen before inspecting the supplementary data. No production behavior was adopted.
The user shortened the planned six-hour window after about three hours and twenty minutes
to conserve ChatGPT usage. No new benchmark launches were started after that instruction. The round completed **20 runs
and 99,654 predictions with zero inference errors** across screening and characterization.

## What the alternatives taught us

Each condition used the same 770 word checkpoints. Baseline scored **288 with screen context
and 235 without**. The strongest screen result was M2, omitting Format: **294/225**. Its
six additional screen hits came with ten fewer no-screen hits, so it failed the registered
qualification rule. M4, omitting Field, made the opposite tradeoff at **282/241**.
Removing Title was worse in both conditions (**264/210**). Changing repetition history or
screen formatting did not produce a qualifying gain. There were no eligible combinations.

These are development comparisons on known data, not evidence that the baseline is globally
optimal. Conditional metadata policies are candidates for a future, separately registered
round with new protected data; they were not tested or selected here.

## Completed baseline characterization

| Corpus / seed | Screen correct | No-screen correct | Interpretation |
| --- | ---: | ---: | --- |
| Historical 1337 / 42 | 2,789/7,437 (37.502%) | 2,306/7,437 (31.007%) | Matches prior recorded baseline counts |
| Historical 1337 / production | 2,813/7,437 (37.824%) | 2,322/7,437 (31.222%) | Matches prior recorded production-seed counts |
| Supplementary 700 / 42 | 982/2,892 (33.956%) | 936/2,892 (32.365%) | Synthetic family-based descriptive check |
| Supplementary 700 / 1337 | 986/2,892 (34.094%) | 932/2,892 (32.227%) | Same cases, another seed |
| Supplementary 700 / production | 986/2,892 (34.094%) | 937/2,892 (32.400%) | Same cases, production seed |
| Historical first 50/category / partial prefixes, seed 42 | 4,883/6,936 (70.401%) | 4,205/6,936 (60.626%) | Partial-only; excludes word-boundary checkpoints |

All completed runs above had zero inference errors. Screen-minus-none differences describe
the existing baseline's use of context; they are not gains from a new implementation.

For the supplementary seed-42 word comparison, the context difference is **+1.591 percentage
points**, with a 95% category-stratified family-bootstrap interval of **[+0.613, +2.613]**.
Useful-context families account for the clearest gain; distracting and neutral groups do not
show a clear positive difference. These intervals concern the authored synthetic families,
not real-user writing quality. Repeated seeds are not additional independent scenarios.

Current-main integration passed **114 focused XCTest methods** and matched the historical
production-seed control exactly at all **14,874 paired checkpoints**, including prompts,
raw output, displayed text, suppression, and correctness. The concurrent Codex bundle
classification edit was preserved. These corpus scenarios do not exercise that bundle ID;
its focused unit test is separate evidence.

## Incomplete attempts and deferred checks

- Two character attempts ended when the test host followed its menu Quit path, followed by
  an exit-time Metal assertion. Input origin is unknown. Neither incomplete attempt was scored;
  a complete retry of the first 50/category run is reported above.
- The first isolated latency preflight refused to start while Time Machine exceeded the
  registered CPU threshold. It has no benchmark score or latency sample. The backup was left running.
- Broader historical and supplementary character checks and two isolated one-worker timing
  repeats were deferred when the user requested early closure. Three-worker replay durations are throughput observations, not
  controlled latency results.
- A test-host menu-hiding wrapper was prepared to avoid another Quit interruption. Its
  standalone preference probe and synthetic checks passed, but it was never used for inference
  and its final peer review was incomplete. It is archived as unexecuted experimental tooling.

## Evidence and reproduction

The authoritative adoption decision is `decision-assessment.json`. Descriptive measurements
and uncertainty are in `baseline-characterization.json`; each run retains its registration,
source/model/corpus identities, logs, and raw results. `reproduction-notes.md` explains the
native changes that predated this round and the exact inputs needed for a matching replay.
The brainstorming checklist records the planned window, hypotheses, execution decisions,
and user-directed early closure. The durable package retains these records independently
of compiler caches. Both isolated DerivedData directories were removed, freeing approximately
2.8 GiB of allocated build files. Current main/native production bytes still match the completed
integration snapshot. No performance change was merged, committed, or applied to production.
