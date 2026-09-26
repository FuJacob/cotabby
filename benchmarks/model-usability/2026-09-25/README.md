# Installed-model usability investigation — 2026-09-25 UTC

This investigation evaluates CoHamster's four downloaded catalog GGUFs on an Apple M1 Max with
32 GiB memory, macOS 27.0 (26A428). All generation ran locally through the Release app's Swift
request builder, llama.cpp integration, normalization, and display eligibility rules.

## Practical outcome

**Mini is the best measured starting point for these local word-prediction workloads. Nano is
best when latency and download size matter most. Base and Pro did not show a consistent
next-word advantage that justified their larger files; Pro was substantially slower.** Small
accuracy differences among Mini, Base and Pro are inconclusive, and this is one bounded English
sample, not a universal ranking.

The poor-prediction complaint is reproducible. None of these models eliminated the short
technical-prefix failures. No generation-quality fix passed screening, so no shipping prompt,
sampler, selected model, or installed app was changed. The fixes in this change address the
harness and misleading evaluation settings; **the semantic prediction problem remains open**.

Each next-word percentage below uses the same 584 checkpoints from 105 held-out scenarios.
File size is the installed GGUF size in decimal GB, not a peak RAM measurement. Latency is
final generation through the replay pipeline, excluding load and UI work.

| Model | GGUF GB | Next word: no screen | Next word: screen | p95 ms: no screen / screen |
|---|---:|---:|---:|---:|
| Nano | 0.63 | 29.5% | 36.6% | 110 / 113 |
| Mini | 1.27 | 31.8% | 40.6% | 193 / 232 |
| Base | 3.85 | 30.7% | 41.3% | 247 / 281 |
| Pro | 5.34 | 31.7% | 40.2% | 440 / 490 |

Screen context improved all four scores on these synthetic scenarios. This does not establish
that real OCR provides the same improvement, nor that a displayed suggestion is correct.

Partial-word scores use 767 checkpoints per context from the same smaller 35-scenario subset.
These scores concern finishing a word after one or more letters, not guessing the next word.

| Model | Partial word: no screen | Partial word: screen |
|---|---:|---:|
| Nano | 59.2% | 65.3% |
| Mini | 56.5% | 69.8% |
| Base | 53.2% | 64.8% |
| Pro | 53.2% | 66.0% |

Nano's partial-word result and lower latency make it a reasonable alternative to Mini for fast
typing. The harness therefore does not automatically promote one model or change the app's
selection based on a single aggregate score.

## What was investigated

The user's debug logs contained wrong raw model completions, including `apple int` →
`ellij idea.` and an invented description of MLX as a language. Synthetic regression cases
reproduce related failures without storing the user's captured conversations. A wrong raw
completion is not necessarily displayed: for example, the seam guard suppresses the `intellij`
continuation in the replay. Other incorrect fluent continuations pass the display rules.

This is evidence of model/prompt quality limitations. The native cache and cancellation checks
are reported separately; they cannot establish semantic correctness. Apple Intelligence was
not benchmarked, so these results do not quantify an Apple-versus-GGUF quality gap or isolate
quantization as a cause.

Representative raw completions from the synthetic failure corpus (no screen context):

| Model | After `apple int` | After `Mlx ` |
|---|---|---|
| Nano | `erop is not working.` | `is a very popular app for creating 3D` |
| Mini | `erpreter is not working.` | `1000000000` |
| Base | `ellij idea.` | `is a language for technical discussions.` |
| Pro | `el nvidia amd` | `12.3.1 (21E` |

The Apple example includes a preceding sentence about incorrect GGUF predictions; full prefixes,
raw outputs, displayed outputs and suppressions are in [failure-examples.json](failure-examples.json).
Base's `ellij` completion is suppressed. Nano's display path adds a separating space before
`erop`; the raw prediction was already wrong for the intended word. These are not all display
failures of the same kind, and a blanket cleanup rule would not repair their meaning.

Conversely, Mini's continuation of `gguf models are ` is `not as good as apple intelligence.`.
That conveys the intended complaint, yet misses the fixture's next word `really`. This illustrates
why exact-word percentages must not be presented as percentages of semantically bad suggestions.

## Scripted typing

Five fixed traces cover unfinished words, backspace/retype, rapid word acceptance, lists, and
editing before existing text. Each runs cold/prewarmed and streamed/final-only: 20 sessions per
model. The streamed results below have 20 intended-useful opportunities per cache condition.

| Model | Useful: cold / prewarmed | First-useful p95 ms: cold / prewarmed |
|---|---:|---:|
| Nano | 8/20 / 10/20 | 97 / 124 |
| Mini | 6/20 / 7/20 | 120 / 108 |
| Base | 7/20 / 7/20 | 153 / 121 |
| Pro | 5/20 / 5/20 | 179 / 167 |

Latency is conditional on a useful result appearing; missing results stay in the opportunity
denominator. These are small deterministic schedules, not measured user acceptance rates.
Nano was the most responsive in these traces. Streaming helped useful text arrive before final
completion, but fast edits still left many opportunities without an expected useful suggestion.
All typing measurements had zero generation failures. Superseded callbacks were observed and
rejected by the replay probes; they are not counted as useful output or evidence of actual UI
insertion. Full cold/prewarmed and streaming/final-only measurements are retained in the evidence.

