#!/usr/bin/env bash
# ./configure.sh must report OBSERVED state, in both directions, for every step (issue #155,
# CAS-R056).
#
# A status surface that can be right about a satisfied step and wrong about an unmet one is worse
# than none: it is what an operator trusts instead of looking. So every step is driven twice - once
# with the thing genuinely absent and once with it genuinely present - and the shim IS the observed
# state, so a report that disagrees with it is a failure here.
#
# Two failures already found this way and fixed before the flow shipped, both of which read as
# "satisfied" while the thing was not:
#   - the pin verdict was assembled from per-row "up to date" text, so it reported every pin current
#     while Codex was two minor versions behind;
#   - the Codex probe discarded stderr, which is where `codex login status` writes, so a signed-in
#     Codex read as unmet.
#
# Runs offline: no container is started, no credential is read, no login flow is entered.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASSED=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { PASSED=$((PASSED + 1)); }

[ -x "$ROOT/configure.sh" ] || fail 'configure.sh is missing or not executable'
[ -f "$ROOT/configure.ps1" ] || fail 'configure.ps1 is missing - the flow must exist in both supported shells'
bash -n "$ROOT/configure.sh" || fail 'configure.sh does not parse'

# --- fixture root ------------------------------------------------------------
# Only the surfaces the flow reads. Every delegated path is a stub that RECORDS being called, so
# "the flow delegates rather than reimplementing" is asserted rather than assumed.
FIX="$TMP/tree"
build_fixture() {
    rm -rf "$FIX"
    mkdir -p "$FIX/docs" "$FIX/scripts/auth" "$FIX/scripts/skills"
    cp "$ROOT/configure.sh" "$FIX/configure.sh"
    cp "$ROOT/docs/credential-custody.md" "$FIX/docs/credential-custody.md"
    printf 'TTYD_PASS=please-change-me\n' > "$FIX/.env.example"
    for stub in run.sh scripts/update-agent-clis.sh scripts/auth/claude-login.sh \
                scripts/auth/codex-login.sh scripts/auth/gh-login.sh \
                scripts/auth/deepseek-key.sh scripts/skills/skills-setup.sh; do
        cat > "$FIX/$stub" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "$0" "$*" >> "$DELEGATED"
case "$0" in
    */update-agent-clis.sh)
        if [ -n "${PINS_CURRENT:-}" ]; then
            printf 'claude  1.0.0  1.0.0  up to date\n\nEvery selected pin is already current. Nothing to do.\n'
        else
            printf 'claude  1.0.0  1.0.1  -> published\ncodex   2.0.0  2.0.0  up to date\n'
        fi ;;
    */deepseek-key.sh) [ -n "${PI_OK:-}" ] || exit 1 ;;
esac
exit 0
STUB
        chmod +x "$FIX/$stub"
    done
}

# --- the docker shim ---------------------------------------------------------
# `compose ps` answers with whatever the test wants running. `compose exec ... sh -lc <probe>` is
# answered by exit code: the shim is the observed state, and the flow must report exactly it.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
case " $* " in
    *" ps "*) printf '%s\n' "$RUNNING"; exit 0 ;;
esac
probe=${!#}
case "$probe" in
    *"claude auth status"*)  [ -n "${CLAUDE_OK:-}" ] ; exit $? ;;
    *"codex login status"*)  [ -n "${CODEX_OK:-}" ] ; exit $? ;;
    *"gh auth status"*)      [ -n "${GH_LOGIN:-}" ] ; exit $? ;;
    *GITHUB_TOKEN*)          [ -n "${GH_TOKEN:-}" ] ; exit $? ;;
    *"/workspace/personal/"*) [ -n "${SKILLS_OK:-}" ] ; exit $? ;;
esac
exit 0
SHIM
chmod +x "$TMP/bin/docker"

flow() { # flow [args...] -> stdout+stderr to $TMP/out
    : > "$TMP/delegated"
    : > "$TMP/log"
    set +e
    env PATH="$TMP/bin:$PATH" DOCKER_LOG="$TMP/log" DELEGATED="$TMP/delegated" \
        RUNNING="${RUNNING:-}" CLAUDE_OK="${CLAUDE_OK:-}" CODEX_OK="${CODEX_OK:-}" \
        GH_LOGIN="${GH_LOGIN:-}" GH_TOKEN="${GH_TOKEN:-}" SKILLS_OK="${SKILLS_OK:-}" \
        PI_OK="${PI_OK:-}" PINS_CURRENT="${PINS_CURRENT:-}" \
        bash "$FIX/configure.sh" "$@" > "$TMP/out" 2>&1
    local code=$?
    set -e
    return $code
}
state_of() { # state_of ID -> the state the flow reported for that step
    awk -v id="$2" '$2 == id { print $1 }' "$1"
}
expect() { # expect ID STATE
    local got; got=$(state_of "$TMP/out" "$1")
    [ "$got" = "$2" ] || fail "step '$1': reported '$got', observed state says '$2'
$(cat "$TMP/out")"
    ok
}
delegated_to() { grep -q "$1" "$TMP/delegated"; }

