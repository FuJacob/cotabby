1. Rank screening candidates by screen next-word accuracy, breaking close ties using no-screen
   accuracy and simplicity. Freeze one finalist before opening held-out results. Any additional
   candidates evaluated on those results are exploratory and cannot replace this confirmatory test.
2. For adoption, require at least +0.50 percentage points screen improvement on held-out scenarios
   and a paired, category-stratified phrase-bootstrap 95% interval whose lower bound exceeds zero.
   Phrase resampling keeps correlated checkpoints together; these intervals describe this synthetic
   corpus and do not establish general population writing quality.
3. No-screen held-out accuracy must lose no more than 0.50 percentage points, with its 95% lower
   bound above -1.0 percentage point. No category screen loss may exceed 3 percentage points.
4. Recheck the winner against its matching baseline with the production seed `12648430`: require
   positive screen gain and no-screen point estimate at least -0.50 percentage points. Greedy
   configurations still require this check because the baseline is sampled.
5. Compare one-worker p95 latency on matching inputs. Investigate regression above the larger of
   10% or 20 ms before adoption; three-worker measurements are throughput diagnostics, not typing latency.
6. Require error-free complete reports, relevant unit tests, and a successful build. Full-corpus
   scores include screening data and are descriptive confirmation, not a second unseen test.
7. If these conditions are not met, keep product defaults and label any leading candidate provisional.

Validation priorities for the remaining window are: held-out word-mode seed 42; full word-mode
production seed; full word-mode seed 42; broad character-mode baseline/finalist; one-worker latency;
then additional fixed-seed robustness pairs if time permits. Additional seeds, registered before
validation, are 1337, 2026, and 314159 (in that order). These runs assess robustness; they cannot be
used to tune the already-frozen finalist. Confirmatory bootstrap analyses use 20,000 resamples.