## Verification and retained evidence

- Completed 16 final replay jobs: **13,624 scored checkpoints, zero inference errors**. Sixteen
  checkpoints are tiny runtime smoke replays; the rest are word, character, and regression work.
- All **24 native integration checks** passed: six per model, including cache restoration,
  discarded tails, sampling state, cancellation, and valid cumulative Unicode streaming.
- All four typing suites passed, with 20 sessions per model.
- **108 targeted Swift unit tests** and **64 Python tests** passed. Release build-for-testing
  passed. Existing unrelated Swift concurrency warnings remain in the build log.
- The final runs share the same app/test/native source fingerprint and the same selected inputs
  per workload. The 105 held-out word scenarios have no overlap with the prompt-screening sample.

[All validation metrics](validation.md), [machine-readable summary](summary.json), and
[compressed evidence](evidence.tar.gz) are saved beside this report. The archive contains
completed screening/validation manifests, synthetic prompts and completions, typing reports,
and native/unit test logs. [The archive checksum](evidence.sha256) detects accidental changes.
Captured user debug conversations, model weights and build products are not in the archive.
Raw run directories remain under `build/eval`; `build/DerivedData` was removed after verification.

## Method and limits

- Final validation: 105 held-out word scenarios (15 per category), paired with and without
  synthetic screen context; 35 held-out character scenarios (5 per category); 14 diagnostic
  regression scenarios; native runtime checks and synthetic typing traces.
- Hash-based split seed 1337; fixed inference seed 42; one inference worker; 4–7-word setting;
  synthetic Alex/English profile for phrase replay. Typing traces use their own standard profile.
- Seven categories: conversation, everyday, work, technology, science, entertainment, travel.
- Exact intended-word match is an agreement metric, **not a semantic quality rating**. Another
  reasonable word is a miss. Suppression is also a miss; display coverage is not usefulness.
- Spelling and seam decisions use this Mac's native spelling configuration. English fixture and
  response-language settings do not replace the system dictionary. Raw and displayed text are
  retained separately, including any spacing repair or suppression applied after generation.
- Word and character sets overlap. Character-mode boundary scores come from a smaller subset;
  do not pool these observations as independent evidence or compare their boundary percentages
  as if the inputs were identical.
- Final-generation latency excludes loading, keyboard debounce, Accessibility, and drawing.
  Typing traces include their simulated debounce and measure display eligibility, not pixels.
- Screen context is synthetic text passed through production cleanup and budgeting. No live
  screen capture, real typing acceptance rate, multilingual evaluation, or human semantic rating
  was measured. This is a bounded English qualification, not a claim of universal quality.

## Changes and rejected experiments

The harness discovers exact catalog filenames and fails on missing weights, records source,
model and corpus fingerprints, fixes the worker count, and retains raw and displayed
output plus suppression reasons. It refuses stale build reuse and marks interrupted campaigns
incomplete. It does not download weights or modify saved app settings.

The older eval omitted the user's name/language profile, and the typing suite hardcoded
12–20 words. The new controls reproduce a synthetic personalized profile and honor the chosen
word-count setting. The default for this usability runner is 4–7 words, matching the setting
observed during investigation; the original phrase CLI retains its default unless overridden.

App-hosted test execution also needed repair: a disposable ad-hoc-signed app, retargeted XCTest
framework paths, and hash-checked custom corpus copies avoid stale signatures, Finder metadata,
and file-open stalls under Documents. This is test infrastructure, not a model quality fix.

Three prompt experiments were rejected:

1. Removing surface/profile/language hints reduced next-word accuracy for every model on the
   initial screening sample. Keeping the actual draft and screen excerpt alone was insufficient.
2. Shortening the English-language paragraph improved one Base score but reduced screen-context
   accuracy and partial-word regression accuracy.
3. Omitting app branding and generic field labels gave mixed Base scores and did not fix the
   reported cases. `apple int` still produced `ellij idea.`; MLX still received an invented
   description. A fruit-related Apple completion also appeared with this variant.

Shipping prompts and model selection therefore remain unchanged. `content-only`,
`compact-language`, and `compact-surface` remain explicit harness controls for reproduction;
none is enabled in normal app requests.

## Reproduction

See [the harness guide](../../../SUPPORTED_MODEL_EVAL.md). The completed validation command is:

```sh
scripts/prepare_cohamster_workspace.sh
python3 scripts/supported_model_eval.py --stage validate --variants production \
  --output build/eval/supported-validation-final
```

Use a new output directory when repeating a run. The runner rebuilds verified Release test
binaries by default. Remove `build/DerivedData` after all tests finish; evaluation artifacts
are retained separately under `build/eval`.

Historical experiment labels predate the final CLI names: in `supported-language-screen-3`,
`legacy-language` is the shipping baseline and `production` means the rejected compact-language
candidate. In `supported-surface-screen-3`, `legacy-surface` is the shipping baseline and
`production` means the rejected compact-surface candidate. In `supported-screen-2` and final
validation, `production` is the unchanged shipping prompt. Initial all-model screening used
12–20 words, so its latencies must not be compared with final 4–7-word measurements.
