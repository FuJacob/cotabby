# Cotabby — McHamster's Build 0.6.2.2

An independent experimental build of [Cotabby](https://github.com/FuJacob/cotabby), published from [McHamster's master branch](https://github.com/mc-hamster/cotabby/tree/master). This is not an official upstream release.

## Changes since McHamster 0.6.2.1

- **Finish words without fighting spell-check.** Unfinished words can reach the completion engine; typo suppression and correction wait for a committed word boundary. Final unusable model output can fall back to an exact-prefix ending from local dictionaries, document vocabulary, or the existing glossary, without another model request.
- **More stable ghost text.** Presentation checks the assembled word at the caret, caches spelling decisions per word, and rejects late partials after a generation finishes. A short bounded delay follows typing cadence while a word is unfinished.
- **Respect dismissals.** Escape temporarily remembers a dismissed continuation for the same field and nearby text, reducing repeated suggestions. This memory is bounded, expires, and is not persisted.
- **Compact context and adjusted sampling.** Surface context uses compact format/app/domain/title/field labels, and the default repetition penalty changes from 1.05 to 1.025. Existing context scope and backend selection remain unchanged.
- **Dictionary and metrics improvements.** Dictionary language selection remains available when typo correction is disabled, and recovered word completions are counted consistently in quality metrics.
- **Expanded evaluation tools and evidence.** Includes contextual phrase scenarios, three-worker evaluation, baseline reports, experiment and completion-prefix analysis scripts, and the completed September 17 experiment reports with reproduction instructions. Adds regression tests for caret-word boundaries, local prefix matching, streaming, dismissal memory, timing, and context formatting.
- **Release packaging.** Each DMG now includes its own version's release notes instead of always copying the first McHamster release notes.

## Evaluation context

The checked-in experiment report compares a controlled baseline with the selected compact-context/sampling configuration using Qwen3.5-0.8B-Base Q6 and a synthetic English corpus. Its integration comparison reports exact next-word accuracy of **34.772% → 37.824% with screen context** and **28.506% → 31.222% without screen context**. These are configuration comparisons on that benchmark, not a measurement of overall release-to-release writing quality or a guarantee for other models, languages, or apps. See the [full results and limitations](https://github.com/mc-hamster/cotabby/blob/mchamster-v0.6.2.2/benchmarks/phrase-prediction/round1-20260917/summary.md).

## Installation and identity

- Apple Silicon, macOS 14 or later. Apple Intelligence requires compatible hardware and macOS 26 or later. No Intel build or model weights are included.
- Download **Cotabby-McHamster-0.6.2-mchamster.2-arm64.dmg** and drag **Cotabby McHamster.app** into Applications, replacing the previous McHamster build. Quit the app first.
- The app keeps `org.mchamster.cotabby`, your McHamster settings/model storage, and Jorge Miguel Casler's Developer ID team `8RN882MNR5`.
- Upstream Cotabby remains a separate installation. Quit the other build before enabling autocomplete. Upstream Sparkle updates remain disabled; **Check for Updates** opens this fork's releases.
- Screenshot/OCR processing and the new dictionary fallback remain local. The existing explicitly selected endpoint backend can receive bounded text context; this release adds no new hosted transmission.
- Original Cotabby authorship, licensing, and third-party acknowledgements are retained.

Tag: `mchamster-v0.6.2.2`. In-app version: `0.6.2-mchamster.2`. Build: `2026091702`.
