#!/usr/bin/env bash
# Show the egress audit trail from the persisted audit volume. Survives container restarts.
#
# Default stack (tinyproxy, hostname-only) — every host the proxy was asked to reach:
#   ./audit.sh            # follow live
#   ./audit.sh --refused  # only the blocked attempts (across rotated files too)
#   ./audit.sh --dump     # print all and exit (oldest rotated -> current)
#   ./audit.sh --export [DIR]  # copy the full trail (current + rotated) out to the host,
#                              # so it survives `docker compose down -v`. Default DIR: ./audit-export
#
# Content-mediation stack (mitmproxy) — every per-request decision (ALLOW/DENY/STRIP):
#   ./audit.sh --mitm            # follow live
#   ./audit.sh --mitm --refused  # only DENY/STRIP decisions
#   ./audit.sh --mitm --dump     # print all and exit
#   ./audit.sh --mitm --export [DIR]
#
# The trail stays on this machine. It's owned by the proxy user and the sandboxed agent can't
# read or alter it; rotation (see entrypoint.sh) caps its size. Use --export to back it up.
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

# Concatenate the trail oldest-first: rotated files (.N ... .1) then the live log.
cat_all='L="$1"; for f in $(ls -1 "$L".[0-9]* 2>/dev/null | sort -V -r); do cat "$f"; done; [ -f "$L" ] && cat "$L" || true'

case "${1:-}" in
    --refused) "${COMPOSE[@]}" exec -T "$SVC" sh -c "$cat_all" _ "$LOG" | grep -iE "$REFUSED" \
                 || echo "(no refused/stripped entries logged yet)"; exit 0 ;;
    --dump)    exec "${COMPOSE[@]}" exec -T "$SVC" sh -c "$cat_all" _ "$LOG" ;;
    --export)  DEST="${2:-./audit-export}"; mkdir -p "$DEST"
               "${COMPOSE[@]}" exec -T "$SVC" sh -c 'cd "$(dirname "$1")" && tar cf - "$(basename "$1")"*' _ "$LOG" \
                 | tar xf - -C "$DEST"
               echo "Exported audit trail to: $DEST"; exit 0 ;;
    *)         exec "${COMPOSE[@]}" exec "$SVC" tail -f -n 50 "$LOG" ;;
esac
