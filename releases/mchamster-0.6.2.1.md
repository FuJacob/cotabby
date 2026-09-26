# Cotabby — McHamster's Build 0.6.2.1

An independent, experimental McHamster build of [Cotabby](https://github.com/FuJacob/cotabby), based on upstream commit `ac2699e4ab40b68cf7429b7d13d5a7206c99dbbc` (after `v0.6.2-beta`). This is not an official upstream Cotabby release.

## What changed in this fork

- **Llama prompt-cache reuse:** restores a validated prompt prefix before another generation, including after cancellation; adds native cache checkpoints and diagnostics instead of permanently abandoning reuse after one failed trim.
- **Word continuation:** adds native token-prefix constraints and a Swift token-healing buffer so partially typed words can continue across token boundaries without replaying their already typed prefix.
- **Typing and acceptance:** refines active-tail reconciliation, cancellation ownership, and streamed suggestion presentation timing as the user keeps typing or accepts text.
- **Local visual context:** refreshes screenshot/OCR context while the same field remains focused, bounds and selects relevant excerpts, avoids secure fields, checks permission and focus changes, and clears stale context after failed captures. Screenshot/OCR processing remains local; the existing explicitly selected endpoint backend may receive bounded text context.
- **Prompt construction:** adjusts section budgets and the stable conditioning prefix to support cache reuse and cleaner continuations; improves output normalization.
- **Evaluation coverage:** adds typing-session scoring, a 1,337-case phrase-prediction fixture and runner, token-healing tests, visual-context tests, and native cache integration coverage. These are development tools, not a claim of measured quality or speed gains for every model.

The app changes originated in fork commits `fb47cb2` and `b345ced`. This release also includes the accompanying native-runtime changes as `patches/cotabbyinference-mchamster.patch`, applied to CotabbyInference commit `7574a21`. The release script builds this exact patched dependency rather than relying on a developer's adjacent checkout.

## Separate from upstream

- App: **Cotabby McHamster.app**; bundle identifier: `org.mchamster.cotabby`.
- Signed using **Jorge Miguel Casler's Developer ID**, Apple team `8RN882MNR5`.
- Separate preferences, Keychain service, macOS permission grants, downloaded models, and file logs. Existing upstream settings and models are not migrated automatically.
- Upstream Sparkle updates are disabled. **Check for Updates** opens this fork's GitHub releases; updates are installed manually.
- Feedback links point to this fork. Upstream's release workflow, update domain, and Homebrew publishing are guarded against use in the fork.
- Release tag: `mchamster-v0.6.2.1`; in-app version: `0.6.2-mchamster.1`.

## Installation

Apple Silicon Mac, macOS 14 or later. Apple Intelligence requires compatible hardware and macOS 26 or later; other engines retain their existing requirements. This asset does not include an Intel build or model weights.

Download the `Cotabby-McHamster-0.6.2-mchamster.1-arm64.dmg` asset, open it, and drag **Cotabby McHamster** into Applications. Grant Accessibility and Input Monitoring to this separately named app; grant Screen Recording only if using visual context. Quit the other Cotabby build before enabling this one: separate identities allow both to be installed, but both monitor typing and should not run autocomplete simultaneously.

Original authorship and license remain with Cotabby and its contributors; see the repository's LICENSE and acknowledgements. The upstream Homebrew cask installs upstream Cotabby, not this build.
