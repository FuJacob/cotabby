# Automated model qualification

`scripts/model_eval.py` evaluates candidate GGUFs against a baseline through CoHamster's actual
local autocomplete pipeline. It discovers models on Hugging Face, in a directory, or acquires them from a manifest,
then runs candidates sequentially and writes `qualification.md` and `qualification.json`.
It does not change the catalog or the user's model/settings. No prompts or writing data are uploaded.

The orchestrator owns acquisition, scheduling, time limits, and admission policy. It delegates build
verification and replay to `scripts/phrase_eval.py`; Swift remains the only implementation of prompt
construction, inference, normalization, display eligibility, and scoring. This boundary prevents a
standalone model benchmark from approving a model that performs differently inside the app.

## Hands-off Hugging Face discovery

When neither `--models-dir` nor `--manifest` is supplied, candidate discovery runs automatically:

```sh
python3 scripts/model_eval.py \
  --baseline build/models/Qwen3.5-0.8B-Base.i1-Q6_K.gguf \
  --workspace build/cohamster-dependencies/CoHamster.xcworkspace \
  --output build/eval/model-qualification/huggingface-first
```

Prepare the pinned native workspace first using `scripts/prepare_cohamster_workspace.sh` if needed.
This one command searches, chooses candidates, downloads them, and runs qualification unattended.
Add `--plan` to query metadata and inspect the shortlist without downloading weights or running Xcode.
Pass `--discover-hf` explicitly to combine discovery with local/manifest candidates.

`hf_model_discovery.py` owns the public Hub API boundary and deterministic selection policy. It returns
ordinary pinned manifest entries to `model_eval.py`, so discovered and manually supplied models use
exactly the same downloader and production replay. Public API metadata requests contain search terms
and repository identifiers only. No token, login, remote inference, or repository Python code is used.

The default discovery policy:

- Interleave recent `base`, recent `pretrain`, and popular `base` GGUF search results.
- Inspect at most **120 repositories**, select at most **6 models**, and plan at most **16 GiB** of
  downloads, with the existing **8 GiB per-file** ceiling.
- Require public, ungated `text-generation` repositories with an explicit base/pretrained name in
  the repository or declared upstream. Exclude chat/instruct/reasoning and named image/encoder artifacts.
- Skip explicitly declared non-English-only models because the current corpus is English. Missing
  language declarations remain eligible. Metadata is a heuristic, not proof of suitability.
- Prefer `Q4_K_M`, then `Q5_K_M`, `Q6_K`, and `Q8_0`; choose one fitting file per declared upstream.
  Reject multipart weights and projectors. Deduplicate hashes and exclude the exact baseline artifact.
- Require file size and SHA-256 metadata, then pin downloads to the immutable repository commit.

Use `--max-candidates`, `--hf-search-limit`, and `--max-download-gib` to change discovery budgets.
These budgets apply to automatically discovered candidates; explicit local/manifest inputs are extra.
Downloads are capped at the discovered byte count and verified against both size and hash.

`discovery.json` records the policy, queries, selected manifests, metadata errors, and skip reasons;
`--plan` includes the same audit in its JSON output. Qualification still supplies the final decision.
If discovery produces no candidates, a real campaign writes the audit and exits 2 instead of reporting
success. Transient API errors have bounded retries; errors in one repository do not stop others.

Searches are bounded snapshots, not an exhaustive crawl. Explicit naming/tag requirements can miss
valid models, and Hub `lastModified` is a repository update time, not the original model release date.
Popularity never establishes quality. License tags are recorded for later catalog review, not treated
as permission to redistribute. Discovery does not publish catalog changes or schedule recurring runs.

