#!/usr/bin/env bash
# Deterministic coverage for issue #93's stack-isolation check.
# Starts no container: the classifier is driven with fixture volume lists and fixture compose files.
#
# The defect this holds shut is documentation drifting from the compose file. #69 proved isolation
# once, by hand, with the volume variables set externally; nothing then held it, and its own
# regression suite never mentioned a volume. So the proof expired silently and the header kept
# listing four of the nine variables an operator needs — the four it omitted being the ones that
# protect a login. Both halves are asserted here: the check itself, and that the instructions stay
# complete as the compose file changes.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHECK="$ROOT/scripts/check-stack-isolation.sh"
SMOKE="$ROOT/sidecar-smoketest.sh"
COMPOSE="$ROOT/docker-compose.sidecar.yml"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASSED=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { PASSED=$((PASSED + 1)); printf 'ok  %s\n' "$*"; }

[ -x "$CHECK" ] || fail "the isolation check is missing or not executable"
bash -n "$CHECK" || fail "the isolation check does not parse"
bash -n "$SMOKE" || fail "the smoke test does not parse"
ok "both scripts are present and parse"

run() { printf '%s\n' "$1" | "$CHECK" "${2:-$COMPOSE}"; }

# --- the real compose file --------------------------------------------------
defaults=$(sed -nE 's/^[[:space:]]*name:[[:space:]]*"?\$\{[A-Za-z_][A-Za-z0-9_]*:-([^}]+)\}"?.*/\1/p' "$COMPOSE")
[ -n "$defaults" ] || fail "no overridable volumes found in the sidecar compose file"
count=$(printf '%s\n' "$defaults" | grep -c .)
ok "the sidecar compose file declares $count overridable volume names"

# A fully isolated stack is clean.
out=$(run "$(printf 'idd93-config\nidd93-secret\nidd93-mitm-ca')") && rc=0 || rc=$?
[ -z "$out" ] || fail "a fully scoped stack reported '$out'"
[ "$rc" -eq 0 ] || fail "a fully scoped stack exited $rc"
ok "a fully scoped stack is reported clean, exit 0"

# The exact #93 case: project scoped, volumes not.
out=$(run "$(printf 'coding-agent-sandbox-config\ncoding-agent-sandbox-mitm-ca')") && rc=0 || rc=$?
[ "$rc" -eq 1 ] || fail "an unscoped stack exited $rc, expected 1"
grep -q 'coding-agent-sandbox-config' <<<"$out" || fail "the operator's config volume was not reported"
ok "the operator's config volume is reported, exit 1"

# Every single default must be caught on its own — not just the one that happened to be tested.
while IFS= read -r def; do
    [ -n "$def" ] || continue
    out=$(run "$def") && rc=0 || rc=$?
    [ "$rc" -eq 1 ] || fail "'$def' was not reported as shared"
    [ "$out" = "$def" ] || fail "'$def' reported as '$out'"
done <<<"$defaults"
ok "every overridable volume in the compose file is caught individually"

# A partial override is the likeliest real mistake, and must not pass.
out=$(run "$(printf 'idd93-config\ncoding-agent-sandbox-secret\nidd93-mitm-ca')") && rc=0 || rc=$?
[ "$rc" -eq 1 ] || fail "a partially scoped stack passed"
[ "$out" = "coding-agent-sandbox-secret" ] || fail "partial override reported '$out'"
ok "a partially scoped stack is caught, naming only the volume that is shared"

# --- it must not over-report ------------------------------------------------
out=$(run "$(printf 'coding-agent-sandbox-config-backup\nmy-coding-agent-sandbox-config')") && rc=0 || rc=$?
[ "$rc" -eq 0 ] || fail "names merely containing a default were reported: '$out'"
ok "a volume whose name merely contains a default is not reported"

out=$(run "") && rc=0 || rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] || fail "an empty mount list did not come back clean"
ok "an empty mount list is clean"

# --- it is driven by the compose file, not a list kept in the script --------
# The point of reading defaults from compose is that a volume added there is covered the same day.
cat > "$TMP/added.yml" <<'YML'
volumes:
  claude-config:
    name: "${SIDECAR_CONFIG_VOLUME_NAME:-coding-agent-sandbox-config}"
  brand-new:
    name: "${BRAND_NEW_VOLUME_NAME:-coding-agent-sandbox-brand-new}"
YML
out=$(run "coding-agent-sandbox-brand-new" "$TMP/added.yml") && rc=0 || rc=$?
[ "$rc" -eq 1 ] || fail "a volume added to the compose file was not picked up"
[ "$out" = "coding-agent-sandbox-brand-new" ] || fail "new volume reported as '$out'"
grep -q 'brand-new' "$CHECK" && fail "the check hardcodes volume names"
ok "a volume added to the compose file is covered without touching the check"

