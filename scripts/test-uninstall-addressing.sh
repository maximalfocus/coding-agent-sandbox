#!/usr/bin/env bash
# The uninstaller must be able to remove ONE named installation and nothing else (issue #123).
#
# Why this exists: `uninstall.sh` used to address fixed names, including
# `coding-agent-sandbox-config` — the operator's login. Observing that it removes what it claims
# therefore destroyed the state a verification run must leave intact, so `CAS-R054`'s removal half
# had never been exercised at all. With the names resolved from the same `SANDBOX_*` variables the
# compose files use, a disposable installation can be created, uninstalled, and asserted gone.
#
# This is the real boundary: a real Compose bring-up, the real uninstaller, and a before/after
# comparison of every default-named resource on the host.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

PASSED=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { PASSED=$((PASSED + 1)); printf 'ok  %s\n' "$*"; }

command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { echo "SKIP: no Docker daemon"; exit 0; }
docker image inspect coding-agent-sandbox:latest >/dev/null 2>&1 \
    || { echo "SKIP: coding-agent-sandbox:latest is not built on this host"; exit 0; }

P=unaddr$$
TMP=$(mktemp -d)
REPO="$TMP/repo"

# Every name this run owns. The list is DERIVED from uninstall.sh's own SANDBOX_VARS rather than
# restated here: when #125 added the credential volumes to that list, a hand-copied version here
# silently became a partial override and the run started tripping its own refusal.
sandbox_vars() {
    sed -n '/^SANDBOX_VARS=(/,/^)/p' "$ROOT/uninstall.sh" | tr ' ' '\n' | grep -E '^[A-Z][A-Z0-9_]+$'
}
addr_env() {
    local v
    for v in $(sandbox_vars); do
        if [ "$v" = COMPOSE_PROJECT_NAME ]; then
            export COMPOSE_PROJECT_NAME="$P"
        else
            export "$v=$P-$(printf '%s' "$v" | tr '[:upper:]_' '[:lower:]-')"
        fi
    done
}
addr_unset() { local v; for v in $(sandbox_vars); do unset "$v"; done; }
CFG_VOL="$P-$(printf '%s' SANDBOX_CONFIG_VOLUME_NAME | tr '[:upper:]_' '[:lower:]-')"

cleanup() {
    ( addr_env; cd "$REPO" 2>/dev/null && docker compose down -v >/dev/null 2>&1 )
    docker rm -f "$P-sandbox-container-name" >/dev/null 2>&1
    for v in $(sandbox_vars); do
        [ "$v" = COMPOSE_PROJECT_NAME ] && continue
        docker volume rm "$P-$(printf '%s' "$v" | tr '[:upper:]_' '[:lower:]-')" >/dev/null 2>&1
    done
    docker network rm "${P}_default" >/dev/null 2>&1
    rm -rf "$TMP"
}
trap cleanup EXIT

nvars=$(sandbox_vars | wc -l | tr -d ' ')
[ "${nvars:-0}" -ge 13 ] || fail "only $nvars SANDBOX_VARS were derived — the parse has stopped matching"
ok "$nvars addressable names derived from uninstall.sh's own list"

before_v=$(docker volume ls --format '{{.Name}}' | sort)
before_c=$(docker ps -a --format '{{.Names}}' | sort)
before_i=$(docker images --format '{{.Repository}}:{{.Tag}}' | sort)

cp -R "$ROOT" "$REPO"
mkdir -p "$TMP/work" "$TMP/personal"
cat > "$REPO/.env" <<ENVEOF
WORKSPACE_DIR=
PERSONAL_DIR=$TMP/personal
WORK_DIR=$TMP/work
TTYD_USER=coder
TTYD_PASS=addressing-test-pw
TTYD_PORT=7698
ALLOW_GITHUB=true
ALLOW_OPENAI=false
ALLOW_DEEPSEEK=false
ENVEOF

( addr_env; cd "$REPO" && docker compose up -d --no-build >/dev/null 2>&1 ) \
    || fail "could not bring up the disposable installation"
docker inspect "$P-sandbox-container-name" >/dev/null 2>&1 || fail "the disposable container was not created"
docker volume inspect "$CFG_VOL" >/dev/null 2>&1 || fail "the disposable login volume was not created"
ok "a disposable installation came up under the SANDBOX_* variables"

# --- the check must be able to fail: a PARTIAL override must be refused -----
partial_out=$( addr_env; unset SANDBOX_CONFIG_VOLUME_NAME; cd "$REPO" && ./uninstall.sh -y 2>&1 )
partial_rc=$?
[ "$partial_rc" -ne 0 ] || fail "a partial override was accepted — it would have removed the operator's login volume"
grep -q 'REFUSING' <<<"$partial_out" || fail "a partial override failed without saying why: $partial_out"
docker volume inspect "$CFG_VOL" >/dev/null 2>&1 || fail "the refused run removed something anyway"
ok "a PARTIAL override is refused, and the refusal removes nothing"

# --- addressing is load-bearing, proven WITHOUT removing anything ------------
# The obvious proof — restore the fixed names and watch the check fail — would run the old
# uninstaller against the DEFAULT names with -y and delete the operator's login. That hazard is the
# entire reason this issue exists, so the proof is done on the PLAN instead, which removes nothing.
plan_addr=$( addr_env; cd "$REPO" && printf 'n\n' | ./uninstall.sh 2>&1 )
grep -q "$CFG_VOL" <<<"$plan_addr" || fail "the addressed plan does not target the disposable login volume"
grep -q 'coding-agent-sandbox-config' <<<"$plan_addr" && fail "the addressed plan still targets the OPERATOR's login volume"
ok "an addressed plan names the disposable volumes and never the operator's"

