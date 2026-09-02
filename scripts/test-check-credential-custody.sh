#!/usr/bin/env bash
# scripts/check-credential-custody.sh is what stops docs/credential-custody.md becoming a
# reassurance with nothing behind it. What matters is that it fails closed in both directions - a
# rostered agent with no row or a command missing from one shell, and a row claiming a tier the
# Compose wiring contradicts - and that a malformed table is an error rather than a pass.
#
# The tier mutations below are the important ones: a table that can drift from the configuration is
# worse than no table, because an operator would act on it.
#
# Runs offline: no container, no network, no credential.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHECK="$ROOT/scripts/check-credential-custody.sh"
DOC="$ROOT/docs/credential-custody.md"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

PASSED=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { PASSED=$((PASSED + 1)); }

[ -x "$CHECK" ] || fail 'scripts/check-credential-custody.sh is missing or not executable'
[ -f "$DOC" ]   || fail 'docs/credential-custody.md is missing'

# macOS ships bash 3.2. An associative array parses on 4+ and dies on the shell most users have.
if grep -Eq 'declare -A|local -A' "$CHECK"; then
    fail 'the check uses an associative array, which bash 3.2 (macOS default) cannot parse'
fi

FIX="$TMP_DIR/tree"
SURFACES="docs/credential-custody.md docs/agent-roster.md docker-compose.yml docker-compose.sidecar.yml
          scripts/auth/claude-login.sh scripts/auth/claude-login.ps1
          scripts/auth/codex-login.sh scripts/auth/codex-login.ps1
          scripts/auth/gh-login.sh scripts/auth/gh-login.ps1
          scripts/auth/deepseek-key.sh scripts/auth/deepseek-key.ps1"
reset_fixture() {
    rm -rf "$FIX"
    for rel in $SURFACES; do
        mkdir -p "$FIX/$(dirname "$rel")"
        cp "$ROOT/$rel" "$FIX/$rel"
    done
}
run() {
    set +e
    CREDENTIAL_CUSTODY_ROOT="$FIX" "$CHECK" "$@" > "$TMP_DIR/out" 2>&1
    local code=$?
    set -e
    return $code
}
# Rewrite one field of one custody row, the way a stale edit would.
set_field() { # set_field ID FIELD_INDEX VALUE
    perl -i -pe '
        BEGIN { ($id, $idx, $val) = @ARGV; splice(@ARGV, 0, 3) }
        if (/^\Q$id\E \|/) {
            chomp;
            my @f = split /\|/, $_, -1;
            $f[$idx] = " $val ";
            $_ = join("|", @f) . "\n";
        }
    ' "$1" "$2" "$3" "$FIX/docs/credential-custody.md"
}

# 1. The committed tree passes, through the check's own real root.
set +e; "$CHECK" > "$TMP_DIR/out" 2>&1; code=$?; set -e
[ "$code" = "0" ] || fail "the committed tree does not pass: $(cat "$TMP_DIR/out")"
grep -q 'every custody claim matches the shipped configuration' "$TMP_DIR/out" || fail 'a clean run did not say so'
ok

# 2. The fixture tree passes too, so every later failure is the mutation and not the fixture.
reset_fixture
run || fail "the fixture tree does not pass: $(cat "$TMP_DIR/out")"
ok

# 3. THE tier failure: a credential the agent can read, described as one it cannot. The compose file
#    is authority; the table is the claim.
reset_fixture
set_field codex 6 sidecar-owned
run && fail 'a tier contradicted by the compose wiring was accepted'
grep -q 'MISMATCH' "$TMP_DIR/out" || fail 'the contradicted tier was not reported as a mismatch'
grep -q "mounts 'claude-codex' into the agent" "$TMP_DIR/out" || fail 'the mismatch did not name the evidence'
ok

# 4. ...and the mirror: a sidecar-held key described as agent-readable. Overstating the exposure is
#    also a false statement, and it would send an operator chasing a leak that is not there.
reset_fixture
set_field pi 6 agent-readable
run && fail 'an overstated tier was accepted'
grep -q "no agent service mounts 'deepseek-secret'" "$TMP_DIR/out" || fail 'the overstated tier was not named'
ok

# 5. A row whose stated path is not where the volume is actually mounted.
reset_fixture
set_field gh 5 /home/node/.gh-somewhere-else
run && fail 'a path contradicted by the compose wiring was accepted'
grep -q "is mounted at '/home/node/.config/gh'" "$TMP_DIR/out" || fail 'the real mount point was not named'
ok

