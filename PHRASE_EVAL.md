# Contextual next-word benchmark

The harness replays **1,337 synthetic English writing scenarios**, with **191 per category**:
conversation, science, entertainment, work, technology, everyday life (`everyday`), and travel.
Each scenario pairs a target phrase with individually authored visible screen information. The
screen includes surrounding interface text and unrelated material, not just a category label.

For example, a lab note records ice forming at a thermometer reading of 0 Celsius while the writer
types “Water freezes at zero degrees Celsius.” A hotel message gives Friday-to-Sunday dates while
the writer types “I'd like to book a room for two nights.” Neither screen contains the complete
reference sentence. Facts and individual answer words can naturally occur on screen: using them
is the behavior being measured.

These are **synthetic screen-text fixtures**, not screenshots or captured user data. They exercise
Cotabby's production OCR cleanup, excerpt selection, request construction, prompt budgets, local
llama generation, normalization, and final display guard. They do not exercise screenshot capture,
Vision recognition, Accessibility, actual keyboard events, overlay rendering, or typing latency.

## Run

From the repository root, inspect the workload without loading a model:

```sh
python3 scripts/phrase_eval.py plan
# 1,337 scenarios; 14,874 predictions across both screen conditions

python3 scripts/phrase_eval.py plan --mode character
# 70,756 predictions across both screen conditions
```

Start with a **balanced smoke run** before running the full corpus:

```sh
python3 scripts/phrase_eval.py run --model /absolute/path/to/model.gguf \
  --per-category 2 --label contextual-smoke
# 14 scenarios; 140 predictions

python3 scripts/phrase_eval.py run --model /absolute/path/to/model.gguf --label baseline
```

The default `--context paired` executes each scenario both with and without screen OCR text.
The default **`--workers 3`** runs three independent inference engines in one test host. There is
one build, one combined progress percentage/ETA, and one final report. Use `--workers 1` for
uncontended latency measurements; `--workers 2` is also available for throughput comparisons.
Selections smaller than three phrases use only as many workers as there are phrases.
Other useful selections:

```sh
python3 scripts/phrase_eval.py run --model /absolute/path/to/model.gguf --category science
python3 scripts/phrase_eval.py run --model /absolute/path/to/model.gguf \
  --phrase travel-001 --mode character
python3 scripts/phrase_eval.py run --model /absolute/path/to/model.gguf --context screen
python3 scripts/phrase_eval.py run --model /absolute/path/to/model.gguf --context none
python3 scripts/phrase_eval.py run --model /absolute/path/to/model.gguf --workers 1
```

`--per-category N` takes the first N scenarios within each selected category. `--limit N` truncates
that selection globally; it is not a balanced sample. `--output /absolute/new/directory` selects a
new results directory. Existing directories are rejected to protect previous runs.

Omit `--model` to use the app runtime's model selection. Nothing is downloaded automatically.
This currently evaluates the local llama backend, with a fixed sampling seed of 42 and otherwise
product generation defaults. It requires macOS, Xcode, and the project's usual dependencies.
For a workspace with a local CotabbyInference checkout, add
`--workspace build/CotabbyDevelopment.xcworkspace` after creating that workspace through the
repository's existing setup tooling.

The CLI builds Release with testability and `RUN_LLAMA_EVAL`, then supplies configuration through
an `.xctestrun` file. Ordinary tests do not run inference: both the compile flag and the explicit
`COTABBY_PHRASE_EVAL=1` test-host switch are required. All build output goes into
`build/DerivedData`; remove that directory after the runs finish and no other build needs it.
Reports remain under `build/eval/phrases/`. Xcode build/launch failures are retained in the run logs.

## Store baselines in GitHub and compare a change

From the repository root, this uses the local model and development workspace already available
in this checkout. It runs all **1,337 scenarios / 14,874 predictions**, including both screen
conditions. Detailed run artifacts remain local; export the completed scores into the repository:

```sh
python3 scripts/phrase_eval.py run \
  --model build/models/Qwen3.5-0.8B-Base.i1-Q6_K.gguf \
  --workspace build/CotabbyDevelopment.xcworkspace \
  --label baseline-v1 \
  --output build/eval/phrases/baseline-v1

python3 scripts/phrase_eval.py save-baseline build/eval/phrases/baseline-v1 \
  --name baseline-v1

git add benchmarks/phrase-prediction/baseline-v1
git commit -m "Record phrase prediction baseline v1"
git push
```

