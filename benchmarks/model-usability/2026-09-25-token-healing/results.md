# Measured result

Same installed weights, prompts, sampler settings, and 35 phrase scenarios before and after.
Each percentage below covers 767 partial-word checkpoints; screen conditions are separate.

| Model | No screen: before → fixed | Screen: before → fixed | Fixed p95 generation, no screen / screen |
|---|---:|---:|---:|
| Nano | 59.2% → **78.5%** | 65.3% → **82.7%** | 137 / 135 ms |
| Mini | 56.5% → **80.8%** | 69.8% → **87.5%** | 258 / 279 ms |
| Base | 53.2% → **76.9%** | 64.8% → **85.0%** | 269 / 294 ms |
| Pro | 53.2% → **77.6%** | 66.0% → **87.5%** | 359 / 374 ms |

Final-generation latency includes replay and cleanup; it excludes model loading, keyboard debounce, real screenshot/OCR collection, Accessibility, and overlay work. Character replay includes both partial-word and word-boundary checkpoints. See raw runtime/typing reports for first-useful streaming measurements.

## Word boundaries

| Model | Next-word accuracy, no screen: before → fixed | Screen: before → fixed | Raw next-word outputs changed |
|---|---:|---:|---:|
| Nano | 28.0% → 28.0% | 35.4% → 35.4% | 0/378 |
| Mini | 30.2% → 30.2% | 37.6% → 37.6% | 3/378 |
| Base | 30.2% → 30.2% | 37.6% → 37.6% | 0/378 |
| Pro | 31.2% → 31.2% | 39.2% → 39.2% | 6/378 |

## Scripted typing, streaming enabled

These are five short traces with 20 useful-word opportunities per cache condition, not observed human accepts. Input-to-first-useful latency includes the fixed 20 ms debounce; the usual app/AX/OCR limitations above still apply.

| Model | Cold useful: before → fixed | Prewarmed useful: before → fixed | Fixed p95 first useful, cold / prewarmed |
|---|---:|---:|---:|
| Nano | 8/20 → 12/20 | 10/20 → 12/20 | 88 / 100 ms |
| Mini | 6/20 → 12/20 | 7/20 → 14/20 | 140 / 129 ms |
| Base | 7/20 → 11/20 | 7/20 → 13/20 | 159 / 130 ms |
| Pro | 5/20 → 9/20 | 5/20 → 10/20 | 230 / 154 ms |

## Reported examples

Raw completions for the original `apple int` checkpoint (the typed prefix ends in `int`):

| Model | Before | Fixed |
|---|---|---|
| Nano | `erop is not working.` | `ernal model is not working.` |
| Mini | `erpreter is not working.` | `elligence has a new model called gpt-4` |
| Base | `ellij idea.` | `elligence is not working.` |
| Pro | `el nvidia amd` | `elligence is not working.` |

Nano can still choose “internal” instead of “intelligence”; this is a different intended word, not a malformed replay. Very short, under-specified inputs can still prompt fabricated content. This fix does not make model knowledge or next-word prediction perfect.

## Validation

- Release build-for-testing succeeded.
- 145 focused Swift tests passed, including 10 new replay-plan tests.
- Native C++ vocabulary/replay tests passed, including single-line and byte-fallback regressions.
- 64 Python harness tests passed.
- All four models completed the character, reported-regression, and runtime jobs; see the campaign and test logs in the evidence archive.
- The app code and native package patch are changed; saved settings and the installed application are not replaced by the benchmark.

**24 native lifecycle checks passed** (six per model); the final campaign contains **8,952 prediction checkpoints with zero inference errors**.


## Rebuilt app

A clean, signed **Release build for Apple silicon** is packaged at `build/token-healing-fix/CoHamster.zip` (version 0.6.5, build 2026092403). It contains no XCTest bundle. Its deep code signature was verified after extracting the ZIP; `release-build.json` records the hashes and signing team. The ZIP avoids Finder metadata being added inside the app by folder synchronization.

To try it, extract the ZIP, quit the currently running CoHamster, and open the extracted app. It uses the existing local models and preferences. **Mini with Fast Mode off** is the best quality/speed balance in this English replay; Nano is faster. The installed copy and saved preferences have not been replaced or changed.