# 6. A rostered agent with no custody row: its tier would simply be unstated.
reset_fixture
perl -0pi -e 's/^codex \| Codex \|.*\n//m' "$FIX/docs/credential-custody.md"
run && fail 'a rostered agent with no custody row was accepted'
grep -q "MISSING" "$TMP_DIR/out" || fail 'the missing row was not reported'
grep -q "'codex' is a shipped agent with no custody row" "$TMP_DIR/out" || fail 'the missing agent was not named'
ok

# 7. A sign-in command present in one shell and absent from the other. Half the operators would
#    have no host-side path, which is the state Claude was in before this issue.
for ext in sh ps1; do
    reset_fixture
    rm -f "$FIX/scripts/auth/claude-login.$ext"
    run && fail "a command missing its .$ext twin was accepted"
    grep -q "no host-side sign-in for every supported shell: claude-login.$ext" "$TMP_DIR/out" \
        || fail "the missing claude-login.$ext was not named"
    ok
done

# 8. A command that stops reading its custody row would be free to print a stale tier. The table is
#    the single source of truth precisely so the two cannot disagree.
reset_fixture
perl -0pi -e 's/auth_row codex/auth_row somethingelse/' "$FIX/scripts/auth/codex-login.sh"
run && fail 'a command that no longer reads its row was accepted'
grep -q 'does not read its custody row' "$TMP_DIR/out" || fail 'the drifting disclosure was not reported'
ok

# 9. A malformed row is an error exit (2), never a pass.
reset_fixture
perl -0pi -e 's/^gh \| GitHub CLI \|.*$/gh | GitHub CLI | gh-login/m' "$FIX/docs/credential-custody.md"
run && fail 'a malformed custody row was accepted'
[ "$?" != "1" ] || fail 'a malformed table was reported as drift rather than as an error'
grep -q '9 |-separated fields' "$TMP_DIR/out" || fail 'the malformed row was not explained'
ok

# 10. A row with no note is refused: "no isolation exists" and "nobody wrote it down" must not be
#     indistinguishable. This is the same rule docs/pin-acceptance.md applies to verification=none.
reset_fixture
set_field codex 8 -
run && fail 'a custody row with no note was accepted'
grep -q 'must carry a note' "$TMP_DIR/out" || fail 'the empty note was not explained'
ok

# 11. An unknown tier or isolation value fails closed rather than passing through unrecognised.
reset_fixture
set_field codex 6 probably-fine
run && fail 'an unknown tier was accepted'
grep -q "unknown tier 'probably-fine'" "$TMP_DIR/out" || fail 'the unknown tier was not named'
ok
reset_fixture
set_field codex 7 mostly
run && fail 'an unknown isolation state was accepted'
grep -q "unknown isolation 'mostly'" "$TMP_DIR/out" || fail 'the unknown isolation was not named'
ok

# 12. A tier=none row that nonetheless declares a credential. "Needs no credential" and "has one we
#     did not classify" must not be expressible as the same row.
reset_fixture
set_field herdr 4 claude-config
set_field herdr 5 /home/node/.claude
run && fail 'a tier=none row declaring a credential was accepted'
grep -q 'claims tier=none' "$TMP_DIR/out" || fail 'the contradictory none row was not explained'
ok

# 13. The agent boundary must be derived, not assumed: a service name that no longer matches the
#     compose file is an error, so a silent parse failure cannot turn every tier check green.
reset_fixture
perl -0pi -e 's/\| claude-sandbox \|/| claude-sandbox-typo |/' "$FIX/docs/credential-custody.md"
run && fail 'an agent service that does not exist was accepted'
grep -q 'declares no named-volume mount' "$TMP_DIR/out" || fail 'the unmatched service was not reported'
ok

# 14. --json stays parseable and agrees with the human output.
reset_fixture
run --json || fail 'a clean --json run failed'
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
assert d["custodyDrift"] is False, d
assert d["missing"]==0 and d["mismatched"]==0, d
assert d["passed"]==len(d["checks"]), d
' "$TMP_DIR/out" || fail 'the clean --json output is not the shape it claims'
reset_fixture
set_field codex 6 sidecar-owned
run --json && fail 'a --json run with a mismatch exited 0'
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
assert d["custodyDrift"] is True, d
assert d["mismatched"] >= 1, d
' "$TMP_DIR/out" || fail 'the mismatch --json output is not the shape it claims'
ok

printf 'PASS: %d credential-custody checks\n' "$PASSED"
