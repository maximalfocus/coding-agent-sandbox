#!/usr/bin/env bash
# scripts/check-agent-roster.sh is the gate that makes removing a bundled agent complete. What
# matters is that it fails closed in BOTH directions - a shipped agent absent from a surface it must
# appear on, and a surface still naming an agent the roster does not ship - and that a malformed
# roster is an error rather than a pass.
#
# Each mutation below reintroduces OpenCode on exactly one surface, which is what a half-done
# removal actually looks like.
#
# Runs offline: no container, no network, no credential.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHECK="$ROOT/scripts/check-agent-roster.sh"
DOC="$ROOT/docs/agent-roster.md"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

PASSED=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { PASSED=$((PASSED + 1)); }

[ -x "$CHECK" ] || fail 'scripts/check-agent-roster.sh is missing or not executable'
[ -f "$DOC" ]   || fail 'docs/agent-roster.md is missing'

# macOS ships bash 3.2. An associative array parses on 4+ and dies on the shell most users have.
if grep -Eq 'declare -A|local -A' "$CHECK"; then
    fail 'the check uses an associative array, which bash 3.2 (macOS default) cannot parse'
fi

# --- fixture: an isolated tree the mutations can edit --------------------------------------------
# It carries only the surfaces the check reads. It is deliberately NOT a git checkout, so the
# residue scan's non-git path is the one exercised here.
FIX="$TMP_DIR/tree"
SURFACES="Dockerfile entrypoint.sh mitm/entrypoint.sh mitm/sidecar-entrypoint.sh
          docs/agent-roster.md docs/pin-acceptance.md README.md PROBLEM.md
          scripts/update-agent-clis.sh scripts/update-agent-clis.ps1 scripts/verify-npm-bundle.sh"
reset_fixture() {
    rm -rf "$FIX"
    for rel in $SURFACES; do
        mkdir -p "$FIX/$(dirname "$rel")"
        cp "$ROOT/$rel" "$FIX/$rel"
    done
}
run() {  # run -> stdout+stderr to $TMP_DIR/out, returns the exit code
    set +e
    AGENT_ROSTER_ROOT="$FIX" "$CHECK" "$@" > "$TMP_DIR/out" 2>&1
    local code=$?
    set -e
    return $code
}
# Reintroduce a line into a fixture file, the way a half-reverted removal would.
append() { printf '%s\n' "$2" >> "$FIX/$1"; }

# 1. The committed tree passes, through the check's own real root.
set +e
"$CHECK" > "$TMP_DIR/out" 2>&1
code=$?
set -e
[ "$code" = "0" ] || fail "the committed tree does not pass: $(cat "$TMP_DIR/out")"
grep -q 'names exactly the agents the roster ships' "$TMP_DIR/out" || fail 'a clean run did not say so'
grep -q '0 missing, 0 residue' "$TMP_DIR/out" || fail 'a clean run reported drift'
ok

# 2. The fixture tree passes too, so every later failure is the mutation and not the fixture.
reset_fixture
run || fail "the fixture tree does not pass: $(cat "$TMP_DIR/out")"
ok

# 3. The roster is derived from the image build, not from the document. An install marked in the
#    Dockerfile with no roster row is RESIDUE - this is the "added an agent quietly" direction.
reset_fixture
append Dockerfile '# agent-cli: opencode'
run && fail 'an unrostered agent install was accepted'
grep -q 'RESIDUE' "$TMP_DIR/out" || fail 'an unrostered install was not reported as residue'
grep -q "agent-cli: opencode" "$TMP_DIR/out" || fail 'the unrostered install was not named'
ok

# 4. ...and the other way: a roster row whose install is gone is MISSING, so the document cannot
#    claim an agent the build does not install.
reset_fixture
sed -i.bak 's/^# agent-cli: pi$/# agent-cli: pi-renamed/' "$FIX/Dockerfile" && rm -f "$FIX/Dockerfile.bak"
run && fail 'a roster row with no install was accepted'
grep -q "MISSING" "$TMP_DIR/out" || fail 'a rowed-but-uninstalled agent was not reported'
grep -q "no '# agent-cli: pi' marker" "$TMP_DIR/out" || fail 'the missing marker was not named'
ok

