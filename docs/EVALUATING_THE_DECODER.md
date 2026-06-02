# Evaluating the Experimental Constrained Decoder

The constrained decoder, multi-branch (beam) search, and fill-in-middle (FIM)
prompting ship **behind default-off developer flags**. Decode quality can only be
judged with a real model in a real text field, so none of them is promoted to the
default until it has been dogfooded on device. This doc is the recipe for that:
how to turn each path on, and how to read the logs to decide whether it earns the
default.

The flags live in `LlamaSuggestionEngine` and `LlamaGenerationOptions`; they do
not affect KV reuse, so toggling them mid-session is safe.

## Flags

Set these against the app's `UserDefaults` domain (`com.jacobfu.tabby`), then
restart the app:

| Key | Type | Effect |
| --- | --- | --- |
| `cotabbyConstrainedDecoderEnabled` | Bool | Routes generation through the deterministic constrained decoder (logit read + admissibility mask + manual token commit) instead of the engine's stochastic sampler. |
| `cotabbyConstrainedBeamWidth` | Int (default `1`) | Beam width when the constrained decoder is on. `1` is greedy; `>1` enables multi-branch search. |
| `cotabbyFillInMiddleEnabled` | Bool | Uses FIM prompting for genuine mid-line carets (text after the caret on the same line) on models that ship FIM markers. |

```bash
# Greedy constrained decode
defaults write com.jacobfu.tabby cotabbyConstrainedDecoderEnabled -bool YES

# Constrained decode with a 3-wide beam
defaults write com.jacobfu.tabby cotabbyConstrainedBeamWidth -int 3

# Mid-line fill-in-middle (only engages on a FIM-capable model, e.g. the Qwen tiers)
defaults write com.jacobfu.tabby cotabbyFillInMiddleEnabled -bool YES

# Back to the shipping sampler
defaults delete com.jacobfu.tabby cotabbyConstrainedDecoderEnabled
```

Run the app with `-cotabby-debug` so the on-disk JSONL sinks are populated (see
the main README / CLAUDE notes). All recipes below read those files.

## Reading the results

Every suggestion carries a `request_id` that joins the engine logs
(`llm-io.jsonl`) to the coordinator stage logs (`cotabby.jsonl`). The two signals
that matter for a quality call are **acceptance rate** and the
**suppression-reason breakdown**.

### Acceptance rate

A suggestion is *shown* when the coordinator logs `stage == "ready"`, and
*accepted* when it logs an `…-accepted-chunk` / `…-accepted-final-chunk` stage.
Approximate the rate by deduping on `request_id`:

```bash
L=~/Library/Logs/Cotabby/cotabby.jsonl
shown=$(jq -r 'select(.stage=="ready") | .request_id' "$L" | sort -u | wc -l)
accepted=$(jq -r 'select(.stage|test("accepted")) | .request_id' "$L" | sort -u | wc -l)
echo "accepted $accepted / shown $shown"
```

Compare a session with the flag on against one with it off. A decode change earns
the default only if acceptance does not regress.

### Why suggestions were suppressed

When ghost text comes back empty, `suppression_reason` says why — the join key
for telling "the model produced nothing usable" apart from "a filter dropped a
real completion":

```bash
jq -r 'select(.suppression_reason and .suppression_reason != "none") | .suppression_reason' \
  ~/Library/Logs/Cotabby/cotabby.jsonl | sort | uniq -c | sort -rn
```

- `emptyGeneration` / `normalizedToEmpty` dominating → the **model/decode** is
  producing nothing usable. Look at the prompt and the decode path, not the
  filters.
- `duplicatesTrailingText` / `echoesPrecedingText` / `unsafeToInsert` dominating
  → the model *is* producing text but a **filter** is dropping it. Decide whether
  the filter is too aggressive or the model genuinely needs the guard.

### Latency

The constrained/beam paths do more per token than the sampler. Confirm latency
stays acceptable before promoting, especially at beam width `> 1`:

```bash
jq 'select(.engine=="llama") | .latency_ms' ~/Library/Logs/Cotabby/llm-io.jsonl \
  | jq -s 'sort | {p50: .[length/2|floor], p95: .[length*95/100|floor], max: max}'
```

## Promotion checklist

Flip a flag's default (in `LlamaSuggestionEngine`) only when, on device:

1. Acceptance rate is at least on par with the shipping sampler.
2. The suppression breakdown is not dominated by `emptyGeneration` /
   `normalizedToEmpty` (the model is actually completing, not stalling).
3. p95 latency is within the typing-latency budget the app already targets.

Until then, the flags stay off and the shipping sampler is untouched.
