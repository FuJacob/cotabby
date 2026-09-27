# Frozen character-pair subset analysis

All correctness and display counts use Swift report flags. No lexical rescoring was performed.

`wordBoundary` means typedCharacters == 0; `partialOnly` means typedCharacters > 0; `all` is their disjoint union. Suppressed predictions remain misses in every denominator.

| Subset / context | Checkpoints | Correct before → after | Accuracy before → after | Δ pp | Shown before → after | Gains / losses |
|---|---:|---:|---:|---:|---:|---:|
| wordBoundary / none | 5,782 | 1,664 → 1,800 | 28.78% → 31.13% | +2.352 | 5,781 → 5,780 | 327 / 191 |
| wordBoundary / screen | 5,782 | 2,013 → 2,199 | 34.81% → 38.03% | +3.217 | 5,782 → 5,781 | 331 / 145 |
| partialOnly / none | 21,584 | 12,106 → 12,925 | 56.09% → 59.88% | +3.794 | 19,843 → 20,031 | 1,652 / 833 |
| partialOnly / screen | 21,584 | 14,056 → 14,879 | 65.12% → 68.94% | +3.813 | 20,040 → 20,237 | 1,269 / 446 |
| all / none | 27,366 | 13,770 → 14,725 | 50.32% → 53.81% | +3.490 | 25,624 → 25,811 | 1,979 / 1,024 |
| all / screen | 27,366 | 16,069 → 17,078 | 58.72% → 62.41% | +3.687 | 25,822 → 26,018 | 1,600 / 591 |

## Partial-word uncertainty

20,000 paired category-stratified whole-phrase resamples, fixed bootstrap seed 1337. Character checkpoints within a phrase remain together, and screen/no-screen share every sampled phrase draw.

| Context / group | Partial-only Δ pp | 95% interval, pp |
|---|---:|---:|
| none / suite | +3.794 | [+3.087, +4.515] |
| none / conversation | +5.021 | [+3.075, +7.073] |
| none / entertainment | +5.318 | [+3.455, +7.215] |
| none / everyday | +5.038 | [+3.145, +6.930] |
| none / science | +3.720 | [+2.259, +5.198] |
| none / technology | -1.681 | [-3.620, +0.214] |
| none / travel | +6.685 | [+4.653, +8.723] |
| none / work | +4.098 | [+2.214, +6.064] |
| screen / suite | +3.813 | [+3.247, +4.382] |
| screen / conversation | +3.971 | [+2.574, +5.452] |
| screen / entertainment | +7.815 | [+5.985, +9.655] |
| screen / everyday | +4.710 | [+3.067, +6.435] |
| screen / science | -0.083 | [-1.133, +0.915] |
| screen / technology | +2.370 | [+1.029, +3.720] |
| screen / travel | +7.347 | [+5.486, +9.266] |
| screen / work | +2.092 | [+0.750, +3.421] |

## wordBoundary category denominators

| Context / category | Checkpoints | Correct before → after | Shown before → after | Δ pp | Gains / losses |
|---|---:|---:|---:|---:|---:|
| none / conversation | 725 | 206 → 241 | 725 → 725 | +4.828 | 51 / 16 |
| none / entertainment | 830 | 185 → 221 | 830 → 830 | +4.337 | 59 / 23 |
| none / everyday | 806 | 215 → 225 | 805 → 806 | +1.241 | 47 / 37 |
| none / science | 819 | 366 → 384 | 819 → 819 | +2.198 | 34 / 16 |
| none / technology | 881 | 225 → 223 | 881 → 881 | -0.227 | 39 / 41 |
| none / travel | 849 | 214 → 250 | 849 → 849 | +4.240 | 62 / 26 |
| none / work | 872 | 253 → 256 | 872 → 870 | +0.344 | 35 / 32 |
| screen / conversation | 725 | 285 → 313 | 725 → 725 | +3.862 | 42 / 14 |
| screen / entertainment | 830 | 240 → 283 | 830 → 830 | +5.181 | 64 / 21 |
| screen / everyday | 806 | 246 → 299 | 806 → 806 | +6.576 | 73 / 20 |
| screen / science | 819 | 383 → 390 | 819 → 819 | +0.855 | 26 / 19 |
| screen / technology | 881 | 271 → 280 | 881 → 880 | +1.022 | 40 / 31 |
| screen / travel | 849 | 277 → 311 | 849 → 849 | +4.005 | 57 / 23 |
| screen / work | 872 | 311 → 323 | 872 → 872 | +1.376 | 29 / 17 |

## partialOnly category denominators

| Context / category | Checkpoints | Correct before → after | Shown before → after | Δ pp | Gains / losses |
|---|---:|---:|---:|---:|---:|
| none / conversation | 2,191 | 1,318 → 1,428 | 2,062 → 2,078 | +5.021 | 173 / 63 |
| none / entertainment | 3,084 | 1,518 → 1,682 | 2,839 → 2,863 | +5.318 | 279 / 115 |
| none / everyday | 2,739 | 1,362 → 1,500 | 2,516 → 2,560 | +5.038 | 235 / 97 |
| none / science | 3,629 | 2,449 → 2,584 | 3,385 → 3,414 | +3.720 | 196 / 61 |
| none / technology | 3,628 | 2,014 → 1,953 | 3,276 → 3,269 | -1.681 | 189 / 250 |
| none / travel | 2,872 | 1,437 → 1,629 | 2,613 → 2,676 | +6.685 | 327 / 135 |
| none / work | 3,441 | 2,008 → 2,149 | 3,152 → 3,171 | +4.098 | 253 / 112 |
| screen / conversation | 2,191 | 1,528 → 1,615 | 2,059 → 2,089 | +3.971 | 110 / 23 |
| screen / entertainment | 3,084 | 1,844 → 2,085 | 2,868 → 2,917 | +7.815 | 305 / 64 |
| screen / everyday | 2,739 | 1,642 → 1,771 | 2,544 → 2,582 | +4.710 | 203 / 74 |
| screen / science | 3,629 | 2,693 → 2,690 | 3,410 → 3,415 | -0.083 | 73 / 76 |
| screen / technology | 3,628 | 2,247 → 2,333 | 3,295 → 3,309 | +2.370 | 172 / 86 |
| screen / travel | 2,872 | 1,757 → 1,968 | 2,673 → 2,710 | +7.347 | 262 / 51 |
| screen / work | 3,441 | 2,345 → 2,417 | 3,191 → 3,215 | +2.092 | 144 / 72 |

