#!/usr/bin/env bash
# Measure browser and POSIX terminal paths against a probe pane in a disposable compose stack.
# PowerShell is deliberately UNEVALUATED here: its real boundary needs a Windows host.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

PROJECT="cas-terminal-capabilities-$$"
SUFFIX="terminal-capabilities-$$"
SVC=claude-sandbox

skip() { printf 'UNEVALUATED: %s\n' "$*" >&2; exit 2; }
fail() { printf 'FAIL: %s\n' "$*" >&2; cleanup; exit 1; }
ok() { printf 'PASS %-18s %s\n' "$1" "$2"; }

command -v docker >/dev/null 2>&1 || skip "docker is required"
command -v python3 >/dev/null 2>&1 || skip "python3 is required for the POSIX PTY driver"
docker info >/dev/null 2>&1 || skip "the Docker daemon is not reachable"
docker image inspect coding-agent-sandbox:latest >/dev/null 2>&1 \
    || skip "coding-agent-sandbox:latest is not built — run ./run.sh first"

export COMPOSE_PROJECT_NAME="$PROJECT"
export SANDBOX_CONFIG_VOLUME_NAME="cas-$SUFFIX-config"
export SANDBOX_CODEX_VOLUME_NAME="cas-$SUFFIX-codex"
export SANDBOX_GH_VOLUME_NAME="cas-$SUFFIX-gh"
export SANDBOX_HERDR_VOLUME_NAME="cas-$SUFFIX-herdr"
export SANDBOX_AUDIT_VOLUME_NAME="cas-$SUFFIX-audit"
export SANDBOX_WORKSPACE_VOLUME_NAME="cas-$SUFFIX-workspace"
export SANDBOX_WORK_VOLUME_NAME="cas-$SUFFIX-work"
export SANDBOX_PERSONAL_VOLUME_NAME="cas-$SUFFIX-personal"
export SANDBOX_CONTAINER_NAME="cas-$SUFFIX"
export TTYD_PORT=$((7900 + ($$ % 90)))
export TTYD_USER=capability-probe
export TTYD_PASS="verify-$SUFFIX-password"
unset WORKSPACE_DIR WORK_DIR PERSONAL_DIR 2>/dev/null || true

dc() { docker compose -p "$PROJECT" "$@"; }
cleanup() { dc down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT

for volume in "$SANDBOX_CONFIG_VOLUME_NAME" "$SANDBOX_HERDR_VOLUME_NAME" "$SANDBOX_GH_VOLUME_NAME"; do
    case "$volume" in
        coding-agent-sandbox-*) skip "volume isolation failed: '$volume' is a default name" ;;
    esac
done
[ "$SANDBOX_CONTAINER_NAME" != claude-sandbox ] \
    || skip "container isolation failed — refusing to run against the operator's container"
if docker ps -a --format '{{.Names}}' | grep -qx "$SANDBOX_CONTAINER_NAME"; then
    skip "a container named $SANDBOX_CONTAINER_NAME already exists"
fi

wait_healthy() {
    local deadline=$(( $(date +%s) + 180 )) state id
    while [ "$(date +%s)" -lt "$deadline" ]; do
        id=$(dc ps -q "$SVC" 2>/dev/null || true)
        state=$(docker inspect -f '{{.State.Health.Status}}' "$id" 2>/dev/null || true)
        [ "$state" = healthy ] && return 0
        sleep 1
    done
    return 1
}

