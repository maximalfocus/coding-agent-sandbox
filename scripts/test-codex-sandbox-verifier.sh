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
  [[ ! -s "$TMP/out" ]] || fail "$mode emitted success-shaped stdout while failing"
  grep -Fq "$needle" "$TMP/err" || fail "$mode did not report: $needle"
}

if [[ "${1:-}" == --delivery ]]; then
  [[ -z "$(git -C "$ROOT" ls-files '.cdd-auto/*')" ]] || fail '.cdd-auto remains tracked at delivered tip'
  grep -Fxq '.cdd-auto/' "$ROOT/.gitignore" || fail '.gitignore does not exclude .cdd-auto/'
  echo 'PASS: delivery excludes .cdd-auto/'
  exit 0
fi
[[ $# -eq 0 ]] || fail "usage: $0 [--delivery]"

cat >"$TMP/docker" <<'FAKE'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"${FAKE_LOG:?}"
case "${1:-}" in
  inspect)
    case "${FAKE_MODE:?}" in
      privileged-inspect) printf '%s\n' 'true|[]|["ALL"]|["no-new-privileges:true"]' ;;
      sysadmin-inspect) printf '%s\n' 'false|["CAP_SYS_ADMIN"]|["ALL"]|["no-new-privileges:true"]' ;;
      missing-drop-inspect) printf '%s\n' 'false|[]|[]|["no-new-privileges:true"]' ;;
      missing-nnp-inspect) printf '%s\n' 'false|[]|["ALL"]|[]' ;;
      unconfined-inspect) printf '%s\n' 'false|[]|["ALL"]|["no-new-privileges:true","seccomp=unconfined"]' ;;
      *) printf '%s\n' 'false|["CAP_CHOWN","CAP_DAC_OVERRIDE","CAP_NET_ADMIN","CAP_SETGID","CAP_SETUID"]|["ALL"]|["no-new-privileges:true"]' ;;
    esac
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
        fallback-proxy-open|fallback-direct-open) echo 'bwrap: No permissions to create a new namespace' >&2; exit 1 ;;
        *) exit 99 ;;
      esac
    elif [[ "$args" == *" -P :danger-full-access "* ]]; then
      case "${FAKE_MODE:?}" in
        fallback-proxy-open) printf '%s\n' 'workspace_write=0 outside_write=1 proxy_http=200 direct_ip=28' ;;
        fallback-direct-open) printf '%s\n' 'workspace_write=0 outside_write=1 proxy_http=403 direct_ip=0' ;;
        *) printf '%s\n' 'workspace_write=0 outside_write=1 proxy_http=403 direct_ip=28' ;;
      esac
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

for mapping in 'mitm claude-sandbox-mitm' 'sidecar claude-sandbox-node'; do
  read -r mapped_variant mapped_container <<<"$mapping"
  : >"$FAKE_LOG"
  FAKE_MODE=nested-success DOCKER_BIN="$TMP/docker" "$VERIFY" --variant "$mapped_variant" >"$TMP/mapped"
  grep -Fxq "variant=$mapped_variant" "$TMP/mapped" || fail "$mapped_variant output mislabeled"
  grep -Fq "inspect $mapped_container" "$FAKE_LOG" || fail "$mapped_variant selected the wrong container"
done
if DOCKER_BIN="$TMP/docker" "$VERIFY" --variant typo >"$TMP/out" 2>"$TMP/err"; then
  fail 'unknown variant unexpectedly passed'
fi
[[ ! -s "$TMP/out" ]] || fail 'unknown variant emitted success-shaped stdout'
grep -Fq 'unknown variant: typo' "$TMP/err" || fail 'unknown variant error is unclear'

for mode in bundled-blocked debian-blocked; do
  : >"$FAKE_LOG"
  echo "checking $mode" >&2
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
  grep -Fq 'HTTP_PROXY' "$FAKE_LOG" || fail "$mode fallback ignored the variant proxy environment"
  ! grep -Fq -- '--version' "$FAKE_LOG" || fail "$mode used version-only bubblewrap evidence"
done

expect_fail missing-codex 'Codex is unavailable'
expect_fail unknown-error 'unrecognized nested sandbox failure'
expect_fail malformed-success 'malformed nested probe output'
expect_fail fallback-proxy-open 'outer fallback restrictions failed'
expect_fail fallback-direct-open 'outer fallback restrictions failed'
expect_fail privileged-inspect 'is privileged'
expect_fail sysadmin-inspect 'adds SYS_ADMIN'
expect_fail missing-drop-inspect 'does not drop ALL capabilities'
expect_fail missing-nnp-inspect 'lacks no-new-privileges'
expect_fail unconfined-inspect 'disables seccomp'

# Static fail-closed guard: parse rendered Compose JSON so comments cannot satisfy controls.
for file in docker-compose.yml docker-compose.mitm.yml docker-compose.sidecar.yml; do
  path="$ROOT/$file"
  docker compose -f "$path" config --format json >"$TMP/compose.json"
  python3 - "$file" "$TMP/compose.json" <<'PY'
import json, sys
name, path = sys.argv[1:]
data = json.load(open(path))
for service, cfg in data.get("services", {}).items():
    caps_add = {str(x).upper().removeprefix("CAP_") for x in cfg.get("cap_add", [])}
    caps_drop = {str(x).upper() for x in cfg.get("cap_drop", [])}
    security = {str(x).lower() for x in cfg.get("security_opt", [])}
    assert "ALL" in caps_drop, f"{name}:{service} does not drop ALL capabilities"
    assert "SYS_ADMIN" not in caps_add, f"{name}:{service} adds SYS_ADMIN"
    assert "no-new-privileges:true" in security, f"{name}:{service} lacks no-new-privileges"
    assert not cfg.get("privileged", False), f"{name}:{service} is privileged"
    assert str(cfg.get("network_mode", "")).lower() != "host", f"{name}:{service} shares host network"
    assert str(cfg.get("pid", "")).lower() != "host", f"{name}:{service} shares host pid namespace"
    assert str(cfg.get("ipc", "")).lower() != "host", f"{name}:{service} shares host ipc namespace"
    assert not any("seccomp=unconfined" in x or "seccomp:unconfined" in x for x in security), f"{name}:{service} disables seccomp"
PY
done
! grep -Fq 'bubblewrap' "$ROOT/Dockerfile" || fail 'Dockerfile installs bubblewrap without functional benefit'

# Pin the delivered attribution matrix and supported execution surfaces.
DOC="$ROOT/docs/codex-sandbox.md"
[[ -f "$DOC" ]] || fail 'missing docs/codex-sandbox.md attribution matrix'
grep -Fq 'remove only `no-new-privileges` | namespace creation denied' "$DOC" || fail 'docs do not distinguish NNP'
grep -Fq 'retain NNP but set `seccomp=unconfined`' "$DOC" || fail 'docs do not distinguish seccomp'
grep -Fq 'Debian bubblewrap on PATH' "$DOC" || fail 'docs lack Debian PATH operation'
for service in claude-sandbox claude-sandbox-mitm claude-sandbox-node; do
  grep -Fq "$service" "$DOC" || fail "docs lack $service execution surface"
done

echo 'PASS: Codex sandbox verifier conformance (16 behavioral cases; control-attribution evidence; 3 variant guards)'
