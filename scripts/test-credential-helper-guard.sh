#!/usr/bin/env bash
# Deterministic coverage for issue #97's shared credential-store guard.
#
# Runs the real helpers against a `docker` shim on PATH, so the assertions are about what they do,
# not how they read. No container is started and no key is written.
#
# The defect: #93 established that a declared project must not silently touch an operator volume, and
# #95 gave `claim-token` the refusal — but `deepseek-key` got #95's project scoping without #95's
# guard. That asymmetry was worse than a plain omission, because making `-p` work there made "I am
# isolated" more believable without making it more true. `deepseek-key store` is an unconditional
# write and `delete` a removal; unlike a claim there is nothing to validate against, so nothing else
# would have stopped it.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
GUARD="$ROOT/scripts/stack-guard.sh"
DEEPSEEK="$ROOT/scripts/auth/deepseek-key.sh"
CLAIM="$ROOT/scripts/auth/claim-token.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASSED=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { PASSED=$((PASSED + 1)); printf 'ok  %s\n' "$*"; }

[ -f "$GUARD" ] || fail "the shared guard is missing"
for f in "$GUARD" "$DEEPSEEK" "$CLAIM"; do bash -n "$f" || fail "$(basename "$f") does not parse"; done
ok "the shared guard and both helpers parse"

# --- the docker shim --------------------------------------------------------
# `config` renders a volumes section whose resolved names the test controls; `run` records and stops.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
# Reject a malformed invocation the way the real docker does. A permissive shim once let
# `docker compose docker compose … config` through unnoticed, which under the caller's `set -e`
# aborted the helper silently — the shim has to be as strict as the thing it stands in for.
[ "${1:-}" = compose ] || [ "${1:-}" = inspect ] || { echo "unknown command: ${1:-}" >&2; exit 1; }
if [ "${1:-}" = compose ] && [ "${2:-}" = docker ]; then
    echo "docker: 'docker' is not a docker compose command" >&2; exit 1
fi
for a in "$@"; do
    if [ "$a" = config ]; then
        echo "services:"
        echo "  claude-sandbox-egress:"
        echo "    image: x"
        echo "volumes:"
        for v in $RESOLVED_VOLUMES; do
            echo "  some-key:"
            echo "    name: $v"
        done
        exit 0
    fi
done
case " $* " in *" run "*) echo "MANAGER-RAN" ; exit 0 ;; esac
exit 0
SHIM
chmod +x "$TMP/bin/docker"

ds() { # project  resolved-volumes  action  [allow]
    # `store` actions read a key from stdin; a fixture is enough and no real key is ever involved.
    printf 'fixture-key-not-a-real-deepseek-key\n' \
    | env -u SIDECAR_COMPOSE_PROJECT -u SIDECAR_ALLOW_SHARED_VOLUMES \
        DOCKER_LOG="$TMP/log" RESOLVED_VOLUMES="$2" PATH="$TMP/bin:$PATH" \
        ${1:+SIDECAR_COMPOSE_PROJECT="$1"} ${4:+SIDECAR_ALLOW_SHARED_VOLUMES="$4"} \
        bash "$DEEPSEEK" "$3" 2>&1
}
ran() { grep -q 'MANAGER-RAN' <<<"$1"; }
reset_log() { : > "$TMP/log"; }

# --- the defect, on every mutating action -----------------------------------
for action in provision rotate revoke; do
    reset_log
    out=$(ds idd97 "coding-agent-sandbox-deepseek-secret idd97-config" "$action")
    grep -qi 'REFUSING' <<<"$out" || fail "'$action' against an operator volume was not refused: $out"
    grep -q 'coding-agent-sandbox-deepseek-secret' <<<"$out" || fail "'$action' refusal did not name the volume"
    ran "$out" && fail "'$action' ran the key manager anyway"
done
ok "provision, rotate and revoke are all refused when the key volume is the operator's"

reset_log
out=$(ds idd97 "coding-agent-sandbox-deepseek-secret" status)
grep -qi 'REFUSING' <<<"$out" || fail "'status' was not guarded: $out"
ok "status is guarded too — a read against the wrong store answers about the wrong store"

# --- and must not fire when it should not -----------------------------------
reset_log
out=$(ds idd97 "idd97-deepseek-secret idd97-config idd97-mitm-ca" provision)
grep -qi 'REFUSING' <<<"$out" && fail "a properly scoped stack was refused: $out"
ran "$out" || fail "a properly scoped provision did not reach the key manager"
ok "a properly scoped stack is not refused and proceeds"

reset_log
out=$(ds "" "coding-agent-sandbox-deepseek-secret" provision)
grep -qi 'REFUSING' <<<"$out" && fail "an unscoped default run was refused: $out"
ran "$out" || fail "the default invocation did not reach the key manager"
ok "the default, unscoped invocation is untouched by the guard"

