# Live typing latency comparison

Measured September 24, 2026 (Pacific), using real CGEvent keyboard input through the running app in a dedicated TextEdit document. Apple Intelligence and saved settings were held constant. This was automated typing, not a human typing session.

- Valid pauses: 10 baseline, 10 updated; four partial-word trials excluded because the observed field changed `schedu` to `schedule`. Warmups excluded.
- Prediction coverage within 3 seconds: 6/10 baseline versus 10/10 updated.
- On the 6 paired pauses where both builds produced a prediction: median 513.2 ms baseline versus 424.1 ms updated (89.1 ms, 17.4% lower).
- Median paired reduction: 96.1 ms; range -22.7 to 106.9 ms (negative means slower).

| Phrase ending | Baseline runs (ms) | Updated runs (ms) |
|---|---:|---:|
| Please send me the updated | 408.2, 409.2 | 430.9, 407.9 |
| There is a long delay | none within 3 s, none within 3 s | 533.7, 492.0 |
| The predictions come up | none within 3 s, none within 3 s | 724.3, 665.2 |
| I would like to build | 517.4, 508.9 | 414.9, 417.2 |
| We should review the proposal | 567.5, 575.5 | 467.0, 468.6 |

The baseline suppressed both no-space continuations in each repetition (`seam-suppressed`). Coverage is reported separately so missing predictions do not disappear from the comparison.

Method: updated-1, baseline-1, baseline-2, updated-2; restart between blocks and one excluded warmup per block. Requested suffix cadence was 120 ms per key; actual median interval was 125.1 ms. Prefix setup was faster. The harness checked app/window/field focus before every key and verified final text through Accessibility.

Timing uses the app’s existing last-input-to-first-accepted-overlay-submission metric, joined to each final key within 100 ms and a 3-second observation window. This is not a display compositor timestamp. Small fixed-phrase sample, two repetitions per case; no statistical confidence or cross-app generalization claimed. No claim that every phrase became faster.

The updated build was restored after the baseline blocks and remained running after the final block. Binary hashes and source state are in manifest.json. Compact per-trial measurements are in results.json; raw logs and the local keyboard driver remain untracked.
