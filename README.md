# Cotabby

<sub>If Cotabby is useful to you, consider supporting development:</sub>

<a href='https://ko-fi.com/I2F22066MI' target='_blank'><img height='36' style='border:0px;height:36px;' src='https://storage.ko-fi.com/cdn/kofi6.png?v=6' border='0' alt='Buy Me a Coffee at ko-fi.com' /></a>

---

<p align="center">
  <img width="128" alt="Cotabby logo" src="https://github.com/user-attachments/assets/8a67095e-4d03-4055-8d4c-8871335152dd" />
</p>

<p align="center">
  <em>Open-source, local-first AI autocomplete for macOS. [beta]</em>
  </p>
  
<p align="center">
  <a href="https://cotabby.app"><strong>Visit the landing page →</strong></a>
</p>

<p align="center">
  <a href="LICENSE"><img alt="License: AGPL v3" src="https://img.shields.io/badge/license-AGPL--3.0-blue.svg" /></a>
  <a href="https://github.com/FuJacob/tabby/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/FuJacob/tabby" /></a>
  <a href="https://github.com/FuJacob/tabby/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/FuJacob/tabby/total" /></a>
  <a href="https://github.com/FuJacob/tabby/stargazers"><img alt="Stars" src="https://img.shields.io/github/stars/FuJacob/tabby?style=flat" /></a>
  <img alt="Platform" src="https://img.shields.io/badge/platform-macOS%2015%2B-lightgrey" />
  <img alt="Visitors" src="https://visitor-badge.laobi.icu/badge?page_id=FuJacob.tabby" />
</p>

---

## What It Does

Cotabby is a menu bar app that brings inline autocomplete to the text field you're already using. Keep typing in your host app: Cotabby watches the focused field, generates a continuation, and renders it as ghost text next to your caret. Press `Tab` to accept a chunk, keep pressing to advance, or just keep typing to diverge.

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
- **100% local** -- All inference runs on-device. No data ever leaves your Mac
- **Visual context** -- Screenshot OCR gives the model awareness of what's on screen
- **Low latency** -- Optimized for fast response on Apple Silicon

## Engines

**Apple Intelligence**: uses Apple's on-device `FoundationModels` runtime on macOS 26 or later, no download required.

**Open Source**: runs local GGUF models in-process through llama.cpp via `llama.swift`. Built-in downloadable models suggested for use:

| Model                | File                          | Size    |
| -------------------- | ----------------------------- | ------- |
| `cotabby-swift-1`     | `Qwen3-0.6B-Q4_K_M.gguf`     | ~0.4 GB |
| `cotabby-swift-pro-1` | `Qwen3.5-0.8B-Q4_K_M.gguf`   | ~0.5 GB |
| `cotabby-balanced-1`  | `gemma-3-1b-it-Q4_K_M.gguf`  | ~0.8 GB |
| `cotabby-careful-1`   | `gemma-4-E2B-it-Q4_K_M.gguf` | ~3.1 GB |

You can also drop your own `.gguf` files into Cotabby's models folder and refresh the model list.

## Install

1. Download the latest `Cotabby.dmg` from GitHub Releases.
2. Drag `Cotabby.app` into `Applications` and launch it.
3. Grant **Accessibility**, **Input Monitoring**, and **Screen Recording** when prompted.
4. Pick an engine. Apple Intelligence if available, otherwise Open Source plus a model.
5. Start typing in any supported editable field.

If macOS blocks first launch, right-click `Cotabby.app` → `Open`, or allow it in `System Settings → Privacy & Security`.

### Why those permissions?

- **Accessibility**: read the focused text field's value and caret position.
- **Input Monitoring**: detect global `Tab` presses for acceptance.
- **Screen Recording**: capture a screenshot around the focused field for visual context (OCR).

**Requires macOS 15.0 or later.** Apple Intelligence suggestions require macOS 26 or later; on earlier supported systems, use the Open Source engine.

## Local Development

Requires Xcode and Command Line Tools. Apple Silicon is strongly recommended for local model performance. For setup, build, test, and contribution workflow details, start with [CONTRIBUTING.md](CONTRIBUTING.md).

```bash
git clone https://github.com/FuJacob/tabby.git Cotabby
cd Cotabby
open Cotabby.xcodeproj
```

If you want to understand the runtime and suggestion pipeline before contributing, read [ARCHITECTURE.md](ARCHITECTURE.md).

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, build, and PR guidelines, and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) for community expectations. For a tour of the runtime and suggestion pipeline, read [ARCHITECTURE.md](ARCHITECTURE.md).

## Acknowledgments

- [llama.cpp](https://github.com/ggerganov/llama.cpp): local GGUF inference engine that powers the Open Source models
- [llama.swift](https://github.com/mattt/llama.swift): Swift package wrapping llama.cpp for in-process inference
- [Sparkle](https://github.com/sparkle-project/Sparkle): in-app update framework
- Apple's [FoundationModels](https://developer.apple.com/documentation/foundationmodels) framework: on-device Apple Intelligence runtime
- Apple's Accessibility (AX) APIs: focused-field discovery and caret geometry
- The [Qwen](https://github.com/QwenLM) and [Gemma](https://ai.google.dev/gemma) model teams for the open-weight models Cotabby ships with
- The Hugging Face community for hosting and distributing GGUF model weights
- Swift, SwiftUI, and AppKit, which together make the menu bar app, overlays, and settings UI possible
- Everyone who has filed issues, tested prereleases, and contributed pull requests

## Built by

<a href="https://github.com/FuJacob">@FuJacob</a> and <a href="https://github.com/jam-cai">@jam-cai</a>

## License

Cotabby is licensed under the [GNU Affero General Public License v3.0](LICENSE). The AGPL's network-use clause means any modified version made available to users over a network must also be source-available under the same terms.
