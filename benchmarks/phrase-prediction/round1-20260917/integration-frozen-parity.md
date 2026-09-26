# Frozen vs integration pointwise parity

Compared 29,748 matched word-boundary observations across two configuration pairs and two context conditions; 0 have a difference in the recorded fields below. Latency is excluded.

Before comparison, verified complete error-free reports, 1,337 unique phrases and 7,437 checkpoints per condition, exact phrase/checkpoint identities, paired word mode, three workers, seed 12,648,430, corpus/model hashes, matching effective sampler settings, full selection, and observation-to-suite totals. The existing paired analyzer supplies identity validation.

| Pair / context | Checkpoints | Any field difference | Prompt / excerpt | Raw / shown | Visibility / predicted word | Correct / suppression | Integration gains / losses |
|---|---:|---:|---:|---:|---:|---:|---:|
| baseline / none | 7,437 | 0 | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |
| baseline / screen | 7,437 | 0 | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |
| candidate / none | 7,437 | 0 | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |
| candidate / screen | 7,437 | 0 | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |

Checkpoint fields and optional field presence are also compared exactly; their counts are retained in the JSON. Missing and null optional fields are distinguished. No reference phrases, prompts, excerpts, or generated text are exported.

Both baselines use repetition penalty 1.05; both candidates use 1.025. All use temperature 0.1, top-k 20, top-p 0.7, min-p 0.08, and the same model. Integration runs obtain sampler defaults from their source configuration; frozen runs use explicit CLI overrides. The only recorded configuration metadata difference within each matched pair is the integration harness’s `wordPolicy` description. Source and product fingerprints differ and are retained in the JSON.

Equal aggregate scores alone were not used to infer parity. These results apply only to the compared fields, corpus, model, and seed; they do not establish general equivalence of current-main and frozen policies or live behavior. Timing and interactive focus/debounce/overlay are outside this comparison.

| Configuration / context | Frozen correct | Integration correct | Checkpoints |
|---|---:|---:|---:|
| baseline / none | 2,120 | 2,120 | 7,437 |
| baseline / screen | 2,586 | 2,586 | 7,437 |
| candidate / none | 2,322 | 2,322 | 7,437 |
| candidate / screen | 2,813 | 2,813 | 7,437 |

Model SHA-256: `febd85051361ccb34d0925744c819f9ae0724117e8f946a2852dd0edfa90a5a1`. Corpus SHA-256: `b41c8089a58ae1e0ee84b95ac9283cf71db4e713e25bd8fed47220be69d8b0f6`.

Full local report/manifest paths, hashes, build identities, sampler metadata, condition/category counts, and analyzer hash: [integration-frozen-parity.json](integration-frozen-parity.json).