# 5. A reintroduced build pin. The ARG alone is residue even with no install behind it, because a
#    pin is what the host updater and the pin inventory key off.
reset_fixture
append Dockerfile 'ARG OPENCODE_VERSION=1.18.25'
run && fail 'a reintroduced build pin was accepted'
grep -q 'RESIDUE.*opencode' "$TMP_DIR/out" || fail 'the reintroduced pin was not reported as residue'
grep -q 'Dockerfile' "$TMP_DIR/out" || fail 'the offending surface was not named'
ok

# 6. A reintroduced always-on egress grant, in each stack independently. A grant that survives in
#    only the mitm or the sidecar variant is still a grant, so all three are checked separately.
for stack in entrypoint.sh mitm/entrypoint.sh mitm/sidecar-entrypoint.sh; do
    reset_fixture
    perl -0pi -e 's/(BASE_DOMAINS=\()/$1"opencode.ai" /' "$FIX/$stack"
    run && fail "a reintroduced always-on host in $stack was accepted"
    grep -q "RESIDUE" "$TMP_DIR/out" || fail "the $stack grant was not reported as residue"
    grep -q "$stack" "$TMP_DIR/out" || fail "the offending stack $stack was not named"
    ok
done

# 7. An always-on host belonging to no rostered agent at all - the same failure, arriving as a new
#    entry rather than as a leftover one.
reset_fixture
perl -0pi -e 's/(BASE_DOMAINS=\()/$1"someagent.example" /' "$FIX/entrypoint.sh"
run && fail 'an unclaimed always-on host was accepted'
grep -q 'claimed by no rostered agent: someagent.example' "$TMP_DIR/out" \
    || fail 'the unclaimed host was not named'
ok

# 8. A reintroduced pin-acceptance row.
reset_fixture
perl -0pi -e 's/^(pi\.version \|)/opencode.version | OpenCode CLI | Dockerfile | ARG OPENCODE_VERSION=1.18.25 | verify-npm-bundle.sh | repo | -\n$1/m' \
    "$FIX/docs/pin-acceptance.md"
run && fail 'a reintroduced pin-acceptance row was accepted'
grep -q 'RESIDUE' "$TMP_DIR/out" || fail 'the reintroduced inventory row was not reported'
grep -q 'docs/pin-acceptance.md' "$TMP_DIR/out" || fail 'the offending inventory was not named'
ok

# 9. A reintroduced host pin-updater entry, in each shell. Parity matters: an agent removed from the
#    POSIX updater and left in the PowerShell one is still offered to half the operators.
reset_fixture
sed -i.bak 's/^KEYS="claude codex pi herdr"$/KEYS="claude codex opencode pi herdr"/' \
    "$FIX/scripts/update-agent-clis.sh" && rm -f "$FIX/scripts/update-agent-clis.sh.bak"
run && fail 'a reintroduced POSIX updater entry was accepted'
grep -q "update-agent-clis.sh.*opencode" "$TMP_DIR/out" || fail 'the POSIX updater entry was not named'
ok

reset_fixture
perl -0pi -e 's/(\@\{ Name = "pi";)/\@{ Name = "opencode"; Arg = "OPENCODE_VERSION"; Package = "opencode-ai" },\n        $1/' \
    "$FIX/scripts/update-agent-clis.ps1"
run && fail 'a reintroduced PowerShell updater entry was accepted'
grep -q "update-agent-clis.ps1.*opencode" "$TMP_DIR/out" || fail 'the PowerShell updater entry was not named'
ok

# 10. A reintroduced bundled-CLI verification invocation.
reset_fixture
perl -0pi -e 's/^(  pi --version)$/  opencode --version\n$1/m' "$FIX/scripts/verify-npm-bundle.sh"
run && fail 'a reintroduced bundled-CLI invocation was accepted'
grep -q 'RESIDUE' "$TMP_DIR/out" || fail 'the reintroduced invocation was not reported'
grep -q 'verify-npm-bundle.sh' "$TMP_DIR/out" || fail 'the offending verifier was not named'
ok

