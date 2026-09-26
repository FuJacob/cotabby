# Reproducing round two

This evidence describes the retained P2-H baseline and twelve rejected alternatives. It does
not introduce new application defaults. The protected 700-case corpus is now inspected
development data for any future tuning; a future selection round needs new protected data.

## Inputs that must match

- App revision: `cd99305b169c714074c6ea1fda33f21e6cd0beda`.
- Native revision: `7574a21516c65fc31f5cf8ef7380a03412eed480`, plus the **pre-existing**
  local changes in `native-start.patch`. In particular, token healing is a baseline prerequisite.
- Local GGUF: `Qwen3.5-0.8B-Base.i1-Q6_K.gguf`, SHA-256
  `febd85051361ccb34d0925744c819f9ae0724117e8f946a2852dd0edfa90a5a1`.
- Original version-two 1337-case corpus, SHA-256
  `b41c8089a58ae1e0ee84b95ac9283cf71db4e713e25bd8fed47220be69d8b0f6`.
- Supplementary version-three 700-case corpus, SHA-256
  `2529c17f21b276eecafe7859853b1aafeba967346f205fa9f378631aa2dda828`.
- Sampling: temperature `0.1`, repetition penalty `1.025`, top-k `20`, top-p `0.7`,
  min-p `0.08`, native repetition history `64`. Each registration states its seed.

The native prerequisite changes were already present when the round began. The app's remote
package pin was not updated during this experiment, and the GGUF is not included in the bundle.

## Replay procedure

1. Use isolated checkouts at the recorded app and native revisions. Preserve any current user
   edits. Apply the native prerequisite patch, the frozen evaluation-harness patch, and any
   frozen evaluation untracked files. `starting-snapshot.json` and the complete production
   inventories record exactly what was measured. `app-start.patch` also retains the initial
   app worktree patch for provenance; it is not a new round-two implementation.
2. Use a development workspace resolving the local native package. The original workspace
   path and dependency lock hashes are recorded in `execution.json` and run manifests.
   Keep derived data under the isolated app's `build/DerivedData`.
3. Read the chosen `<label>-registration.json` for the exact benchmark command. Substitute
   only the executable, workspace, model, fixture and output paths appropriate to the new
   checkout. Preserve all sampling/cohort flags. The default 1337 corpus does not require
   `--corpus`; the supplementary fixture does. Character runs use `--mode character` and
   the registered category limit, or all cases when that limit is zero.
4. Rebuild and run the recorded focused tests before replay. Compare complete reports only
   when corpus, checkpoint, source, model and effective-configuration hashes match. Latency
   requires one worker and an otherwise quiet machine; three-worker times describe throughput.

For example, the shared baseline flags are:

```text
scripts/phrase_eval.py run --model <GGUF> --workspace <local-workspace>
  --output <new-output-directory> --label <new-label>
  --mode word --context paired --workers 3 --split all
  --split-seed 1337 --screen-per-category 20 --seed 42
  --temperature 0.1 --repetition-penalty 1.025 --top-k 20 --top-p 0.7 --min-p 0.08
```

That block is a flag reference, not a shell-ready command: supply actual paths and put it on
one command line. Use seed `12648430` for the production-seed replay. Use the exact screening
IDs and frozen source variants for alternative reproduction; do not infer them from a score.

The original orchestration scripts enforce this round's recorded deadlines, immutable selection
and local absolute paths. They are preserved audit records, not a promise of one-command
execution on another machine. A new experiment should register its own paths, deadlines and
decision policy while retaining the same scorer when making a historical comparison.

## Evidence interpretation

`decision-assessment.json` records the frozen selection. `baseline-characterization.json`
reports descriptive context, seed, partial-word, parity and timing measurements. Positive
screen-minus-none differences in that file are context effects, not improvements from a new
implementation. Missing or failed registered runs remain visible.

Scores are checkpoint-weighted. Fresh intervals resample whole authored families within
categories; they do not estimate real-user quality or all possible generation randomness.
Small category/context groups and multiple pointwise intervals call for restraint. The exact
corpora do not exercise the concurrent Codex bundle-classification edit; its focused test is
separate from benchmark parity. Model timing excludes focus tracking, debounce and UI work.

The durable archive retains original path strings to preserve hashes and provenance. Its
manifest records every archived text file's size and SHA-256, plus the archive hash. Compiler
products and model weights are omitted; original raw evidence remains under `build/eval/`.
