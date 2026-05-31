#!/usr/bin/env bash
# Show the egress audit trail from the persisted audit volume. Survives container restarts.
#
# Default stack (tinyproxy, hostname-only) — every host the proxy was asked to reach:
#   ./audit.sh            # follow live
#   ./audit.sh --refused  # only the blocked attempts
#   ./audit.sh --dump     # print all and exit
#
# Content-mediation stack (mitmproxy) — every per-request decision (ALLOW/DENY/STRIP):
#   ./audit.sh --mitm            # follow live
#   ./audit.sh --mitm --refused  # only DENY/STRIP decisions
#   ./audit.sh --mitm --dump     # print all and exit
set -euo pipefail
cd "$(dirname "$0")"

# Select the stack: --mitm targets the mitmproxy variant (its own compose file + log), otherwise
# the default tinyproxy stack. The flag may appear in any position.
MITM=0; args=()
for a in "$@"; do [ "$a" = "--mitm" ] && MITM=1 || args+=("$a"); done
set -- ${args+"${args[@]}"}

if [ "$MITM" = "1" ]; then
    COMPOSE=(docker compose -f docker-compose.mitm.yml); SVC=claude-sandbox-mitm
    LOG=/var/log/mitm/decisions.log; REFUSED='DENY|STRIP'
else
    COMPOSE=(docker compose); SVC=claude-sandbox
    LOG=/var/log/tinyproxy/tinyproxy.log; REFUSED='refused on filtered'
fi

if ! "${COMPOSE[@]}" ps --status running --format '{{.Name}}' 2>/dev/null | grep -q .; then
    if [ "$MITM" = "1" ]; then
        echo "Mitm sandbox isn't running. Start it:  docker compose -f docker-compose.mitm.yml up -d --build"
    else
        echo "Sandbox isn't running. Start it first:  ./run.sh"
    fi
    exit 1
fi

case "${1:-}" in
    --refused) "${COMPOSE[@]}" exec -T "$SVC" grep -iE "$REFUSED" "$LOG" \
                 || echo "(no refused/stripped entries logged yet)"; exit 0 ;;
    --dump)    exec "${COMPOSE[@]}" exec -T "$SVC" cat "$LOG" ;;
    *)         exec "${COMPOSE[@]}" exec "$SVC" tail -f -n 50 "$LOG" ;;
esac
