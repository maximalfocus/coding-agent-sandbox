#!/usr/bin/env bash
# Herdr's layout is meant to survive a container recreation while its runtime artifacts are not
# (issue #141). The behavioural proof needs a real recreation and lives in
# scripts/verify-herdr-state-persistence.sh; this is the offline half, and it exists because every
# way of getting the wiring wrong is statically visible:
#
#   - the volume declared on one stack but not another, so the mitm or sidecar operator silently
#     keeps the old behaviour;
#   - mounted at the wrong path, so it persists nothing;
#   - added to the compose files but not the uninstallers, which is issue #125's shape;
#   - the stale-socket cleanup placed AFTER the passed-command exit, so `docker compose exec herdr`
#     in a recreated container meets a dead socket.
#
# Runs offline: no container, no network.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MOUNT='claude-herdr:/home/node/.config/herdr'
DEFAULT_NAME='coding-agent-sandbox-herdr'
OVERRIDE='SANDBOX_HERDR_VOLUME_NAME'

PASSED=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { PASSED=$((PASSED + 1)); printf 'ok  %s\n' "$1"; }

# 1. Every stack that persists the Claude login also persists the Herdr layout. A stack that mounts
#    one and not the other is the asymmetry this issue exists to remove, reintroduced on a variant.
for f in docker-compose.yml docker-compose.mitm.yml docker-compose.sidecar.yml; do
    grep -q 'claude-config:/home/node/.claude' "$ROOT/$f" \
        || fail "$f no longer mounts the Claude config volume — this check has stopped matching"
    grep -Fq "$MOUNT" "$ROOT/$f" \
        || fail "$f persists the Claude login but not the Herdr layout"
    grep -Eq "^  claude-herdr:\$" "$ROOT/$f" \
        || fail "$f mounts claude-herdr without declaring it"
    # Each stack uses its own override prefix — the sidecar file is SIDECAR_* throughout — so match
    # the prefix that file already uses rather than forcing one name across all three.
    grep -Eq "\\\$\{(SANDBOX|SIDECAR)_HERDR_VOLUME_NAME:-${DEFAULT_NAME}\}" "$ROOT/$f" \
        || fail "$f does not parameterise the Herdr volume name like the existing volumes"
done
ok 'all three stacks persist the Herdr layout, parameterised like the existing volumes'

# 2. In the sidecar stack the volume belongs to the AGENT service only. The sidecar holds the
#    credential broker; giving it a terminal-state volume would widen what that container carries.
python3 - "$ROOT/docker-compose.sidecar.yml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
mount = 'claude-herdr:/home/node/.config/herdr'
holders = [name for name, svc in (doc.get('services') or {}).items()
           if mount in (svc.get('volumes') or [])]
assert holders == ['claude-sandbox-node'], \
    f'the Herdr state volume must be on the agent service alone, found: {holders}'
PY
ok 'the sidecar stack gives the Herdr volume to the agent service only'

# 3. Both uninstallers remove it. test-uninstall-inventory.sh proves the general rule against the
#    compose files; this names the volume, so a rewrite of that scan cannot quietly drop it.
grep -q "$OVERRIDE" "$ROOT/uninstall.sh" \
    || fail 'uninstall.sh does not remove the Herdr state volume'
grep -q "$OVERRIDE" "$ROOT/uninstall-windows.ps1" \
    || fail 'uninstall-windows.ps1 does not remove the Herdr state volume'
ok 'both uninstallers remove the Herdr state volume'

# 4. The cleanup runs before BOTH exits. A recreated container can serve its first Herdr server
#    through the passed-command path (./shell.sh) just as easily as through the web terminal, so
#    cleanup placed after the `exec "$@"` branch would leave that path meeting a stale socket.
ENTRY="$ROOT/entrypoint.sh"
cleanup_line=$(grep -n '_herdr_state=' "$ENTRY" | head -1 | cut -d: -f1)
[ -n "$cleanup_line" ] || fail 'entrypoint.sh no longer clears the Herdr runtime artifacts'
passthrough_line=$(grep -n '^    exec "\$@"$' "$ENTRY" | head -1 | cut -d: -f1)
ttyd_line=$(grep -n '^exec ttyd' "$ENTRY" | head -1 | cut -d: -f1)
[ -n "$passthrough_line" ] && [ -n "$ttyd_line" ] \
    || fail 'entrypoint.sh no longer has both exit paths — this check has stopped matching'
[ "$cleanup_line" -lt "$passthrough_line" ] \
    || fail 'the stale-socket cleanup runs after the passed-command exit, so ./shell.sh can meet a dead socket'
[ "$cleanup_line" -lt "$ttyd_line" ] \
    || fail 'the stale-socket cleanup runs after the web terminal starts'
ok 'the stale-socket cleanup precedes both entrypoint exit paths'

# 5. It clears the runtime artifacts and NOTHING else. Removing session.json would defeat the whole
#    volume; a wildcard over the directory is the easy way to write that bug.
block=$(sed -n "${cleanup_line},\$p" "$ENTRY" | sed -n '1,8p')
grep -q '\*\.sock' <<<"$block" || fail 'the cleanup does not remove stale sockets'
grep -q 'herdr-server\.log' <<<"$block" || fail 'the cleanup does not remove the stale server log'
grep -q 'session\.json' <<<"$block" \
    && fail 'the cleanup removes session.json, which is the state the volume exists to keep'
grep -Eq 'rm -[rRf]*r' <<<"$block" \
    && fail 'the cleanup removes recursively, which would take the persisted layout with it'
ok 'the cleanup removes the runtime artifacts and leaves the layout alone'

# 6. The boundary is documented, including what is NOT offered. An operator discovering that their
#    running panes died is the failure mode; being told beforehand is the requirement.
grep -q 'pin-acceptance\|Herdr' "$ROOT/README.md" || fail 'README.md has stopped mentioning Herdr'
grep -qi 'running pane processes' "$ROOT/README.md" \
    || fail 'README.md does not state that running pane processes are lost at recreation'
ok 'README.md states the boundary, including the part that is not offered'

# 7. The behavioural half exists and is executable. This check is deliberately not a substitute for
#    it and must not be mistaken for one.
[ -x "$ROOT/scripts/verify-herdr-state-persistence.sh" ] \
    || fail 'the real recreation check is missing or not executable'
ok 'the behavioural recreation check exists (run it separately; it needs Docker)'

printf 'PASS: the Herdr state volume is wired on every stack and clears only runtime artifacts (%d checks)\n' "$PASSED"
