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
Other useful selections:

```sh
python3 scripts/phrase_eval.py run --model /absolute/path/to/model.gguf --category science
python3 scripts/phrase_eval.py run --model /absolute/path/to/model.gguf \
  --phrase travel-001 --mode character
python3 scripts/phrase_eval.py run --model /absolute/path/to/model.gguf --context screen
python3 scripts/phrase_eval.py run --model /absolute/path/to/model.gguf --context none
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
warmup/thermal bias. One engine retains its prompt cache as the phrase grows within a condition.
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

## Code boundaries and tests

The JSON fixture owns scenarios and references. `PhrasePredictionScoring.swift` owns immutable
values, checkpoints, matching, aggregates, and lift calculations with no inference dependency.
`PhrasePredictionScreenContext.swift` adapts fixtures to production OCR selection and request
construction. `PhrasePredictionEvalTests.swift` owns the temporary runtime and replay lifecycle.
The Python CLI owns launch configuration and report comparisons; scoring remains in Swift.

The model-free Swift tests validate scoring and pass **all 1,337 scenarios** through request
construction to check that context reaches the prompt without the complete future answer.

```sh
xcodebuild test -project Cotabby.xcodeproj -scheme Cotabby -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData -only-testing:CotabbyTests/PhrasePredictionScoringTests \
  -only-testing:CotabbyTests/PhrasePredictionScreenContextTests CODE_SIGNING_ALLOWED=NO
python3 -m unittest discover -s scripts/tests -p 'test_phrase_eval.py'
```
