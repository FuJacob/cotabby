# Cotabby

<img src="Cotabby/Assets.xcassets/CotabbyLogo.imageset/CotabbyLogo.png" alt="Cotabby cat icon" width="112" />

Local-first AI autocomplete for macOS. Open source, with Apple Intelligence, local GGUF models,
and an optional OpenAI-compatible endpoint you configure.

This repository is a development fork of [Cotabby](https://github.com/FuJacob/cotabby).
We are retiring the CoHamster branding and intend to contribute our changes upstream before
ending maintenance of the fork. That transition is in progress; this checkout still contains
changes that upstream has not accepted. No end-of-life date has been set.

**[Upstream Cotabby](https://github.com/FuJacob/cotabby)** · [Fork release archive](https://github.com/mc-hamster/CoHamster/releases) · [FAQ](FAQ.md) · [AGPLv3](LICENSE)

## Features

- **Ghost-text autocomplete** — AI suggestions inline in almost any macOS text field; `Tab` accepts a word at a time
- **Emoji autocomplete** — type `:rocket:` and accept it without leaving the field
- **Inline macros** — type `/` for quick math, unit and currency conversion, dates, and random values
- **One-key autocorrect** — fix a likely typo with a single keystroke

## Privacy

Privacy is the whole point, so Cotabby's default engines keep generation on your Mac:

- Apple Intelligence and Open Source generation run on-device.
- The optional OpenAI-compatible engine sends a bounded request only to the endpoint you configure;
  that endpoint can be loopback, on your local network, or a public HTTPS service.
- No analytics, no telemetry, no crash reporting.
- A normal install never writes what you type to disk.
- Apart from a configured endpoint, the network is used for model downloads and update checks, not
  suggestion generation.

## Engines

Cotabby generates suggestions in three ways. You choose which in Settings → Engine:

- **Apple Intelligence** — Apple's model, built into macOS 26 or later on supported Macs. Nothing to download.
- **Open Source** — a small AI model you download that runs entirely on your Mac. Works on any supported Mac (macOS 14+), with or without Apple Intelligence.
- **OpenAI-compatible** — a completion or chat endpoint you configure, including local Ollama,
  another LAN host, or a public HTTPS service. Endpoint credentials are stored in Keychain.

If your Mac supports Apple Intelligence, that's the easiest place to start. Otherwise, use the Open Source engine and pick one of the built-in models:

| Model          | Size    | Good for                          |
| -------------- | ------- | --------------------------------- |
| `Cotabby Nano` | ~0.8 GB | Older or low-memory Macs; fastest |
| `Cotabby Mini` | ~1.4 GB | A solid everyday balance          |
| `Cotabby Base` | ~4.5 GB | Higher-quality suggestions        |
| `Cotabby Pro`  | ~5.0 GB | Best quality                      |

Download any of them straight from Cotabby's menu bar.

<details>
<summary><strong>Advanced:</strong> model files, custom models, and how generation works</summary>

<br />

Under the hood, the Open Source engine runs local GGUF *base* models in-process through [llama.cpp](https://github.com/ggerganov/llama.cpp) (via [CotabbyInference](https://github.com/FuJacob/cotabbyinference)). Instead of prompting an instruction-tuned chat model, Cotabby treats the model as a pure text continuer and conditions it on your name, writing style, language, and on-screen context.

| Model          | File                             | Size    | Source                                                                       |
| -------------- | -------------------------------- | ------- | ---------------------------------------------------------------------------- |
| `Cotabby Nano` | `Qwen3.5-0.8B-Base.i1-Q6_K.gguf` | ~0.8 GB | [Hugging Face](https://huggingface.co/mradermacher/Qwen3.5-0.8B-Base-i1-GGUF) |
| `Cotabby Mini` | `Qwen3.5-2B-Base.i1-Q4_K_M.gguf` | ~1.4 GB | [Hugging Face](https://huggingface.co/mradermacher/Qwen3.5-2B-Base-i1-GGUF)   |
| `Cotabby Base` | `gemma-4-E2B.i1-Q6_K.gguf`       | ~4.5 GB | [Hugging Face](https://huggingface.co/mradermacher/gemma-4-E2B-i1-GGUF)       |
| `Cotabby Pro`  | `gemma-4-E4B.i1-Q4_K_M.gguf`     | ~5.0 GB | [Hugging Face](https://huggingface.co/mradermacher/gemma-4-E4B-i1-GGUF)       |

**Bring your own model.** Any GGUF small enough to run on-device works. Drop a `.gguf` file into Cotabby's models folder and refresh the model list from the menu bar. Browse the [unsloth GGUF collection](https://huggingface.co/unsloth) for more variants — smaller quants (`Q3_K_M`, `Q4_K_S`) trade quality for size; larger models give better completions at the cost of memory and per-token latency.

For the full suggestion pipeline, see [ARCHITECTURE.md](ARCHITECTURE.md).

</details>

## Install

**Compatibility:** macOS 14.0 or later. Apple Intelligence requires macOS 26 or later on a supported Mac.

For upstream downloads, visit [Cotabby](https://github.com/FuJacob/cotabby).
To run the changes in this development fork, follow [CONTRIBUTING.md](CONTRIBUTING.md).
Previously published fork binaries remain in the [release archive](https://github.com/mc-hamster/CoHamster/releases)
under their original names; this cleanup does not rename or replace those artifacts.

This fork still uses manual update checks against its own releases. Its bundle ID, preferences,
Keychain credentials, and model directory remain stable until an explicit upstream migration is ready.
Quit other copies before launching a development build.

## Permissions

Cotabby works inside other apps, so macOS asks for a few permissions. Each one maps to a specific feature, and Cotabby walks you through them on first launch:

- **Accessibility** — read the text and cursor position in the field you're typing in, and insert what you accept.
- **Input Monitoring** — notice your typing so it knows when to suggest, and detect the accept keys.
- **Screen Recording** *(optional)* — capture the area around your cursor for visual context. Leave it off and everything else still works.

Cotabby blocks generation, presentation, and insertion in password and other secure fields.

## Local Development

Requires Xcode and Command Line Tools. Apple Silicon is strongly recommended for local model performance. For setup, build, test, and contribution workflow details, start with [CONTRIBUTING.md](CONTRIBUTING.md).

For autocomplete tuning, the [phrase prediction benchmark](PHRASE_EVAL.md) replays 1,337 writing scenarios with synthetic screen context, reports next-word accuracy per phrase, category, and suite, and measures the gain or regression from that context.

```bash
git clone https://github.com/mc-hamster/CoHamster.git Cotabby
cd Cotabby
bundle install
bundle exec fastlane mac dev
```

If you want to understand the runtime and suggestion pipeline before contributing, read [ARCHITECTURE.md](ARCHITECTURE.md).

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, build, and PR guidelines, and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) for community expectations. For a tour of the runtime and suggestion pipeline, read [ARCHITECTURE.md](ARCHITECTURE.md).

### Contributing changes upstream

Our intended destination is [Cotabby](https://github.com/FuJacob/cotabby). We plan to contribute
fixes and features as focused, independently reviewable PRs, with tests and supporting benchmark
results. The native changes in `patches/cotabbyinference-upstream-pending.patch` also need review
in [CotabbyInference](https://github.com/FuJacob/cotabbyinference). Keep those changes and their
reproducible build inputs until upstream provides the required APIs.

Fork retirement will follow upstream review and a documented migration for existing users.
This repository remains the source for its published binaries and pending changes.

## Acknowledgments

- [llama.cpp](https://github.com/ggerganov/llama.cpp), [CotabbyInference](https://github.com/FuJacob/cotabbyinference), and [swift-log](https://github.com/apple/swift-log) for runtime and logging.
- Apple's FoundationModels, Accessibility, SwiftUI, and AppKit for on-device generation and macOS integration.
- [GitHub gemoji](https://github.com/github/gemoji) and Hugging Face for the emoji data and downloadable models.
- [SymSpell](https://github.com/wolfgarbe/SymSpell) by Wolf Garbe (MIT) for multilingual autocorrect; frequency dictionaries derive from [Google Ngrams](https://books.google.com/ngrams) (CC BY 3.0) and licensed SCOWL/Hunspell word lists.
- Everyone who filed issues, tested prereleases, and sent pull requests.

## Attribution

[Cotabby](https://github.com/FuJacob/cotabby) was originally created by
[FuJacob](https://github.com/FuJacob) and developed with [jam-cai](https://github.com/jam-cai),
[akramj13](https://github.com/akramj13), and other contributors. This development fork contains
changes by [McHamster](https://github.com/mc-hamster) and contributors. Its former CoHamster
branding and published versions remain recorded in [release notes](releases/). The app now uses
the original Cotabby artwork from upstream.

## License

Cotabby is licensed under the [GNU Affero General Public License v3.0](LICENSE). You can use, study, modify, and redistribute the app, but if you distribute a modified version or make one available to users over a network, you must provide the corresponding source code under the same license.

Third-party dependencies, emoji data, and downloadable model weights keep their own licenses and usage terms. Bundled third-party notices (SymSpell and the autocorrect frequency dictionary) are reproduced in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
