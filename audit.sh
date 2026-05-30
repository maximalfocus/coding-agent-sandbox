#!/usr/bin/env bash
# Show the egress audit trail — every host the proxy was asked to reach (allowed + refused),
# from the persisted audit volume. Survives container restarts.
#   ./audit.sh            # follow live
#   ./audit.sh --refused  # only the blocked attempts
#   ./audit.sh --dump     # print all and exit
set -euo pipefail
cd "$(dirname "$0")"
LOG=/var/log/tinyproxy/tinyproxy.log

if ! docker compose ps --status running --format '{{.Name}}' 2>/dev/null | grep -q .; then
    echo "Sandbox isn't running. Start it first:  ./run.sh"; exit 1
fi

case "${1:-}" in
    --refused) docker compose exec -T claude-sandbox grep -i "refused on filtered" "$LOG" \
                 || echo "(no refused attempts logged yet)"; exit 0 ;;
    --dump)    exec docker compose exec -T claude-sandbox cat "$LOG" ;;
    *)         exec docker compose exec claude-sandbox tail -f -n 50 "$LOG" ;;
esac
