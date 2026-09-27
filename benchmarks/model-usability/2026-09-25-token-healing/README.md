# GGUF prediction root cause and fix

The main reproducible defect was CoHamster's **partial-word token healing**, not a property of the GGUF file format. The same installed weights produce much better word completions after repairing how the typed fragment constrains decoding. The model downloads, quantization, prompts, and sampling parameters are unchanged.

## What went wrong

A language model predicts vocabulary tokens, which need not align with words. CoHamster already tried to “heal” an unfinished token by removing it from the prompt, forcing the model to replay its bytes, and hiding that replay from the UI. There were two problems:

1. **Only the last token was reconsidered.** A fragment such as ` intell` can already span several tokens. Keeping ` int` in the prompt while replaying only `ell` prevents the model from choosing its token for ` intelligence`.
2. **Shorter fragments competed with tokens covering all the typed bytes.** For ` int`, a token such as ` i` or a bare space can have high probability because it starts many unrelated words. Choosing that token first, then forcing the remaining bytes, does not account for how unlikely those remaining bytes are on the chosen path. It can lead to `intellij` or malformed words despite a strong ` intelligence` candidate.

For Base, an independent llama.cpp decode loop matched CoHamster's native wrapper on all 14 initial greedy controls. A controlled three-way ablation then changed only (a) the candidate rule and (b) the amount of prompt text reconsidered. This reproduced the original failures and isolated a large improvement before any Swift normalization or ghost-text rendering. The preliminary probe used a 64-byte experimental word limit; the shipping implementation retains the existing, stricter **16-byte** replay allowance. Final app measurements use the shipping implementation.

## Implementation and ownership

- `TokenHealingPlan` is a pure, short-lived value created by `LlamaRuntimeCore` for each generation/prefill. It selects a bounded, byte-exact suffix covering the current word and its leading separator when possible. Special tokens, single-line boundaries, long identifiers, and the last conditioning token retain safe fallback behavior.
- `TokenHealingVocabulary` lives in the pinned native package patch. It prefers tokens covering the complete remaining fragment, including an exact replay. It permits shorter matching pieces only when no covering token exists. Single-line filtering happens before this decision, so a forbidden newline token cannot strand a valid multi-token spelling.
- `TokenHealingBuffer` continues to remove replayed editor bytes and buffer incomplete UTF-8 before publishing streamed text. Cache, cancellation, and UI ownership remain with their existing components.

This is a bounded decoding heuristic, not an exact sum over every possible tokenization. In particular, it prioritizes vocabulary tokens that cover known bytes over alternate shorter-token paths. The app-level before/after replay measures that tradeoff instead of assuming it always helps.

## A separate limitation: missing context

The user's saved `cotabbyFastModeEnabled` preference was `true` during diagnosis. Fast Mode disables screen context, and the reproduced `Mlx ` prompt contained only generic app/language metadata and that short fragment. Base invented a language associated with the app. The same failure appeared in a fresh direct llama.cpp run.

In a separate control, adding relevant synthetic local context (“MLX targets Apple silicon…” and a question about an Intel laptop) changed the continuation to “is a new framework for building machine learning models.” Supplying that topic in the preceding draft also corrected the subject. This establishes a context problem for that example; it does not prove that all hallucinations disappear with screen context.

For short technical prompts, disable Fast Mode when surrounding screen text is useful, or include the topic in the draft/extended context. The decoder fix also works with Fast Mode enabled. This task does not change saved preferences or enable screen capture on the user's behalf.

## Reproduce the app evaluation

```sh
scripts/prepare_cohamster_workspace.sh
python3 scripts/supported_model_eval.py \
  --output build/eval/healing-validation \
  --stage validate --workloads character regressions runtime
```

The pure native vocabulary regression can also run without loading a model:

```sh
clang++ -std=c++17 \
  build/cohamster-dependencies/CotabbyInference/Tests/TokenHealingTests.cpp \
  build/cohamster-dependencies/CotabbyInference/Sources/CotabbyInferenceEngine/TokenHealing.cpp \
  -o build/token-healing-tests
build/token-healing-tests
```

The harness uses all four already-installed catalog models, a fixed synthetic English profile, seed 42, the production prompt/sampler, 4–7-word settings, and one inference worker. It runs the real request, normalization, eligibility, streaming, and native lifecycle paths. No hosted inference or model downloads are involved.

The comparison uses the previous immutable `2026-09-25` evaluation as its baseline. Character replay has 35 scenarios, 1,912 checkpoints per model, and paired screen/no-screen conditions. Each condition contains 767 partial-word and 189 next-word checkpoints. The preliminary 100-point diagnostic sample comes from this corpus, so the final replay is an expanded regression comparison, **not a wholly unseen benchmark**. Exact intended-word matches are not a human acceptance rate: plausible alternatives count as misses. Apple Intelligence was not benchmarked.

See `results.md` for the final measured comparison and `evidence.tar.gz` for reproducible raw outputs and provenance. Incomplete/interrupted exploratory campaigns are excluded.
