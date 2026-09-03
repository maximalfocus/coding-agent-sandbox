#!/usr/bin/env bash
# scripts/check-public-surface.sh is what stops a reference to private companion material returning
# to a tracked file after this repository is public (issue #165).
#
# Two properties matter, and the second is easy to lose:
#
#   1. it catches a reference, naming the file;
#   2. IT CONTAINS NONE OF THE TERMS IT MATCHES ON. A guard that writes a forbidden term in order to
#      forbid it is an instance of the thing it forbids, and once merged it sits in a retained
#      pull-request ref that no history rewrite reaches. So the terms are hex-encoded there, and
#      asserted here rather than assumed.
#
# This file has the same obligation, so it builds its fixtures from the same encoding.
#
# Runs offline: no container, no network, no credential.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHECK="$ROOT/scripts/check-public-surface.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASSED=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { PASSED=$((PASSED + 1)); }

[ -x "$CHECK" ] || fail 'scripts/check-public-surface.sh is missing or not executable'

# The same encoded terms, decoded here so this file carries none of them in the clear either.
ENCODED=(
    "companion-repo:636f64696e672d6167656e742d73616e64626f782d707264"
    "companion-doc:505244"
    "companion-tracker:50524f47524553532e6d64"
)
decode() {
    local hex=$1 out=""
    while [ -n "$hex" ]; do out+="\x${hex:0:2}"; hex=${hex:2}; done
    printf '%b' "$out"
}

# --- 2. the guard must not be the thing it guards against -----------------------------------------
# Asserted first, because it is the property most likely to be quietly lost by a later edit that
# "simplifies" the encoding away.
for entry in "${ENCODED[@]}"; do
    term=$(decode "${entry#*:}")
    grep -qF -- "$term" "$CHECK" \
        && fail "the guard carries a forbidden term in the clear; encode it, or merging it publishes it"
    grep -qF -- "$term" "${BASH_SOURCE[0]}" \
        && fail "this test carries a forbidden term in the clear; build fixtures from the encoding"
    ok
done

# --- 1. it catches a reference, and says which file ------------------------------------------------
FIX="$TMP/tree"
reset_fixture() {
    rm -rf "$FIX"
    mkdir -p "$FIX/docs"
    printf 'nothing private here\n' > "$FIX/README.md"
    printf 'a clean document\n' > "$FIX/docs/notes.md"
}
run() {
    set +e
    PUBLIC_SURFACE_ROOT="$FIX" "$CHECK" "$@" > "$TMP/out" 2>&1
    local code=$?
    set -e
    return $code
}

reset_fixture
run || fail "a clean tree did not pass: $(cat "$TMP/out")"
grep -q 'no tracked file names private companion material' "$TMP/out" || fail 'a clean run did not say so'
ok

# The scope limit must be stated on every clean run. A guard whose reach is misread as a clearance is
# worse than none, because it is what someone trusts instead of looking.
grep -q 'commit and pull-request text are NOT covered' "$TMP/out" \
    || fail 'the clean run did not state what it cannot reach'
ok

# One case per term, each built from the encoding rather than written out.
for entry in "${ENCODED[@]}"; do
    label=${entry%%:*}
    term=$(decode "${entry#*:}")
    reset_fixture
    printf 'see %s for the rationale\n' "$term" > "$FIX/docs/notes.md"
    run && fail "a tracked file naming '$label' was accepted"
    grep -q 'docs/notes.md' "$TMP/out" || fail "the offending file was not named for '$label'"
    grep -q "$label" "$TMP/out" || fail "the matched term was not identified for '$label'"
    ok
done

# A reference anywhere in the tree counts, not only under docs/.
reset_fixture
term=$(decode "${ENCODED[0]#*:}")
printf '# %s\n' "$term" > "$FIX/Makefile"
run && fail 'a reference outside docs/ was accepted'
grep -q 'Makefile' "$TMP/out" || fail 'the offending file outside docs/ was not named'
ok

# --- the real tree, which is the claim that matters ------------------------------------------------
set +e
"$CHECK" > "$TMP/out" 2>&1
code=$?
set -e
[ "$code" = "0" ] || fail "the committed tree names private companion material: $(cat "$TMP/out")"
ok

# --json stays parseable and agrees with the human output.
reset_fixture
run --json || fail 'a clean --json run failed'
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
assert d["clean"] is True, d
assert d["hits"] == [], d
assert "cannot" in d["scope"] or "out of reach" in d["scope"], d
' "$TMP/out" || fail 'the clean --json output is not the shape it claims'
reset_fixture
printf 'see %s\n' "$(decode "${ENCODED[0]#*:}")" > "$FIX/docs/notes.md"
run --json && fail 'a --json run with a hit exited 0'
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
assert d["clean"] is False, d
assert len(d["hits"]) >= 1, d
assert d["hits"][0]["file"] == "docs/notes.md", d
' "$TMP/out" || fail 'the hit --json output is not the shape it claims'
ok

printf 'PASS: %d public-surface checks\n' "$PASSED"
