# Registered character diagnostics

The durable [helper](analyze_character_subsets.py), [character150 registration](character150-plan.json), and [boundary-identity source rationale](character-boundary-identity-plan.md) preserve the supplemental analysis prepared before examining character results. Their original source hashes are retained in `export-provenance.json`. Copying them does not imply that the character pair has completed.

After both character reports and their full-word references are complete, the helper validates registration, recorded source identity, model identity, effective sampler configuration, seed, selected phrases, complete character-checkpoint expansion, errors, and authoritative counts. It records build-product fingerprints from the manifests; it does not independently inspect the executed binaries. It then produces:

- Separate word-boundary (`typedCharacters == 0`), partial-only (`typedCharacters > 0`), and all-checkpoint denominators, using Swift's recorded correctness and display flags.
- Partial-only uncertainty from paired, category-stratified whole-phrase resampling.
- Aggregate word-mode versus character-mode boundary-identity mismatches, comparing each configuration with its own full42 reference. This is a diagnostic, not a replacement score or a causal claim about cache behavior.

The report writer retains `character150-subsets.json` and `character150-subsets.md` only when both completed outputs exist, their recorded source hashes still match, their boundary/all totals match the validated completed pair, partial counts partition those totals, and Markdown matches the JSON. It then links them from the summary. It reads no partial journals and creates no placeholder results. The frozen finalist and explicit adoption decision remain unchanged.

## Reproduce from retained raw report directories

The copied helper keeps the same directory depth as the round-local version: `SCRIPT.parents[3]` resolves to the repository root from `benchmarks/phrase-prediction/round1-20260917/`. Its default full-word reference directories would be beside that copied helper, where raw reports are deliberately not published. Pass the reference paths explicitly.

The actual command-line flags are **`--before-reference`**, **`--after-reference`**, and **`--registration`**. The helper accepts run directories containing both `report.json` and `manifest.json`, or a `report.json` path with a sibling manifest.

```bash
REPORT_REPO=/absolute/path/to/repository-containing-this-report
RAW_ROUND=/absolute/path/to/local-completed-round-results
ARTIFACTS="$REPORT_REPO/benchmarks/phrase-prediction/round1-20260917"
OUTPUT_PREFIX=/absolute/path/to/new-output-directory/character150-subsets

python3 "$ARTIFACTS/analyze_character_subsets.py" \
  "$RAW_ROUND/character150-baseline" \
  "$RAW_ROUND/character150-finalist" \
  --before-reference "$RAW_ROUND/full42-baseline" \
  --after-reference "$RAW_ROUND/full42-finalist" \
  --registration "$ARTIFACTS/character150-plan.json" \
  --analyzer "$REPORT_REPO/scripts/analyze_phrase_experiments.py" \
  --samples 20000 --bootstrap-seed 1337 \
  --output-prefix "$OUTPUT_PREFIX"
```

Create the output parent directory first and choose a fresh prefix. `--help` lists the supported flags; `--self-test` runs only the helper's synthetic checks. The output JSON records hashes for the exact helper, analyzer, registration, reports, and manifests used, so reproduced hashes will refer to the explicit paths above. Raw prompt and completion values are compared locally but are never included in the aggregate output.

Character150 covers the first 150 corpus-order phrases per category, including screening phrases. It is not a new held-out set. Three-worker character runs do not establish interactive latency, and diagnostic findings do not authorize candidate retuning or changes to current-main policies.
