# Next-word phrase benchmark

This harness replays **1,337 fixed English phrases** through Cotabby's local llama prediction
path. It scores each prediction, each phrase, each category, and the whole suite. Use it to compare
prompt, normalization, suppression, sampling, and model changes against the same intended text.

The original synthetic corpus has **191 individually written phrases per category**:
conversation, science, entertainment, work, technology, everyday life (`everyday`), and travel.
It uses familiar English constructions, but is not a frequency-ranked or statistically representative
sample. No private user text or online source material was used. Provenance lives in the corpus.

## Run

From the repository root, preview the workload without building or loading a model:

```sh
python3 scripts/phrase_eval.py plan
# 1,337 phrases; 7,437 next-word checkpoints

python3 scripts/phrase_eval.py plan --mode character
# 35,378 checkpoints, including the same 7,437 word boundaries
```

Run the full suite using a downloaded local GGUF:

```sh
python3 scripts/phrase_eval.py run --model /absolute/path/to/model.gguf --label baseline
```

Omit `--model` to use the app runtime's model selection. The harness does not download models.
It requires macOS, Xcode, and the normal project dependencies. It currently evaluates the local
llama backend; it does not use Apple Intelligence or an endpoint.

Start with a small selection when validating a code change:

```sh
python3 scripts/phrase_eval.py run --model /absolute/path/to/model.gguf --limit 3 --label smoke
python3 scripts/phrase_eval.py run --model /absolute/path/to/model.gguf --category science --label science-baseline
python3 scripts/phrase_eval.py run --model /absolute/path/to/model.gguf --phrase conversation-001 --mode character
```

`--limit` takes the first N phrases **after** filtering; it is for smoke tests, not a balanced sample.
`--output /absolute/new/directory` chooses a results directory. Existing directories are rejected
to avoid overwriting baselines. If you use a workspace with a local CotabbyInference checkout, add
`--workspace build/CotabbyDevelopment.xcworkspace` (create that workspace through the repository's
existing inference workspace setup first).

The CLI builds Release with testability and `RUN_LLAMA_EVAL`, then injects the selection and model
path into a temporary `.xctestrun` file. Exporting arbitrary environment variables before
`xcodebuild` is insufficient for this app-hosted test. Both the compile flag and the explicit
`COTABBY_PHRASE_EVAL=1` test-host switch are required, so ordinary tests and the older live evals
do not accidentally execute the full corpus.

Builds use `build/DerivedData`. Xcode signing/Team ID restrictions may prevent an unsigned app-hosted
test from launching on some machines; the command preserves the exact failure in `test.log`.
After all runs are finished and no other build is using it, remove `build/DerivedData`; results
remain separately under `build/eval/phrases/`.

## What "typing" means

For `Please send the report.`, word mode asks for predictions after `Please `, `Please send `,
and `Please send the `. The targets are `send`, `the`, and `report`.

Character mode also asks after `Please s`, `Please se`, `Please sen`, and so on. At `Please se`,
the continuation `nd the report` correctly completes `send`; ` nd` and `nder` do not.

The first word provides context and is not scored. The harness waits for each final result, then
advances through the **reference phrase regardless of the prediction**. The next request receives
only the text typed so far. Future text, phrase IDs, and category labels are never passed to the model.
This is often called teacher-forced replay: errors cannot change the rest of the test input.

Each phrase starts with a reset prompt cache. Within a phrase, one engine retains its cache as the
prefix grows. The runner uses production request construction, the real local engine, output
normalization, and the final spelling/seam display guard. Clipboard, screen, profile, custom rules,
and trailing context are absent. Sampling uses product defaults with a fixed seed of 42. The
product's default word-count preset determines the generation budget; scoring examines only the
first resulting word.

This measures final display-eligible prediction quality, not actual keystroke injection, Accessibility,
overlay pixels, debounce, streaming latency, or acceptance-tail reuse. Keep using
`LlamaTypingSessionEvalTests` for timing and cancellation scenarios.

## Scoring

At every checkpoint, a correct complete next word earns **1**, anything else earns **0**.
Suppression, empty text, and inference errors remain in the denominator. A plausible synonym
still misses the intended word: this is exact prediction accuracy, not a semantic quality judge.

