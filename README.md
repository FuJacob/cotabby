
<p align="center">
  <a href="https://cotabby.app" target="_blank">
    <img height="150" alt="Cotabby logo" src=".github/assets/readme/logo.png" />
  </a>
</p>

<h1 align="center">Cotabby [beta]</h1>

<p align="center"><em>Open-source, local AI autocomplete for macOS - an AI-native productivity layer for everything you type.</em></p>

<p align="center">
  <a href="https://cotabby.app">
  <img width="200" alt="landing-page" src="https://github.com/user-attachments/assets/c28fbb4b-6dfb-4403-a040-1df61daf4df2" /></a>
  

<a href="https://github.com/FuJacob/cotabby/releases/latest/download/Cotabby.dmg">
<img width="200" alt="download" src="https://github.com/user-attachments/assets/d5cb4454-d2ab-41d3-9d36-171d44ebfc52" />
</a></p>

<p align="center">
  <a href="https://github.com/FuJacob/cotabby/actions/workflows/build.yml"><img alt="Build" src="https://img.shields.io/github/actions/workflow/status/FuJacob/cotabby/build.yml?branch=main" /></a>
  <a href="LICENSE"><img alt="License: AGPL v3" src="https://img.shields.io/badge/license-AGPL--3.0-blue.svg" /></a>
  <a href="https://github.com/FuJacob/cotabby/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/FuJacob/cotabby" /></a>
  <a href="https://github.com/FuJacob/cotabby/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/FuJacob/cotabby/total" /></a>
  <a href="https://github.com/FuJacob/cotabby/stargazers"><img alt="Stars" src="https://img.shields.io/github/stars/FuJacob/cotabby?style=flat" /></a>
  <a href="https://github.com/FuJacob/cotabby/commits/main"><img alt="Last commit" src="https://img.shields.io/github/last-commit/FuJacob/cotabby" /></a>
  <img alt="Swift" src="https://img.shields.io/badge/Swift-F05138?logo=swift&amp;logoColor=white" />
  <img alt="Platform" src="https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey" />
  <img alt="Visitors" src="https://visitor-badge.laobi.icu/badge?page_id=FuJacob.tabby" />
</p>

<p align="center">
  <sub>Cotabby is free and open-source - maintained by two students. If it's useful to you, please consider supporting Cotabby's future.</sub>
</p>

<p align="center">
  <a href='https://ko-fi.com/I2F22066MI' target='_blank'><img height='36' style='border:0px;height:36px;' src='https://storage.ko-fi.com/cdn/kofi6.png?v=6' border='0' alt='Buy Me a Coffee at ko-fi.com' /></a>
</p>

---

## What It Does

Cotabby shows AI suggestions as ghost text in any macOS text field. Press `Tab` to accept, or keep typing to ignore.

It also does inline `:emoji:` autocomplete, `/` macros (math, unit and currency conversion, dates), and autocorrect that fixes typos with one keystroke.

Everything runs on-device. No hosted API, no cloud round-trip.

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

- **Ghost-text autocomplete** -- Inline AI suggestions in any macOS text field; `Tab` to accept
- **Emoji autocomplete** -- Type `:emoji:` and insert without leaving the field
- **Inline macros** -- `/` for math, unit and currency conversion, dates, and random values
- **Autocorrect** -- One-key fixes for likely typos
- **Two engines** -- Apple Intelligence or local models via llama.cpp
- **Personalize** -- Name, languages, length, and per-app control
- **100% local** -- Everything runs on-device
- **Visual context** -- Optional screenshot OCR for on-screen awareness

## Engines

**Apple Intelligence**: uses Apple's on-device `FoundationModels` runtime on macOS 26 or later, no download required.

**Open Source**: runs local GGUF *base* models in-process through llama.cpp via `CotabbyInference`. Rather than instructing an instruction-tuned model, Cotabby treats the model as a pure text continuer and conditions it on your persona, style, language, and on-screen context. Cotabby ships with four built-in downloadable models:

| Model          | File                             | Size    | Source                                                                                                  |
| -------------- | -------------------------------- | ------- | ------------------------------------------------------------------------------------------------------- |
| `tabby-2-nano` | `Qwen3.5-0.8B-Base.i1-Q6_K.gguf` | ~0.8 GB | [Link](https://huggingface.co/mradermacher/Qwen3.5-0.8B-Base-i1-GGUF) |
| `tabby-2-mini` | `Qwen3.5-2B-Base.i1-Q4_K_M.gguf` | ~1.4 GB | [Link](https://huggingface.co/mradermacher/Qwen3.5-2B-Base-i1-GGUF)     |
| `tabby-2-base` | `gemma-4-E2B.i1-Q6_K.gguf`       | ~4.5 GB | [Link](https://huggingface.co/mradermacher/gemma-4-E2B-i1-GGUF)             |
| `tabby-2-pro`  | `gemma-4-E4B.i1-Q4_K_M.gguf`     | ~5.0 GB | [Link](https://huggingface.co/mradermacher/gemma-4-E4B-i1-GGUF)             |

### Bring your own model

Any GGUF small enough to run on-device works. Drop a `.gguf` file into Cotabby's models folder and refresh the model list from the menu bar.

Browse the [unsloth GGUF collection on Hugging Face](https://huggingface.co/unsloth) for more variants. Smaller quants (`Q3_K_M`, `Q4_K_S`) trade quality for size; larger models give better completions at the cost of memory and per-token latency.

## Install

**Compatibility:** Requires macOS 14.0 or later. Apple Intelligence suggestions require macOS 26 or later; on earlier supported systems, use the Open Source engine.

### Homebrew

```sh
brew tap FuJacob/cotabby
brew install --cask cotabby
```

Upgrade later with `brew upgrade --cask cotabby`. The tap repo is [FuJacob/homebrew-cotabby](https://github.com/FuJacob/homebrew-cotabby).

### Manual download

Download and install the latest release from [cotabby.app](https://cotabby.app).

### Why those permissions?

- **Accessibility**: read the focused text field's value and caret position.
- **Input Monitoring**: detect global `Tab` presses, acceptance shortcuts, and inline emoji triggers.
- **Screen Recording**: capture a screenshot around the focused field for visual context (OCR).

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
- [SymSpell](https://github.com/wolfgarbe/SymSpell) by Wolf Garbe (MIT) for autocorrect; dictionary from [Google Ngrams](https://books.google.com/ngrams) (CC BY 3.0) and [SCOWL](http://wordlist.aspell.net/).
- Everyone who filed issues, tested prereleases, and sent pull requests.

## Created by

Originally created by <a href="https://github.com/FuJacob">@FuJacob</a>, now developed and maintained by <a href="https://github.com/FuJacob">@FuJacob</a> and <a href="https://github.com/jam-cai">@jam-cai</a>.

## License

Cotabby is licensed under the [GNU Affero General Public License v3.0](LICENSE). You can use, study, modify, and redistribute the app, but if you distribute a modified version or make one available to users over a network, you must provide the corresponding source code under the same license.

Third-party dependencies, emoji data, and downloadable model weights keep their own licenses and usage terms. Bundled third-party notices (SymSpell and the autocorrect frequency dictionary) are reproduced in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
