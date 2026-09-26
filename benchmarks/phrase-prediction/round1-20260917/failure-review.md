# Remaining prediction failures after frozen P2-H validation

The remaining benchmark gap is overwhelmingly a generated first-word mismatch to the reference, not loss of a correct word during normalization or display. This memo is a post-freeze diagnostic for future rounds. It does not propose another change to the frozen finalist.

## Evidence and interpretation

- Seed 42 uses 1,197 held-out phrases: 6,667 next-word checkpoints per context condition.
- Production seed 12,648,430 uses the full 1,337 phrases: 7,437 checkpoints per condition. This includes screening phrases, so it is a seed robustness check, not a second independent held-out writing set.
- Baseline-to-finalist comparisons within each pair have identical fixtures, checkpoint identities, and seeds. Cross-seed stability below uses only the 1,197 common held-out phrases.
- Primary correctness, coverage, and gains/losses use the existing Swift report values. Existing analysis and completion-prefix outputs were read first; raw-first-word, excerpt-word, and later-word diagnostics are explicitly approximate lexical checks.
- These reports use the frozen source snapshot and display policy. They do not measure the concurrently edited main-worktree typo/completion behavior. No real user logs were read.

## Matched accuracy and remaining misses

| Pair / condition | Baseline correct | Finalist correct | Gain | Paired gains / losses | Shown lexical mismatch | Shown unscorable first word | Not shown |
|---|---:|---:|---:|---:|---:|---:|---:|
| Held-out 42 / none | 1,909/6,667 (28.63%) | 2,071/6,667 (31.06%) | +2.43 pp | 369 / 207 | 4,580 | 15 | 1 |
| Held-out 42 / screen | 2,295/6,667 (34.42%) | 2,501/6,667 (37.51%) | +3.09 pp | 382 / 176 | 4,158 | 7 | 1 |
| Production seed / none | 2,120/7,437 (28.51%) | 2,322/7,437 (31.22%) | +2.72 pp | 420 / 218 | 5,098 | 16 | 1 |
| Production seed / screen | 2,586/7,437 (34.77%) | 2,813/7,437 (37.82%) | +3.05 pp | 429 / 202 | 4,614 | 9 | 1 |

All four finalist condition summaries have exactly one suppression, attributed to the normalizer, and zero inference errors. Coverage is about 99.99%. The approximate raw-correct/display-incorrect count is **zero in all four summaries**; raw and displayed strings differ only on the single suppressed observation in each. The displayed but unscorable outputs all have a leading non-whitespace punctuation fragment under the lexical diagnostic. This does not justify stripping punctuation blindly.

For the full production-seed screen condition, 4,614 of 4,624 misses are shown lexical first-word mismatches. Only ten checkpoints are in the punctuation/suppression classes combined (0.13% of all checkpoints). Thus broad relaxation of cleanup or display guards has very little measured headroom in this word-boundary benchmark.

A shown reference mismatch is not automatically a bad suggestion: this exact-match test gives a plausible alternative zero credit. These counts locate the measured mismatch in generation; they do not establish semantic unacceptability.

## Stability across sampling seeds

| On the same 6,667 held-out checkpoints | Screen | No screen |
|---|---:|---:|
| Finalist correct with both seeds | 2,438 | 2,011 |
| Finalist misses with both seeds | 4,080 | 4,529 |
| Same incorrect lexical first word with both seeds | 3,791 | 4,202 |
| Finalist correctness changes across seeds | 149 | 127 |
| Both baseline and finalist miss with both seeds | 3,900 | 4,324 |
| Baseline→finalist gain repeats with both seeds | 310 | 304 |
| Baseline→finalist loss repeats with both seeds | 118 | 160 |

On screen-context checkpoints, 4,080 remain misses at both seeds, and 3,791 produce the same incorrect lexical first word. Only 149 of 6,667 correctness outcomes change across seeds (2.23%). This supports investigating model word choice and context use ahead of another random-seed search. It does not prove invariance over every seed, nor authorize choosing a seed against these now-inspected validation results.

## Category pattern

All seven screen categories improve within both matched comparisons. Technology and entertainment retain the lowest absolute screen accuracy; science has the highest absolute accuracy but the smallest gain from this candidate. Category labels identify where to test a hypothesis, not its cause.

| Category | Held-out 42 finalist | Gain | Gains / losses | Production-seed finalist | Gain | Gains / losses |
|---|---:|---:|---:|---:|---:|---:|
| conversation | 366/841 (43.52%) | +3.57 pp | 50 / 20 | 404/937 (43.12%) | +3.84 pp | 55 / 19 |
| entertainment | 319/954 (33.44%) | +4.30 pp | 70 / 29 | 358/1065 (33.62%) | +4.04 pp | 69 / 26 |
| everyday | 346/931 (37.16%) | +6.23 pp | 80 / 22 | 383/1036 (36.97%) | +5.12 pp | 82 / 29 |
| science | 433/944 (45.87%) | +0.95 pp | 30 / 21 | 488/1052 (46.39%) | +0.67 pp | 35 / 28 |
| technology | 319/1015 (31.43%) | +1.67 pp | 52 / 35 | 356/1131 (31.48%) | +1.59 pp | 60 / 42 |
| travel | 349/983 (35.50%) | +3.36 pp | 62 / 29 | 410/1103 (37.17%) | +5.08 pp | 84 / 28 |
| work | 369/999 (36.94%) | +1.80 pp | 38 / 20 | 414/1113 (37.20%) | +1.26 pp | 44 / 30 |