After tweaking Cotabby, run the same command with a new label and directory:

```sh
python3 scripts/phrase_eval.py run \
  --model build/models/Qwen3.5-0.8B-Base.i1-Q6_K.gguf \
  --workspace build/CotabbyDevelopment.xcworkspace \
  --label candidate-v1 \
  --output build/eval/phrases/candidate-v1

python3 scripts/phrase_eval.py compare \
  benchmarks/phrase-prediction/baseline-v1/report.json \
  build/eval/phrases/candidate-v1/report.json \
  > build/eval/phrases/candidate-v1/comparison.txt
```

`save-baseline` works with any completed run directory, including the previously suggested
`$HOME/Documents/CotabbyBenchmarks/baseline-v1`. It writes three Git-trackable files under
`benchmarks/phrase-prediction/<name>/`: `report.json`, `summary.txt`, and `manifest.json`.
The report preserves all phrase/category/suite scores, both context conditions, context lift,
latency metrics, fixture/checkpoint identities, model/corpus hashes, and generation settings.
The manifest records the original run's revision, working-tree status, platform, and report hash.
Both the run metadata and exported manifest record the effective worker count. Older baselines
without this field are treated as one-worker runs.
Model paths are reduced to filenames. Full prompts, completions, journals, patches, and Xcode logs
stay in the local run directory; model weights remain gitignored.

Exports carry `baselineFormatVersion: 1` and are intended for score comparison, not replay or
per-prediction debugging. Failed, incomplete, or duplicate runs are rejected. Existing baseline
folders cannot be overwritten: give each accepted baseline a new name. Commit the evaluated code
before collecting a release baseline; exporting results does not commit, push, or snapshot dirty
source files. Export a candidate the same way when you want to preserve it in GitHub too.

During a run, the terminal displays progress such as:

```text
Building | elapsed 00:00:25 | replay ETA available after predictions begin
Replay  42.0% | 6,247/14,874 predictions | elapsed 00:08:00 | ETA 00:11:03 | science-083 [screen]
```

Progress counts completed predictions, updating as each phrase-condition record is saved.
The journal receives results from all workers in completion order; progress counts each result
once. The final report restores the original phrase/condition order for baseline comparisons.
The ETA estimates **remaining replay time** from elapsed replay time and the completed checkpoint
count; it excludes build/model-loading time and cannot predict final report/test teardown time.
It starts as `estimating`, then adapts as predictions finish. Percentages update about once per
second in a terminal or every five seconds when redirected/piped. At 100%, the runner still checks
the test result and report before printing `Complete: replay and report validation passed.`
Ctrl-C stops the child command and preserves completed records; an interrupted run is not a
complete baseline and cannot be resumed. Raw Xcode output remains in `build.log` and `test.log`.

## Inputs and controls

Each corpus record contains:

- A stable ID, category, and reference phrase.
- A screen kind, application/bundle identity, window title, and focused-field placeholder.
- `screenText`: a visible chat, email, reference note, support discussion, or travel message,
  plus interface text and unrelated content.
- `documentPrefix`: text already present in the focused field for some scenarios.

A checkpoint's input is the existing draft plus the portion of the reference phrase typed so far.
Future words, the category label, and the reference phrase as a whole are never supplied to the
request adapter. The first word of the phrase supplies context and is not scored; words in the
existing draft are not scored either.

The **none** condition keeps the same existing draft and app/title/field metadata but supplies no
screen OCR excerpt. The **screen** condition adds synthetic high-confidence OCR lines with fixed
geometry above the input field. The current typed text is included as an OCR echo so the real
field-text stripping policy is exercised. Production cleanup, selection, sanitization, and prompt
budgets still apply. This measures the incremental value of visible screen text beyond the active
field and surface metadata, rather than comparing unrelated prompts.

The cache is reset before every scenario-condition replay. Condition order alternates to reduce
warmup/thermal bias. Phrases are distributed round-robin across workers using their original
selection indices, so condition order does not change when worker count changes. Each worker owns
its own model context, sampler, cache, and spell checker for the run. Model initialization finishes
before concurrent replay begins. A worker retains its prompt cache as the phrase grows within a
condition, and all checkpoints and both conditions of a phrase stay on that worker. In-flight
native generations run off the main actor; journal writes and spell checking remain serialized.
The replay waits for final output, then advances through the **reference text regardless of the
prediction**. A wrong prediction therefore cannot change later checkpoints. Clipboard, profile,
and custom rules are disabled. Use `LlamaTypingSessionEvalTests` separately for timing, streaming,
acceptance, and cancellation behavior.