## all category denominators

| Context / category | Checkpoints | Correct before → after | Shown before → after | Δ pp | Gains / losses |
|---|---:|---:|---:|---:|---:|
| none / conversation | 2,916 | 1,524 → 1,669 | 2,787 → 2,803 | +4.973 | 224 / 79 |
| none / entertainment | 3,914 | 1,703 → 1,903 | 3,669 → 3,693 | +5.110 | 338 / 138 |
| none / everyday | 3,545 | 1,577 → 1,725 | 3,321 → 3,366 | +4.175 | 282 / 134 |
| none / science | 4,448 | 2,815 → 2,968 | 4,204 → 4,233 | +3.440 | 230 / 77 |
| none / technology | 4,509 | 2,239 → 2,176 | 4,157 → 4,150 | -1.397 | 228 / 291 |
| none / travel | 3,721 | 1,651 → 1,879 | 3,462 → 3,525 | +6.127 | 389 / 161 |
| none / work | 4,313 | 2,261 → 2,405 | 4,024 → 4,041 | +3.339 | 288 / 144 |
| screen / conversation | 2,916 | 1,813 → 1,928 | 2,784 → 2,814 | +3.944 | 152 / 37 |
| screen / entertainment | 3,914 | 2,084 → 2,368 | 3,698 → 3,747 | +7.256 | 369 / 85 |
| screen / everyday | 3,545 | 1,888 → 2,070 | 3,350 → 3,388 | +5.134 | 276 / 94 |
| screen / science | 4,448 | 3,076 → 3,080 | 4,229 → 4,234 | +0.090 | 99 / 95 |
| screen / technology | 4,509 | 2,518 → 2,613 | 4,176 → 4,189 | +2.107 | 212 / 117 |
| screen / travel | 3,721 | 2,034 → 2,279 | 3,522 → 3,559 | +6.584 | 319 / 74 |
| screen / work | 4,313 | 2,656 → 2,740 | 4,063 → 4,087 | +1.948 | 173 / 89 |

## Word-mode versus character-mode boundary identity

Each configuration is compared only with its own frozen full-word run, on the character run's overlapping zero-letter checkpoints. Exact recorded prompt, excerpt, raw, shown, visibility, predicted word, suppression, and correctness values are compared; latency is ignored. Counts describe disagreements and do not replace either score.

| Configuration / context | Boundaries | Any mismatch | Prompt / excerpt mismatch | Raw mismatch, same input | Shown mismatch, same input + raw | Correct mismatch | Character gains / losses |
|---|---:|---:|---:|---:|---:|---:|---:|
| baseline / none | 5,782 | 1 | 0 / 0 | 1 | 0 | 0 | 0 / 0 |
| baseline / screen | 5,782 | 0 | 0 / 0 | 0 | 0 | 0 | 0 / 0 |
| finalist / none | 5,782 | 3 | 0 / 0 | 3 | 0 | 0 | 0 / 0 |
| finalist / screen | 5,782 | 4 | 0 / 0 | 4 | 0 | 0 | 0 / 0 |

| Configuration / context / position | Boundaries | Raw mismatch, same input | Correct mismatch |
|---|---:|---:|---:|
| baseline / none / firstBoundary | 1,050 | 0 | 0 |
| baseline / none / laterBoundaries | 4,732 | 1 | 0 |
| baseline / screen / firstBoundary | 1,050 | 0 | 0 |
| baseline / screen / laterBoundaries | 4,732 | 0 | 0 |
| finalist / none / firstBoundary | 1,050 | 0 | 0 |
| finalist / none / laterBoundaries | 4,732 | 3 | 0 |
| finalist / screen / firstBoundary | 1,050 | 0 | 0 |
| finalist / screen / laterBoundaries | 4,732 | 4 | 0 |

The first boundary follows an explicit phrase/context cache reset in both modes; later boundaries follow different generation histories. There is no deliberate mode-specific prompt or sampler policy at zero-letter checkpoints. Different KV restoration/decode batching and worker/spelling-session histories mean a mismatch is not by itself proof of a cache bug. Per-category and per-field counts are retained in JSON.

## Interpretation and provenance

- Partial-only estimates are separate from the primary zero-letter word-boundary score; an all-checkpoint improvement cannot establish partial-word non-regression.
- Intervals describe phrase-sampling uncertainty in this selected synthetic corpus, not runtime noise, semantic utility, or general writing accuracy.
- This registered subset is the first 150 corpus-order phrases per category, including screening phrases; it is not a new untouched held-out writing set.
- Category intervals and three subset summaries are descriptive and are not corrected for multiple comparisons or screening selection.
- All scoring uses the frozen snapshot's display policy; concurrently edited production completion behavior requires separate integration validation.
- No latency inference is made from these three-worker runs. Production seed robustness is evaluated separately; this pair uses seed 42.

The JSON companion records report, manifest, registration, helper, and existing-analyzer SHA-256 hashes, plus both source and binary fingerprints. These are recorded provenance checks, not a cryptographic attestation of a historical execution.