At seed 42, the finalist still misses 696 technology, 635 entertainment, 630 work, and 634 travel checkpoints. The full production-seed suite shows the same broad residual pattern. These are large enough groups for future balanced experiments; adding fixture-specific vocabulary or answer rules would invalidate that interpretation.

## Screen context helps overall, with a measurable harm subset

| Finalist pair | Screen lift over no-screen | Screen helps / harms | Expected word occurs in bounded excerpt (approx.) | Misses among those cue-present checkpoints |
|---|---:|---:|---:|---:|
| Held-out 42 | +6.45 pp | 726 / 296 | 1,246 | 493 |
| Production seed | +6.60 pp | 815 / 324 | 1,385 | 536 |

The production-seed finalist benefits from screen context on 815 checkpoints while losing an otherwise correct no-screen prediction on 324. Separately, 536 misses occur where the exact expected word is lexically present in the bounded excerpt. This is evidence for a future controlled context-use study, not proof that those 536 words should have been copied: common words, unrelated occurrences, and alternative sentence choices are included. The excerpt-presence test uses the existing approximate tokenizer and does not assign new correctness scores.

## Multiword lexical tails remain short

| Pair / condition | Mean correct-prefix words, before→after | P(prefix ≥2), before→after | P(prefix ≥3), before→after | Second word matches given first is correct and another word remains |
|---|---:|---:|---:|---:|
| Held-out 42 / none | 0.377→0.422 | 8.24%→10.05% (n=5,470) | 2.57%→3.32% (n=4,273) | 550/1586 (34.68%) |
| Held-out 42 / screen | 0.485→0.541 | 12.21%→14.31% (n=5,470) | 4.47%→5.29% (n=4,273) | 783/1894 (41.34%) |
| Production seed / none | 0.375→0.427 | 8.11%→10.20% (n=6,100) | 2.67%→3.53% (n=4,763) | 622/1769 (35.16%) |
| Production seed / screen | 0.489→0.549 | 12.39%→14.48% (n=6,100) | 4.43%→5.69% (n=4,763) | 883/2122 (41.61%) |

The finalist improves the longer lexical prefix diagnostics too, so the primary gain is not accompanied by an observed tail regression. Nevertheless, in the full production-seed screen run, 1,239 of 2,122 completions with a correct first word and another reference word available fail to match that second word or stop before it (58.39%). This motivates a separate acceptance-length/continuation-utility evaluation. It does not by itself establish that the tail is semantically wrong or that shortening output improves next-word accuracy.

The first word always defers to Swift correctness; later words use the existing approximate lexical matcher. All four finalist summaries report zero first-word parser disagreements. P(prefix ≥k) uses only checkpoints with at least k reference words left, so its denominators differ across k. Extra output after the reference ends is unknown and never penalized.

## Priorities for a later round

1. **Prediction capacity or word-selection quality:** compare a finite set of genuinely different model/word-selection approaches on a fresh screening/validation split. The 3,791 repeatable same-word screen misses and 3,900 checkpoints missed by both baseline and finalist at both seeds justify this ahead of more seed tuning. Keep memory, model-loading, and one-worker latency constraints explicit.
2. **Context use:** evaluate generic relevance/conditioning hypotheses using fresh scenarios with controlled useful and distracting cues. Preserve paired no-screen controls: the current +6.60 pp context lift and 815/324 help/harm split show that context is valuable but not uniformly helpful. Do not tune production rules to the 536 cue-present reference misses.
3. **Continuation utility beyond one word:** retain the unchanged first-word score while adding independent typing/acceptance measures or human judgments. Lexical second-word match is only about 41.6% conditional on an available second word and a correct first word in the production-seed screen run.
4. **Delivery/normalization as a targeted, low-priority audit for this mode:** zero observed raw-correct losses and one suppression per condition do not support broadly weakening guards. Partial-word and streaming behavior require their separately registered evaluations and may have different failure classes.

Future work should use newly protected validation data because this memo intentionally inspects aggregate validation failures. No corpus text, generated completions, prompts, user logs, or fixture-specific production rules are included here.

## Reproduction and source integrity

The existing `heldout42-analysis.json`, `productionseed-analysis.json`, `heldout42-prefixes.json`, and `productionseed-prefixes.json` supply reported accuracy, transitions, and lexical-prefix metrics. Additional aggregate classification uses authoritative `correct`, `wasShown`, and `predictedWord` fields. Cross-seed records join on phrase ID, condition, and word index, with checkpoint equality verified.

`failure-review.json` records all aggregate tables, method limitations, and SHA-256 hashes of the four raw reports and four existing analysis inputs. Original reports were not modified.
