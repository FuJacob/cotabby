Metric: **nextWord (zero-letter word boundaries)**.

| Condition / category | Accuracy change | 95% interval | Gains / losses | p95 change |
|---|---:|---:|---:|---:|
| none / suite | +0.565 pp | [+0.108, +1.016] pp | 171 / 129 | -39.1 ms |
| none / conversation | +0.000 pp | [-1.166, +1.162] pp | 18 / 18 | -63.8 ms |
| none / entertainment | +0.282 pp | [-0.847, +1.398] pp | 21 / 18 | -34.3 ms |
| none / everyday | +1.351 pp | [+0.193, +2.519] pp | 28 / 14 | -10.6 ms |
| none / science | -0.095 pp | [-1.354, +1.208] pp | 20 / 21 | -108.9 ms |
| none / technology | +2.210 pp | [+0.975, +3.442] pp | 36 / 11 | -49.4 ms |
| none / travel | -0.816 pp | [-2.089, +0.446] pp | 23 / 32 | +18.1 ms |
| none / work | +0.898 pp | [-0.180, +1.998] pp | 25 / 15 | -28.8 ms |
| screen / suite | +0.013 pp | [-0.483, +0.511] pp | 178 / 177 | -34.2 ms |
| screen / conversation | +0.107 pp | [-1.468, +1.702] pp | 25 / 24 | -17.3 ms |
| screen / entertainment | +0.188 pp | [-1.215, +1.595] pp | 31 / 29 | -11.2 ms |
| screen / everyday | +1.158 pp | [-0.577, +2.860] pp | 44 / 32 | -30.3 ms |
| screen / science | -1.141 pp | [-2.262, -0.093] pp | 12 / 24 | -66.3 ms |
| screen / technology | +1.061 pp | [-0.178, +2.326] pp | 32 / 20 | -11.4 ms |
| screen / travel | +0.181 pp | [-1.000, +1.357] pp | 24 / 22 | -10.3 ms |
| screen / work | -1.438 pp | [-2.480, -0.444] pp | 10 / 26 | -31.6 ms |

- Intervals are descriptive fixture uncertainty, not runtime repeatability or proof of general writing improvement.
- Screening several candidates introduces selection bias; validate finalists on an untouched subset.
- Raw-output correctness is approximate Python diagnostics; Swift report scores remain authoritative.
- Latency with parallel workers includes contention; use matching one-worker runs for interactive latency.
