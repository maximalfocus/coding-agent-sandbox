#!/usr/bin/env bash
# Deterministic coverage for issue #95's credential-helper stack targeting.
#
# It runs the real helpers against a `docker` shim on PATH that records every argument it is handed,
# so the assertions are about what the helpers actually invoke rather than about what their source
# looks like. No container is started and no credential is read.
#
# What this holds shut: `claim-token` MOVES a real subscription token, so which stack it resolves to
# is a credential-affecting choice. It honoured a container-name override but passed no `-p`, and a
# Compose call without `-p` cannot see a project started with one — so an isolated run could not be
# reached through the documented variable, while an unset name could resolve the operator's own
# stack instead. The comment claimed consistency with sidecar-smoketest.sh that did not exist.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CLAIM="$ROOT/scripts/auth/claim-token.sh"
DEEPSEEK="$ROOT/scripts/auth/deepseek-key.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASSED=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { PASSED=$((PASSED + 1)); printf 'ok  %s\n' "$*"; }

for f in "$CLAIM" "$DEEPSEEK"; do
    [ -x "$f" ] || fail "$(basename "$f") is missing or not executable"
    bash -n "$f" || fail "$(basename "$f") does not parse"
done
ok "both helpers are present, executable, and parse"

# --- the docker shim --------------------------------------------------------
# Answers `ps` with whatever container the test wants running, answers `inspect` with a volume list,
# and records every invocation. `run`/`exec` record and stop, so nothing downstream is reached.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
case " $* " in
    *" inspect "*) printf '%s\n' $MOUNTED_VOLUMES; exit 0 ;;
esac
for a in "$@"; do
    case "$a" in
        ps)   printf '%s\n' "$RUNNING_CONTAINERS"; exit 0 ;;
        exec|run) exit 0 ;;
    esac
done
exit 0
SHIM
chmod +x "$TMP/bin/docker"

run_claim() { # project  running-containers  [mounted-volumes]
    DOCKER_LOG="$TMP/log" RUNNING_CONTAINERS="$2" MOUNTED_VOLUMES="${3:-idd-config}" \
    PATH="$TMP/bin:$PATH" \
    env ${1:+SIDECAR_COMPOSE_PROJECT="$1"} ${4:+SIDECAR_EGRESS_CONTAINER_NAME="$4"} \
        DOCKER_LOG="$TMP/log" RUNNING_CONTAINERS="$2" MOUNTED_VOLUMES="${3:-idd-config}" \
        PATH="$TMP/bin:$PATH" bash "$CLAIM" 2>&1
}
log() { cat "$TMP/log" 2>/dev/null; }
reset_log() { : > "$TMP/log"; }

# --- claim-token: the project must reach every Compose call -----------------
reset_log
out=$(run_claim idd95 idd95-egress idd95-config idd95-egress)
[ -n "$(log)" ] || fail "the shim recorded nothing — claim-token never called docker"
while IFS= read -r line; do
    case "$line" in
        compose*) grep -q -- '-p idd95' <<<"$line" || fail "a Compose call was left unscoped: $line" ;;
    esac
done < <(log)
ok "with a project set, every Compose call claim-token makes carries -p"

grep -q 'exec -u root' <<<"$(log)" || fail "claim-token never reached the exec"
grep -qE 'compose -p idd95 .*exec -u root' <<<"$(log)" || fail "the exec itself is not scoped to the project"
ok "the exec that performs the claim is scoped to the project"

grep -q 'Claiming into: idd95-egress' <<<"$out" || fail "claim-token did not name the container it resolved: $out"
grep -q "project 'idd95'" <<<"$out" || fail "claim-token did not name the project"
ok "claim-token names the container and project before acting"

# --- and must NOT appear when no project is declared ------------------------
reset_log
out=$(run_claim "" claude-sandbox-egress coding-agent-sandbox-config)
grep -q -- '-p ' <<<"$(log)" && fail "an unscoped run passed -p anyway"
grep -q 'exec -u root' <<<"$(log)" || fail "the default invocation did not reach the exec"
ok "with no project set, no -p is passed and the default invocation still works"

grep -qi 'REFUSING' <<<"$out" && fail "the default invocation was refused over shared volumes"
ok "the default invocation is not blocked by the shared-volume guard"

# --- the shared-volume guard ------------------------------------------------
# A run that declares a project but mounts an operator volume would claim the real login.
reset_log
out=$(run_claim idd95 idd95-egress coding-agent-sandbox-config idd95-egress)
grep -qi 'REFUSING' <<<"$out" || fail "a claim into an operator volume was not refused: $out"
grep -q 'coding-agent-sandbox-config' <<<"$out" || fail "the refusal did not name the shared volume"
grep -q 'exec -u root' <<<"$(log)" && fail "the claim ran anyway after refusing"
ok "a claim into a stack mounting an operator volume is refused before it acts"

