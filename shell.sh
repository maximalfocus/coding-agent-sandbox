#!/usr/bin/env bash
# Open Herdr in a local terminal with the same sandbox isolation as the browser.
#
#   ./shell.sh            # attach another Herdr client to its persistent session
#   ./shell.sh --shell    # escape hatch: a fresh Bash shell in /workspace
#   ./shell.sh --attach   # backward-compatible alias for the default
set -euo pipefail
cd "$(dirname "$0")"

if ! docker compose ps --status running --format '{{.Name}}' 2>/dev/null | grep -q .; then
    echo "Sandbox isn't running. Start it first:  ./run.sh"; exit 1
fi

if [ "${1:-}" = "--shell" ]; then
    exec docker compose exec -u node -w /workspace claude-sandbox bash -l
fi

command=(docker compose exec -u node -w /workspace claude-sandbox herdr)
# Apple Terminal does not implement OSC 52. Proxy Herdr through a host PTY so selections are
# written with pbcopy; paste remains normal terminal input. Other terminals handle OSC 52 directly.
if [ "$(uname -s)" = "Darwin" ] && command -v pbcopy >/dev/null 2>&1; then
    exec python3 scripts/terminal/herdr-pty-bridge.py "${command[@]}"
fi
exec "${command[@]}"
