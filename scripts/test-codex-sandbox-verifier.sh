#!/usr/bin/env bash
# Conformance gate for issue #32. Uses a fake Docker boundary for deterministic negative cases,
# then statically guards every shipped agent variant against security-profile relaxation.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VERIFY="$ROOT/scripts/verify-codex-sandbox.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_fail() {
  local mode=$1 needle=$2
  if FAKE_MODE="$mode" DOCKER_BIN="$TMP/docker" "$VERIFY" --variant default --container fixture >"$TMP/out" 2>"$TMP/err"; then
    fail "$mode unexpectedly passed"
  fi
  grep -Fq "$needle" "$TMP/err" || fail "$mode did not report: $needle"
}

cat >"$TMP/docker" <<'FAKE'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"${FAKE_LOG:?}"
case "${1:-}" in
  inspect)
    printf '%s\n' 'false|["CAP_CHOWN","CAP_DAC_OVERRIDE","CAP_NET_ADMIN","CAP_SETGID","CAP_SETUID"]|["ALL"]|["no-new-privileges:true"]'
    ;;
  exec)
    args=" $* "
    if [[ "$args" == *" -P :workspace "* ]]; then
      case "${FAKE_MODE:?}" in
        nested-success) printf '%s\n' 'workspace_write=0 outside_write=1 network=7' ;;
        bundled-blocked) echo 'bwrap: No permissions to create a new namespace, likely because the kernel does not allow non-privileged user namespaces.' >&2; exit 1 ;;
        debian-blocked) echo 'bwrap: No permissions to create new namespace, likely because the kernel does not allow non-privileged user namespaces.' >&2; exit 1 ;;
        missing-codex) echo 'exec: codex: not found' >&2; exit 127 ;;
        unknown-error) echo 'bwrap: unexpected setup failure' >&2; exit 1 ;;
        malformed-success) echo 'looks good'; exit 0 ;;
        fallback-network-open) echo 'bwrap: No permissions to create a new namespace' >&2; exit 1 ;;
        *) exit 99 ;;
      esac
    elif [[ "$args" == *" -P :danger-full-access "* ]]; then
      if [[ "${FAKE_MODE:?}" == fallback-network-open ]]; then
        printf '%s\n' 'workspace_write=0 outside_write=1 proxy_http=200 direct_ip=0'
      else
        printf '%s\n' 'workspace_write=0 outside_write=1 proxy_http=403 direct_ip=28'
      fi
    else
      echo 'unexpected fake docker invocation' >&2
      exit 98
    fi
    ;;
  *) exit 97 ;;
esac
FAKE
chmod +x "$TMP/docker"
export FAKE_LOG="$TMP/commands.log"

[[ -x "$VERIFY" ]] || fail "missing executable scripts/verify-codex-sandbox.sh"

: >"$FAKE_LOG"
FAKE_MODE=nested-success DOCKER_BIN="$TMP/docker" "$VERIFY" --variant default --container fixture >"$TMP/nested"
diff -u - "$TMP/nested" <<'EXPECTED'
variant=default
nested_sandbox=available
fallback_profile=not-used
workspace_write=PASS
outside_write=DENIED
network=DENIED
result=PASS
EXPECTED

grep -Fq 'codex sandbox -P :workspace' "$FAKE_LOG" || fail 'nested smoke did not run a real codex sandbox command'
! grep -Fq -- '--version' "$FAKE_LOG" || fail 'version-only bubblewrap evidence is forbidden'

for mode in bundled-blocked debian-blocked; do
  : >"$FAKE_LOG"
  FAKE_MODE="$mode" DOCKER_BIN="$TMP/docker" "$VERIFY" --variant default --container fixture >"$TMP/fallback"
  diff -u - "$TMP/fallback" <<'EXPECTED'
variant=default
nested_sandbox=blocked-known
fallback_profile=:danger-full-access
workspace_write=PASS
outside_write=DENIED
network_proxy_filter=PASS
network_direct_ip=DENIED
result=PASS
EXPECTED
  grep -Fq 'codex sandbox -P :workspace' "$FAKE_LOG" || fail "$mode skipped the nested operational probe"
  grep -Fq 'codex sandbox -P :danger-full-access' "$FAKE_LOG" || fail "$mode skipped the explicit outer fallback probe"
done

expect_fail missing-codex 'Codex is unavailable'
expect_fail unknown-error 'unrecognized nested sandbox failure'
expect_fail malformed-success 'malformed nested probe output'
expect_fail fallback-network-open 'outer fallback restrictions failed'

# Static fail-closed guard: all agent execution variants keep the outer boundary intact.
for file in docker-compose.yml docker-compose.mitm.yml docker-compose.sidecar.yml; do
  path="$ROOT/$file"
  grep -Eq 'no-new-privileges:true' "$path" || fail "$file lacks no-new-privileges"
  grep -Eq 'cap_drop:' "$path" || fail "$file lacks cap_drop"
  grep -Eq '(^|[[:space:],\[])ALL([][:space:],#]|$)' "$path" || fail "$file does not drop ALL capabilities"
  ! grep -Eq 'privileged:[[:space:]]*true|SYS_ADMIN|seccomp[=:][[:space:]]*unconfined|network_mode:[[:space:]]*host|pid:[[:space:]]*host|ipc:[[:space:]]*host' "$path" || fail "$file weakens the outer boundary"
done
! grep -Eq 'apt-get install[^\n]*bubblewrap|[[:space:]\\]bubblewrap([[:space:]\\]|$)' "$ROOT/Dockerfile" || fail 'Dockerfile installs bubblewrap without functional benefit'

echo 'PASS: Codex sandbox verifier conformance (7 behavioral cases; 3 variant control guards)'
