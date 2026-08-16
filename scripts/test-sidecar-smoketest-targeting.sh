#!/usr/bin/env bash
# Regression guards for issue #69's two defects in sidecar-smoketest.sh.
#
# These are deliberately static checks on the script's own text. The behavioural proof for this issue
# is a live one and is recorded on the pull request — 20 consecutive runs of the interface-binding
# check on a healthy isolated stack, plus three negative cases against a deliberately broken rule
# set. What a live run cannot do is stop the two defects from being reintroduced later, which is what
# this file is for:
#
#   1. the interface-binding check must not depend on `docker logs`. That made a correct boundary
#      report failure 7 times in 20 measured runs, because it required a historical line whose read
#      races with the log driver rather than the state being asserted; and
#   2. the script must be able to address a named Compose project, so `ps`/`exec` reach an isolated
#      stack instead of the operator's default one.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SMOKE="$ROOT/sidecar-smoketest.sh"

PASSED=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { PASSED=$((PASSED + 1)); printf 'ok  %s\n' "$*"; }

[ -x "$SMOKE" ] || fail "sidecar-smoketest.sh is missing or not executable"
bash -n "$SMOKE" || fail "sidecar-smoketest.sh does not parse"
ok "sidecar-smoketest.sh is present, executable, and parses"

# --- 1. no dependency on retained log output ------------------------------
binding=$(awk '/^verify_sidecar_input_binding\(\)/,/^}$/' "$SMOKE")
[ -n "$binding" ] || fail "could not find verify_sidecar_input_binding in the smoketest"

if grep -qE '^[^#]*docker[[:space:]]+logs' <<<"$binding"; then
    fail "the interface-binding check reads docker logs again (issue #69)"
fi
ok "interface-binding check does not read docker logs"

# The whole assertion has to come from state read at check time, so the sources it is allowed to use
# are Docker's current metadata and live commands inside the container.
grep -q 'docker inspect' <<<"$binding" || fail "binding check no longer reads current Docker metadata"
grep -q 'iptables -C INPUT' <<<"$binding" || fail "binding check no longer reads the live INPUT chain"
ok "interface-binding check reads current Docker metadata and the live INPUT chain"

# --- 2. every unmet condition names itself --------------------------------
# The original check was one large `if` whose only message named the conclusion, not the cause.
causes=$(grep -c 'return 1' <<<"$binding")
[ "$causes" -ge 8 ] || fail "binding check has only $causes distinct failure paths; expected at least 8"
ok "interface-binding check has $causes distinct, individually reported failure paths"

grep -q 'not bound exclusively to its verified internal interface — \$binding_detail' "$SMOKE" \
    || fail "the FAIL message does not report the specific unmet condition"
ok "the FAIL message reports the specific unmet condition"

# Each condition that can fail must say something, rather than returning bare.
while IFS= read -r line; do
    grep -q 'echo' <<<"$line" || fail "a failure path returns without naming a cause: $line"
done < <(grep -E 'return 1' <<<"$binding" | grep -v 'binding_detail')
ok "every failure path names a cause"

# --- 3. the script can address a named Compose project --------------------
grep -q 'SIDECAR_COMPOSE_PROJECT' "$SMOKE" || fail "SIDECAR_COMPOSE_PROJECT is not supported"
grep -qE 'COMPOSE\+=\(-p "\$SIDECAR_COMPOSE_PROJECT"\)' "$SMOKE" \
    || fail "SIDECAR_COMPOSE_PROJECT is not wired to compose's -p flag"
ok "SIDECAR_COMPOSE_PROJECT selects the Compose project via -p"

# It has to be scoped before the file arguments so every ps/exec inherits it.
project_line=$(grep -n 'COMPOSE+=(-p' "$SMOKE" | cut -d: -f1)
compose_file_line=$(grep -n 'COMPOSE+=(-f docker-compose.sidecar.yml)' "$SMOKE" | cut -d: -f1)
[ -n "$project_line" ] && [ -n "$compose_file_line" ] || fail "could not locate the COMPOSE construction"
[ "$project_line" -lt "$compose_file_line" ] || fail "the project flag is added after the compose file"
ok "the project flag is part of the COMPOSE invocation used by every ps/exec"

# The container-name variables only steer `docker inspect`; without project scope the script would
# inspect an isolated stack while executing against the default one. Both must be documented.
for var in SIDECAR_COMPOSE_PROJECT SIDECAR_AGENT_CONTAINER_NAME SIDECAR_EGRESS_CONTAINER_NAME SIDECAR_COMPOSE_OVERRIDE; do
    grep -q "^#.*$var" "$SMOKE" || fail "$var is not documented in the script header"
done
ok "all four targeting variables are documented in the script header"

printf '\nAll %d checks passed.\n' "$PASSED"
