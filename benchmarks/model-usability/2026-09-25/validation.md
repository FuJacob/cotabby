# Supported model evaluation

Local Release replay, one inference worker, fixed seed 42, synthetic English profile (Alex).
Exact intended-word match is not a semantic quality rating; plausible alternatives count as misses.
Final-generation latency excludes model load, keyboard debounce and Accessibility/overlay work.
Completion length: 4-7 words.

| Model | Prompt | Workload | Context | Next word | Partial word | Shown | Precision | p50 / p95 ms | Errors |
|---|---|---|---|---:|---:|---:|---:|---:|---:|
| CoHamster Nano | production | word | none | 29.5% | — | 100.0% | 29.5% | 52 / 110 | 0 |
| CoHamster Nano | production | word | screen | 36.6% | — | 100.0% | 36.6% | 57 / 113 | 0 |
| CoHamster Nano | production | character | none | 28.0% | 59.2% | 95.7% | 55.4% | 54 / 97 | 0 |
| CoHamster Nano | production | character | screen | 35.4% | 65.3% | 96.3% | 61.7% | 53 / 100 | 0 |
| CoHamster Nano | production | regressions | none | 39.4% | 64.1% | 95.7% | 61.4% | 54 / 99 | 0 |
| CoHamster Nano | production | runtime | none | 75.0% | — | 100.0% | 75.0% | 29 / 116 | 0 |
| CoHamster Mini | production | word | none | 31.8% | — | 100.0% | 31.8% | 87 / 193 | 0 |
| CoHamster Mini | production | word | screen | 40.6% | — | 100.0% | 40.6% | 89 / 232 | 0 |
| CoHamster Mini | production | character | none | 30.2% | 56.5% | 95.3% | 53.8% | 81 / 157 | 0 |
| CoHamster Mini | production | character | screen | 37.6% | 69.8% | 96.5% | 65.7% | 81 / 192 | 0 |
| CoHamster Mini | production | regressions | none | 39.4% | 66.9% | 96.3% | 63.2% | 95 / 159 | 0 |
| CoHamster Mini | production | runtime | none | 75.0% | — | 100.0% | 75.0% | 34 / 174 | 0 |
| CoHamster Base | production | word | none | 30.7% | — | 100.0% | 30.7% | 111 / 247 | 0 |
| CoHamster Base | production | word | screen | 41.3% | — | 99.8% | 41.3% | 99 / 281 | 0 |
| CoHamster Base | production | character | none | 30.2% | 53.2% | 91.8% | 53.0% | 115 / 203 | 0 |
| CoHamster Base | production | character | screen | 37.6% | 64.8% | 91.6% | 64.8% | 90 / 236 | 0 |
| CoHamster Base | production | regressions | none | 38.0% | 66.9% | 94.7% | 63.9% | 130 / 208 | 0 |
| CoHamster Base | production | runtime | none | 75.0% | — | 100.0% | 75.0% | 42 / 229 | 0 |
| CoHamster Pro | production | word | none | 31.7% | — | 100.0% | 31.7% | 169 / 440 | 0 |
| CoHamster Pro | production | word | screen | 40.2% | — | 100.0% | 40.2% | 168 / 490 | 0 |
| CoHamster Pro | production | character | none | 31.2% | 53.2% | 91.2% | 53.6% | 171 / 381 | 0 |
| CoHamster Pro | production | character | screen | 39.2% | 66.0% | 94.1% | 64.4% | 132 / 452 | 0 |
| CoHamster Pro | production | regressions | none | 40.8% | 66.1% | 95.7% | 63.3% | 169 / 360 | 0 |
| CoHamster Pro | production | runtime | none | 75.0% | — | 100.0% | 75.0% | 66 / 320 | 0 |

Status: complete.

Raw prompts, completions, source/binary/model hashes and per-case suppressions are in each replay directory.
The word and character samples overlap; do not pool them as independent evidence. Regression cases are development examples.
Use a held-out validation campaign after choosing a fix. No model is automatically declared usable from a small sample.
