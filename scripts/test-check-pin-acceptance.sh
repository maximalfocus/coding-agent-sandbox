#!/usr/bin/env bash
# scripts/check-pin-acceptance.sh is the gate that makes a pin move state its cost. What matters is
# that it fails closed in BOTH directions - a pin baked into the Dockerfile with no inventory row,
# and an inventory row whose pin has moved on - and that it never lets a malformed record through as
# a pass.
#
# Runs offline: no container, no network, no credential.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHECK="$ROOT/scripts/check-pin-acceptance.sh"
DOC="$ROOT/docs/pin-acceptance.md"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

PASSED=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { PASSED=$((PASSED + 1)); }

[ -x "$CHECK" ] || fail 'scripts/check-pin-acceptance.sh is missing or not executable'
[ -f "$DOC" ]   || fail 'docs/pin-acceptance.md is missing'

# macOS ships bash 3.2. An associative array parses on 4+ and dies on the shell most users have.
if grep -Eq 'declare -A|local -A' "$CHECK"; then
    fail 'the check uses an associative array, which bash 3.2 (macOS default) cannot parse'
fi

# --- fixture: an isolated tree the mutations can edit --------------------------------------------
FIX="$TMP_DIR/tree"
mkdir -p "$FIX/docs" "$FIX/mitm"
# The coupled file belongs in the fixture: the inventory declares a literal that must live in
# mitm/filter_addon.py, and a declaration whose file is absent is now a fail-closed error rather
# than a silent skip. A fixture without it would be testing a tree the product never ships.
reset_fixture() {
    cp "$ROOT/Dockerfile" "$FIX/Dockerfile"
    cp "$DOC" "$FIX/docs/pin-acceptance.md"
    cp "$ROOT/mitm/filter_addon.py" "$FIX/mitm/filter_addon.py"
}
run() {  # run -> stdout+stderr to $TMP_DIR/out, returns the exit code
    set +e
    PIN_ACCEPTANCE_ROOT="$FIX" "$CHECK" "$@" > "$TMP_DIR/out" 2>&1
    local code=$?
    set -e
    return $code
}

# 1. The committed tree passes: every baked pin is mapped, every recorded pin is intact.
reset_fixture
run || fail "the committed tree does not pass: $(cat "$TMP_DIR/out")"
grep -q 'every baked pin is mapped' "$TMP_DIR/out" || fail 'a clean run did not say so'
grep -q '0 drifted' "$TMP_DIR/out" || fail 'a clean run reported drift'
ok

# 2. Every pin the real Dockerfile bakes is mapped. This is the coverage claim itself, asserted
#    against the real file rather than the fixture, so a new pin added later fails here.
run || fail 'the real tree is not fully mapped'
ok

# 3. A pin added to the Dockerfile with no inventory row is DRIFTED, not a pass. This is the
#    hand-edit case: the mapping is mandatory, so an unrecorded pin cannot slip through.
reset_fixture
printf 'ARG SOMETHING_NEW_VERSION=1.2.3\n' >> "$FIX/Dockerfile"
run && fail 'an unmapped pin was accepted'
grep -q 'unmapped:SOMETHING_NEW_VERSION' "$TMP_DIR/out" || fail 'the unmapped pin was not named'
grep -q 'no row in docs/pin-acceptance.md' "$TMP_DIR/out" || fail 'the reason was not stated'
ok

# 4. Every enumerated shape is covered, not just ARG lines. A digest-pinned FROM and the vendored
#    client's literal checksum are pins too, and an inventory that missed them would look clean.
reset_fixture
printf 'FROM scratch@sha256:%s\n' "$(printf '0%.0s' $(seq 64))" >> "$FIX/Dockerfile"
run && fail 'an unmapped FROM digest was accepted'
ok
reset_fixture
printf 'RUN echo "%s  /usr/local/share/other" | sha256sum -c -\n' \
    "$(printf 'a%.0s' $(seq 64))" >> "$FIX/Dockerfile"
