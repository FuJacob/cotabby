#!/usr/bin/env bash
# Cotabby cooperative prompt integration for bash.
# Live per-keystroke reporting requires Bash 4+ (`brew install bash` on macOS).

[[ $- == *i* ]] || return 0
[[ -n "${_cotabby_integration_loaded:-}" ]] && return 0
_cotabby_integration_loaded=1

_cotabby_socket_root="${TMPDIR:-/tmp}"
_cotabby_socket="${COTABBY_SOCKET_PATH:-${_cotabby_socket_root%/}/cotabby-terminal/cotabby.sock}"
_cotabby_nc=/usr/bin/nc
[[ -x "$_cotabby_nc" ]] || { printf '%s\n' '[cotabby] /usr/bin/nc unavailable; integration disabled' >&2; return 0; }

if [[ -n "${__CFBundleIdentifier:-}" ]]; then
    _cotabby_terminal_bundle_id="$__CFBundleIdentifier"
elif [[ "${TERM_PROGRAM:-}" == ghostty ]]; then _cotabby_terminal_bundle_id=com.mitchellh.ghostty
elif [[ "${TERM_PROGRAM:-}" == iTerm.app ]]; then _cotabby_terminal_bundle_id=com.googlecode.iterm2
elif [[ "${TERM_PROGRAM:-}" == Apple_Terminal ]]; then _cotabby_terminal_bundle_id=com.apple.Terminal
elif [[ "${TERM_PROGRAM:-}" == vscode ]]; then _cotabby_terminal_bundle_id=com.microsoft.VSCode
elif [[ "${TERM_PROGRAM:-}" == WezTerm ]]; then _cotabby_terminal_bundle_id=com.github.wez.wezterm
elif [[ "${TERM_PROGRAM:-}" == kitty ]]; then _cotabby_terminal_bundle_id=net.kovidgoyal.kitty
elif [[ "${TERM_PROGRAM:-}" == Alacritty ]]; then _cotabby_terminal_bundle_id=io.alacritty
elif [[ "${TERM_PROGRAM:-}" == Hyper ]]; then _cotabby_terminal_bundle_id=co.zeit.hyper
elif [[ "${TERM_PROGRAM:-}" == WarpTerminal ]]; then _cotabby_terminal_bundle_id=dev.warp.Warp-Stable
elif [[ "${TERM_PROGRAM:-}" == Rio ]]; then _cotabby_terminal_bundle_id=io.rio.terminal
else _cotabby_terminal_bundle_id=unknown
fi

_cotabby_session="$$-${RANDOM}-${SECONDS}"
_cotabby_tty="$(tty 2>/dev/null)"
[[ "$_cotabby_tty" == /dev/* ]] || { printf '%s\n' '[cotabby] no interactive tty; integration disabled' >&2; return 0; }
_cotabby_revision=0
_cotabby_last_state=''

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
    printf '%s\n' "$1" | "$_cotabby_nc" -U -w 1 "$_cotabby_socket" 2>/dev/null
}

_cotabby_report_buffer() {
    local line="${READLINE_LINE-}" point="${READLINE_POINT:-0}"
    local state="${line}"$'\x1f'"${point}"$'\x1f'"${PWD}"
    [[ "$state" == "$_cotabby_last_state" ]] && return 0
    _cotabby_last_state="$state"
    ((_cotabby_revision++))
    _cotabby_escape_json "$line"; local text="$REPLY"
    _cotabby_escape_json "$PWD"; local cwd="$REPLY"
    _cotabby_escape_json "$_cotabby_tty"; local tty="$REPLY"
    _cotabby_send "{\"type\":\"buffer\",\"text\":\"${text}\",\"cursor\":${point},\"shell\":\"bash\",\"terminal\":\"${_cotabby_terminal_bundle_id}\",\"pid\":$$,\"session\":\"${_cotabby_session}\",\"tty\":\"${tty}\",\"cwd\":\"${cwd}\",\"revision\":${_cotabby_revision}}"
}

_cotabby_report_disconnect() {
    _cotabby_send "{\"type\":\"disconnect\",\"pid\":$$,\"session\":\"${_cotabby_session}\"}"
}
trap _cotabby_report_disconnect EXIT

if [[ -n "${PROMPT_COMMAND:-}" ]]; then
    PROMPT_COMMAND="_cotabby_report_buffer;${PROMPT_COMMAND}"
else
    PROMPT_COMMAND=_cotabby_report_buffer
fi

if (( BASH_VERSINFO[0] < 4 )); then
    printf '%s\n' "[cotabby] bash ${BASH_VERSION} supports prompt heartbeats only; Bash 4+ is required for live typing" >&2
    return 0
fi

_cotabby_self_insert() {
    local value="$1"
    READLINE_LINE="${READLINE_LINE:0:READLINE_POINT}${value}${READLINE_LINE:READLINE_POINT}"
    ((READLINE_POINT += ${#value}))
    _cotabby_report_buffer
}

_cotabby_bind_printables() {
    local code value key
    for ((code=32; code<=126; code++)); do
        printf -v value "\\$(printf '%03o' "$code")"
        printf -v "_cotabby_char_${code}" '%s' "$value"
        key="$value"
        [[ "$value" == '"' ]] && key='\"'
        [[ "$value" == '\' ]] && key='\\'
        bind -x "\"${key}\":_cotabby_self_insert \"\$_cotabby_char_${code}\"" 2>/dev/null
    done
}
_cotabby_bind_printables
unset -f _cotabby_bind_printables

_cotabby_backspace() {
    if ((READLINE_POINT > 0)); then
        READLINE_LINE="${READLINE_LINE:0:READLINE_POINT-1}${READLINE_LINE:READLINE_POINT}"
        ((READLINE_POINT--))
    fi
    _cotabby_report_buffer
}
bind -x '"\C-h":_cotabby_backspace' 2>/dev/null
bind -x '"\C-?":_cotabby_backspace' 2>/dev/null

printf '%s\n' "[cotabby] shell integration loaded for ${_cotabby_terminal_bundle_id}" >&2
