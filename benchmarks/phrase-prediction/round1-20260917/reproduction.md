# Reproducing the frozen 1337 comparisons

These instructions reconstruct the controlled frozen experiment in a separate checkout. The adoption decision and current-main integration evidence are recorded in [summary.md](summary.md). Preserve the concurrent typo gating, seam handling, word completion, coordinator, and evaluation-policy changes in the working application checkout.

The completed `heldout42-local-finalist` run supplies the app patch. Its base is `342a76d002b534d13d3a9689768d13fda12f8609`; the native base is `7574a21516c65fc31f5cf8ef7380a03412eed480`. The app patch captures the exact frozen benchmark harness, old CLI, P2 composer, and three reviewed test files. The native patch is a **pre-existing dirty prerequisite**, including token healing, and is not an improvement attributable to this round.

The frozen checkout still has the standard repetition penalty **1.05**. The finalist uses **1.025 through the CLI override**; both sides explicitly use temperature 0.1, top-k 20, top-p 0.7, and min-p 0.08. Seed 42 is the benchmark seed. Production's `nil` seed delegates to the fixed native default `0x00C0_FFEE` / **12648430**, not a random seed.

## Retained source prerequisites

All files below are in [`source-prerequisites/`](source-prerequisites/). Exact hashes, per-file reconstructed hashes, and verification evidence are in [`manifest.json`](source-prerequisites/manifest.json).

| File | Bytes | Purpose |
|---|---:|---|
| `native-start.patch` | 52,654 | Byte-identical native patch recorded at round start |
| `frozen-app-finalist.patch` | 63,581 | Byte-identical working-tree patch from the completed held-out finalist |
| `surface-p2.patch` | 6,567 | Exact composer-only section extracted from the app patch; reverse for baseline |
| `Package.resolved` | 939 | Frozen generated-workspace dependency pins |

Native patch SHA-256: `814a139320af2bcbfb57751508511c4a2f0e62ef8e4f56fbb951fedbf74d4bd5`. App patch SHA-256: `61371e63a1fd466a84f2543a480c8cb9d81fd154eb79d2814dc256a8d786ef72`.

Both patches were applied to files materialized from the recorded Git objects in temporary directories. Reconstructed files matched the frozen execution source; native files also matched `native-frozen-manifest.json`. Reversing and reapplying the composer patch changed only that file and preserved the reviewed tests. This audit performed no build or inference.

The full app patch records tracked changes. The standalone offline analyzers are separate repository deliverables under `scripts/`; their SHA-256 values are recorded in the prerequisite manifest. No raw prompts, completions, user logs, archives, model weights, or binaries are included here.

## Create a separate checkout

Use macOS on Apple Silicon with Xcode and Python 3. The recorded run used macOS 27.0, the macOS 27.0 SDK, and Xcode build `27A266a`. Different hardware or toolchains can change timings and numerical behavior. Choose a nonsynced local directory: this round encountered pre-main dyld/getxattr stalls when executing under Documents.

Run these blocks in the same Bash shell. Supply absolute paths for the report repository, a **new** reproduction root, and the existing local GGUF. The root must not be your working application checkout.