run && fail 'an unmapped vendored-artifact checksum was accepted'
ok

# 5. Moving a pin by hand without updating the inventory fails from BOTH directions: the new value
#    is unmapped and the recorded value is gone. Either alone would be enough; both is the proof
#    that neither check is carrying the other.
reset_fixture
python3 - "$FIX/Dockerfile" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read().replace("ARG BUN_VERSION=1.3.11", "ARG BUN_VERSION=9.9.9")
open(p, "w").write(t)
PY
run && fail 'a hand-moved pin was accepted'
grep -q 'unmapped:BUN_VERSION' "$TMP_DIR/out" || fail 'the new value was not reported as unmapped'
grep -q 'recorded pin is absent from Dockerfile' "$TMP_DIR/out" \
    || fail 'the stale inventory row was not reported'
ok

# 6. A row naming a file that does not exist is DRIFTED, not silently skipped.
reset_fixture
python3 - "$FIX/docs/pin-acceptance.md" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read().replace("bun.version | Bun | Dockerfile |", "bun.version | Bun | NoSuchFile |")
open(p, "w").write(t)
PY
run && fail 'a row pointing at a missing file was accepted'
grep -q 'recorded file is missing' "$TMP_DIR/out" || fail 'the missing file was not named'
ok

# 7. Malformed records fail closed with exit 2 - never a pass, and never exit 1, which would read
#    as ordinary drift.
malform() {  # malform SED_REPLACEMENT EXPECTED_MESSAGE
    reset_fixture
    python3 - "$FIX/docs/pin-acceptance.md" "$1" <<'PY'
import sys
p, repl = sys.argv[1], sys.argv[2]
old, new = repl.split("=>", 1)
t = open(p).read()
assert old in t, "fixture line not found: " + old
open(p, "w").write(t.replace(old, new, 1))
PY
    local code=0
    run || code=$?
    [ "$code" = "2" ] || fail "expected exit 2 for '$2', got $code: $(cat "$TMP_DIR/out")"
    grep -q "$2" "$TMP_DIR/out" || fail "expected message '$2', got: $(cat "$TMP_DIR/out")"
    ok
}

# A record with the wrong field count must not silently collapse into the last variable.
malform 'pi.version | Pi CLI | Dockerfile | ARG PI_VERSION=0.84.4 | verify-npm-bundle.sh | repo | -=>pi.version | Pi CLI | Dockerfile | ARG PI_VERSION=0.84.4 | verify-npm-bundle.sh | repo' \
        'must have 7 |-separated fields'
# "nothing depends on this" and "nobody looked" must not be indistinguishable.
malform 'bun.version | Bun | Dockerfile | ARG BUN_VERSION=1.3.11 | verify-npm-bundle.sh | repo | -=>bun.version | Bun | Dockerfile | ARG BUN_VERSION=1.3.11 | none | none | -' \
        'must state in its note why nothing depends on it'
# The rerun class is derived from the checks listed, so it cannot be decoration.
malform 'pi.version | Pi CLI | Dockerfile | ARG PI_VERSION=0.84.4 | verify-npm-bundle.sh | repo | -=>pi.version | Pi CLI | Dockerfile | ARG PI_VERSION=0.84.4 | verify-npm-bundle.sh | operator | -' \
        'declares rerun=operator but its checks imply repo'
malform 'herdr.version | Terminal multiplexer | Dockerfile | ARG HERDR_VERSION=0.8.2 | test-osc52-boundary.sh,operator:herdr-selection-copy | mixed |=>herdr.version | Terminal multiplexer | Dockerfile | ARG HERDR_VERSION=0.8.2 | test-osc52-boundary.sh,operator:herdr-selection-copy | repo |' \
        'declares rerun=repo but its checks imply mixed'
# A duplicate id would let one row shadow another.
malform 'bun.version | Bun |=>pi.version | Bun |' 'duplicate pin id'

