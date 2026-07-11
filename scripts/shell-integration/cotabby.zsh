#!/usr/bin/env zsh
# Cotabby cooperative prompt integration for zsh.
# Source this file from .zshrc after enabling Terminal Autocomplete in Cotabby.

[[ -o interactive ]] || return 0
[[ -n "${_cotabby_integration_loaded:-}" ]] && return 0
_cotabby_integration_loaded=1

_cotabby_socket_root="${TMPDIR:-/tmp}"
_cotabby_socket="${COTABBY_SOCKET_PATH:-${_cotabby_socket_root%/}/cotabby-terminal/cotabby.sock}"
_cotabby_nc=/usr/bin/nc
[[ -x "$_cotabby_nc" ]] || { print -u2 "[cotabby] /usr/bin/nc is unavailable; integration disabled"; return 0; }

if [[ -n "${__CFBundleIdentifier:-}" ]]; then
    _cotabby_terminal_bundle_id="$__CFBundleIdentifier"
elif [[ "${TERM_PROGRAM:-}" == ghostty ]]; then
    _cotabby_terminal_bundle_id=com.mitchellh.ghostty
elif [[ "${TERM_PROGRAM:-}" == iTerm.app ]]; then
    _cotabby_terminal_bundle_id=com.googlecode.iterm2
elif [[ "${TERM_PROGRAM:-}" == Apple_Terminal ]]; then
    _cotabby_terminal_bundle_id=com.apple.Terminal
elif [[ "${TERM_PROGRAM:-}" == vscode ]]; then
    _cotabby_terminal_bundle_id=com.microsoft.VSCode
elif [[ "${TERM_PROGRAM:-}" == WezTerm ]]; then
    _cotabby_terminal_bundle_id=com.github.wez.wezterm
elif [[ "${TERM_PROGRAM:-}" == kitty ]]; then
    _cotabby_terminal_bundle_id=net.kovidgoyal.kitty
elif [[ "${TERM_PROGRAM:-}" == Alacritty ]]; then
    _cotabby_terminal_bundle_id=io.alacritty
elif [[ "${TERM_PROGRAM:-}" == Hyper ]]; then
    _cotabby_terminal_bundle_id=co.zeit.hyper
elif [[ "${TERM_PROGRAM:-}" == WarpTerminal ]]; then
    _cotabby_terminal_bundle_id=dev.warp.Warp-Stable
elif [[ "${TERM_PROGRAM:-}" == Rio ]]; then
    _cotabby_terminal_bundle_id=io.rio.terminal
else
    _cotabby_terminal_bundle_id=unknown
fi

_cotabby_session="$$-${RANDOM}-${SECONDS}"
_cotabby_tty="$(tty 2>/dev/null)"
[[ "$_cotabby_tty" == /dev/* ]] || { print -u2 "[cotabby] no interactive tty; integration disabled"; return 0; }
typeset -gi _cotabby_revision=0
typeset -g _cotabby_last_state=""

_cotabby_escape_json() {
    REPLY="$1"
    REPLY="${REPLY//\\/\\\\}"
    REPLY="${REPLY//\"/\\\"}"
    REPLY="${REPLY//$'\n'/\\n}"
    REPLY="${REPLY//$'\t'/\\t}"
    REPLY="${REPLY//$'\r'/\\r}"
}

_cotabby_send() {
    [[ -S "$_cotabby_socket" ]] || return 0
    print -r -- "$1" | "$_cotabby_nc" -U -w 1 "$_cotabby_socket" 2>/dev/null
}

_cotabby_report_buffer() {
    local state="${BUFFER}\x1f${CURSOR}\x1f${PWD}"
    [[ "$state" == "$_cotabby_last_state" ]] && return 0
    _cotabby_last_state="$state"
    ((_cotabby_revision++))
    _cotabby_escape_json "$BUFFER"; local text="$REPLY"
    _cotabby_escape_json "$PWD"; local cwd="$REPLY"
    _cotabby_escape_json "$_cotabby_tty"; local tty="$REPLY"
    _cotabby_send "{\"type\":\"buffer\",\"text\":\"${text}\",\"cursor\":${CURSOR:-0},\"shell\":\"zsh\",\"terminal\":\"${_cotabby_terminal_bundle_id}\",\"pid\":$$,\"session\":\"${_cotabby_session}\",\"tty\":\"${tty}\",\"cwd\":\"${cwd}\",\"revision\":${_cotabby_revision}}"
}

_cotabby_report_disconnect() {
    _cotabby_send "{\"type\":\"disconnect\",\"pid\":$$,\"session\":\"${_cotabby_session}\"}"
}

# `line-pre-redraw` observes every editor change without replacing the user's ZLE widgets or
# keybindings. That compatibility boundary is why the hook requires the modern macOS zsh.
autoload -Uz add-zle-hook-widget 2>/dev/null
if (( $+functions[add-zle-hook-widget] )); then
    add-zle-hook-widget line-pre-redraw _cotabby_report_buffer
    add-zle-hook-widget line-init _cotabby_report_buffer
else
    print -u2 "[cotabby] zsh line-pre-redraw hooks are unavailable; integration disabled"
    return 0
fi

autoload -Uz add-zsh-hook 2>/dev/null
if (( $+functions[add-zsh-hook] )); then
    add-zsh-hook precmd _cotabby_report_buffer
    add-zsh-hook zshexit _cotabby_report_disconnect
fi

print -u2 "[cotabby] shell integration loaded for ${_cotabby_terminal_bundle_id}"