reset_log
out=$(ds idd97 "coding-agent-sandbox-deepseek-secret" provision true)
grep -qi 'REFUSING' <<<"$out" && fail "the opt-out did not work: $out"
ran "$out" || fail "the opt-out refused to proceed"
grep -qi 'WARNING' <<<"$out" || fail "the opt-out proceeded without saying so"
ok "the documented opt-out proceeds, and says that it did"

# --- the two helpers must refuse identically --------------------------------
# Differing refusals are how the copies drift apart, which is the failure #93 was.
for tok in 'REFUSING' 'SIDECAR_ALLOW_SHARED_VOLUMES' "mounts the operator's own volumes"; do
    grep -q "$tok" "$GUARD" || fail "the shared guard lost '$tok'"
done
ok "the refusal wording lives in one place"

for f in "$CLAIM" "$DEEPSEEK"; do
    grep -q 'stack-guard.sh' "$f" || fail "$(basename "$f") does not use the shared guard"
    grep -q 'REFUSING' "$f" && fail "$(basename "$f") still has its own copy of the refusal"
done
ok "both helpers refuse through the shared guard, with no private copy"

# --- the guard must not be neutered by a pipeline ---------------------------
# `exit` inside a pipeline leaves only the subshell, so a piped guard would print and continue.
for f in "$CLAIM" "$DEEPSEEK"; do
    grep -qE '\|[[:space:]]*stack_guard_refuse_if_shared' "$f" \
        && fail "$(basename "$f") pipes into the guard, so its exit cannot stop the script"
done
ok "neither helper pipes into the guard, so its exit actually stops the script"

# --- no credential-mutating helper may be left without it -------------------
# Enumerated, not a list someone maintained by hand.
missing=""
for f in "$ROOT"/scripts/auth/*.sh; do
    grep -qE 'docker-compose\.(sidecar|mitm)\.yml' "$f" || continue      # touches a stack at all?
    grep -qE 'exec -u root|run --rm' "$f" || continue                    # acts inside one?
    grep -q 'stack-guard.sh' "$f" || missing="$missing $(basename "$f")"
done
[ -z "$missing" ] || fail "credential-mutating helpers without the guard:$missing"
ok "every helper that acts inside a stack uses the guard"

# --- the compose resolution must read what compose says ---------------------
# Two things must not be re-implemented here, because each would be another place to drift: the
# `${VAR:-default}` expansion (compose does it) and the list of operator defaults
# (check-stack-isolation.sh owns it, reading them from the compose file).
grep -q 'compose "\$@" config' "$GUARD" || fail "the guard no longer reads resolved names from compose"
grep -q 'check-stack-isolation.sh' "$GUARD" || fail "the guard no longer delegates the default list"
grep -qE '\$\{[A-Za-z_][A-Za-z0-9_]*:-[^}]*\}.*name|name.*\\\$\\\{' "$GUARD" \
    && fail "the guard parses compose volume-name defaults itself"
grep -q 'coding-agent-sandbox' "$GUARD" && fail "the guard hardcodes an operator volume name"
ok "resolved names come from compose, and the default list from check-stack-isolation"

# --- a guard that cannot resolve must say so --------------------------------
# It silently aborted the helper once, because a failed resolution under `set -e` + `pipefail` exits
# with nothing printed. An unresolvable stack has to be loud: silence is indistinguishable from a
# clean pass to anyone reading the terminal.
reset_log
out=$(printf 'k\n' | env DOCKER_LOG="$TMP/log" RESOLVED_VOLUMES="" PATH="$TMP/bin:$PATH" \
      SIDECAR_COMPOSE_PROJECT=idd97 STACK_GUARD_COMPOSE_FILE=docker-compose.sidecar.yml \
      bash -c '. scripts/stack-guard.sh; stack_guard_volumes_of_compose docker compose -f docker-compose.sidecar.yml' 2>&1)
rc=$?
[ "$rc" -ne 0 ] || fail "an unresolvable compose invocation returned success"
grep -q 'could not resolve volumes' <<<"$out" || fail "an unresolvable stack failed silently: '$out'"
ok "a guard that cannot resolve the stack says so instead of exiting silently"

# --- the PowerShell sibling must not lag ------------------------------------
ps1="$ROOT/scripts/auth/deepseek-key.ps1"
grep -q 'REFUSING' "$ps1" || fail "deepseek-key.ps1 has no refusal"
grep -q 'SIDECAR_ALLOW_SHARED_VOLUMES' "$ps1" || fail "deepseek-key.ps1 has no opt-out"
grep -q 'config' "$ps1" || fail "deepseek-key.ps1 does not resolve volumes from compose"
ok "deepseek-key.ps1 carries the same guard and opt-out"

printf '\nAll %d checks passed.\n' "$PASSED"
