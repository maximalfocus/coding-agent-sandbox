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
# cannot establish a trusted source. The gate supplies the missing signal from the HOST side: a
# clipboard write is applied only when it follows a mouse-button release you just made (mode
# `gesture`, the default) or when you confirm it with Ctrl-]. Unattended output still cannot touch
# your clipboard, and OSC 52 read-back queries are always dropped.
#
#   SANDBOX_CLIPBOARD=gesture   select-to-copy works; anything else asks (default)
#   SANDBOX_CLIPBOARD=confirm   every write asks, including selections
#   SANDBOX_CLIPBOARD=off       discard every OSC 52 sequence
if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required to enforce the local-terminal clipboard boundary" >&2
    exit 1
fi
exec python3 scripts/terminal/osc52-filter.py "${command[@]}"
