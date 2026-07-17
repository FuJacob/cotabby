# Cotabby cooperative prompt integration for fish.
# Source from ~/.config/fish/conf.d/cotabby.fish after enabling the feature.

status is-interactive; or return 0
set -q _cotabby_integration_loaded; and return 0
set -g _cotabby_integration_loaded 1

set -g _cotabby_socket "$COTABBY_SOCKET_PATH"
set -l _cotabby_socket_root "$TMPDIR"
test -n "$_cotabby_socket_root"; or set _cotabby_socket_root /tmp
test -n "$_cotabby_socket"; or set -g _cotabby_socket (string trim -r -c / -- $_cotabby_socket_root)/cotabby-terminal/cotabby.sock
set -g _cotabby_nc /usr/bin/nc
test -x $_cotabby_nc; or begin; echo '[cotabby] /usr/bin/nc unavailable; integration disabled' >&2; return 0; end

if set -q __CFBundleIdentifier
    set -g _cotabby_terminal_bundle_id "$__CFBundleIdentifier"
else if test "$TERM_PROGRAM" = ghostty
    set -g _cotabby_terminal_bundle_id com.mitchellh.ghostty
else if test "$TERM_PROGRAM" = iTerm.app
    set -g _cotabby_terminal_bundle_id com.googlecode.iterm2
else if test "$TERM_PROGRAM" = Apple_Terminal
    set -g _cotabby_terminal_bundle_id com.apple.Terminal
else if test "$TERM_PROGRAM" = vscode
    set -g _cotabby_terminal_bundle_id com.microsoft.VSCode
else if test "$TERM_PROGRAM" = WezTerm
    set -g _cotabby_terminal_bundle_id com.github.wez.wezterm
else if test "$TERM_PROGRAM" = kitty
    set -g _cotabby_terminal_bundle_id net.kovidgoyal.kitty
else if test "$TERM_PROGRAM" = Alacritty
    set -g _cotabby_terminal_bundle_id io.alacritty
else if test "$TERM_PROGRAM" = Hyper
    set -g _cotabby_terminal_bundle_id co.zeit.hyper
else if test "$TERM_PROGRAM" = WarpTerminal
    set -g _cotabby_terminal_bundle_id dev.warp.Warp-Stable
else if test "$TERM_PROGRAM" = Rio
    set -g _cotabby_terminal_bundle_id io.rio.terminal
else
    set -g _cotabby_terminal_bundle_id unknown
end

set -g _cotabby_session "$fish_pid-"(random)"-"$CMD_DURATION
set -g _cotabby_tty (tty 2>/dev/null)
string match -q '/dev/*' -- $_cotabby_tty; or begin; echo '[cotabby] no interactive tty; integration disabled' >&2; return 0; end
set -g _cotabby_revision 0
set -g _cotabby_last_state ''

function _cotabby_escape_json
    string escape --style=json -- $argv[1] | string replace -r '^"|"$' ''
end

function _cotabby_send
    test -S $_cotabby_socket; or return 0
    printf '%s\n' $argv[1] | $_cotabby_nc -U -w 1 $_cotabby_socket 2>/dev/null
end

function _cotabby_report_buffer
    set -l text (commandline)
    set -l cursor (commandline -C)
    set -l state "$text\x1f$cursor\x1f$PWD"
    test "$state" = "$_cotabby_last_state"; and return 0
    set -g _cotabby_last_state "$state"
    set -g _cotabby_revision (math $_cotabby_revision + 1)
    set -l escaped_text (_cotabby_escape_json "$text")
    set -l escaped_tty (_cotabby_escape_json "$_cotabby_tty")
    set -l escaped_cwd (_cotabby_escape_json "$PWD")
    _cotabby_send "{\"type\":\"buffer\",\"text\":\"$escaped_text\",\"cursor\":$cursor,\"shell\":\"fish\",\"terminal\":\"$_cotabby_terminal_bundle_id\",\"pid\":$fish_pid,\"session\":\"$_cotabby_session\",\"tty\":\"$escaped_tty\",\"cwd\":\"$escaped_cwd\",\"revision\":$_cotabby_revision}"
end

function _cotabby_report_disconnect --on-event fish_exit
    _cotabby_send "{\"type\":\"disconnect\",\"pid\":$fish_pid,\"session\":\"$_cotabby_session\"}"
end

# Fish has no generic post-self-insert hook. The opt-in integration wraps printable keys and the
# most common editing key; users relying heavily on custom bind/abbr behavior should prefer zsh.
for _cotabby_code in (seq 32 126)
    set -l _cotabby_char (printf '%b' (printf '\\%03o' $_cotabby_code))
    set -l _cotabby_escaped (string escape -- $_cotabby_char)
    bind --silent -- $_cotabby_char "commandline -i -- $_cotabby_escaped" _cotabby_report_buffer 2>/dev/null
end
set -e _cotabby_code

function _cotabby_backspace
    commandline -f backward-delete-char
    _cotabby_report_buffer
end
bind --silent \b _cotabby_backspace 2>/dev/null
bind --silent \ch _cotabby_backspace 2>/dev/null

function _cotabby_prompt_report --on-event fish_prompt
    _cotabby_report_buffer
end

echo "[cotabby] shell integration loaded for $_cotabby_terminal_bundle_id" >&2
