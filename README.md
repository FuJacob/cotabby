# Tabby

<p align="center">
  <img width="128" alt="Tabby logo" src="https://github.com/user-attachments/assets/8a67095e-4d03-4055-8d4c-8871335152dd" />
</p>

<p align="center">
  <em>On-device AI autocomplete for macOS text fields.</em>
</p>

<p align="center">
  <strong>1st Place — Ramp Emerging Talent 2026 AI Hackathon</strong>
</p>

## Demo

[Watch on YouTube](https://www.youtube.com/watch?v=p3TIgxQFQGE)

## What It Does

Tabby is a menu bar app that brings inline autocomplete to the text field you're already using. Keep typing in your host app — Tabby watches the focused field, generates a continuation, and renders it as ghost text next to your caret. Press `Tab` to accept a chunk, keep pressing to advance, or just keep typing to diverge.

Everything runs on-device. No hosted API, no cloud round-trip.

## Engines

**Apple Intelligence** — uses Apple's on-device `FoundationModels` runtime. No download required. Availability depends on your Mac; Tabby checks at runtime and tells you why if it's unavailable.

**Open Source** — runs local GGUF models in-process through llama.cpp via `llama.swift`. Built-in downloadable models:

| Model | File | Size |
|---|---|---|
| `tabby-fast-1` | `Qwen3-0.6B-Q4_K_M.gguf` | ~0.4 GB |
| `tabby-balanced-1` | `gemma-3-1b-it-Q4_K_M.gguf` | ~0.8 GB |
| `tabby-depth-1` | `gemma-3n-E4B-it-Q4_K_M.gguf` | ~3.5 GB |

You can also drop your own `.gguf` files into Tabby's models folder and hit Refresh. The Open Source engine supports a fast prefix-continuation mode and a "Use My Instructions" mode that folds your custom AI instructions into the prompt.

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
- Settings for launch at login, ghost text color, prompt mode, custom AI instructions, model downloads, and updates
- Activity indicators that can be hidden, anchored to the caret, or shown as a field-edge icon
- Accepted-word counter

**Requires macOS 26.0 or later.** Behavior depends on what each host app exposes through the Accessibility APIs — some fields only provide coarse caret geometry, so Tabby falls back to more conservative placement.

## How It Works

Tabby tracks the focused Accessibility element and resolves caret geometry with a layered strategy: exact bounds-for-range, text-marker fallback for browsers, nested `AXStaticText` geometry, and conservative full-frame estimation when that's all the app gives up.

A coordinator combines focus state, input events, settings, permissions, and runtime availability, then builds a request with a truncated prefix and your selected length preset. It routes to the active engine, normalizes the output into a short continuation, and renders ghost text near the caret.

On `Tab`, Tabby writes the accepted chunk back and keeps a live session with the full generation, how much was accepted, and what remains. That's why partial acceptance works — and why short-lived Accessibility lag in browser editors doesn't kill the suggestion.

> The codebase contains a screenshot/OCR visual-context subsystem, but it's deprecated for live autocomplete and Screen Recording is not required.

## Local Development

Requires Xcode and Command Line Tools. Apple Silicon is strongly recommended for local model performance.

```bash
git clone <repo>
open tabby.xcodeproj
```

Set your signing team in `Signing & Capabilities`, then build and run the `tabby` target. Or from the CLI:

```bash
xcodebuild -project tabby.xcodeproj -scheme tabby -configuration Debug build
```

On first launch, complete onboarding, grant permissions, pick an engine, and (if Open Source) download or drop in a GGUF.

## License

Tabby is licensed under the [GNU Affero General Public License v3.0](LICENSE). The AGPL's network-use clause means any modified version made available to users over a network must also be source-available under the same terms.