In word mode, `Please send the report.` produces targets `send`, `the`, and `report` at their word
boundaries. Character mode additionally tests `Please s`, `Please se`, and `Please sen`. Completing
`se` with `nd` succeeds; ` nd` or `nder` does not. Partial-word accuracy is reported separately from
zero-letter next-word accuracy.

## Scores

Every correct complete next word earns **1**, every other outcome earns **0**. Empty output,
suppression, and inference errors remain in the denominator. A plausible synonym is still a miss:
this measures prediction of the intended wording, not general semantic quality.

Matching ignores case and terminal punctuation and normalizes curly/straight apostrophes. Internal
apostrophes and hyphens remain significant. `cat` does not match `catalog`, `cats`, `cat's`, or `ca`;
`don't` does not match `dont`. Leading wrong words or broken spacing at the caret cannot be skipped.

For **each phrase, each category, and the suite**, each condition reports:

| Metric | Meaning |
| --- | --- |
| Next-word accuracy | Correct zero-letter predictions divided by all word-boundary checkpoints. |
| Coverage | Nonempty display-eligible predictions divided by all checkpoints. |
| Precision when shown | Correct predictions divided by shown predictions. |
| All-checkpoint accuracy | Also includes partially typed words in character mode. |
| Mean phrase accuracy | Gives each phrase equal weight regardless of length. |
| Mean category accuracy | Gives each category's pooled next-word accuracy equal weight. |
| Latency p50/p95 | Final generation plus display guard, excluding gated requests and errors. |

Paired runs additionally report **screen-context lift**: screen accuracy minus no-screen accuracy,
at phrase, category, and suite levels. They also count checkpoints that changed from wrong to right
and from right to wrong. Negative lift is a useful result: the context may be distracting or may
not be surviving selection/prompting effectively.

Top-level `suite` and `categories` describe the screen condition when present, otherwise none.
`conditions` contains separate aggregates for both. `phrases` contains one record per phrase per
executed condition, tagged by `condition`. Denominators never mix the two conditions.
`contextLift` is present only for complete matching pairs. JSON accuracy and lift values are
fractions; printed accuracy is a percentage and printed lift is percentage points. Undefined
metrics are omitted from JSON and shown as `n/a`, never fabricated as zero.

Inference errors fail the test after the report is written. Accuracy has no hard threshold yet;
establish baselines before adding a quality gate.

## Inspect and compare

A run creates:

- `report.json`: observations, per-condition scores, paired lifts, corpus/model hashes and settings.
  Each observation includes expected/predicted words, correctness, raw/display output, suppression,
  the cleaned screen excerpt, and the final request prompt.
- `summary.txt`: readable suite/category scores and paired lifts.
- `phrases.jsonl`: durable records for completed phrase-condition replays. Interrupted runs retain
  these records, but do not produce a complete `report.json`.
- `metadata.json`: execution identity written before inference.
- `manifest.json` and `working-tree.patch`: selection, git revision/status, and tracked code changes.
  Untracked file contents are not included in the patch.
- `build.log` and `test.log`: build output and per-phrase progress.

```sh
python3 scripts/phrase_eval.py compare path/to/baseline/report.json path/to/candidate/report.json
jq '.phrases[] | select(.phrase.id == "science-001")' path/to/report.json
jq '.contextLift' path/to/report.json
jq '.phrases[].observations[] | select(.correct == false)' path/to/report.json
```

Comparison requires the same corpus hash, checkpoint mode, context mode, seed, and scenario/condition
selection. It reports changes for each condition and phrase, plus paired lift. Model/configuration
changes are printed as intentional tuning dimensions. Corpus/report schema version 2 distinguishes
these contextual results from the earlier context-free prototype.

The corpus is a development fixture, not a frequency-ranked or representative writing sample.
Context supplies evidence and intent but does not make every next word uniquely determined. Test
improvements on unseen writing too. A fixed seed improves repeatability without guaranteeing
identical results across native runtime or hardware versions; use the same quiet machine when
comparing latency.

Parallel replay shares the GPU and memory bandwidth, so its per-request latency includes worker
contention. Accuracy comparisons across worker counts are allowed and the CLI prints the counts;
use matching one-worker runs for interactive latency comparisons. More workers also require more
model/context memory and do not guarantee proportional speedup. The production autocomplete
runtime remains single-sequence; these independent engines exist only inside the opt-in test.

