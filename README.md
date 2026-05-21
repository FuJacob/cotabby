# tabby

<p align="center">
  <img width="128" alt="tabby logo" src="https://github.com/user-attachments/assets/8a67095e-4d03-4055-8d4c-8871335152dd" />
</p>

<p align="center">
  <em>On-device AI autocomplete for macOS text fields.</em>
</p>

<p align="center">
  <a href="https://tabbyapp.dev"><strong>Visit the landing page →</strong></a>
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

## Demo

<p align="center">
  <a href="https://www.youtube.com/watch?v=p3TIgxQFQGE"><strong>Watch on YouTube →</strong></a>
</p>

<table align="center" width="100%">
  <tr>
    <td align="center" valign="top" width="50%">
      <img src=".github/assets/readme/demo-email.png" alt="tabby autocomplete in Email" width="100%" />
      <br />
      <sub><b>Email</b></sub>
    </td>
    <td align="center" valign="top" width="50%">
      <img src=".github/assets/readme/demo-slack.png" alt="tabby autocomplete in Slack" width="100%" />
      <br />
      <sub><b>Slack</b></sub>
    </td>
  </tr>
  <tr>
    <td align="center" valign="top" width="50%">
      <img src=".github/assets/readme/demo-notes.png" alt="tabby autocomplete in Notes" width="100%" />
      <br />
      <sub><b>Notes</b></sub>
    </td>
    <td align="center" valign="top" width="50%">
      <img src=".github/assets/readme/demo-imessage.png" alt="tabby autocomplete in iMessage" width="100%" />
      <br />
      <sub><b>iMessage</b></sub>
    </td>
  </tr>
</table>

## What It Does

tabby is a menu bar app that brings inline autocomplete to the text field you're already using. Keep typing in your host app: tabby watches the focused field, generates a continuation, and renders it as ghost text next to your caret. Press `Tab` to accept a chunk, keep pressing to advance, or just keep typing to diverge.

Everything runs on-device. No hosted API, no cloud round-trip.

## Features

- **System-wide completions** -- Works in any macOS text field (Safari, Notes, Mail, etc.)
- **Ghost text UI** -- Suggestions appear as translucent overlay text at your cursor
- **100% local** -- All inference runs on-device. No data ever leaves your Mac
- **Visual context** -- Screenshot OCR gives the model awareness of what's on screen
- **Low latency** -- Optimized for fast response on Apple Silicon

## Engines

**Apple Intelligence [BETA]**: uses Apple's on-device `FoundationModels` runtime on macOS 26 or later. No download required. Availability depends on your Mac; tabby checks at runtime and explains when this engine is unavailable. Apple Intelligence support is currently in beta and may not perform as well as the Open Source models. We're actively working on improving it.

**Open Source**: runs local GGUF models in-process through llama.cpp via `llama.swift`. Built-in downloadable models:

| Model              | File                            | Size    |
| ------------------ | ------------------------------- | ------- |
| `tabby-fast-1`     | `Qwen3-0.6B-Q4_K_M.gguf`       | ~0.4 GB |
| `tabby-balanced-1` | `gemma-3-1b-it-Q4_K_M.gguf`    | ~0.8 GB |

You can also drop your own `.gguf` files into tabby's models folder and refresh the model list.

## Install

1. Download the latest `tabby.dmg` from GitHub Releases.
2. Drag `tabby.app` into `Applications` and launch it.
3. Grant **Accessibility**, **Input Monitoring**, and **Screen Recording** when prompted.
4. Pick an engine. Apple Intelligence if available, otherwise Open Source plus a model.
5. Start typing in any supported editable field.

If macOS blocks first launch, right-click `tabby.app` → `Open`, or allow it in `System Settings → Privacy & Security`.

### Why those permissions?

- **Accessibility**: read the focused text field's value and caret position.
- **Input Monitoring**: detect global `Tab` presses for acceptance.
- **Screen Recording**: capture a screenshot around the focused field for visual context (OCR).

**Requires macOS 15.0 or later.** Apple Intelligence suggestions require macOS 26 or later; on earlier supported systems, use the Open Source engine.

## Local Development

Requires Xcode and Command Line Tools. Apple Silicon is strongly recommended for local model performance. For setup, build, test, and contribution workflow details, start with [CONTRIBUTING.md](CONTRIBUTING.md).

```bash
git clone https://github.com/FuJacob/tabby.git
cd tabby
open tabby.xcodeproj
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
- The [Qwen](https://github.com/QwenLM) and [Gemma](https://ai.google.dev/gemma) model teams for the open-weight models Tabby ships with
- The Hugging Face community for hosting and distributing GGUF model weights
- Swift, SwiftUI, and AppKit, which together make the menu bar app, overlays, and settings UI possible
- Everyone who has filed issues, tested prereleases, and contributed pull requests

## Built by

<a href="https://github.com/FuJacob">@FuJacob</a> and <a href="https://github.com/jam-cai">@jam-cai</a>

## License

tabby is licensed under the [GNU Affero General Public License v3.0](LICENSE). The AGPL's network-use clause means any modified version made available to users over a network must also be source-available under the same terms.