# A satisfied stack for the steps that need one.
satisfied_env() { printf 'TTYD_PASS=a-real-one\n' > "$FIX/.env"; }

# --- env: absent, placeholder, set ------------------------------------------
build_fixture
rm -f "$FIX/.env"
flow --step env || true
expect env unmet
grep -q 'no .env' "$TMP/out" || fail 'the unmet .env step did not name the reason'
ok

printf 'TTYD_PASS=please-change-me\n' > "$FIX/.env"
flow --step env || true
expect env decision
grep -q 'only you can choose it' "$TMP/out" || fail 'a shipped placeholder was not stated as a decision'
ok

satisfied_env
flow --step env || true
expect env satisfied

# --run on a missing .env writes the CONTROL PLANE, never a workspace path, and still stops for the
# one value only the operator can choose.
build_fixture
rm -f "$FIX/.env"
flow --step env --run || true
expect env decision
[ -f "$FIX/.env" ] || fail '--run did not create .env from .env.example'
ok

# --- stack: down, then up ----------------------------------------------------
build_fixture; satisfied_env
RUNNING="" flow --step stack || true
expect stack unmet
RUNNING="claude-sandbox" flow --step stack || true
expect stack satisfied

# A satisfied step performs NO work - the idempotence claim, asserted rather than assumed.
delegated_to 'run.sh' && fail 'the flow ran run.sh for an already-satisfied stack'
ok
RUNNING="claude-sandbox" flow --step stack --run || true
expect stack satisfied
delegated_to 'run.sh' && fail 'a --run over a satisfied stack still invoked run.sh'
ok

# --- pins: drifted (a decision, never adopted) then current ------------------
build_fixture; satisfied_env
RUNNING="claude-sandbox" flow --step pins || true
expect pins decision
grep -q 'adopting one is your call' "$TMP/out" || fail 'a pin gap was not stated as an operator decision'
grep -q -- '-> published' "$TMP/out" || fail 'the pin diff was not presented'
ok
grep -q -- '--apply' "$TMP/delegated" && fail 'the flow adopted a pin on the operator behalf'
ok
RUNNING="claude-sandbox" PINS_CURRENT=1 flow --step pins || true
expect pins satisfied

# Even with --run, a pin is never adopted: it is a rebuild and a revalidation.
RUNNING="claude-sandbox" flow --step pins --run || true
expect pins decision
grep -q -- '--apply' "$TMP/delegated" && fail 'a --run adopted a pin without an explicit decision'
ok