# The same assertion against a copy whose config volume name is hardcoded again: it must fail, or it
# was never testing anything. Only the plan is printed, so nothing is removed either way.
cp -R "$REPO" "$TMP/regress"
sed -i.bak -E 's|"\$\(pick [^)]*coding-agent-sandbox-config\)"|coding-agent-sandbox-config|' "$TMP/regress/uninstall.sh"
grep -qE '^[[:space:]]*coding-agent-sandbox-config[[:space:]]*$' "$TMP/regress/uninstall.sh" \
    || fail "the regression mutation did not apply"
plan_bad=$( addr_env; cd "$TMP/regress" && printf 'n\n' | ./uninstall.sh 2>&1 )
grep -q 'coding-agent-sandbox-config' <<<"$plan_bad" \
    || fail "the check cannot detect a hardcoded name — it would pass a regression"
ok "the check DETECTS a re-hardcoded name (proven able to fail, without removing anything)"

# --- the addressed uninstall ------------------------------------------------
( addr_env; cd "$REPO" && ./uninstall.sh -y >"$TMP/uninstall.log" 2>&1 ) \
    || { sed 's/^/    /' "$TMP/uninstall.log"; fail "the addressed uninstall exited non-zero"; }

docker inspect "$P-sandbox-container-name" >/dev/null 2>&1 && fail "the disposable container survived the uninstall"
for v in $(sandbox_vars); do
    [ "$v" = COMPOSE_PROJECT_NAME ] && continue
    case "$v" in *VOLUME_NAME) ;; *) continue;; esac
    n="$P-$(printf '%s' "$v" | tr '[:upper:]_' '[:lower:]-')"
    docker volume inspect "$n" >/dev/null 2>&1 && fail "disposable volume $n survived the uninstall"
done
ok "the addressed uninstall removed the disposable container and every disposable volume"

# --- and touched nothing else ----------------------------------------------
after_v=$(docker volume ls --format '{{.Name}}' | sort)
lost_v=$(comm -23 <(printf '%s\n' "$before_v") <(printf '%s\n' "$after_v"))
[ -z "$lost_v" ] || fail "the addressed uninstall removed pre-existing volumes:
$lost_v"
ok "no pre-existing volume was removed (the operator's login among them)"

after_c=$(docker ps -a --format '{{.Names}}' | sort)
lost_c=$(comm -23 <(printf '%s\n' "$before_c") <(printf '%s\n' "$after_c"))
[ -z "$lost_c" ] || fail "the addressed uninstall removed pre-existing containers: $lost_c"
ok "no pre-existing container was removed"

after_i=$(docker images --format '{{.Repository}}:{{.Tag}}' | sort)
lost_i=$(comm -23 <(printf '%s\n' "$before_i") <(printf '%s\n' "$after_i"))
[ -z "$lost_i" ] || fail "the addressed uninstall removed shared images: $lost_i"
ok "the shared image tags are untouched — an addressed run does not own them"

[ -d "$REPO" ] || fail "the addressed uninstall deleted the repo directory, which it does not own"
ok "the repo directory survives an addressed uninstall"
grep -q "Addressing the named installation '$P'" "$TMP/uninstall.log" \
    || fail "the uninstall did not say which installation it was acting on"
ok "the run names the installation it acted on rather than leaving it to be inferred"

# --- the default path targets the default resources but preserves the checkout ------------
addr_unset
plan=$( cd "$REPO" && printf 'n\n' | ./uninstall.sh 2>&1 )
grep -q 'coding-agent-sandbox-config' <<<"$plan" || fail "the default plan no longer targets the default login volume"
grep -q 'Aborted' <<<"$plan" || fail "declining no longer aborts"
grep -q 'Addressing the named installation' <<<"$plan" && fail "an un-overridden run claimed to be addressed"
grep -q 'Directory:.*kept' <<<"$plan" || fail "the default plan does not preserve the checkout"
grep -q 'this whole repo\|Removing directory' <<<"$plan" && fail "the default plan still claims it deletes the checkout"
ok "with no overrides the default resources are targeted and the checkout is preserved"

# --- the two halves must stay in step ---------------------------------------
for v in SANDBOX_CONTAINER_NAME SANDBOX_CONFIG_VOLUME_NAME SANDBOX_TRIVY_CACHE_VOLUME_NAME COMPOSE_PROJECT_NAME; do
    grep -q "$v" uninstall.sh || fail "uninstall.sh does not consume $v"
    grep -q "$v" uninstall-windows.ps1 || fail "uninstall-windows.ps1 does not consume $v — the halves have diverged"
done
ok "uninstall.sh and uninstall-windows.ps1 consume the same variable names"

# An addressed run must not take the shared resources with it, on EITHER half. On Windows this was
# the easier half to get wrong: the refusal can be added without the scoping, leaving an addressed
# run still uninstalling Docker Desktop.
for half in uninstall.sh uninstall-windows.ps1; do
    block=$(grep -A12 -iE 'addressed run removes ONE named installation' "$half")
    [ -n "$block" ] || fail "$half has no addressed-run scoping block"
    grep -qiE 'KeepImages|KEEP_IMAGES' <<<"$block" || fail "$half does not keep the shared images on an addressed run"
    grep -qiE 'Engine'                 <<<"$block" || fail "$half does not spare the host Docker engine on an addressed run"
    grep -qiE '_default' <<<"$block" \
        || fail "$half does not narrow the network list on an addressed run — it would remove the shared claude-safe-net"
done
ok "both halves scope an addressed run away from the shared images, engine and network"

printf '\nAll %d checks passed.\n' "$PASSED"
