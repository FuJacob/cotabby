# Word/character boundary identity diagnostic

Prepared from source before inspecting any character150 report or journal. The finalist remains frozen. This adds an offline diagnostic to `analyze_character_subsets.py`; it schedules no inference and changes no scoring.

At `typedCharacters == 0`, the frozen implementation has no intentional mode-specific request, sampling, normalization, or scoring behavior. Equal outputs are the intended semantic result. Exact raw-output equality is a useful diagnostic expectation, rather than an unconditional guarantee of identical native floating-point execution across histories.

## Source evidence

All application paths below are relative to the frozen execution checkout `/Users/jmcasler/.codex/experiments/cotabby-1337-20260917/cotabby`, not the concurrently edited main worktree.

- `CotabbyTests/Evals/PhrasePredictionScoring.swift:112`: character mode expands each target word into offsets `0..<word.count`; offset zero is the same checkpoint as word mode. The expected word, draft prefix, and typed-word prefix are identical.
- `CotabbyTests/Evals/PhrasePredictionEvalTests.swift:96`: each worker owns an engine and spelling session; every phrase/context condition explicitly resets the engine cache before replay. Mode only selects the checkpoint list. `observe` at line 209 receives the checkpoint, scenario, context condition, settings, and configuration, with no mode argument.
- `CotabbyTests/Evals/PhrasePredictionScreenContext.swift:12`: request construction depends on those equal inputs. Synthetic OCR selection, surface metadata, and the existing draft are deterministic functions of the checkpoint/scenario. A generated request ID is bookkeeping, not prompt or sampler input.
- `Cotabby/Services/Runtime/Llama/LlamaSuggestionEngine.swift:264`: generation options, including the seed and word-continuation constraint, come from the request. Normalization uses the same raw output and request. The post-generation seam guard sees the same preceding text at a matching boundary.
- `Cotabby/Services/Runtime/Llama/LlamaRuntimeCore.swift:561`: reuse restores the actual prompt prefix, reapplies token-healing and continuation constraints, and decodes the required prompt suffix. A rejected restoration rebuilds a fresh sequence. Token healing is derived from the same tokenized prompt at line 315.
- In the sibling frozen native checkout, `Sources/CotabbyInferenceEngine/CotabbyInferenceEngine.cpp:778` resets the sampler on each prompt decode and accepts only the restored prompt tokens. `trimKV` at line 972 trims the token ledger and clears stale sampled/pending tokens. Discarded partial-word generations should not advance the next request's random stream or repetition history.

## Why disagreement still needs diagnosis

Character mode inserts generations between word boundaries. Its cache restoration points, tokenization history, and native prompt-decode batch shapes can therefore differ. The 150-per-category selection also changes worker assignments and context-order parity versus the full suite. The phrase/context cache reset should remove earlier native generation state, but native numerical execution need not be bitwise invariant across every batching path.

The same per-worker `CurrentWordSpellChecker` survives across phrases. Its source uses `NSSpellChecker.shared` with a unique document tag and `language: nil`; OS spelling state is not a recorded immutable model input. A display-only discrepancy with equal raw text is therefore distinguished from a raw generation discrepancy. These are potential explanations from the code, not findings about the unseen character results.

## Planned comparison

After both character reports are complete, the existing command validates their registration, source fingerprints, model hash, effective configuration, seed, errors, complete checkpoint expansion, and authoritative aggregates. It then compares each configuration only against its own full42 word-mode reference, using the character run's overlapping phrases and zero-letter checkpoints.

Compared fields are exact recorded `prompt`, `screenExcerpt`, `raw`, `shown`, `wasShown`, `predictedWord`, `suppression`, and `correct`. Optional fields absent on both sides compare equal. Latency is ignored. Scores are never recomputed from text.

The JSON and Markdown include aggregate mismatch counts, correctness gains/losses, and first-boundary versus later-boundary counts. JSON additionally retains category and individual-field counts. The first boundary follows an explicit phrase/context cache reset in both modes, providing a useful comparison with later boundaries that follow different within-phrase histories. Mismatch categories are diagnostic and can overlap; they are not a causal attribution or a new benchmark score.

The original subset report remains unchanged in purpose: zero-letter boundaries, positive-letter checkpoints, and all checkpoints are separate denominators, and partial-only uncertainty resamples whole phrases. No identity result authorizes retuning the frozen finalist.
