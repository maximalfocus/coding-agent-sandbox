#!/usr/bin/env bash
# Run functional Codex Linux-sandbox checks in an already-running sandbox container.
set -euo pipefail

DOCKER_BIN=${DOCKER_BIN:-docker}
variant=default
container=

fail() { echo "FAIL: $*" >&2; exit 1; }
usage() { echo "usage: $0 [--variant default|mitm|sidecar] [--container NAME]" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --variant) [[ $# -ge 2 ]] || usage; variant=$2; shift 2 ;;
    --container) [[ $# -ge 2 ]] || usage; container=$2; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
case "$variant" in
  default) default_container=claude-sandbox ;;
  mitm) default_container=claude-sandbox-mitm ;;
  sidecar) default_container=claude-sandbox-node ;;
  *) fail "unknown variant: $variant" ;;
esac
container=${container:-$default_container}

# Re-prove the outer control plane before accepting a danger-full-access fallback.
inspect=$($DOCKER_BIN inspect "$container" --format '{{.HostConfig.Privileged}}|{{json .HostConfig.CapAdd}}|{{json .HostConfig.CapDrop}}|{{json .HostConfig.SecurityOpt}}' 2>&1) || fail "cannot inspect container $container: $inspect"
IFS='|' read -r privileged cap_add cap_drop security_opt <<<"$inspect"
[[ "$privileged" == false ]] || fail "container $container is privileged"
[[ "$cap_drop" == *'"ALL"'* ]] || fail "container $container does not drop ALL capabilities"
[[ "$cap_add" != *'SYS_ADMIN'* ]] || fail "container $container adds SYS_ADMIN"
[[ "$security_opt" == *'no-new-privileges:true'* ]] || fail "container $container lacks no-new-privileges"
[[ "$security_opt" != *'seccomp=unconfined'* && "$security_opt" != *'seccomp:unconfined'* ]] || fail "container $container disables seccomp"

nested_cmd='set +e
marker=/tmp/codex-sandbox-smoke-$$
touch "$marker"; ws=$?
touch /etc/codex-sandbox-should-not-write >/dev/null 2>&1; outside=$?
curl -sS --max-time 3 http://example.com >/dev/null 2>&1; network=$?
rm -f "$marker"
printf "workspace_write=%s outside_write=%s network=%s\n" "$ws" "$outside" "$network"
test "$ws" -eq 0 && test "$outside" -ne 0 && test "$network" -ne 0'

nested_out=$(mktemp)
nested_err=$(mktemp)
fallback_out=$(mktemp)
fallback_err=$(mktemp)
trap 'rm -f "$nested_out" "$nested_err" "$fallback_out" "$fallback_err"' EXIT

set +e
$DOCKER_BIN exec -u node "$container" codex sandbox -P :workspace -C /tmp bash -c "$nested_cmd" >"$nested_out" 2>"$nested_err"
nested_rc=$?
set -e

if [[ $nested_rc -eq 0 ]]; then
  [[ "$(cat "$nested_out")" =~ ^workspace_write=0\ outside_write=[1-9][0-9]*\ network=[1-9][0-9]*$ ]] || fail 'malformed nested probe output'
  cat <<EOF
variant=$variant
nested_sandbox=available
fallback_profile=not-used
workspace_write=PASS
outside_write=DENIED
network=DENIED
result=PASS
EOF
  exit 0
fi

nested_text=$(cat "$nested_err")
if [[ $nested_rc -eq 127 || "$nested_text" =~ ([Cc]odex:.*not[[:space:]]found|executable[[:space:]]file[[:space:]]not[[:space:]]found) ]]; then
  fail 'Codex is unavailable in the target container'
fi
if ! grep -Eq 'No permissions to create (a )?new namespace|kernel does not allow non-privileged user namespaces' "$nested_err"; then
  fail "unrecognized nested sandbox failure: $nested_text"
fi

fallback_cmd='set +e
marker=/tmp/codex-outer-smoke-$$
touch "$marker"; ws=$?
touch /etc/codex-sandbox-should-not-write >/dev/null 2>&1; outside=$?
proxy=${HTTP_PROXY:-http://127.0.0.1:8888}
proxy_http=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 -x "$proxy" http://example.com/ 2>/dev/null); proxy_rc=$?
curl --noproxy "*" -sS --connect-timeout 2 --max-time 3 http://1.1.1.1/ >/dev/null 2>&1; direct=$?
rm -f "$marker"
[[ "$proxy_rc" -eq 0 ]] || proxy_http="ERR${proxy_rc}"
printf "workspace_write=%s outside_write=%s proxy_http=%s direct_ip=%s\n" "$ws" "$outside" "$proxy_http" "$direct"
test "$ws" -eq 0 && test "$outside" -ne 0 && test "$proxy_http" = 403 && test "$direct" -ne 0'

set +e
$DOCKER_BIN exec -u node "$container" codex sandbox -P :danger-full-access -C /tmp bash -c "$fallback_cmd" >"$fallback_out" 2>"$fallback_err"
fallback_rc=$?
set -e
fallback_line=$(cat "$fallback_out")
if [[ $fallback_rc -ne 0 || ! "$fallback_line" =~ ^workspace_write=0\ outside_write=[1-9][0-9]*\ proxy_http=403\ direct_ip=[1-9][0-9]*$ ]]; then
  fail "outer fallback restrictions failed: ${fallback_line:-$(cat "$fallback_err")}"
fi

cat <<EOF
variant=$variant
nested_sandbox=blocked-known
fallback_profile=:danger-full-access
workspace_write=PASS
outside_write=DENIED
network_proxy_filter=PASS
network_direct_ip=DENIED
result=PASS
EOF
