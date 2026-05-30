#!/usr/bin/env bash
# Open a local terminal INSIDE the running sandbox — same isolation as the browser
# (egress proxy, /workspace scope, subscription login). Just run `claude` once you're in.
#
#   ./shell.sh            # a fresh shell in /workspace
#   ./shell.sh --attach   # attach to the SAME tmux session the browser tab shows (shared screen)
set -euo pipefail
cd "$(dirname "$0")"

if ! docker compose ps --status running --format '{{.Name}}' 2>/dev/null | grep -q .; then
    echo "Sandbox isn't running. Start it first:  ./run.sh"; exit 1
fi

if [ "${1:-}" = "--attach" ]; then
    exec docker compose exec -u node claude-sandbox tmux new-session -A -s claude
fi
exec docker compose exec -u node -w /workspace claude-sandbox bash -l