## Bounded improvement experiments

`IMPROVEMENT_BRAINSTORMING.md` records the current experiment hypotheses, checklist, time window,
and adoption criteria. Keep the model and corpus fixed while comparing sampling configurations.
The CLI supports explicit test-only overrides without changing product defaults or saved settings:

```sh
python3 scripts/phrase_eval.py run \
  --model build/models/Qwen3.5-0.8B-Base.i1-Q6_K.gguf \
  --workspace build/CotabbyDevelopment.xcworkspace \
  --split screen --screen-per-category 20 --split-seed 1337 \
  --temperature 0 --repetition-penalty 1.0 --seed 42 --label greedy-screen
```

Other sampling controls are `--top-k`, `--top-p`, and `--min-p`. Omitted values inherit product
defaults, except the benchmark's fixed default seed of 42. Temperature zero selects the native
greedy sampler; probability filters do not affect that path. The native configuration is recorded
in the report and checked against every requested override after replay.

`--split screen` ranks stable phrase IDs by SHA-256 of `split-seed:phrase-id` and chooses the first
N within each category. With the default 20, screening contains 140 scenarios. `--split heldout`
selects the disjoint remaining 1,197 scenarios; `--split all` preserves the original full suite.
Membership is chosen before category/phrase filters, independent of answers or model results.
When a split is active, `--per-category` caps that partition in hash order; replay still follows
corpus order. This allows a balanced small validation run without taking just the first written
phrases. Keep the split seed and size identical across baseline/candidate comparisons.

After one successful build, sampler-only experiments can use `--skip-build`. The runner refuses
reuse when app/test source, referenced local package source, or app/test binary fingerprints differ.
Code changes require a new build. Manifests retain the build fingerprints and whether reuse occurred;
the checked-in source configuration alone is not evidence that an old binary ran the new code.
Fresh builds resolve dependencies before freezing compilation inputs. `resolution-inputs.json`
records package-lock changes from that setup step; app, test, native, or configuration changes
still abort the run. Compilation then guards all inputs, including locks. `--skip-build` never
resolves packages or silently updates the recorded build.

The offline analysis tool reports condition/category deltas, paired gains/losses, suppression
diagnostics, and category-stratified phrase-bootstrap intervals:

```sh
python3 scripts/analyze_phrase_experiments.py \
  path/to/baseline/report.json path/to/candidate/report.json --markdown
# For character-mode overall accuracy, also pass --metric all.
```

Its input is the Swift report; it never replaces the benchmark scorer. It resamples whole phrases
because checkpoints in one sentence are correlated, and keeps baseline/candidate and both context
conditions paired. Output is aggregate-only by default, so reviewing screening results does not
require exposing held-out text. The intervals describe stability across these synthetic fixtures,
not a representative population of user writing. Freeze a finalist before held-out validation;
repeatedly choosing new candidates based on held-out misses turns that set into development data.

`scripts/analyze_completion_prefixes.py` adds a separate lexical-tail diagnostic for two reports.
It keeps the Swift scorer's first-word decision, then counts consecutive reference-word matches.
Two- and three-word rates include only checkpoints with that many reference words remaining;
text beyond the reference ending is unknown. These diagnostics do not measure semantic quality
or accepted keystrokes and must not replace the primary score.

## Code boundaries and tests

The JSON fixture owns scenarios and references. `PhrasePredictionScoring.swift` owns immutable
values, checkpoints, matching, aggregates, and lift calculations with no inference dependency.
`PhrasePredictionReplayPlan` in the scoring file owns deterministic partitioning, completeness
checks, and report ordering. `PhrasePredictionScreenContext.swift` adapts fixtures to production
OCR selection and request construction. `PhrasePredictionEvalTests.swift` owns the temporary
runtime pool, structured worker tasks, and the main-actor `ReplayJournal` that combines results.
The Python CLI owns launch configuration and report comparisons; scoring remains in Swift.

The model-free Swift tests validate scoring and pass **all 1,337 scenarios** through request
construction to check that context reaches the prompt without the complete future answer.

```sh
xcodebuild test -project Cotabby.xcodeproj -scheme Cotabby -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData -only-testing:CotabbyTests/PhrasePredictionScoringTests \
  -only-testing:CotabbyTests/PhrasePredictionScreenContextTests CODE_SIGNING_ALLOWED=NO
python3 -m unittest discover -s scripts/tests -p 'test_phrase_eval.py'
```
