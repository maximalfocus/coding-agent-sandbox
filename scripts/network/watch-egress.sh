#!/usr/bin/env bash
# Watch the sandbox's egress audit trail and ALERT the moment a NEW host is refused (403/filtered).
# For each new blocked host you get a macOS desktop notification + a terminal bell.
#
#   ./scripts/network/watch-egress.sh              # interactive: notify + prompt allow/skip per host
#   ./scripts/network/watch-egress.sh --notify-only  # only alert (toast + bell), never act
#   ./scripts/network/watch-egress.sh --auto         # AUTO-ASSESS: classify by risk and act automatically
#   ./scripts/network/watch-egress.sh --auto --llm   # same, but route gray-zone hosts to headless `claude -p /assess`
#   ./scripts/network/watch-egress.sh --notify-only --wait  # supervised: wait for the sandbox, self-heal across
#                                                            # restarts (used by the LaunchAgent — see
#                                                            # install-egress-watcher.sh)
#
# --auto tiers (mirrors the /assess skill):
#   ALLOW  : known-safe first-party read-only / cloud APIs -> allow-domain + persist + notify
#   REJECT : trackers / ads / metadata / IP literals       -> leave blocked + notify
#   GRAY   : everything else (incl. storage/drive)          -> notify "needs review"
#            (with --llm: hand to `claude -p "/assess <host>"`, which defaults to reject-on-uncertainty)
#
# Allowing is IMMEDIATE; --auto also persists to EXTRA_ALLOWED_DOMAINS in .env. Ctrl-C to stop.
set -uo pipefail
cd "$(dirname "$0")/../.."

SVC=claude-sandbox
LOG=/var/log/tinyproxy/tinyproxy.log

MODE=interactive; LLM=0; WAIT=0
for a in "$@"; do
    case "$a" in
        --notify-only) MODE=notify ;;
        --auto)        MODE=auto ;;
        --llm)         LLM=1 ;;
        --wait)        WAIT=1 ;;
        *) echo "unknown arg: $a" >&2; exit 1 ;;
    esac
done

# True iff the claude-sandbox compose service is running (the SPECIFIC service, not just any
# container in the project) — both the readiness gate and the --wait supervisor use this.
service_running() {
    docker compose ps --status running --format '{{.Service}}' 2>/dev/null | grep -qx "$SVC"
}

# Block until the service is up, with capped exponential backoff. Only used in --wait mode.
wait_for_service() {
    local delay=2
    until service_running; do
        sleep "$delay"
        [ "$delay" -lt 30 ] && delay=$((delay * 2))
    done
}

# Without --wait, fail fast (manual/interactive use). With --wait (LaunchAgent), the supervisor
# loop below waits the sandbox into existence instead of exiting.
if [ "$WAIT" != "1" ] && ! service_running; then
    echo "Sandbox isn't running. Start it first:  ./run.sh"; exit 1
fi

notify() {  # macOS desktop notification; no-op elsewhere
    command -v osascript >/dev/null 2>&1 || return 0
    osascript -e "display notification \"$2\" with title \"$1\" sound name \"Funk\"" >/dev/null 2>&1 || true
}

# Risk verdict for a host: echoes allow | reject | gray. Conservative — unknown => gray.
classify() {
    local h="$1"
    # IP literal (covers the 169.254.x metadata endpoint and any direct-IP attempt)
    if [[ "$h" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then echo reject; return; fi
    case "$h" in
        # --- REJECT: trackers / ads / metadata / background phone-home ---
        *doubleclick.net|*.googlesyndication.com|*.googleadservices.com|googleads.*|\
        *.google-analytics.com|*.analytics.google.com|*.googletagmanager.com|*.umami.is|\
        mtalk.google.com|metadata.google.internal|*.metadata.goog)
            echo reject; return ;;
        # --- GRAY: known-but-risky (bidirectional / broad) -> never silently auto-allow ---
        storage.googleapis.com|*.storage.googleapis.com|drive.google.com|*.drive.google.com)
            echo gray; return ;;
        # --- ALLOW: first-party read-only CDNs / docs / package indexes / scoped cloud APIs ---
        *.googleapis.com|*.pkg.dev|gstatic.com|*.gstatic.com|ggpht.com|*.ggpht.com|\
        googlevideo.com|*.googlevideo.com|ytimg.com|*.ytimg.com|dl.google.com|\
        accounts.google.com|*.developers.google.com|ai.google.dev|\
        pypi.org|files.pythonhosted.org|*.pythonhosted.org|pypa.io|*.pypa.io|\
        crates.io|*.crates.io|static.rust-lang.org|rustup.rs|cdn.playwright.dev|astral.sh)
            echo allow; return ;;
    esac
    echo gray
}

