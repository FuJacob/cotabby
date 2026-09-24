# CoHamster

<img src="Cotabby/Assets.xcassets/CoHamsterLogo.imageset/CoHamsterLogo.png" alt="CoHamster hamster icon" width="112" />

Local-first AI autocomplete for macOS. Open source, with Apple Intelligence, local GGUF models,
and an optional OpenAI-compatible endpoint you configure.

**[Download CoHamster for Apple Silicon](https://github.com/mc-hamster/CoHamster/releases/download/cohamster-v0.6.3/CoHamster-0.6.3-arm64.dmg)** · [Release notes](https://github.com/mc-hamster/CoHamster/releases/tag/cohamster-v0.6.3) · [FAQ](FAQ.md) · [AGPLv3](LICENSE)

## Features

- **Ghost-text autocomplete** — AI suggestions inline in almost any macOS text field; `Tab` accepts a word at a time
- **Emoji autocomplete** — type `:rocket:` and accept it without leaving the field
- **Inline macros** — type `/` for quick math, unit and currency conversion, dates, and random values
- **One-key autocorrect** — fix a likely typo with a single keystroke

## Privacy

Privacy is the whole point, so CoHamster's default engines keep generation on your Mac:

- Apple Intelligence and Open Source generation run on-device.
- The optional OpenAI-compatible engine sends a bounded request only to the endpoint you configure;
  that endpoint can be loopback, on your local network, or a public HTTPS service.
- No analytics, no telemetry, no crash reporting.
- A normal install never writes what you type to disk.
- Apart from a configured endpoint, the network is used for model downloads and update checks, not
  suggestion generation.

## Engines

CoHamster generates suggestions in three ways. You choose which in Settings → Engine:

- **Apple Intelligence** — Apple's model, built into macOS 26 or later on supported Macs. Nothing to download.
- **Open Source** — a small AI model you download that runs entirely on your Mac. Works on any supported Mac (macOS 14+), with or without Apple Intelligence.
- **OpenAI-compatible** — a completion or chat endpoint you configure, including local Ollama,
  another LAN host, or a public HTTPS service. Endpoint credentials are stored in Keychain.

If your Mac supports Apple Intelligence, that's the easiest place to start. Otherwise, use the Open Source engine and pick one of the built-in models:

| Model          | Size    | Good for                          |
| -------------- | ------- | --------------------------------- |
| `CoHamster Nano` | ~0.8 GB | Older or low-memory Macs; fastest |
| `CoHamster Mini` | ~1.4 GB | A solid everyday balance          |
| `CoHamster Base` | ~4.5 GB | Higher-quality suggestions        |
| `CoHamster Pro`  | ~5.0 GB | Best quality                      |

Download any of them straight from CoHamster's menu bar.

<details>
<summary><strong>Advanced:</strong> model files, custom models, and how generation works</summary>

<br />

Under the hood, the Open Source engine runs local GGUF *base* models in-process through [llama.cpp](https://github.com/ggerganov/llama.cpp) (via [CotabbyInference](https://github.com/FuJacob/cotabbyinference)). Instead of prompting an instruction-tuned chat model, CoHamster treats the model as a pure text continuer and conditions it on your name, writing style, language, and on-screen context.

| Model          | File                             | Size    | Source                                                                       |
| -------------- | -------------------------------- | ------- | ---------------------------------------------------------------------------- |
| `CoHamster Nano` | `Qwen3.5-0.8B-Base.i1-Q6_K.gguf` | ~0.8 GB | [Hugging Face](https://huggingface.co/mradermacher/Qwen3.5-0.8B-Base-i1-GGUF) |
| `CoHamster Mini` | `Qwen3.5-2B-Base.i1-Q4_K_M.gguf` | ~1.4 GB | [Hugging Face](https://huggingface.co/mradermacher/Qwen3.5-2B-Base-i1-GGUF)   |
| `CoHamster Base` | `gemma-4-E2B.i1-Q6_K.gguf`       | ~4.5 GB | [Hugging Face](https://huggingface.co/mradermacher/gemma-4-E2B-i1-GGUF)       |
| `CoHamster Pro`  | `gemma-4-E4B.i1-Q4_K_M.gguf`     | ~5.0 GB | [Hugging Face](https://huggingface.co/mradermacher/gemma-4-E4B-i1-GGUF)       |

**Bring your own model.** Any GGUF small enough to run on-device works. Drop a `.gguf` file into CoHamster's models folder and refresh the model list from the menu bar. Browse the [unsloth GGUF collection](https://huggingface.co/unsloth) for more variants — smaller quants (`Q3_K_M`, `Q4_K_S`) trade quality for size; larger models give better completions at the cost of memory and per-token latency.

For the full suggestion pipeline, see [ARCHITECTURE.md](ARCHITECTURE.md).

</details>

## Install

**Compatibility:** macOS 14.0 or later. Apple Intelligence requires macOS 26 or later on a supported Mac.

Download the [signed and notarized CoHamster 0.6.3 prerelease](https://github.com/mc-hamster/CoHamster/releases/tag/cohamster-v0.6.3),
open the DMG, and drag **CoHamster.app** into Applications. Quit any older copy before opening it.
The matching source and checksums are included on the release page. To build from source, follow
the development instructions below.

Check for new releases in Settings → About. CoHamster currently uses manual updates.

## Permissions

CoHamster works inside other apps, so macOS asks for a few permissions. Each one maps to a specific feature, and CoHamster walks you through them on first launch:

- **Accessibility** — read the text and cursor position in the field you're typing in, and insert what you accept.
- **Input Monitoring** — notice your typing so it knows when to suggest, and detect the accept keys.
- **Screen Recording** *(optional)* — capture the area around your cursor for visual context. Leave it off and everything else still works.

CoHamster blocks generation, presentation, and insertion in password and other secure fields.

## Local Development

Requires Xcode and Command Line Tools. Apple Silicon is strongly recommended for local model performance. For setup, build, test, and contribution workflow details, start with [CONTRIBUTING.md](CONTRIBUTING.md).

For autocomplete tuning, the [phrase prediction benchmark](PHRASE_EVAL.md) replays 1,337 writing scenarios with synthetic screen context, reports next-word accuracy per phrase, category, and suite, and measures the gain or regression from that context.

```bash
git clone https://github.com/mc-hamster/CoHamster.git CoHamster
cd CoHamster
scripts/prepare_cohamster_workspace.sh
open build/cohamster-dependencies/CoHamster.xcworkspace
```

If you want to understand the runtime and suggestion pipeline before contributing, read [ARCHITECTURE.md](ARCHITECTURE.md).

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, build, and PR guidelines, and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) for community expectations. For a tour of the runtime and suggestion pipeline, read [ARCHITECTURE.md](ARCHITECTURE.md).

## Acknowledgments

- [llama.cpp](https://github.com/ggerganov/llama.cpp), [CotabbyInference](https://github.com/FuJacob/cotabbyinference), [Sparkle](https://github.com/sparkle-project/Sparkle), and [swift-log](https://github.com/apple/swift-log) for runtime, updates, and logging.
- Apple's FoundationModels, Accessibility, SwiftUI, and AppKit for on-device generation and macOS integration.
- [GitHub gemoji](https://github.com/github/gemoji) and Hugging Face for the emoji data and downloadable models.
- [SymSpell](https://github.com/wolfgarbe/SymSpell) by Wolf Garbe (MIT) for multilingual autocorrect; frequency dictionaries derive from [Google Ngrams](https://books.google.com/ngrams) (CC BY 3.0) and licensed SCOWL/Hunspell word lists.
- Everyone who filed issues, tested prereleases, and sent pull requests.

## Attribution

CoHamster is an independent fork of [Cotabby](https://github.com/FuJacob/cotabby), originally
created by [FuJacob](https://github.com/FuJacob) and developed with [jam-cai](https://github.com/jam-cai),
[akramj13](https://github.com/akramj13), and other contributors. CoHamster is maintained by
[McHamster](https://github.com/mc-hamster). The CoHamster rebranding began September 24, 2026;
earlier fork changes are recorded in [release notes](releases/).

## License

CoHamster is licensed under the [GNU Affero General Public License v3.0](LICENSE). You can use, study, modify, and redistribute the app, but if you distribute a modified version or make one available to users over a network, you must provide the corresponding source code under the same license.

Third-party dependencies, emoji data, and downloadable model weights keep their own licenses and usage terms. Bundled third-party notices (SymSpell and the autocorrect frequency dictionary) are reproduced in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
