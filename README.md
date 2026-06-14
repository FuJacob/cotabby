
<p align="center">
  <a href="https://cotabby.app" target="_blank">
    <img height="150" alt="Cotabby logo" src=".github/assets/readme/logo.png" />
  </a>
</p>

<h1 align="center">Cotabby [beta]</h1>

<p align="center"><em>Open-source, on-device AI autocomplete for macOS.</em></p>

<p align="center">
  <a href="https://cotabby.app">
  <img width="200" alt="landing-page" src="https://github.com/user-attachments/assets/c28fbb4b-6dfb-4403-a040-1df61daf4df2" /></a>
  

<a href="https://github.com/FuJacob/cotabby/releases/latest/download/Cotabby.dmg">
<img width="200" alt="download" src="https://github.com/user-attachments/assets/d5cb4454-d2ab-41d3-9d36-171d44ebfc52" /></a>


<a href="https://ko-fi.com/cotabby" target="_blank">
<img width="200" alt="support" src=".github/assets/readme/support-cotabby.png" />
</a></p>

<p align="center">
  <a href="https://github.com/FuJacob/cotabby/actions/workflows/build.yml"><img alt="Build" src="https://img.shields.io/github/actions/workflow/status/FuJacob/cotabby/build.yml?branch=main" /></a>
  <a href="LICENSE"><img alt="License: AGPL v3" src="https://img.shields.io/badge/license-AGPL--3.0-blue.svg" /></a>
  <a href="https://github.com/FuJacob/cotabby/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/FuJacob/cotabby" /></a>
  <a href="https://github.com/FuJacob/cotabby/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/FuJacob/cotabby/total" /></a>
  <a href="https://github.com/FuJacob/cotabby/stargazers"><img alt="Stars" src="https://img.shields.io/github/stars/FuJacob/cotabby?style=flat" /></a>
  <img alt="Swift" src="https://img.shields.io/badge/Swift-F05138?logo=swift&amp;logoColor=white" />
  <img alt="Platform" src="https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey" />
</p>

<p align="center">
  <sub>Cotabby is free and open-source — maintained by two students. If it's useful to you, please consider supporting Cotabby's future.</sub>
</p>

---

## What It Does

Cotabby adds AI autocomplete to almost any text field on your Mac. As you type, a gray suggestion appears inline next to your cursor. Press `Tab` to accept it a word at a time, or keep typing to ignore it.

Everything runs on your Mac. No account, no cloud, no telemetry.

## Demo

<p align="center">
  <a href="https://www.youtube.com/watch?v=p3TIgxQFQGE"><strong>Watch on YouTube →</strong></a>
</p>

<div align="center">

|  |  |
|:---:|:---:|
| <img src="gifs/slack.gif" alt="Cotabby emoji autocomplete demo" width="400" height="225" /> | <img src="gifs/imessage.gif" alt="Cotabby autocomplete demo" width="400" height="225" /> |
| <img src="gifs/autocorrect.gif" alt="Cotabby autocorrect demo" width="400" height="225" /> | <img src="gifs/macros.gif" alt="Cotabby inline macros demo" width="400" height="225" /> |

</div>

## Features

- **Ghost-text autocomplete** — AI suggestions inline in almost any macOS text field; `Tab` accepts a word at a time
- **Emoji autocomplete** — type `:rocket:` and accept it without leaving the field
- **Inline macros** — type `/` for quick math, unit and currency conversion, dates, and random values
- **One-key autocorrect** — fix a likely typo with a single keystroke

## Privacy

Privacy is the whole point — everything that produces a suggestion happens on your Mac:

- All AI runs on-device. There's no hosted API and no cloud round-trip.
- No analytics, no telemetry, no crash reporting.
- A normal install never writes what you type to disk.
- The network is used only to download a model you pick and to check for updates — never to send your text, your screen, or your suggestions anywhere.

## Engines

Cotabby generates suggestions one of two ways. You choose which in Settings → Engine:

- **Apple Intelligence** — Apple's model, built into macOS 26 or later on supported Macs. Nothing to download.
- **Open Source** — a small AI model you download that runs entirely on your Mac. Works on any supported Mac (macOS 14+), with or without Apple Intelligence.

If your Mac supports Apple Intelligence, that's the easiest place to start. Otherwise, use the Open Source engine and pick one of the built-in models:

| Model          | Size    | Good for                          |
| -------------- | ------- | --------------------------------- |
| `tabby-2-nano` | ~0.8 GB | Older or low-memory Macs; fastest |
| `tabby-2-mini` | ~1.4 GB | A solid everyday balance          |
| `tabby-2-base` | ~4.5 GB | Higher-quality suggestions        |
| `tabby-2-pro`  | ~5.0 GB | Best quality                      |