# Persist a host to EXTRA_ALLOWED_DOMAINS in .env (append, comma-separated).
persist_env() {
    local h="$1"
    grep -qE "(^|[=,])${h}([,]|$)" .env 2>/dev/null && return 0
    perl -0pi -e "s/^(EXTRA_ALLOWED_DOMAINS=.*?)\$/\$1,$h/m" .env
}

do_allow() {  # hot-add + persist + notify
    local h="$1"
    if ./scripts/network/allow-domain.sh "$h" >/dev/null 2>&1; then
        persist_env "$h"
        printf '       \xe2\x9c\x93 AUTO-ALLOWED %s (persisted)\n' "$h"
        notify "✅ Sandbox auto-allowed" "$h — known-safe, allowed + persisted."
    else
        printf '       allow-domain failed for %s (left blocked)\n' "$h"
        notify "⚠️ Sandbox allow failed" "$h — could not allow; left blocked."
    fi
}

wlabel=""; [ "$WAIT" = "1" ] && wlabel=" wait=on"
echo "Watching sandbox egress for refused hosts… mode=$MODE${LLM:+ llm=$LLM}$wlabel (Ctrl-C to stop)"
seen=$(mktemp "${TMPDIR:-/tmp}/sandbox-egress-seen.XXXXXX")
trap 'rm -f "$seen"' EXIT

# Tail the proxy log and alert per newly-refused host. Blocks while the container is up; returns
# when the tail/exec pipeline ends (container stop/restart, dropped exec, etc.).
run_pipeline() {
  docker compose exec -T "$SVC" tail -F -n0 "$LOG" 2>/dev/null \
  | grep --line-buffered -i "refused on filtered" \
  | while IFS= read -r line; do
        host=$(printf '%s' "$line" | sed -E 's/.*filtered domain "([^"]+)".*/\1/')
        [ -n "$host" ] || continue
        [ "$host" = "example.com" ] && continue   # allow-domain.sh's safety-canary probe — never a real host
        grep -qxF "$host" "$seen" 2>/dev/null && continue
        printf '%s\n' "$host" >> "$seen"
        printf '\a\n  [%s] 🚫 BLOCKED: %s\n' "$(date '+%H:%M:%S')" "$host"

        case "$MODE" in
          notify)
            notify "🚫 Sandbox blocked egress" "$host — blocked. Evaluate & allow if trusted." ;;
          interactive)
            notify "🚫 Sandbox blocked egress" "$host — blocked. Evaluate & allow if trusted."
            if [ -r /dev/tty ]; then
                printf '       Allow %s now? [y = allow / Enter = skip]: ' "$host" > /dev/tty
                read -r ans < /dev/tty || ans=""
                case "$ans" in y|Y) do_allow "$host" ;; *) printf '       ↳ left blocked.\n' ;; esac
            fi ;;
          auto)
            verdict=$(classify "$host")
            case "$verdict" in
              allow)  do_allow "$host" ;;
              reject) printf '       ⛔ AUTO-REJECTED %s (tracker/metadata — left blocked)\n' "$host"
                      notify "⛔ Sandbox auto-rejected" "$host — tracker/metadata, left blocked." ;;
              gray)
                if [ "$LLM" = "1" ]; then
                    printf '       🤖 gray zone → headless /assess %s …\n' "$host"
                    notify "🤖 Sandbox assessing" "$host — running /assess…"
                    claude -p "/assess $host" >/dev/null 2>&1 \
                      && printf '       /assess finished for %s (see audit.sh / .env)\n' "$host" \
                      || printf '       /assess could not complete for %s (left blocked)\n' "$host"
                else
                    printf '       ⚠ NEEDS REVIEW %s — run: /assess %s  (or ./scripts/network/allow-domain.sh %s)\n' "$host" "$host" "$host"
                    notify "⚠️ Sandbox: needs your review" "$host — not auto-classified. Run /assess."
                fi ;;
            esac ;;
        esac
    done
}

if [ "$WAIT" = "1" ]; then
    # Supervisor: keep watching across container stop/restart cycles WITHOUT relying on launchd
    # to relaunch us. `run_pipeline || true` keeps a nonzero pipeline exit (pipefail) from killing
    # the loop; the 5s backoff stops a persistent immediate-fail from hot-spinning.
    while true; do
        wait_for_service
        run_pipeline || true
        sleep 5
    done
else
    run_pipeline
fi
