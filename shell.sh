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
    command=(docker compose exec -u node -w /workspace claude-sandbox bash -l)
else
    command=(docker compose exec -u node -w /workspace claude-sandbox herdr)
fi

# Herdr forwards pane-generated OSC 52 with the same bytes it uses for selections, so output alone
# cannot establish a trusted source. Filter every OSC 52 sequence before it reaches the host
# terminal; use the terminal's native selection/copy gesture for trusted clipboard writes.
if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required to enforce the local-terminal clipboard boundary" >&2
    exit 1
fi
exec python3 scripts/terminal/osc52-filter.py "${command[@]}"