reset_log
out=$(SIDECAR_ALLOW_SHARED_VOLUMES=true DOCKER_LOG="$TMP/log" RUNNING_CONTAINERS=idd95-egress \
      MOUNTED_VOLUMES=coding-agent-sandbox-config SIDECAR_COMPOSE_PROJECT=idd95 \
      SIDECAR_EGRESS_CONTAINER_NAME=idd95-egress PATH="$TMP/bin:$PATH" bash "$CLAIM" 2>&1)
grep -qi 'REFUSING' <<<"$out" && fail "the documented opt-out did not work"
grep -q 'exec -u root' <<<"$(log)" || fail "the opt-out refused to proceed"
ok "the documented opt-out allows a deliberately shared run"

# --- resolving nothing must not fall through to another stack ---------------
reset_log
out=$(run_claim idd95 some-other-stack idd95-config idd95-egress)
grep -q 'exec -u root' <<<"$(log)" && fail "claim-token acted on a stack it did not resolve"
grep -q "project 'idd95'" <<<"$out" || fail "the not-found message does not name the project: $out"
ok "when the named stack is not running, nothing is claimed and the project is named"

# --- deepseek-key -----------------------------------------------------------
reset_log
DOCKER_LOG="$TMP/log" SIDECAR_COMPOSE_PROJECT=idd95 PATH="$TMP/bin:$PATH" \
    RUNNING_CONTAINERS="" MOUNTED_VOLUMES="" bash "$DEEPSEEK" status >/dev/null 2>&1
grep -q -- '-p idd95' <<<"$(log)" || fail "deepseek-key ignored the project: $(log)"
ok "deepseek-key scopes its Compose call to the project"

reset_log
DOCKER_LOG="$TMP/log" PATH="$TMP/bin:$PATH" RUNNING_CONTAINERS="" MOUNTED_VOLUMES="" \
    env -u SIDECAR_COMPOSE_PROJECT bash "$DEEPSEEK" status >/dev/null 2>&1
grep -q -- '-p ' <<<"$(log)" && fail "deepseek-key passed -p with no project set"
[ -n "$(log)" ] || fail "deepseek-key never called docker"
ok "deepseek-key omits -p when no project is set"

# --- no Compose invocation may be left behind -------------------------------
# Driven by scanning every occurrence rather than the ones someone remembered, in all four helpers.
for f in "$ROOT"/scripts/auth/claim-token.sh "$ROOT"/scripts/auth/deepseek-key.sh; do
    while IFS= read -r line; do
        case "$line" in
            *'echo'*|*'#'*) continue ;;
        esac
        grep -q 'docker-compose\.\(sidecar\|mitm\)\.yml' <<<"$line" || continue
        grep -qE '\$\{?COMPOSE|\$\{?compose|"\$\{COMPOSE\[@\]\}"' <<<"$line" \
            || fail "$(basename "$f") builds a Compose call outside the scoped array: $line"
    done < <(grep -n 'docker compose' "$f" | grep -v '^\s*#')
done
ok "neither shell helper invokes Compose outside its scoped array"

# --- the PowerShell siblings must not lag -----------------------------------
for f in "$ROOT"/scripts/auth/claim-token.ps1 "$ROOT"/scripts/auth/deepseek-key.ps1; do
    grep -q 'SIDECAR_COMPOSE_PROJECT' "$f" || fail "$(basename "$f") does not honour the project"
done
ok "both PowerShell helpers honour the project too"

grep -q 'SIDECAR_EGRESS_CONTAINER_NAME' "$ROOT/scripts/auth/claim-token.ps1" \
    || fail "claim-token.ps1 does not honour the egress container name"
grep -q 'SIDECAR_ALLOW_SHARED_VOLUMES' "$ROOT/scripts/auth/claim-token.ps1" \
    || fail "claim-token.ps1 has no shared-volume guard"
ok "claim-token.ps1 matches the shell version's overrides and guard"

# --- the comment that was wrong ---------------------------------------------
# It asserted consistency with sidecar-smoketest.sh while passing no -p. A claim of consistency has
# to be backed by the mechanism that makes it true.
if grep -q 'keeps the two helpers consistent' "$CLAIM"; then
    grep -q 'SIDECAR_COMPOSE_PROJECT' "$CLAIM" || fail "claim-token still claims consistency without honouring the project"
fi
grep -q 'SIDECAR_COMPOSE_PROJECT' "$CLAIM" || fail "claim-token.sh does not honour SIDECAR_COMPOSE_PROJECT"
ok "claim-token honours the same project variable the smoke test does"

printf '\nAll %d checks passed.\n' "$PASSED"
