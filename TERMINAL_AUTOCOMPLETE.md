# Terminal Autocomplete (Beta)

Cotabby can provide inline autocomplete in dedicated terminal apps and integrated terminal panes.
It is off by default because terminal output is not a normal editable text field and must never be
treated as one without a trustworthy input source.

## Enable and set up

1. Open **Settings → Apps** and enable **Terminal Autocomplete (Beta)**.
2. Grant Screen Recording if prompted. Cotabby uses it to locate the visible shell prompt and to
   read Claude Code's input box; screenshots and recognized text stay on the Mac.
3. Copy the zsh, Bash, or fish command shown in Settings into that shell's startup file.
4. Open a new terminal window.

Settings generates paths for the exact app build being used. This matters during development:
Cotabby and Cotabby Dev use different sockets and installed hook directories, so they can run
side-by-side without unlinking or impersonating each other's endpoint.

zsh is recommended. It uses `line-pre-redraw` and does not replace normal key bindings. Bash 4+
and fish do not expose an equivalent generic redraw hook, so their beta hooks wrap printable-key
bindings and may conflict with custom Readline/fish bindings. The stock Bash included with macOS
only provides prompt heartbeats; install Bash 4 or newer for live per-keystroke suggestions.

## How it works

Shell prompts and terminal TUIs use separate source adapters:

- **zsh, Bash, and fish:** a sourced hook sends the exact line-editor buffer, cursor, shell, TTY,
  working directory, session nonce, and monotonic revision over a local Unix-domain socket. OCR
  matches that exact buffer to the visible prompt once, then cursor movement is tracked from the
  hook's character offset until the anchor expires or the prompt moves.
- **Claude Code:** the shell no longer owns stdin, so Cotabby checks the frontmost terminal title
  and process tree, captures only the active terminal window or integrated pane, and runs Apple's
  Vision OCR locally. A Claude Code screen fingerprint and a prompt line must both be present before
  the OCR text becomes autocomplete focus.

Both sources feed the existing suggestion coordinator. The normal accept shortcuts still apply;
there is no separate terminal-only shortcut. Accepted terminal text is inserted through paste so
bracketed-paste-aware shells and TUIs receive literal text.

At an end-of-line shell prompt, a short imperative English instruction such as
`delete folder named dork` enters command-replacement mode. Cotabby shows the complete translated
command as a replacement offer; accepting deletes the unchanged English line and pastes the command.
It never presses Return, so commands—including destructive ones—remain visible for review and only
run after the user explicitly submits them. Real shell syntax, paths, flags, pipes, and redirects
remain on the normal continuation path.

## Security and privacy boundaries

- The socket lives under the current user's private temporary directory so its endpoint stays below
  macOS's Unix-socket path limit. Its directory is mode `0700`, the socket is mode `0600`, and peer
  user IDs are checked before any frame is decoded. Installed hook copies remain in Application
  Support.
- Existing non-socket paths, sockets owned by another user, and live endpoints owned by another
  Cotabby process are never removed. Only a same-user, non-listening stale socket is replaced.
- Frames are newline-delimited JSON capped at 64 KiB. Shell PIDs must belong to the current user;
  bundle IDs, TTY paths, nonces, revisions, cursor offsets, and text sizes are validated.
- The IPC/OCR subsystem does not write terminal data to disk or make network requests. Like normal
  autocomplete text, the result flows to the engine selected in Cotabby; choosing a remote
  OpenAI-compatible endpoint therefore carries the same privacy tradeoff as it does in other apps.
- Enabling the preference is only a master switch. Cotabby still refuses terminal autocomplete
  unless a live hook snapshot or a currently verified Claude Code OCR snapshot owns focus.

## Current limitations

- Screen Recording is required for trustworthy prompt positioning and for Claude Code OCR.
- Claude Code OCR is best-effort and intentionally fail-closed. If the UI fingerprint, prompt line,
  frontmost app, or window geometry changes during OCR, Cotabby hides the terminal suggestion.
- Multiplexer panes and heavily customized prompt themes can make OCR anchoring less reliable.
- Bash/fish custom key bindings may need manual adjustment; zsh is the compatibility-first path.
