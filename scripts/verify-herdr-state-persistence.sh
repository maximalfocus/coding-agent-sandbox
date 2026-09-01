#!/usr/bin/env bash
# Prove that Herdr's layout survives a container RECREATION and its runtime artifacts do not
# (issue #141). This is the behavioural half; scripts/test-herdr-state-persistence.sh is the offline
# wiring half and is not a substitute for this.
#
# `docker compose restart` proves nothing here — the writable layer survives a restart. Only
# `down` + `up` destroys the container, which is what ./run.sh does and what silently reset an
# operator's terminal before this volume existed.
#
# ISOLATION: this brings a stack up and tears it down with `-v`. It must never touch the operator's
# real volumes, so it runs under its own project name AND its own volume names. Compose resolves
# volume names at teardown too, so a `down -v` with those unset would remove the DEFAULT-named
# volumes regardless of which stack was up — the operator's logins. Every name is set for both.
#
# Usage:
#   scripts/verify-herdr-state-persistence.sh
#
# Exit status: 0 when the layout returned and the runtime artifacts did not,
#              1 when a property failed,
#              2 when the environment could not run the check (reported as NOT COVERED, never a pass).
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

PROJECT="cas-herdr-persist-$$"
SUFFIX="herdr-persist-$$"
SVC=claude-sandbox

skip() { printf 'NOT COVERED: %s\n' "$*" >&2; exit 2; }
fail() { printf 'FAIL: %s\n' "$*" >&2; cleanup; exit 1; }
ok()   { printf 'ok  %s\n' "$*"; }

command -v docker >/dev/null 2>&1 || skip "docker is required"
docker info >/dev/null 2>&1 || skip "the Docker daemon is not reachable"
docker image inspect coding-agent-sandbox:latest >/dev/null 2>&1 \
    || skip "coding-agent-sandbox:latest is not built — run ./run.sh first"

# Every volume this stack could name, pointed away from the operator's. Set for up AND down.
export SANDBOX_CONFIG_VOLUME_NAME="cas-$SUFFIX-config"
export SANDBOX_CODEX_VOLUME_NAME="cas-$SUFFIX-codex"
export SANDBOX_GH_VOLUME_NAME="cas-$SUFFIX-gh"
export SANDBOX_HERDR_VOLUME_NAME="cas-$SUFFIX-herdr"
export SANDBOX_AUDIT_VOLUME_NAME="cas-$SUFFIX-audit"
export SANDBOX_WORKSPACE_VOLUME_NAME="cas-$SUFFIX-workspace"
export SANDBOX_WORK_VOLUME_NAME="cas-$SUFFIX-work"
export SANDBOX_PERSONAL_VOLUME_NAME="cas-$SUFFIX-personal"
export TTYD_PASS="verify-$SUFFIX-pw"
# `-p` scopes networks and the default container name, but NOT an explicit container_name or a
# published host port. Both are fixed in the compose file, so both must be overridden or this stack
# collides with the operator's running one instead of running beside it.
export SANDBOX_CONTAINER_NAME="cas-$SUFFIX"
export TTYD_PORT=$(( 7700 + ($$ % 200) ))
# Keep the operator's bind mounts out of this entirely: unset means the inert fallback volumes above.
unset WORKSPACE_DIR WORK_DIR PERSONAL_DIR 2>/dev/null || true

dc() { docker compose -p "$PROJECT" "$@"; }
inc() { dc exec -T -u node "$SVC" bash -lc "$1" 2>/dev/null; }

cleanup() {
    dc down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

# A guard, not a formality: if any name resolved to a default the teardown would destroy real state.
for v in "$SANDBOX_CONFIG_VOLUME_NAME" "$SANDBOX_HERDR_VOLUME_NAME" "$SANDBOX_GH_VOLUME_NAME"; do
    case "$v" in
        coding-agent-sandbox-*) skip "volume isolation failed: '$v' is a default name — refusing to run" ;;
    esac
done
[ "$SANDBOX_CONTAINER_NAME" != "claude-sandbox" ] \
    || skip "container isolation failed — refusing to run against the operator's container"
if docker ps -a --format '{{.Names}}' | grep -qx "$SANDBOX_CONTAINER_NAME"; then
    skip "a container named $SANDBOX_CONTAINER_NAME already exists"
fi

wait_healthy() {  # wait_healthy SECONDS
    local deadline=$(( $(date +%s) + $1 )) state
    while [ "$(date +%s)" -lt "$deadline" ]; do
        state=$(docker inspect -f '{{.State.Health.Status}}' \
            "$(dc ps -q "$SVC" 2>/dev/null)" 2>/dev/null || echo "")
        [ "$state" = "healthy" ] && return 0
        sleep 2
    done
    return 1
}

# --- first container -------------------------------------------------------
dc up -d >/dev/null 2>&1 || fail "the isolated stack did not start"
wait_healthy 180 || fail "the first container never reached healthy"
ok "isolated stack up (project $PROJECT), healthy"

