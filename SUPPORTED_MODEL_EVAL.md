# Installed CoHamster model evaluation

Investigation and retained evidence: [2026-09-25 usability report](benchmarks/model-usability/2026-09-25/README.md).

Run the shipping catalog against the real autocomplete pipeline, without downloading models:

```sh
scripts/prepare_cohamster_workspace.sh
python3 scripts/supported_model_eval.py --output build/eval/supported-screen --plan
python3 scripts/supported_model_eval.py --output build/eval/supported-screen
```

The runner reads filenames and display names from `LlamaRuntimeModels.swift`. Every catalog
file must exist in `~/Library/Application Support/Cotabby McHamster/LlamaRuntime`, or in the
explicit `--models-dir`. Extra GGUF files are ignored. Model loading, generation, and screen
fixtures stay on the Mac. Dependency preparation may contact package hosts; writing is never
sent to a hosted model. Saved app preferences and installed weights are not modified.

`--variants production content-only` compares the production prompt against a test-only ablation
that removes app/surface, profile and language hints while retaining the same draft and selected
screen text. Both use the same fixed sampler seed and synthetic profile (Alex, English). This
covers settings omitted from the older default phrase benchmark. An ablation is diagnostic,
not an automatically approved product change.

The default campaign includes:

- `word`: five hash-selected scenarios per category, with and without screen context.
- `character`: two per category, including every partial-word checkpoint.
- `regressions`: 14 synthetic development examples / 322 character checkpoints, including the
  reported Apple Intelligence, GGUF and MLX failures, plus ordinary messages and email.
- `runtime`: native cache restoration, discarded tails, cancellation, Unicode streaming, and
  cold/prewarmed typing traces. `typing.json` retains first-visible and cancellation measurements.

Use `--workloads word regressions` for a shorter diagnostic campaign. Use `--model base`
(or repeat `--model`) to isolate catalog entries. `--word-count 4-7` is the default for this
usability runner; the older phrase CLI still inherits product defaults unless explicitly set.
The effective length is recorded in each report. Do not compare latency across different lengths.

`--variants production compact-surface` compares the shipping surface metadata with an experimental
preface that omits app branding and generic composer labels. `--variants production compact-language`
compares the separate compact-language experiment; it retains the shipping surface format.
Both experiments gave mixed or worse screening results and remain opt-in evaluation controls.
No shipping prompt or backend selection was changed as a result of these experiments.

For a focused, reproducible comparison:

```sh
python3 scripts/supported_model_eval.py --model base --workloads word regressions \
  --variants production compact-language compact-surface --word-count 4-7 \
  --output build/eval/base-prompt-comparison
```

Runtime checks execute once per model, and typing traces inherit and record the chosen word-count
setting. Each replay owns its `typing.json`; older shared per-model reports are never reused.
Workloads run sequentially
with one inference worker, so different models do not contend with one another. A busy Mac can
still distort timings. Release builds are required. Each run stages a clean, ad-hoc-signed test host under `/private/tmp`
and removes it afterward; no developer signing identity is required. Custom corpora are also staged
after their hashes are checked, and XCTest's library paths point at the copied frameworks.
This avoids stale seals and file-access stalls under Documents. Fingerprints prevent reuse after app,
test, native source or binary changes. `--skip-build` requires an unchanged verified build.

Validate the frozen configuration on disjoint cases (also do this after selecting any future change):

```sh
python3 scripts/supported_model_eval.py --stage validate --variants production \
  --output build/eval/supported-validation
```

Validation uses 15 held-out word scenarios and five held-out character scenarios per category.
Regression cases remain explicitly separate development examples. Word and character samples
overlap within a campaign; their scores must not be pooled as independent evidence.

`campaign.json` and `report.md` are updated after each run. Each child directory includes source,
binary, corpus and model fingerprints, exact prompts, raw completions, display decisions,
suppression reasons and per-checkpoint scores. Failures and interruptions leave an **incomplete**
campaign, never a passing qualification. Existing output directories cannot be overwritten.
The default per-replay timeout is 1,800 seconds and can be set with `--timeout-seconds`.

Exact next-word accuracy measures agreement with the intended wording. Plausible alternatives
are misses; it is not a semantic rating. Coverage counts all display-eligible output, including
wrong suggestions. Precision alone must not reward a model for hiding most predictions.
Final-generation latency excludes model load, focus polling, debounce and overlay drawing;
read typing traces for first-visible latency and cancellation. None of these tests exercises
live Accessibility or inserts text into another app.

The Python orchestrator owns campaign discovery, process lifetime and report aggregation.
`phrase_eval.py` owns build verification and test-host configuration. Swift's
`PhrasePredictionEvalTests` owns actual replay, and `PhrasePredictionScoring` owns correctness.
Optional custom corpora use the same validation and scoring rules but do not need the canonical
1,337-case shape. The canonical benchmark keeps its original strict validation.

After all tests/runs finish and artifacts are no longer needed, remove `build/DerivedData`.
Results in `build/eval` remain available. See `PHRASE_EVAL.md` for detailed scorer semantics.