# 8. A missing inventory is exit 2, never a pass. An absent mapping must not read as "no pins".
reset_fixture
rm "$FIX/docs/pin-acceptance.md"
code=0; run || code=$?
[ "$code" = "2" ] || fail "a missing inventory returned $code, expected 2"
ok

# 9. Verification that needs an operator or another host class is UNEVALUATED, never PASS. This is
#    the distinction the whole inventory exists to keep: a pin can be intact and its evidence stale.
reset_fixture
run || fail 'clean run failed'
grep -qE '^UNEVALUATED +herdr\.version' "$TMP_DIR/out" \
    || fail 'the Herdr pin, whose selection check is operator-only, was not UNEVALUATED'
grep -q 'operator:herdr-selection-copy' "$TMP_DIR/out" \
    || fail 'the operator-only check was not named'
grep -qE '^UNEVALUATED +herdr\.sha256\.amd64' "$TMP_DIR/out" \
    || fail 'a checksum needing another host class was not UNEVALUATED'
# A mixed row must name only the part this checkout cannot produce.
if grep -E '^UNEVALUATED +herdr\.version' "$TMP_DIR/out" | grep -q 'test-osc52-boundary.sh'; then
    fail 'a re-runnable check was listed among the ones needing an operator'
fi
ok

# 10. --arg resolves a pin to its row for the updater, and exits 3 - not 0, not 2 - when there is
#     no row. The updater keys its refusal on that code.
reset_fixture
run --arg HERDR_VERSION || fail '--arg failed for a mapped pin'
grep -q 'operator:herdr-selection-copy' "$TMP_DIR/out" || fail '--arg did not return the row'
code=0; run --arg NO_SUCH_VERSION || code=$?
[ "$code" = "3" ] || fail "--arg for an unmapped pin returned $code, expected 3"
ok

# 11. --json stays parseable and agrees with the human output.
reset_fixture
run --json || fail '--json failed'
python3 - "$TMP_DIR/out" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["drifted"] == 0, d["drifted"]
assert d["pinDrift"] is False
assert d["passed"] + d["unevaluated"] == len(d["checks"]), d
assert any(c["pin"] == "herdr.version" and c["status"] == "UNEVALUATED" for c in d["checks"])
PY
ok


# --- couplings: the same fact in two files -------------------------------------------------------
# The pin/coupled-literal relationship used to be a `note`, and a note is not a gate. #137 moved the
# Claude pin and left mitm/filter_addon.py's refresh User-Agent behind; every check passed. These
# cases are that episode, driven from both sides.
[ -f "$ROOT/mitm/filter_addon.py" ] || fail 'mitm/filter_addon.py is missing - the coupling cases prove nothing'
# Rewrite the one coupling row; the block is `|`-separated so sed's delimiter must not be `|`.
set_coupling() { # set_coupling ROW
    python3 - "$FIX/docs/pin-acceptance.md" "$1" <<'COUPLE'
import sys
path, row = sys.argv[1], sys.argv[2]
text = open(path, encoding='utf-8').read()
old = "claude-code.version | mitm/filter_addon.py | claude-cli/{pin} (external, cli)"
assert text.count(old) == 1, "the coupling row moved; this case no longer tests what it says"
open(path, 'w', encoding='utf-8').write(text.replace(old, row))
COUPLE
}

# The committed tree agrees with itself.
reset_fixture
run || fail "the committed tree fails its own coupling check: $(cat "$TMP_DIR/out")"
grep -q 'coupled literal agrees' "$TMP_DIR/out" || fail 'the coupling was not evaluated at all'
ok

