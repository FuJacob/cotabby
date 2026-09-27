# Phrase prediction baselines

This directory holds versioned benchmark results for GitHub. Each named baseline contains:

- `report.json`: compact comparison inputs and scores for every phrase, category, and condition.
- `summary.txt`: readable suite/category scores and screen-context lift.
- `manifest.json`: run selection, source revision/status, model filename, platform, and source report hash.

Create a baseline from a successful run:

```sh
python3 scripts/phrase_eval.py save-baseline build/eval/phrases/baseline-v1 --name baseline-v1
git add benchmarks/phrase-prediction/baseline-v1
git commit -m "Record phrase prediction baseline v1"
git push
```

Compare any future matching run directly against the tracked report:

```sh
python3 scripts/phrase_eval.py compare \
  benchmarks/phrase-prediction/baseline-v1/report.json \
  build/eval/phrases/candidate-v1/report.json
```

Names are immutable: save new results under a new name. Commit the evaluated source before
collecting a release baseline; the manifest records dirty status but does not store source changes.
Raw observations, prompts, logs, and model weights remain local. The export keeps exact fixture
and checkpoint identities, so comparisons still reject mismatched corpus or workload selections.
Runs default to three independent workers. Reports and manifests retain the worker count; old
baselines without it mean one worker. Accuracy remains comparable across worker counts, but
parallel per-request latency includes contention. Use `--workers 1` for interactive latency tests.

`smoke-14-qwen35-0.8b-q6` records the existing 14-scenario, 140-prediction smoke run. It is a
small workflow reference, **not the full 1,337-scenario baseline**. Its source tree was dirty,
as recorded in the manifest. Use `--per-category 2` to select the same workload for comparisons.

[`baseline-v1`](baseline-v1/summary.txt) is the first full baseline: 1,337 phrases and 14,874
predictions across both screen conditions, collected with one worker. Its exact next-word
accuracy is 34.50% with screen context and 28.47% without it, a gain of 6.04 percentage points.

See [PHRASE_EVAL.md](../../PHRASE_EVAL.md) for full run commands, progress/ETA behavior, and scores.