Matching folds case and curly/straight apostrophes and ignores punctuation after the first complete
word. Internal apostrophes and hyphens remain significant. It never searches later in the output
for the expected word. `cat` does not match `catalog`, `cats`, `cat's`, or `ca`; `don't` does not
match `dont`. Whitespace inserted inside a partially typed word is a miss.

| Metric | Meaning |
| --- | --- |
| Next-word accuracy | Correct word-boundary predictions / all word-boundary checkpoints. Main score. |
| Coverage | Nonempty display-eligible predictions / all checkpoints. |
| Precision when shown | Correct predictions / shown predictions; unavailable when nothing was shown. |
| All-checkpoint accuracy | Includes partially typed words in character mode. Reported separately. |
| Mean phrase accuracy | Each phrase receives equal weight, regardless of length. |
| Mean category accuracy | Each category's pooled next-word accuracy receives equal weight. |
| Latency p50/p95 | Monotonic time for final generation plus the display guard; excludes gated requests and errors. |

Phrase, category, and suite `nextWord` aggregates use only zero-letter checkpoints. Their `all`
aggregates include every requested checkpoint. The suite's pooled score weights each target word
equally. JSON rates are fractions from 0 to 1; console rates are percentages. Missing metrics are
omitted in JSON and displayed as `n/a`, never replaced with a fabricated zero.

No accuracy threshold is imposed yet: establish a baseline first. Inference errors are recorded as
misses and make the test fail after the report is saved. The comparator refuses errored runs.

## Inspect and compare

Each run creates a unique directory containing:

- `report.json`: complete observations and phrase/category/suite scores, model and corpus hashes,
  configuration, and measurement scope.
- `summary.txt`: readable category and suite scores.
- `phrases.jsonl`: one durable record per completed phrase, useful if a long run is interrupted.
- `metadata.json`: execution identity written before inference begins.
- `manifest.json` and `working-tree.patch`: requested selection, git revision/status, and tracked
  working-tree changes. Untracked file contents are not included in the patch.
- `build.log` and `test.log`: Xcode output, including per-phrase progress.

The complete `report.json` only appears after the entire requested selection finishes. A partial
journal cannot masquerade as a full-suite result. Model loading, model hashing, and building are
outside the checkpoint latency measurements.

```sh
python3 scripts/phrase_eval.py compare \
  build/eval/phrases/BASELINE/report.json \
  build/eval/phrases/CANDIDATE/report.json
```

The comparison prints percentage-point changes for the suite, every category, and every phrase.
It rejects different corpus hashes, modes, seeds, phrase selections, or checkpoint sequences.
Model/configuration differences are displayed because those are intentional tuning dimensions.
Use the same hardware and a quiet machine for latency comparisons. A fixed seed improves
repeatability but does not promise identical outputs across native runtime/hardware versions.

Inspect an individual miss without running inference again:

```sh
jq '.phrases[] | select(.phrase.id == "science-001")' path/to/report.json
jq '.phrases[].observations[] | select(.correct == false)' path/to/report.json
```

The corpus is a development benchmark. Improvements here should also be checked against separate,
unseen writing rather than repeatedly tailoring prompts to these exact phrases. If wording or
grouping changes, treat the changed corpus hash as a new baseline.

## Code boundaries

- `CotabbyTests/Fixtures/phrase-prediction-1337.json` owns the versioned dataset and stable IDs.
- `CotabbyTests/Evals/PhrasePredictionScoring.swift` owns corpus validation, prefix checkpoints,
  exact matching, and hierarchical reports. It has no inference or XCTest dependency.
- `CotabbyTests/Evals/PhrasePredictionEvalTests.swift` owns the short-lived replay, local runtime,
  display guard, and artifact writes. It reuses `LlamaEvalRuntime` without changing app preferences.
- `CotabbyTests/Evals/PhrasePredictionScoringTests.swift` validates measurement rules and the corpus
  during normal tests, without a model.
- `scripts/phrase_eval.py` owns launch configuration and comparisons. Scoring stays in Swift so
  the reporting tool cannot silently implement a different definition of success.

Run scoring tests with the normal Cotabby test target:

```sh
xcodebuild test -project Cotabby.xcodeproj -scheme Cotabby -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData -only-testing:CotabbyTests/PhrasePredictionScoringTests \
  CODE_SIGNING_ALLOWED=NO
python3 -m unittest discover -s scripts/tests -p 'test_phrase_eval.py'
```