# Direction 1 - #137 exactly: the pin moves, the coupled literal is left behind.
reset_fixture
sed -i.bak 's/^ARG CLAUDE_CODE_VERSION=.*/ARG CLAUDE_CODE_VERSION=9.9.9/' "$FIX/Dockerfile"
sed -i.bak 's/ARG CLAUDE_CODE_VERSION=[^ ]*/ARG CLAUDE_CODE_VERSION=9.9.9/' "$FIX/docs/pin-acceptance.md"
rm -f "$FIX/Dockerfile.bak" "$FIX/docs/pin-acceptance.md.bak"
run && fail 'a coupled literal left behind was accepted'
grep -q 'DRIFTED' "$TMP_DIR/out" || fail 'the stale coupled literal was not reported as drift'
grep -q "mitm/filter_addon.py does not carry 'claude-cli/9.9.9 (external, cli)'" "$TMP_DIR/out" \
    || fail "the drift did not name the file and the literal it expected: $(cat "$TMP_DIR/out")"
ok

# Direction 2 - the mirror image: the coupled literal moves alone. One assertion catches both,
# because rendering from the pin's CURRENT value makes either mismatch equally absent.
reset_fixture
python3 - "$FIX/mitm/filter_addon.py" <<'BUMP'
import re, sys
path = sys.argv[1]
text = open(path, encoding='utf-8').read()
new = re.sub(r'claude-cli/[0-9][^ ]* \(external, cli\)', 'claude-cli/9.9.9 (external, cli)', text)
assert new != text, 'the User-Agent literal moved; this case no longer tests what it says'
open(path, 'w', encoding='utf-8').write(new)
BUMP
run && fail 'a coupled literal moved alone was accepted'
grep -q 'DRIFTED' "$TMP_DIR/out" || fail 'the lone coupled move was not reported as drift'
ok

# A declaration that cannot be evaluated is an ERROR (2), never a silent skip: a coupling nobody can
# check is indistinguishable from one nobody wrote.
reset_fixture; set_coupling 'claude-code.version | mitm/filter_addon.py'
run && fail 'a two-field coupling was accepted'
grep -q '3 |-separated fields' "$TMP_DIR/out" || fail 'the malformed coupling was not explained'
ok
reset_fixture; set_coupling 'nosuch.pin | mitm/filter_addon.py | claude-cli/{pin} (external, cli)'
run && fail 'a coupling naming an unknown pin was accepted'
grep -q "names pin 'nosuch.pin'" "$TMP_DIR/out" || fail 'the unknown pin was not named'
ok
reset_fixture; set_coupling 'claude-code.version | mitm/nope.py | claude-cli/{pin} (external, cli)'
run && fail 'a coupling naming a missing file was accepted'
grep -q 'names a file that does not exist' "$TMP_DIR/out" || fail 'the missing file was not named'
ok
reset_fixture; set_coupling 'claude-code.version | mitm/filter_addon.py | claude-cli/fixed (external, cli)'
run && fail 'a coupling with no {pin} was accepted'
grep -q 'tracks nothing' "$TMP_DIR/out" || fail 'a literal that tracks nothing was not refused'
ok

# --coupled is what the host updater reads, so it must answer from the SAME parse the check uses.
reset_fixture
run --coupled CLAUDE_CODE_VERSION || fail '--coupled failed for a coupled pin'
grep -q 'mitm/filter_addon.py' "$TMP_DIR/out" || fail '--coupled did not name the coupled file'
grep -q '{pin}' "$TMP_DIR/out" \
    || fail '--coupled rendered the literal; the caller needs the template to render both values'
ok
run --coupled CODEX_VERSION || fail '--coupled must exit 0 for a pin that simply has no coupling'
[ ! -s "$TMP_DIR/out" ] || fail "--coupled printed something for an uncoupled pin: $(cat "$TMP_DIR/out")"
ok
run --coupled NOT_A_REAL_ARG && fail '--coupled accepted an ARG with no inventory row'
[ "$?" != "1" ] || fail '--coupled reported a missing row as drift rather than as exit 3'
ok

printf 'PASS: the pin-acceptance inventory is enforced in both directions (%d checks)\n' "$PASSED"
