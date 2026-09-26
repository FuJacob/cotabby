# Cotabby — McHamster's Build 0.6.2.3

An independent experimental build of [Cotabby](https://github.com/FuJacob/cotabby), published from [McHamster's repository](https://github.com/mc-hamster/cotabby). This is not an official upstream release.

## Changes since McHamster 0.6.2.2

- **Continuous suggestions while typing.** Matching letters, spaces, and repeated acceptance advance through the existing prediction. Following words stay buffered behind a cautious word ending rather than being discarded and generated again.
- **Prepare what comes next.** On-device engines prepare following words while a local word completion or typo correction is offered. Correction continuations stay hidden until the editor publishes the exact accepted replacement. Configured endpoints retain their existing returned phrases without receiving these new hypothetical-edit requests.
- **Two typing preferences.** Settings → General → Suggestions now includes **Suggest while typing a word** and **Show following words**. Both default on. Turning off following words shows one word at a time while keeping the rest ready; full acceptance inserts only the visible offer.
- **Safer streaming and editing.** Incomplete hidden streamed words cannot become the next suggestion when Tab stops generation. Cached word endings prepare their continuation when restored after editing. Focus changes, dismissal, and changed text retire stale lookahead; matching Chromium AX token changes no longer discard valid correction sessions.
- **Codex desktop support.** A Codex-specific accessibility fallback enables its web tree and incrementally locates an explicitly focused editable field in the active window.

## Validation and limitations

The development build passed 323 targeted tests and four real-model replays using Qwen3.5-0.8B-Base Q6. Phrase and one-word replays each used one request across the word ending, a typed space, and two acceptances. The correction replay reused its prepared continuation after exact editor publication; divergent typing and dismissal rejected late output.

Those replays use the production coordinator and local model with synthetic editor boundaries. They do not measure live third-party Accessibility behavior or visual placement. The small model still produced awkward wording in one example; these results establish interaction continuity, not a new model-accuracy score.

## Installation and identity

- Apple Silicon, macOS 14 or later. Apple Intelligence requires compatible hardware and macOS 26 or later. No Intel build or model weights are included.
- Download **Cotabby-McHamster-0.6.2-mchamster.3-arm64.dmg** and drag **Cotabby McHamster.app** into Applications, replacing the previous McHamster build. Quit the app first.
- The app retains `org.mchamster.cotabby`, existing McHamster settings/model storage, and Developer ID team `8RN882MNR5`.
- Quit other Cotabby builds before enabling autocomplete. Upstream automatic updates remain disabled; **Check for Updates** opens this fork's releases.
- Original Cotabby authorship, licensing, and third-party acknowledgements are retained.

Tag: `mchamster-v0.6.2.3`. In-app version: `0.6.2-mchamster.3`. Build: `2026092401`.