wait_ttyd_log() {
    local deadline=$(( $(date +%s) + 180 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        docker logs "$SANDBOX_CONTAINER_NAME" 2>&1 | grep -Fq 'Listening on port: 7681' && return 0
        sleep 1
    done
    return 1
}

dc up -d >/dev/null 2>&1 || fail "the isolated terminal stack did not start"
wait_healthy || fail "the isolated terminal stack never reached healthy"
wait_ttyd_log || fail "ttyd never became ready in the isolated terminal stack"
ok isolation "project=$PROJECT container=$SANDBOX_CONTAINER_NAME"

PROBE_PATH=/tmp/terminal-capability-probe.py
docker cp "$ROOT/scripts/terminal/capability-probe.py" "$SANDBOX_CONTAINER_NAME:$PROBE_PATH" >/dev/null \
    || fail "the probe could not be copied into the disposable container"

POSIX_OUTPUT="/tmp/capability-posix-$SUFFIX.json"
POSIX_READY="/tmp/capability-posix-$SUFFIX.ready"
POSIX_TOKEN="posix$$"
python3 scripts/terminal/drive-posix-terminal.py \
    --root "$ROOT" --probe "$PROBE_PATH" \
    --output "$POSIX_OUTPUT" --ready "$POSIX_READY" --token "$POSIX_TOKEN" \
    || fail "the POSIX local-terminal path could not be driven"
POSIX_JSON=$(dc exec -T -u node "$SVC" cat "$POSIX_OUTPUT" 2>/dev/null) \
    || fail "the POSIX probe produced no report"

BROWSER_DIR=/workspace/.terminal-capability-probe
BROWSER_OUTPUT="$BROWSER_DIR/capability-browser-$SUFFIX.json"
BROWSER_READY="$BROWSER_DIR/capability-browser-$SUFFIX.ready"
BROWSER_TOKEN="browser$$"
dc exec -T -u node "$SVC" mkdir -p "$BROWSER_DIR" \
    || fail "the browser probe's disposable directory could not be created"
NETWORK=$(docker inspect -f '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}}{{end}}' \
    "$SANDBOX_CONTAINER_NAME" 2>/dev/null)
[ -n "$NETWORK" ] || fail "the isolated terminal stack has no Docker network"
docker run --rm --network "$NETWORK" --entrypoint node -u node \
    -e NODE_PATH=/usr/local/lib/node_modules \
    -e HTTP_PROXY= -e HTTPS_PROXY= -e ALL_PROXY= -e NO_PROXY='*' \
    -e http_proxy= -e https_proxy= -e all_proxy= -e no_proxy='*' \
    -v "$SANDBOX_WORKSPACE_VOLUME_NAME:/workspace" \
    -v "$ROOT/scripts/terminal/drive-browser-terminal.js:/driver.js:ro" \
    coding-agent-sandbox:latest \
    /driver.js \
    --url "http://$SANDBOX_CONTAINER_NAME:7681" --user "$TTYD_USER" --password "$TTYD_PASS" \
    --probe "$PROBE_PATH" --output "$BROWSER_OUTPUT" --ready "$BROWSER_READY" \
    --token "$BROWSER_TOKEN" >/dev/null \
    || fail "the ttyd/Chromium terminal path could not be driven"
BROWSER_JSON=$(dc exec -T -u node "$SVC" cat "$BROWSER_OUTPUT" 2>/dev/null) \
    || fail "the browser probe produced no report"

python3 - "$POSIX_JSON" "$BROWSER_JSON" <<'PY' || fail "a terminal capability assertion failed"
import json, sys

reports = [json.loads(value) for value in sys.argv[1:]]
expected = (
    'ordinary-text', 'enter', 'ctrl-c', 'arrow-up', 'arrow-down', 'arrow-right',
    'arrow-left', 'home', 'end', 'alt-b', 'shift-enter', 'ctrl-arrow-left',
    'ctrl-arrow-right', 'alt-enter', 'resize-marker',
)

def emit(status, path, capability, detail):
    print(f'{status:<10} {path:<12} {capability:<18} {detail}')

for report in reports:
    path = report['path']
    actions = {item['name']: item for item in report['actions']}
    if tuple(actions) != expected:
        raise AssertionError(f'{path}: action matrix changed or is incomplete: {tuple(actions)}')
    if report['advertised_colours'] < 256:
        raise AssertionError(f"{path}: pane advertises only {report['advertised_colours']} colours")
    if report['colorterm'].lower() not in ('truecolor', '24bit'):
        raise AssertionError(f"{path}: pane does not advertise true colour: {report['colorterm']!r}")
    emit('PASS', path, 'colour',
         f"TERM={report['term']} colors={report['advertised_colours']} COLORTERM={report['colorterm']}")

    before, after = report['initial_geometry'], report['resized_geometry']
    if before == after:
        raise AssertionError(f'{path}: geometry did not change from {before}')
    emit('PASS', path, 'geometry',
         f"{before['rows']}x{before['cols']} -> {after['rows']}x{after['cols']}")

    required = ('ordinary-text', 'enter', 'ctrl-c', 'arrow-up', 'arrow-down',
                'arrow-right', 'arrow-left', 'home', 'end')
    for name in required:
        if actions[name]['bytes'] == 0:
            raise AssertionError(f'{path}: {name} delivered no bytes')
        emit('PASS', path, name, f"bytes={actions[name]['hex']}")

    for name in ('alt-b', 'ctrl-arrow-left', 'ctrl-arrow-right', 'alt-enter'):
        if actions[name]['bytes'] == 0:
            emit('LIMITATION', path, name, 'no sequence reached the pane; the chord has no effect')
        else:
            emit('PASS', path, name, f"bytes={actions[name]['hex']}")

    shift = actions['shift-enter']['hex']
    if shift == actions['enter']['hex']:
        emit('LIMITATION', path, 'shift-enter',
             f'bytes={shift}; indistinguishable from Enter, so multiline input cannot rely on it')
    elif actions['shift-enter']['bytes']:
        emit('PASS', path, 'shift-enter', f'bytes={shift}')
    else:
        emit('LIMITATION', path, 'shift-enter', 'no sequence reached the pane; the chord has no effect')

print('UNEVALUATED powershell-local all                requires a real Windows PowerShell 5.1 host')
PY

printf '\nPASS: browser and POSIX terminal paths were measured through real entry points; PowerShell was reported unevaluated.\n'
