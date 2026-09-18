# Round three text-prediction cycle

Run date: 2026-09-17. Inputs were frozen in the isolated checkout
`/Users/jmcasler/.codex/experiments/cotabby-1337-round3-20260917`.

The 1337 corpus, Qwen3.5-0.8B-Base GGUF, native package snapshot, prompt settings, worker count,
and scorer were held constant. The corpus SHA256 is
`b41c8089a58ae1e0ee84b95ac9283cf71db4e713e25bd8fed47220be69d8b0f6`; the model SHA256 is
`febd85051361ccb34d0925744c819f9ae0724117e8f946a2852dd0edfa90a5a1`.

## Screening

Each candidate used the same 140-phrase seed-42 screen partition and 1,540 paired predictions.
The screening rule was at least four additional correct checkpoints in the target condition and
no loss in the other condition.

| Run | Screen | No-screen | Decision |
| --- | ---: | ---: | --- |
| baseline-screen42 | 288/770 | 235/770 | control |
| A — omit `Format:` only with usable screen context | 294/770 (+6) | 235/770 (+0) | PASS |
| B — omit `Field:` only without usable screen context | 288/770 (+0) | 241/770 (+6) | PASS |
| AB — apply A and B together | 294/770 (+6) | 241/770 (+6) | PASS |

AB was selected because it had the largest sum of gains. Focused Swift tests passed for every
candidate build (95 selected tests, one pre-existing opt-in audit skipped, zero failures), and the
Python harness suite passed (58 tests).

## Full seed-42 gate

The matched full workload was 7,437 checkpoints per condition. The plan requires at least 38
additional correct predictions in both conditions at every full seed.

| Run | Screen | No-screen | Errors | Gate |
| --- | ---: | ---: | ---: | --- |
| baseline-full42 | 2,789/7,437 | 2,306/7,437 | 0 | control |
| AB-full42 | 2,790/7,437 (+1) | 2,348/7,437 (+42) | 0 | **REJECT** |

AB gains the complete no-screen threshold (+42, +0.56 percentage points) but misses the required
screen threshold (+1, +0.01 percentage points). Category changes explain the aggregate result: the
screen condition gained in everyday and technology but lost 12 science and 16 work checkpoints.
Because the full seed-42 gate failed, the plan stops before production-seed, partial-word, and
latency stages.

## Outcome

No production code was adopted. The isolated checkout was restored to the baseline production
files after evidence capture; the current worktree remains unchanged by the experiment. Reports,
build/test logs, and candidate screening results are retained in this directory. The conditional
metadata idea remains a strong follow-on target, but it needs a more selective screen-side policy
before another full run.