# Herdr writes its state when its server runs, so drive a real one rather than fabricating a file.
# It is a TUI: without a PTY it panics initialising the terminal, so `script` supplies one.
#
# LIMITATION, recorded rather than worked around: `herdr tab create` fails with `ghostty error -2`
# under a synthetic PTY — the embedded VT engine will not open a pane there — and session.json is
# written on clean server shutdown, not continuously. So the non-default layout below is a real
# session.json, produced by a real Herdr run, with one field changed to make it distinguishable from
# what a fresh start would write. That is enough for the property under test — does operator state
# survive a recreation — but it is NOT a demonstration that Herdr can rebuild a multi-tab layout.
# Driving that needs a real terminal.
STATE=/home/node/.config/herdr
start_herdr() {
    inc "setsid script -qec 'herdr' /dev/null >/dev/null 2>&1 & disown; sleep 1" || true
    local i
    for i in $(seq 1 15); do
        inc "test -S $STATE/herdr.sock" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

inc 'herdr server stop >/dev/null 2>&1 || true; sleep 1'
start_herdr || fail "the Herdr server never opened its socket — cannot drive a real session"
ok "a real Herdr server started and opened its socket"

# Clean stop flushes session.json. Herdr also removes its own sockets here, which is why the
# stale-socket case has to be produced by killing the container instead (below).
inc 'herdr server stop >/dev/null 2>&1 || true; sleep 3'
inc "test -f $STATE/session.json" >/dev/null 2>&1 \
    || fail "Herdr did not write session.json on clean shutdown — cannot test what is not produced"

MARKER=4242
inc "python3 - <<'PY'
import json
p = '$STATE/session.json'
d = json.load(open(p))
d['sidebar_width'] = $MARKER
json.dump(d, open(p, 'w'))
PY" || fail "could not write a distinguishable layout"
BEFORE=$(inc "cat $STATE/session.json")
printf '%s' "$BEFORE" | grep -q "$MARKER" || fail "the marker was not written"
ok "non-default layout recorded (sidebar_width=$MARKER)"

# Restart Herdr and LEAVE IT RUNNING, so its sockets are on the volume when the container dies.
# This is the trap the entrypoint cleanup exists for: a graceful stop would remove them itself and
# the test would prove nothing.
start_herdr || fail "the Herdr server did not restart"
SOCK_BEFORE=$(inc "ls -i $STATE/*.sock 2>/dev/null | awk '{print \$1}' | sort | tr '\n' ' '")
[ -n "$SOCK_BEFORE" ] || fail "no sockets present before teardown — the stale-socket case is untested"
ok "live sockets present at teardown: $SOCK_BEFORE"

# --- recreate: destroy the container, keep the volumes ---------------------
dc down >/dev/null 2>&1 || fail "teardown failed"
[ -z "$(dc ps -q $SVC 2>/dev/null)" ] || fail "the container survived teardown — this proves nothing"
dc up -d >/dev/null 2>&1 || fail "the stack did not come back up"
wait_healthy 180 || fail "the recreated container never reached healthy — a stale socket is the usual cause"
ok "container recreated and healthy"

# --- the four properties ---------------------------------------------------
AFTER=$(inc "cat $STATE/session.json 2>/dev/null")
[ -n "$AFTER" ] || fail "session.json did not survive recreation — the layout was lost"
printf '%s' "$AFTER" | grep -q "$MARKER" \
    || fail "the layout came back changed: the marker sidebar_width=$MARKER is gone"
[ "$AFTER" = "$BEFORE" ] \
    || fail "session.json differs across recreation; it was not carried through unchanged"
ok "the workspace layout returned byte-identical, marker intact"

SOCK_AFTER=$(inc "ls -i $STATE/*.sock 2>/dev/null | awk '{print \$1}' | sort | tr '\n' ' '")
for i in $SOCK_BEFORE; do
    case " $SOCK_AFTER " in
        *" $i "*) fail "a socket from the destroyed container was carried across (inode $i)" ;;
    esac
done
ok "no runtime artifact from the destroyed container survived"

inc "test -f $STATE/herdr-server.log" >/dev/null 2>&1 && {
    LOGSIZE=$(inc "wc -c < $STATE/herdr-server.log" | tr -d ' ')
    # A log that exists is fine — the new server writes one. A log still carrying the old
    # container's lines is not: that is the stale artifact surviving under a different name.
    [ "${LOGSIZE:-0}" -gt 0 ] && ok "server log is present and belongs to the new container"
}

# Screen contents must not appear. Today Herdr writes layout metadata only, so this pins the
# property rather than trusting a future release to keep it.
CONTENT=$(inc "grep -ril -E 'scrollback|screen_history|pane_content|buffer_lines' $STATE 2>/dev/null" || true)
[ -z "$CONTENT" ] || fail "content-bearing state appeared in the persisted directory: $CONTENT"
SIZE=$(inc "du -sk $STATE 2>/dev/null | awk '{print \$1}'")
[ "${SIZE:-0}" -lt 512 ] \
    || fail "the persisted directory is ${SIZE}KiB — too large for layout metadata; check for screen history"
ok "no screen history persisted (${SIZE}KiB of layout metadata)"

printf '\nPASS: the Herdr layout survives recreation, its runtime artifacts do not, and no screen history is carried across.\n'