The API contract follows [Hugging Face Hub documentation](https://huggingface.co/docs/hub/api).

## One command for a directory of candidates

Prepare the pinned native workspace once using `scripts/prepare_cohamster_workspace.sh`, then run:

```sh
python3 scripts/model_eval.py \
  --baseline build/models/Qwen3.5-0.8B-Base.i1-Q6_K.gguf \
  --models-dir build/models/candidates \
  --workspace build/cohamster-dependencies/CoHamster.xcworkspace \
  --output build/eval/model-qualification/first-campaign
```

Add `--plan` to inspect the candidate list and stages without downloading, building, or generating.
The candidate directory is scanned for `.gguf` files directly inside it; the baseline path is excluded.
Use unique filenames/IDs. Different quantizations are different candidates. The baseline must be a
known-working local model; evaluating against a smaller or larger baseline changes the admission bar.

The first replay builds Release; later runs reuse the existing benchmark's source- and binary-verified
build. One inference worker runs at a time. Concurrent model-eval campaigns are blocked by an advisory
lock. Keep other GPU-heavy apps and unrelated builds idle for meaningful latency comparisons.

## Automatically download candidates

Instead of (or alongside) `--models-dir`, pass `--manifest candidates.json`. Paths are relative to the
manifest. A manifest contains a `models` array; each model has a unique `id` and either `path`, or an
HTTPS `url` plus the exact lowercase 64-character `sha256`. For example, local entries look like:

```json
{
  "models": [
    {"id": "candidate-small-q4", "path": "models/candidate-small-q4.gguf"},
    {"id": "candidate-small-q6", "path": "models/candidate-small-q6.gguf"}
  ]
}
```

For a download, replace `path` with `url` and `sha256`. Prefer a Hugging Face URL pinned to a repository
commit, not a moving `main` revision. Downloaded weights live under the campaign's `models/` directory.
The harness enforces the file-size budget during transfer, verifies SHA-256 before use, and rejects
missing GGUF headers. Local entries can also specify `sha256`. Split/sharded downloads are not managed.
The SHA-256 identifies the evaluated artifact; it is not a license or security assessment.

Explicit manifests bypass automatic discovery unless `--discover-hf` is also supplied. The harness
handles downloading, running, scoring, and qualification without per-model intervention.
Do not commit downloaded weights or private benchmark output.

## Stages and admission rules

Every stage uses paired screen/no-screen context, one worker, sampling seed 42, and production
sampling defaults. The existing deterministic split uses seed 1337 and 20 screening phrases per
category. Held-out phrases are disjoint from screening.

| Stage | Workload | Purpose |
| --- | --- | --- |
| Smoke | 2 screening phrases/category, word checkpoints | Loading, tokenization, generation, usable output, latency |
| Screen | 20 screening phrases/category, word checkpoints | Reject weak candidates cheaply |
| Heldout | All 171 remaining phrases/category, word checkpoints | Validate quality outside screening |
| Midword | 10 held-out phrases/category, character checkpoints | Check continuations while a word is partially typed |

The baseline runs each stage once per campaign, lazily when a candidate reaches it. A failed candidate
stops advancing; subsequent candidates continue. An unavailable or failing baseline aborts the campaign.
Character validation shares held-out phrases with word validation; it tests another interaction mode,
not another independent statistical sample. These runs can take hours for large/slow models.

Provisional default gates (explicitly recorded in the result):

- No inference errors or incomplete/mismatched reports.
- No more than **1 percentage point** accuracy regression in either context condition.
- No more than **5 percentage points** coverage regression in either condition.
- No more than **5 percentage points** next-word accuracy regression in any category.
- Final-generation **p95 ≤ 500 ms** in both conditions, with usable suggestions in both.
- Model file **≤ 8 GiB**; each replay, including build, **≤ 4 hours**.

Smoke applies runtime/output/latency gates only; its sample is too small for quality admission.
Later stages check both next-word and all-checkpoint accuracy/coverage. The latter is necessary for
character mode: a model can predict whole words well but fail at partially typed word boundaries.

Override policy with `--max-accuracy-drop-pp`, `--max-coverage-drop-pp`, `--max-category-drop-pp`,
`--max-p95-ms`, `--max-model-gib`, and `--timeout-seconds`. Zero regression tolerance is allowed.
These are initial engineering thresholds, not empirically calibrated guarantees or significance tests.
Use separate campaigns/policies for different hardware or product tiers.

## Evidence and decisions

Each model gets `qualified`, `rejected`, or `failed`, with stage metrics and specific rejection reasons.
`blocked-baseline` identifies baseline/infrastructure failure. A running/interrupted or failed stage
never counts as passing. Exit status is 0 if at least one candidate qualifies, 1 if none do, and 2 for
baseline/setup failure. A baseline-identical artifact is rejected as a candidate.

Each model/stage directory retains the underlying phrase report, exact model hash, source/build
provenance, settings, per-checkpoint outputs, and logs. Outer stage logs include build/launch errors.
The aggregate JSON is updated atomically after each stage. Output directories cannot be overwritten;
use a new directory for reruns. Automatic resume is intentionally absent, so old hardware/source state
cannot silently mix with a new campaign. Failed downloads are cleaned up; completed weights and reports
are retained. Remove `build/DerivedData` after the campaign when no other build needs it.

`qualified` means the candidate passed this reproducible benchmark policy, not that it is ready to
publish. The corpus is synthetic English writing and exact next-word scoring penalizes valid alternate
wording. It does not establish multilingual/code quality, user preference, license suitability, peak
RAM, energy consumption, time to first visible token, or real keyboard/AX/overlay/cancellation behavior.
The size limit concerns the GGUF file, not process memory. p95 is final generation/display-guard latency,
not end-to-end typing latency. See `PHRASE_EVAL.md` for fixture and scorer details.

## Developer validation

```sh
python3 -m unittest discover -s scripts/tests -p 'test_*eval.py'
```

Tests cover paired-context and mid-word regressions, category regressions hidden by aggregate scores,
configuration/selection mismatch, absent/nonfinite metrics, artifact integrity, process-group timeout
handling, baseline failure, and continuing after a candidate fails. Discovery tests additionally cover
pinned revisions, quantization preference, ancestry/hash deduplication, budgets, gated repositories,
specialized artifacts, metadata failures, and the handoff into the qualification pipeline. They use small fixtures and fake
replay processes; live model qualification additionally requires macOS, Xcode, and actual weights.