```bash
set -euo pipefail
export REPORT_REPO=/absolute/path/to/repository-containing-this-report
export REPRO_ROOT=/absolute/path/to/new-cotabby-1337-reproduction
export MODEL=/absolute/path/to/Qwen3.5-0.8B-Base.i1-Q6_K.gguf
export ARTIFACTS="$REPORT_REPO/benchmarks/phrase-prediction/round1-20260917"
export PREREQUISITES="$ARTIFACTS/source-prerequisites"
export APP="$REPRO_ROOT/cotabby"
export NATIVE="$REPRO_ROOT/cotabbyinference"
export WORKSPACE="$APP/build/CotabbyDevelopment.xcworkspace"
export RESULTS="$REPRO_ROOT/results"

test ! -e "$REPRO_ROOT"
mkdir -p "$REPRO_ROOT"
git clone --no-checkout "$REPORT_REPO" "$APP"
git -C "$APP" checkout --detach 342a76d002b534d13d3a9689768d13fda12f8609
git clone --no-checkout https://github.com/FuJacob/cotabbyinference.git "$NATIVE"
git -C "$NATIVE" checkout --detach 7574a21516c65fc31f5cf8ef7380a03412eed480

python3 - <<'PY'
import hashlib, json, os, pathlib
root = pathlib.Path(os.environ['PREREQUISITES'])
manifest = json.loads((root / 'manifest.json').read_text())
for name, expected in manifest['artifacts'].items():
    data = (root / name).read_bytes()
    assert len(data) == expected['bytes']
    assert hashlib.sha256(data).hexdigest() == expected['sha256'], name
model = pathlib.Path(os.environ['MODEL'])
digest = hashlib.sha256()
with model.open('rb') as stream:
    while chunk := stream.read(1_048_576):
        digest.update(chunk)
assert digest.hexdigest() == manifest['modelSHA256'], 'Wrong model bytes'
PY

git -C "$NATIVE" apply --check "$PREREQUISITES/native-start.patch"
git -C "$NATIVE" apply "$PREREQUISITES/native-start.patch"
git -C "$APP" apply --check "$PREREQUISITES/frozen-app-finalist.patch"
git -C "$APP" apply "$PREREQUISITES/frozen-app-finalist.patch"

python3 - <<'PY'
import hashlib, json, os, pathlib, xml.etree.ElementTree as ET
app, native, workspace = (pathlib.Path(os.environ[k]) for k in ('APP', 'NATIVE', 'WORKSPACE'))
prerequisites = pathlib.Path(os.environ['PREREQUISITES'])
manifest = json.loads((prerequisites / 'manifest.json').read_text())
for root, key in ((app, 'appPatchedFileSHA256'), (native, 'nativePatchedFileSHA256')):
    for name, expected in manifest[key].items():
        assert hashlib.sha256((root / name).read_bytes()).hexdigest() == expected, name
assert hashlib.sha256((app / 'CotabbyTests/Fixtures/phrase-prediction-1337.json').read_bytes()).hexdigest() == manifest['corpusSHA256']
workspace.mkdir(parents=True)
document = ET.Element('Workspace', version='1.0')
for path in (app / 'Cotabby.xcodeproj', native):
    ET.SubElement(document, 'FileRef', location='absolute:' + str(path))
ET.ElementTree(document).write(workspace / 'contents.xcworkspacedata', encoding='UTF-8', xml_declaration=True)
lock = workspace / 'xcshareddata/swiftpm/Package.resolved'
lock.parent.mkdir(parents=True)
lock.write_bytes((prerequisites / 'Package.resolved').read_bytes())
PY
```

The workspace explicitly selects the local patched `cotabbyinference` package. Its pinned `Package.swift` selects llama.cpp `b9310` with XCFramework checksum `e2411e2e1a875d38d7e1cd478ea5ba2db1b70817bcd36c624f2e952fd017eb83`. The workspace lock retains LaunchAtLogin-Modern 1.1.0, Sparkle 2.9.1, and swift-log 1.15.1. Dependency resolution may download these existing build inputs; generation uses the specified local model.

## Resolve dependencies before the old CLI fingerprints inputs

The frozen CLI predates the current-main dependency-resolution fix. A first build that creates or rewrites `Package.resolved` can therefore fail its strict source-stability check after building. Resolve first, verify pins, and then invoke the frozen CLI. Do not disable its source/build guards or replace it with the current-main runner to reproduce controlled evidence.

```bash
xcodebuild -resolvePackageDependencies -workspace "$WORKSPACE" \
  -scheme Cotabby -configuration Release \
  -derivedDataPath "$APP/build/DerivedData" \
  -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates

python3 - <<'PY'
import json, os, pathlib
expected = json.loads((pathlib.Path(os.environ['PREREQUISITES']) / 'Package.resolved').read_text())
actual = json.loads((pathlib.Path(os.environ['WORKSPACE']) / 'xcshareddata/swiftpm/Package.resolved').read_text())
assert actual['pins'] == expected['pins'], 'Dependency pins changed'
PY
```

The CLI owns Release `build-for-testing`, the `RUN_LLAMA_EVAL` compilation condition, unsigned test-host settings, source/product guards, and `test-without-building`. Every invocation below rebuilds after source selection. A new root necessarily produces a different path-sensitive build fingerprint. Retain fresh manifests and compare source file/model/native hashes instead of expecting the old absolute-path fingerprint or binary hash.

If setup still creates a lockfile after the explicit resolution, inspect that change and verify that pins remain unchanged before retrying with a new output label. The failed attempt's output directory is intentionally not overwritten. Machine-local signing configuration is not copied into these artifacts.

## Run matched comparisons

The function begins and ends with P2 applied. It reverses only `SurfaceContextComposer.swift` for the baseline, leaves the same frozen harness and reviewed tests in place, and selects the sampler penalty explicitly. It runs one benchmark command at a time. P2-specific unit assertions describe the candidate; do not execute those assertions while its composer is temporarily reversed.

