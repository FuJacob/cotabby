# Tabby

<p align="center">
  <img width="128" alt="Tabby logo" src="https://github.com/user-attachments/assets/8a67095e-4d03-4055-8d4c-8871335152dd" />
</p>

<p align="center">
  <em>On-device AI autocomplete for macOS text fields.</em>
</p>

## Demo

<p align="center">
  <a href="https://www.youtube.com/watch?v=p3TIgxQFQGE">Watch on YouTube</a>
</p>

<div align="center">

<table>
  <tr>
    <td align="center" width="420">
      <img width="840" alt="Tabby in Email" src="https://github.com/user-attachments/assets/ff89bed1-176e-422b-844f-a46c27b63585" />
      <br />
      <sub>Email</sub>
    </td>
    <td align="center" width="420">
      <img width="840" alt="Tabby in Slack" src="https://github.com/user-attachments/assets/66ae00c6-34a0-4383-beb0-4b0713c9f1bc" />
      <br />
      <sub>Slack</sub>
    </td>
  </tr>
  <tr>
    <td align="center" width="420">
      <img width="840" alt="Tabby in Notes" src="https://github.com/user-attachments/assets/7e60e91f-9d9d-4a98-8810-23b74dfc9657" />
      <br />
      <sub>Notes</sub>
    </td>
    <td align="center" width="420">
      <img width="840" alt="Tabby in iMessage" src="https://github.com/user-attachments/assets/acaa3679-bffc-4fbb-8262-72b651a77f54" />
      <br />
      <sub>iMessage</sub>
    </td>
  </tr>
</table>

</div>

## What It Does

Tabby is a menu bar app that brings inline autocomplete to the text field you're already using. Keep typing in your host app — Tabby watches the focused field, generates a continuation, and renders it as ghost text next to your caret. Press `Tab` to accept a chunk, keep pressing to advance, or just keep typing to diverge.

Everything runs on-device. No hosted API, no cloud round-trip.

## Engines

**Apple Intelligence** — uses Apple's on-device `FoundationModels` runtime. No download required. Availability depends on your Mac; Tabby checks at runtime and explains when this engine is unavailable.

**Open Source** — runs local GGUF models in-process through llama.cpp via `llama.swift`. Built-in downloadable models:

| Model | File | Size |
|---|---|---|
| `tabby-fast-1` | `Qwen3-0.6B-Q4_K_M.gguf` | ~0.4 GB |
| `tabby-balanced-1` | `gemma-3-1b-it-Q4_K_M.gguf` | ~0.8 GB |
| `tabby-depth-1` | `gemma-3n-E4B-it-Q4_K_M.gguf` | ~3.5 GB |

You can also drop your own `.gguf` files into Tabby's models folder and refresh the model list.

## Install

1. Download the latest `Tabby.dmg` from GitHub Releases.
2. Drag `Tabby.app` into `Applications` and launch it.
3. Grant **Accessibility** and **Input Monitoring** when prompted.
4. Pick an engine — Apple Intelligence if available, otherwise Open Source + a model.
5. Start typing in any supported editable field.

If macOS blocks first launch, right-click `Tabby.app` → `Open`, or allow it in `System Settings → Privacy & Security`.

### Why those permissions?

- **Accessibility** — read the focused text field's value and caret position.
- **Input Monitoring** — detect global `Tab` presses for acceptance.

## Features

- Ghost text rendered live next to your caret
- Partial `Tab` acceptance — take a chunk, keep the tail alive, press again to continue
- Menu bar quick controls: enable, engine, model, indicator mode, completion length
- Settings for launch at login, ghost text color, model downloads, and updates
- Activity indicators that can be hidden, anchored to the caret, or shown as a field-edge icon
- Accepted-word counter

**Requires macOS 26.0 or later.** Behavior depends on what each host app exposes through the Accessibility APIs — some fields only provide coarse caret geometry, so Tabby falls back to more conservative placement.

## Local Development

Requires Xcode and Command Line Tools. Apple Silicon is strongly recommended for local model performance. For setup, build, test, and contribution workflow details, start with [CONTRIBUTING.md](CONTRIBUTING.md).

```bash
git clone https://github.com/FuJacob/tabby.git
cd tabby
open tabby.xcodeproj
```

If you want to understand the runtime and suggestion pipeline before contributing, read [ARCHITECTURE.md](ARCHITECTURE.md).

## License

Tabby is licensed under the [GNU Affero General Public License v3.0](LICENSE). The AGPL's network-use clause means any modified version made available to users over a network must also be source-available under the same terms.
