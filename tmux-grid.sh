#!/usr/bin/env bash
# Attach to the shared 'claude' tmux session, creating it as a 2x2 equal grid on first use.
# Installed in the image as /usr/local/bin/sandbox-tmux and used by EVERY entry point — the
# browser (ttyd) and the local terminal (shell.sh --attach / shell.ps1 -Attach) — so the grid
# is identical no matter how you connect, on macOS, Linux, and Windows.
#   TTYD_GRID=2x2 (default) -> four tiled panes; TTYD_GRID=1 -> single pane.
set -u
S=claude
if ! tmux has-session -t "$S" 2>/dev/null; then
    tmux new-session -d -s "$S"
    if [ "${TTYD_GRID:-2x2}" = "2x2" ]; then
        tmux split-window -t "$S"; tmux split-window -t "$S"; tmux split-window -t "$S"
        tmux select-layout -t "$S" tiled
        tmux select-pane  -t "$S:.0"
    fi
fi
# Always re-apply the config (mouse on, clipboard, key bindings) — self-healing, so a server that
# was started by some path which didn't auto-source ~/.tmux.conf still ends up correct on attach.
[ -f "$HOME/.tmux.conf" ] && tmux source-file "$HOME/.tmux.conf" 2>/dev/null
exec tmux attach-session -t "$S"
