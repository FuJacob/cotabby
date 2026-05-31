<p align="center">
  <a href="https://cotabby.app" target="_blank">
    <img height="150" alt="Cotabby logo" src="https://github.com/user-attachments/assets/1e223e72-770c-417b-82e5-83f18cd5a3b2" />
  </a>
</p>

<h1 align="center">Cotabby [beta]</h1>

<p align="center"><em>Open-source, local-first AI autocomplete for macOS, with inline <code>:emoji:</code> suggestions.</em></p>

<p align="center">
  <a href="https://cotabby.app"><strong>Visit the landing page →</strong></a>
</p>

<p align="center">
  <a href="LICENSE"><img alt="License: AGPL v3" src="https://img.shields.io/badge/license-AGPL--3.0-blue.svg" /></a>
  <a href="https://github.com/FuJacob/cotabby/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/FuJacob/cotabby" /></a>
  <a href="https://github.com/FuJacob/cotabby/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/FuJacob/cotabby/total" /></a>
  <a href="https://github.com/FuJacob/cotabby/stargazers"><img alt="Stars" src="https://img.shields.io/github/stars/FuJacob/cotabby?style=flat" /></a>
  <img alt="Platform" src="https://img.shields.io/badge/platform-macOS%2015%2B-lightgrey" />
  <img alt="Visitors" src="https://visitor-badge.laobi.icu/badge?page_id=FuJacob.tabby" />
</p>

<p align="center">
  <sub>Cotabby is free and open source. If it's useful to you, please consider supporting development</sub>
</p>

<p align="center">
  <a href='https://ko-fi.com/I2F22066MI' target='_blank'><img height='36' style='border:0px;height:36px;' src='https://storage.ko-fi.com/cdn/kofi6.png?v=6' border='0' alt='Buy Me a Coffee at ko-fi.com' /></a>
</p>

---

## What It Does

Cotabby brings AI autocomplete to the text fields you already use on macOS. It works system-wide, stays out of your way, and shows suggestions as ghost text beside your cursor. Press `Tab` to accept a word, keep pressing to take more, or keep typing to ignore it.

It also includes inline emoji autocomplete: type `:smile`, `:tada`, or `:+1` and pick the emoji without leaving your current app.

Everything runs on-device. No hosted API, no cloud round-trip.

## Demo

<p align="center">
  <a href="https://www.youtube.com/watch?v=p3TIgxQFQGE"><strong>Watch on YouTube →</strong></a>
</p>

<table align="center" width="100%">
  <tr>
    <td align="center" valign="top" width="50%">
      <img src=".github/assets/readme/demo-email.png" alt="Cotabby autocomplete in Email" width="100%" />
      <br />
      <sub><b>Email</b></sub>
    </td>
    <td align="center" valign="top" width="50%">
      <img src="https://github.com/user-attachments/assets/05c04d09-e658-478b-b10e-25c6a0d1b4ee" alt="Cotabby autocomplete in Slack" width="100%" />
      <br />
      <sub><b>Slack</b></sub>
    </td>
  </tr>
  <tr>
    <td align="center" valign="top" width="50%">
      <img src="https://github.com/user-attachments/assets/7d16957f-e2bd-487a-9910-757286b445ea" alt="Cotabby autocomplete in Notes" width="100%" />
      <br />
      <sub><b>Notes</b></sub>
    </td>
    <td align="center" valign="top" width="50%">
      <img src="https://github.com/user-attachments/assets/407ccd42-b0fb-414d-9bd2-9ce05119777e" alt="Cotabby autocomplete in iMessage" width="100%" />
      <br />
      <sub><b>iMessage</b></sub>
    </td>
  </tr>
</table>

## Features

- **System-wide completions** -- Works in any macOS text field (Safari, Notes, Mail, etc.)
- **Ghost text UI** -- Suggestions appear as translucent overlay text at your cursor
- **Inline emoji autocomplete** -- Type `:emoji:`-style shortcuts and insert the selected emoji without leaving your current app
- **100% local** -- AI inference and emoji matching run on-device
- **Visual context** -- Screenshot OCR gives the model awareness of what's on screen
- **Low latency** -- Optimized for fast response on Apple Silicon

## Engines

**Apple Intelligence**: uses Apple's on-device `FoundationModels` runtime on macOS 26 or later, no download required.

**Open Source**: runs local GGUF models in-process through llama.cpp via `CotabbyInference`. Cotabby ships with four built-in downloadable models:

| Model          | File                              | Size    | Source                                                                                                  |
| -------------- | --------------------------------- | ------- | ------------------------------------------------------------------------------------------------------- |
| `tabby-1-nano` | `SmolLM2-135M-Instruct-q8_0.gguf` | ~0.1 GB | [Mungert/SmolLM2-135M-Instruct-GGUF](https://huggingface.co/Mungert/SmolLM2-135M-Instruct-GGUF)         |
| `tabby-1-mini` | `Qwen3-0.6B-Q4_K_M.gguf`          | ~0.4 GB | [unsloth/Qwen3-0.6B-GGUF](https://huggingface.co/unsloth/Qwen3-0.6B-GGUF)                               |
| `tabby-1-base` | `gemma-4-E2B-it-Q4_K_M.gguf`      | ~3.1 GB | [unsloth/gemma-4-E2B-it-GGUF](https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF)                       |
| `tabby-1-pro`  | `gemma-4-E4B-it-Q4_K_M.gguf`      | ~5.0 GB | [unsloth/gemma-4-E4B-it-GGUF](https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF)                       |

### Bring your own model

Any GGUF small enough to run on-device works. Drop a `.gguf` file into Cotabby's models folder and refresh the model list from the menu bar.

Browse the [unsloth GGUF collection on Hugging Face](https://huggingface.co/unsloth) for more variants. Smaller quants (`Q3_K_M`, `Q4_K_S`) trade quality for size; larger models give better completions at the cost of memory and per-token latency.

## Install

**Compatibility:** Requires macOS 15.0 or later. Apple Intelligence suggestions require macOS 26 or later; on earlier supported systems, use the Open Source engine.

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

- [llama.cpp](https://github.com/ggerganov/llama.cpp), [CotabbyInference](https://github.com/FuJacob/cotabbyinference), [Sparkle](https://github.com/sparkle-project/Sparkle), and [swift-log](https://github.com/apple/swift-log) for the core runtime, update, and logging infrastructure.
- Apple's FoundationModels, Accessibility APIs, SwiftUI, and AppKit for the on-device generation and macOS integration layers.
- [GitHub gemoji](https://github.com/github/gemoji), Hugging Face, and the model teams listed above for the emoji data and downloadable model ecosystem.
- Everyone who has filed issues, tested prereleases, and contributed pull requests.

## Created by

Originally created by <a href="https://github.com/FuJacob">@FuJacob</a>, now developed and maintained by <a href="https://github.com/FuJacob">@FuJacob</a> and <a href="https://github.com/jam-cai">@jam-cai</a>.

## License

Cotabby is licensed under the [GNU Affero General Public License v3.0](LICENSE). You can use, study, modify, and redistribute the app, but if you distribute a modified version or make one available to users over a network, you must provide the corresponding source code under the same license.

Third-party dependencies, emoji data, and downloadable model weights keep their own licenses and usage terms.