# 11. A reintroduced documentation mention. Prose does not enumerate its agents, which is exactly
#     why a retired row keeps the tokens the scan looks for.
reset_fixture
append README.md '- **OpenCode** (`opencode`) — coding agent; `opencode.ai` is allowlisted.'
run && fail 'a reintroduced documentation mention was accepted'
grep -q 'RESIDUE' "$TMP_DIR/out" || fail 'the reintroduced mention was not reported'
grep -q 'README.md' "$TMP_DIR/out" || fail 'the offending document was not named'
ok

# 12. A shipped agent that no documentation names is MISSING - an operator cannot use what the
#     product never mentions.
reset_fixture
perl -0pi -e 's/\bHerdr\b/Multiplexer/g' "$FIX/README.md"
run && fail 'an undocumented shipped agent was accepted'
grep -q "MISSING.*README" "$TMP_DIR/out" || fail 'the undocumented agent was not reported'
ok

# 13. A shipped agent missing from the bundled-CLI verifier is MISSING, not a silent pass.
reset_fixture
perl -0pi -e 's/^  pi --version\n//m' "$FIX/scripts/verify-npm-bundle.sh"
run && fail 'a shipped agent absent from the bundled-CLI check was accepted'
grep -q "MISSING.*verify-npm-bundle.sh" "$TMP_DIR/out" || fail 'the absent invocation was not reported'
ok

# 14. A shipped agent whose pin has no inventory row is MISSING. This is the CAS-R067 coupling
#     pointing the other way: a pin the updater can move must carry recorded acceptance.
reset_fixture
perl -0pi -e 's/^pi\.version \|.*\n//m' "$FIX/docs/pin-acceptance.md"
run && fail 'a shipped pin with no acceptance row was accepted'
grep -q "MISSING.*pin-acceptance" "$TMP_DIR/out" || fail 'the unmapped pin was not reported'
ok

# 15. The exemption is a stated decision, and it holds: PROBLEM.md names OpenCode in the committed
#     tree and must not fail the check.
grep -qi opencode "$ROOT/PROBLEM.md" || fail 'PROBLEM.md no longer names OpenCode, so case 15 proves nothing'
reset_fixture
run || fail 'the exempt historical record failed the residue scan'
ok

# 16. ...and removing the exemption makes the same file fail, so the exemption is load-bearing
#     rather than decorative.
reset_fixture
perl -0pi -e 's/^PROBLEM\.md \|.*\n//m' "$FIX/docs/agent-roster.md"
run && fail 'a non-exempt historical record was accepted'
grep -q 'PROBLEM.md' "$TMP_DIR/out" || fail 'the now-unexempt file was not named'
ok

# 17. A malformed roster is an error exit (2), never a pass. Fail closed on the document itself.
reset_fixture
append docs/agent-roster.md 'ignored, outside the block'
perl -0pi -e 's/^claude \| Claude Code \|.*$/claude | Claude Code | claude/m' "$FIX/docs/agent-roster.md"
run && fail 'a malformed roster row was accepted'
[ "$?" != "1" ] || fail 'a malformed roster was reported as drift rather than as an error'
grep -q '8 |-separated fields' "$TMP_DIR/out" || fail 'the malformed row was not explained'
ok

# 18. A retired row with no note is refused: "withdrawn" and "nobody wrote down why" must not be
#     indistinguishable.
reset_fixture
perl -0pi -e 's/^(opencode \| OpenCode \| opencode \| OPENCODE_VERSION \| opencode\.ai \| - \| retired \|).*$/$1 -/m' \
    "$FIX/docs/agent-roster.md"
run && fail 'a retired row with no note was accepted'
grep -q 'must state in its note' "$TMP_DIR/out" || fail 'the empty note was not explained'
ok

# 19. --json stays parseable and agrees with the human output.
reset_fixture
run --json || fail 'a clean --json run failed'
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
assert d["rosterDrift"] is False, d
assert d["missing"]==0 and d["residue"]==0, d
assert d["passed"]==len(d["checks"]), d
' "$TMP_DIR/out" || fail 'the clean --json output is not the shape it claims'
reset_fixture
append Dockerfile 'ARG OPENCODE_VERSION=1.18.25'
run --json && fail 'a --json run with residue exited 0'
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
assert d["rosterDrift"] is True, d
assert d["residue"] >= 1, d
' "$TMP_DIR/out" || fail 'the residue --json output is not the shape it claims'
ok

printf 'PASS: %d agent-roster checks\n' "$PASSED"
