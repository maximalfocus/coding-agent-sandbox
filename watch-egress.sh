#!/usr/bin/env bash
# Watch the sandbox's egress audit trail and ALERT the moment a NEW host is refused (403/filtered).
# For each new blocked host you get a macOS desktop notification + a terminal bell, then a prompt to
# evaluate and handle it on the spot: allow it (runs ./allow-domain.sh) or leave it blocked (reject).
#
#   ./watch-egress.sh              # alert + interactive allow/skip prompt per new refused host
#   ./watch-egress.sh --notify-only  # only alert (desktop + bell), never prompt — good for background
#
# Allowing here is IMMEDIATE but TEMPORARY (lost on next container restart). For a permanent rule,
# also add the host to EXTRA_ALLOWED_DOMAINS in .env. Ctrl-C to stop watching.
set -euo pipefail
cd "$(dirname "$0")"

SVC=claude-sandbox
LOG=/var/log/tinyproxy/tinyproxy.log
MODE="${1:-}"

if ! docker compose ps --status running --format '{{.Name}}' 2>/dev/null | grep -q .; then
    echo "Sandbox isn't running. Start it first:  ./run.sh"; exit 1
fi

notify() {  # macOS desktop notification; silently no-op on other platforms
    command -v osascript >/dev/null 2>&1 || return 0
    osascript -e "display notification \"$1\" with title \"🚫 Sandbox blocked egress\" sound name \"Funk\"" >/dev/null 2>&1 || true
}

echo "Watching sandbox egress for refused hosts… (Ctrl-C to stop)"
[ "$MODE" = "--notify-only" ] && echo "  (notify-only: will alert but not prompt)"
# Track already-alerted hosts in a temp file (portable to macOS's bash 3.2, which lacks `declare -A`).
seen=$(mktemp "${TMPDIR:-/tmp}/sandbox-egress-seen.XXXXXX")
trap 'rm -f "$seen"' EXIT

# -n0 = only lines from now on; -F = keep following across the entrypoint's log rotation.
docker compose exec -T "$SVC" tail -F -n0 "$LOG" 2>/dev/null \
  | grep --line-buffered -i "refused on filtered" \
  | while IFS= read -r line; do
        host=$(printf '%s' "$line" | sed -E 's/.*filtered domain "([^"]+)".*/\1/')
        [ -n "$host" ] || continue
        grep -qxF "$host" "$seen" 2>/dev/null && continue   # one alert per host per session
        printf '%s\n' "$host" >> "$seen"
        printf '\a'                              # terminal bell
        ts=$(date '+%H:%M:%S')
        printf '\n  [%s] 🚫 BLOCKED: %s\n' "$ts" "$host"
        printf '       allow (this run):  ./allow-domain.sh %s\n' "$host"
        printf "       allow (permanent): add '%s' to EXTRA_ALLOWED_DOMAINS in .env\n" "$host"
        notify "$host — blocked. Evaluate & allow if trusted."
        if [ "$MODE" != "--notify-only" ] && [ -r /dev/tty ]; then
            printf '       Allow %s now? [y = allow / Enter = skip]: ' "$host" > /dev/tty
            read -r ans < /dev/tty || ans=""
            case "$ans" in
                y|Y) ./allow-domain.sh "$host" \
                       && printf '       ✓ allowed for this run — add it to .env to make it permanent.\n' ;;
                *)   printf '       ↳ left blocked (rejected).\n' ;;
            esac
        fi
    done