Download any of them straight from Cotabby's menu bar.

<details>
<summary><strong>Advanced:</strong> model files, custom models, and how generation works</summary>

<br />

Under the hood, the Open Source engine runs local GGUF *base* models in-process through [llama.cpp](https://github.com/ggerganov/llama.cpp) (via [CotabbyInference](https://github.com/FuJacob/cotabbyinference)). Instead of prompting an instruction-tuned chat model, Cotabby treats the model as a pure text continuer and conditions it on your name, writing style, language, and on-screen context.

| Model          | File                             | Size    | Source                                                                       |
| -------------- | -------------------------------- | ------- | ---------------------------------------------------------------------------- |
| `tabby-2-nano` | `Qwen3.5-0.8B-Base.i1-Q6_K.gguf` | ~0.8 GB | [Hugging Face](https://huggingface.co/mradermacher/Qwen3.5-0.8B-Base-i1-GGUF) |
| `tabby-2-mini` | `Qwen3.5-2B-Base.i1-Q4_K_M.gguf` | ~1.4 GB | [Hugging Face](https://huggingface.co/mradermacher/Qwen3.5-2B-Base-i1-GGUF)   |
| `tabby-2-base` | `gemma-4-E2B.i1-Q6_K.gguf`       | ~4.5 GB | [Hugging Face](https://huggingface.co/mradermacher/gemma-4-E2B-i1-GGUF)       |
| `tabby-2-pro`  | `gemma-4-E4B.i1-Q4_K_M.gguf`     | ~5.0 GB | [Hugging Face](https://huggingface.co/mradermacher/gemma-4-E4B-i1-GGUF)       |

**Bring your own model.** Any GGUF small enough to run on-device works. Drop a `.gguf` file into Cotabby's models folder and refresh the model list from the menu bar. Browse the [unsloth GGUF collection](https://huggingface.co/unsloth) for more variants — smaller quants (`Q3_K_M`, `Q4_K_S`) trade quality for size; larger models give better completions at the cost of memory and per-token latency.

For the full suggestion pipeline, see [ARCHITECTURE.md](ARCHITECTURE.md).

</details>

## Install

**Compatibility:** macOS 14.0 or later. The Apple Intelligence engine needs macOS 26 or later on a supported Mac; on older systems, use the Open Source engine.

### Homebrew

```sh
brew tap FuJacob/cotabby
brew install --cask cotabby
```

Upgrade later with `brew upgrade --cask cotabby`. The tap lives at [FuJacob/homebrew-cotabby](https://github.com/FuJacob/homebrew-cotabby).

### Manual download

Grab the latest release from [cotabby.app](https://cotabby.app) and drag Cotabby into your Applications folder.

## Using Cotabby

Start typing in almost any text field. When a gray suggestion appears:

- **`Tab`** — accept the next word. (Prefer whole phrases? Switch this in Settings → Acceptance Mode.)
- **`` ` `` (backtick)** — accept the entire suggestion at once.
- **`Esc`**, or just keep typing — dismiss it.

Every shortcut is rebindable under Settings → Shortcuts.

## Permissions

Cotabby works inside other apps, so macOS asks for a few permissions. Each one maps to a specific feature, and Cotabby walks you through them on first launch:

- **Accessibility** — read the text and cursor position in the field you're typing in, and insert what you accept.
- **Input Monitoring** — notice your typing so it knows when to suggest, and detect the accept keys.
- **Screen Recording** *(optional)* — capture the area around your cursor for visual context. Leave it off and everything else still works.

Cotabby never reads password or other secure fields.

## Local Development

Requires Xcode and Command Line Tools. Apple Silicon is strongly recommended for local model performance. For setup, build, test, and contribution workflow details, start with [CONTRIBUTING.md](CONTRIBUTING.md).

```bash
git clone https://github.com/FuJacob/cotabby.git Cotabby
cd Cotabby
open Cotabby.xcodeproj
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

## Created by

Originally created by <a href="https://github.com/FuJacob">@FuJacob</a>, now developed and maintained by <a href="https://github.com/FuJacob">@FuJacob</a>, <a href="https://github.com/jam-cai">@jam-cai</a>. and <a href="https://github.com/akramj13">@akramj13</a>

## License

Cotabby is licensed under the [GNU Affero General Public License v3.0](LICENSE). You can use, study, modify, and redistribute the app, but if you distribute a modified version or make one available to users over a network, you must provide the corresponding source code under the same license.

Third-party dependencies, emoji data, and downloadable model weights keep their own licenses and usage terms. Bundled third-party notices (SymSpell and the autocorrect frequency dictionary) are reproduced in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