# A compose file with nothing overridable is an error, not a silent pass.
printf 'volumes:\n  a:\n    name: fixed-name\n' > "$TMP/fixed.yml"
run "fixed-name" "$TMP/fixed.yml" >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" -eq 2 ] || fail "a compose file with no overridable names exited $rc, expected 2"
ok "a compose file with no overridable names is an error, not a pass"

printf 'x\n' | "$CHECK" "$TMP/nope.yml" >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" -eq 2 ] || fail "an unreadable compose file exited $rc, expected 2"
ok "an unreadable compose file is an error, not a pass"

# --- the instructions must stay complete ------------------------------------
# This is the assertion that would have caught #93. The header is where an operator learns to isolate
# a stack; if it names fewer variables than the compose file provides, following it is unsafe.
header=$(sed -n '1,/^set -/p' "$SMOKE")
missing=""
while IFS= read -r var; do
    [ -n "$var" ] || continue
    grep -q "$var" <<<"$header" || missing="$missing $var"
done < <(sed -nE 's/^[[:space:]]*name:[[:space:]]*"?\$\{([A-Za-z_][A-Za-z0-9_]*):-[^}]+\}"?.*/\1/p' "$COMPOSE")
[ -z "$missing" ] || fail "the smoke test header does not document:$missing"
ok "the header documents every volume variable the compose file provides"

# The worked example has to be copyable as-is, not a fragment that leaves volumes shared.
example=$(awk '/SIDECAR_COMPOSE_PROJECT=/,/sidecar-smoketest.sh$/' <<<"$header")
[ -n "$example" ] || fail "no worked example found in the header"
while IFS= read -r var; do
    [ -n "$var" ] || continue
    grep -q "$var=" <<<"$example" || fail "the worked example omits $var — copying it leaves a volume shared"
done < <(sed -nE 's/^[[:space:]]*name:[[:space:]]*"?\$\{([A-Za-z_][A-Za-z0-9_]*):-[^}]+\}"?.*/\1/p' "$COMPOSE")
ok "the worked example sets every volume variable, so copying it is safe"

# --- the smoke test wires it in ---------------------------------------------
grep -q 'check-stack-isolation.sh' "$SMOKE" || fail "the smoke test does not run the isolation check"
ok "the smoke test runs the isolation check"

block=$(awk '/^# 0\./,/^echo "Structural guarantees/' "$SMOKE")
# Assert the guard expression itself, not that the variable is mentioned: the failure messages name
# the project too, so a mention survives replacing the condition with `true`.
grep -qE '^if \[ -n "\$\{SIDECAR_COMPOSE_PROJECT:-\}" \]; then$' <<<"$block" \
    || fail "the check is not gated on a declared project"
ok "the check runs only when a project is declared, so default runs are unaffected"

# Prove the gate holds by running the real script with no project set. It must not reach the check —
# the daemon is unreachable in this suite, so a run that got that far would fail differently.
if [ -z "${SIDECAR_COMPOSE_PROJECT:-}" ]; then
    out=$(env -u SIDECAR_COMPOSE_PROJECT PATH=/nonexistent sh "$SMOKE" 2>&1 || true)
    grep -q 'Stack isolation' <<<"$out" && fail "the isolation section ran with no project set"
    ok "with no project set the isolation section does not run at all"
fi

grep -qE '^[[:space:]]*no ' <<<"$block" || fail "a shared operator volume does not fail the smoke test"
ok "a shared operator volume fails the smoke test rather than warning"

grep -q 'SIDECAR_ALLOW_SHARED_VOLUMES' <<<"$block" || fail "there is no documented opt-out"
grep -q 'SIDECAR_ALLOW_SHARED_VOLUMES' <<<"$header" || fail "the opt-out is not documented in the header"
ok "the opt-out exists and is documented"

# The isolation verdict must be reported before anything reads or writes the credential file.
iso_line=$(grep -n 'check-stack-isolation.sh' "$SMOKE" | head -1 | cut -d: -f1)
cred_line=$(grep -n 'credentials.json' "$SMOKE" | head -1 | cut -d: -f1)
[ -n "$iso_line" ] && [ -n "$cred_line" ] || fail "could not locate both the isolation and credential steps"
[ "$iso_line" -lt "$cred_line" ] || fail "isolation is checked after the credential file is read"
ok "isolation is established before the credential file is touched"

printf '\nAll %d checks passed.\n' "$PASSED"