```bash
run_variant() {
  local label="$1" penalty="$2"
  shift 2
  python3 "$APP/scripts/phrase_eval.py" run \
    --model "$MODEL" --workspace "$WORKSPACE" \
    --output "$RESULTS/$label" --label "$label" \
    --context paired --split-seed 1337 --screen-per-category 20 \
    --temperature 0.1 --repetition-penalty "$penalty" \
    --top-k 20 --top-p 0.7 --min-p 0.08 "$@"
}

run_pair() {
  local phase="$1"
  shift
  git -C "$APP" apply --check --reverse "$PREREQUISITES/surface-p2.patch"
  git -C "$APP" apply --reverse "$PREREQUISITES/surface-p2.patch"
  run_variant "$phase-baseline" 1.05 "$@"
  git -C "$APP" apply --check "$PREREQUISITES/surface-p2.patch"
  git -C "$APP" apply "$PREREQUISITES/surface-p2.patch"
  run_variant "$phase-finalist" 1.025 "$@"
}

run_pair screen42 --split screen --mode word --seed 42 --workers 3
run_pair heldout42 --split heldout --mode word --seed 42 --workers 3
run_pair full42 --split all --mode word --seed 42 --workers 3
run_pair productionseed --split all --mode word --seed 12648430 --workers 3
run_pair seed1337-150 --split all --mode word --per-category 150 --seed 1337 --workers 3
run_pair character150 --split all --mode character --per-category 150 --seed 42 --workers 3
run_pair latency --split screen --mode word --seed 12648430 --workers 1
```

Each phase can be run independently; these are reproduction recipes, not a claim that all phases have finished in the published snapshot. If a baseline run fails, the composer remains in baseline form; inspect the failure and reapply `surface-p2.patch` before starting another pair. Each output label requires a new directory.

The SHA-256 split is fixed by split seed 1337 and 20 screening phrases per category: 140 screen phrases, 1,197 held-out phrases, 1,337 total. Character150 uses the first 150 corpus-order phrases in each of seven categories (1,050 phrases), not a new held-out partition. Context `paired` records separate screen and no-screen conditions. The matched one-worker screen comparison is the latency check; concurrent three-worker timings include contention. Keep other inference idle during the latency pair.

The registered `seed1337-150` recipe uses that same corpus-order selection: **1,050 phrases and 5,782 word checkpoints per condition**, inference seed 1337, and three workers. Its 150-per-category size was chosen solely to fit the remaining validation time. It overlaps screening and is a descriptive seed check, not a new held-out partition; this recipe does not assert that the pair has completed.

## Recompute aggregate diagnostics

Use the delivered offline analyzer from the report repository, not the old source base. Its bootstrap seed is independent of the inference seed. Validate its retained hash before use:

```bash
python3 - <<'PY'
import hashlib, json, os, pathlib
repository = pathlib.Path(os.environ['REPORT_REPO'])
manifest = json.loads((pathlib.Path(os.environ['PREREQUISITES']) / 'manifest.json').read_text())
for name, expected in manifest['analysisHelpers'].items():
    assert hashlib.sha256((repository / name).read_bytes()).hexdigest() == expected, name
PY

for phase in screen42 heldout42 full42 productionseed seed1337-150 character150 latency; do
  python3 "$REPORT_REPO/scripts/analyze_phrase_experiments.py" \
    "$RESULTS/$phase-baseline/report.json" "$RESULTS/$phase-finalist/report.json" \
    --metric nextWord --bootstrap-samples 20000 --seed 1337 \
    > "$RESULTS/$phase-word-analysis.json"
done
python3 "$REPORT_REPO/scripts/analyze_phrase_experiments.py" \
  "$RESULTS/character150-baseline/report.json" "$RESULTS/character150-finalist/report.json" \
  --metric all --bootstrap-samples 20000 --seed 1337 \
  > "$RESULTS/character150-all-analysis.json"
```

Run analysis only for pairs you have completed. `nextWord` means zero-letter word boundaries; `all` includes every character checkpoint. Both use paired, category-stratified phrase-cluster uncertainty. Optional `scripts/analyze_completion_prefixes.py BEFORE AFTER` reports longer strict lexical prefix matches at word boundaries; it is neither semantic judgment nor a keystroke metric. Preserve raw generated artifacts locally and publish compact aggregates only. Remove this reproduction checkout's `build/DerivedData` when all runs and checks are finished.

## Scope limits

The fixture corpus is synthetic English writing. Its scenario apps are Messages (573), Safari (382), Notes (191), and Mail (191). None of the 1,337 scenarios provides a URL field, so browser-domain formatting has unit coverage but no domain-valued benchmark input. Actual capture, Accessibility, keyboard handling, acceptance, overlays, Apple generation, and configured endpoint generation are not exercised by these local llama comparisons. Endpoint base prompts share the P2 formatter, but no endpoint quality claim follows from this evidence. Current-main integration results must retain their separate source provenance and policy scope.