# --- each sign-in step: unsatisfied, then satisfied --------------------------
# Enumerated from the custody table, so a tool added there is covered the day it is added.
build_fixture; satisfied_env
printf 'ALLOW_OPENAI=true\nALLOW_GITHUB=true\nALLOW_DEEPSEEK=true\nTTYD_PASS=a-real-one\n' > "$FIX/.env"
for pair in "claude:CLAUDE_OK" "codex:CODEX_OK" "gh:GH_LOGIN" "pi:PI_OK"; do
    id=${pair%%:*}; var=${pair#*:}
    RUNNING="claude-sandbox" flow --step "$id" || true
    expect "$id" unmet
    eval "$var=1"; export "$var"
    RUNNING="claude-sandbox" flow --step "$id" || true
    expect "$id" satisfied
    delegated_to "$id-login.sh" && fail "the flow ran a sign-in for an already-satisfied $id"
    ok
    unset "$var"
done

# A gate that is off is a DECISION, not something the flow turns on.
build_fixture; satisfied_env
printf 'ALLOW_OPENAI=false\nTTYD_PASS=a-real-one\n' > "$FIX/.env"
RUNNING="claude-sandbox" flow --step codex --run || true
expect codex decision
grep -q 'ALLOW_OPENAI is off' "$TMP/out" || fail 'the unmet gate was not named'
grep -q 'capability grant only you can make' "$TMP/out" || fail 'the gate was not stated as a decision'
ok
grep -q 'ALLOW_OPENAI=true' "$FIX/.env" && fail 'the flow enabled a capability gate on its own'
delegated_to 'codex-login.sh' && fail 'the flow entered a sign-in behind a closed gate'
ok

# --- skills: not configured (n/a), configured and missing, then present ------
build_fixture
printf 'TTYD_PASS=a-real-one\nSKILL_REPOS=\n' > "$FIX/.env"
RUNNING="claude-sandbox" flow --step skills || true
expect skills n/a
grep -q 'optional' "$TMP/out" || fail 'an unconfigured skill step was not reported as optional'
ok
printf 'TTYD_PASS=a-real-one\nSKILL_REPOS=https://github.com/you/x-skills.git\n' > "$FIX/.env"
RUNNING="claude-sandbox" flow --step skills || true
expect skills unmet
grep -q 'x-skills' "$TMP/out" || fail 'the missing skill repo was not named'
ok
RUNNING="claude-sandbox" SKILLS_OK=1 flow --step skills || true
expect skills satisfied
delegated_to 'skills-setup.sh' && fail 'the flow re-cloned already-present skill repos'
ok
RUNNING="claude-sandbox" flow --step skills --run || true
delegated_to 'skills-setup.sh' || fail 'the flow did not delegate to the supported skills path'
ok

# --- ordering, resumability, and the full walk -------------------------------
build_fixture; satisfied_env
[ "$(bash "$FIX/configure.sh" --list | tr '\n' ' ')" = "env stack pins claude codex pi gh skills " ] \
    || fail "the step order changed: $(bash "$FIX/configure.sh" --list | tr '\n' ' ')"
ok

# A full --run with the stack down stops there and attempts nothing after it.
build_fixture; satisfied_env
RUNNING="" flow --run || true
expect stack unmet
grep -q 'STOPPED' "$TMP/out" || fail 'a --run past an unmet stack did not stop'
[ -z "$(state_of "$TMP/out" claude)" ] || fail 'the flow attempted a sign-in with the stack down'
ok

# The report-only default writes nothing at all.
build_fixture; satisfied_env
before=$(cat "$FIX/.env")
RUNNING="claude-sandbox" flow || true
[ "$before" = "$(cat "$FIX/.env")" ] || fail 'a report changed .env'
# A report may PROBE - that is how observed state is obtained, and the pin report is read-only by
# its own contract. What it must not do is invoke a path that changes something.
grep -Eq 'run\.sh|-login\.sh|skills-setup\.sh|--apply' "$TMP/delegated" \
    && fail "a report invoked a changing path: $(cat "$TMP/delegated")"
grep -q 'This was a report; nothing was changed' "$TMP/out" || fail 'the report did not say it changed nothing'
ok

# --- agreement with CAS-R055's in-sandbox checklist --------------------------
# Both must be recomputed from the same observed state. The entrypoint derives GIT_CREDS_OK from
# exactly two facts; the flow probes exactly those two, and the checklist block is extracted from
# the shipped entrypoint rather than copied.
grep -q 'env -u GITHUB_TOKEN -u GH_TOKEN gh auth status' "$ROOT/entrypoint.sh" \
    || fail 'entrypoint.sh no longer probes a stored gh login that way; the flow would now disagree'
grep -q 'env -u GITHUB_TOKEN -u GH_TOKEN gh auth status' "$ROOT/configure.sh" \
    || fail 'configure.sh no longer probes the stored gh login the way entrypoint.sh does'
ok

BLOCK="$TMP/todo-block.sh"
awk '/^# >>> sandbox-todo >>>$/{f=1;next} /^# <<< sandbox-todo <<<$/{f=0} f' "$ROOT/entrypoint.sh" > "$BLOCK"
[ -s "$BLOCK" ] || fail 'the sandbox-todo markers are missing from entrypoint.sh'
checklist_silent() { # checklist_silent GIT_CREDS_OK
    local home="$TMP/home"; rm -rf "$home"; mkdir -p "$home"
    env -i HOME="$home" PATH="$PATH" GIT_CREDS_OK="$1" SKILL_REPOS="" \
        bash -c "set -euo pipefail; . '$BLOCK'" >/dev/null 2>&1
    [ ! -f "$home/.sandbox-todo" ]
}
build_fixture; satisfied_env
printf 'ALLOW_GITHUB=true\nTTYD_PASS=a-real-one\n' > "$FIX/.env"
for combo in ":" "1:" ":1" "1:1"; do
    login=${combo%%:*}; token=${combo#*:}
    RUNNING="claude-sandbox" GH_LOGIN="$login" GH_TOKEN="$token" flow --step gh || true
    flow_ok=0; [ "$(state_of "$TMP/out" gh)" = "satisfied" ] && flow_ok=1
    creds=""; { [ -n "$login" ] || [ -n "$token" ]; } && creds=1
    checklist_ok=0; checklist_silent "$creds" && checklist_ok=1
    [ "$flow_ok" = "$checklist_ok" ] \
        || fail "flow and the in-sandbox checklist disagree for gh login='$login' token='$token': flow=$flow_ok checklist=$checklist_ok"
    ok
done

printf 'PASS: %d configure-flow checks\n' "$PASSED"
