#!/usr/bin/env bash
# scripts/check-allowlist-parity.sh compares one admission policy across the paths that implement
# it. The shipped tree passes by construction, so what the check is worth is what these mutations
# are worth: each takes the real tree, makes one change a careless edit could make, and requires the
# check to report it.
#
# Most cases point the check at an image name that does not exist, so tinyproxy is UNEVALUATED and
# the case runs in a second. That is also one of the assertions: an engine that could not be
# executed must never be reported as a pass. One case runs the real engines when the image is
# present, because a check that only ever ran against a stub would be exactly the failure
# `CAS-R183` exists to prevent.
#
# Runs offline apart from that one case: no network, no credential.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHECK="$ROOT/scripts/check-allowlist-parity.sh"
DOC="$ROOT/docs/allowlist-decisions.md"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

PASSED=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { PASSED=$((PASSED + 1)); printf 'PASS: %s\n' "$*"; }

[ -x "$CHECK" ] || fail 'scripts/check-allowlist-parity.sh is missing or not executable'
[ -f "$DOC" ]   || fail 'docs/allowlist-decisions.md is missing'

if grep -Eq 'declare -A|local -A' "$CHECK"; then
    fail 'the check uses an associative array, which bash 3.2 (macOS default) cannot parse'
fi

FIX="$TMP_DIR/tree"
reset_fixture() {
    rm -rf "$FIX"
    mkdir -p "$FIX/mitm" "$FIX/scripts/network" "$FIX/docs"
    cp "$ROOT/entrypoint.sh"                   "$FIX/entrypoint.sh"
    cp "$ROOT/mitm/entrypoint.sh"              "$FIX/mitm/entrypoint.sh"
    cp "$ROOT/mitm/sidecar-entrypoint.sh"      "$FIX/mitm/sidecar-entrypoint.sh"
    cp "$ROOT/mitm/filter_addon.py"            "$FIX/mitm/filter_addon.py"
    cp "$ROOT/scripts/network/allow-domain.sh" "$FIX/scripts/network/allow-domain.sh"
    cp "$ROOT/scripts/network/allow-domain.ps1" "$FIX/scripts/network/allow-domain.ps1"
    cp "$DOC"                                  "$FIX/docs/allowlist-decisions.md"
}

# NO_IMAGE keeps the fast cases off the container path; the check must then say UNEVALUATED.
NO_IMAGE=coding-agent-sandbox:absent-on-purpose-$$

run() {  # run [image] -> output in $TMP_DIR/out, returns the check's exit code
    set +e
    ALLOWLIST_PARITY_ROOT="$FIX" \
    ALLOWLIST_PARITY_DOC="$FIX/docs/allowlist-decisions.md" \
    ALLOWLIST_PARITY_IMAGE="${1:-$NO_IMAGE}" \
        bash "$CHECK" > "$TMP_DIR/out" 2>&1
    local rc=$?
    set -e
    return $rc
}

expect_rc() {  # expect_rc <wanted> <description> [image]
    local rc=0
    run "${3:-}" || rc=$?
    if [ "$rc" -ne "$1" ]; then
        cat "$TMP_DIR/out" >&2
        fail "$2: expected exit $1, got $rc"
    fi
    ok "$2"
}

# --- positive control, and the UNEVALUATED contract -----------------------------------------------
reset_fixture
expect_rc 0 'the shipped tree passes with tinyproxy unavailable'
grep -q 'UNEVALUATED' "$TMP_DIR/out" || fail 'an unavailable engine was not reported as UNEVALUATED'
grep -q 'PASS with .* UNEVALUATED' "$TMP_DIR/out" \
    || fail 'the summary hides that an engine was never executed'
ok 'an engine that could not be executed is UNEVALUATED and named in the summary, never a silent pass'

# --- predicate parity across the construction paths -----------------------------------------------
for target in mitm/sidecar-entrypoint.sh scripts/network/allow-domain.sh scripts/network/allow-domain.ps1; do
    reset_fixture
    # Widen the hostname predicate in one path only: single-label names would now be admitted.
    sed -i.bak 's/(\\\.\[A-Za-z0-9\](\[A-Za-z0-9-\]\*\[A-Za-z0-9\])?)+\$/(\\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$/' "$FIX/$target" 2>/dev/null || true
    python3 - "$FIX/$target" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
# one path stops requiring a second label — the bare-TLD guard, widened
s = s.replace(r')?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$', r')?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$', 1)
open(p, 'w').write(s)
PY
    expect_rc 1 "a widened hostname predicate in $target is reported"
    grep -q 'predicate' "$TMP_DIR/out" || fail "the $target failure does not name the predicate"
done
ok 'a predicate divergence names which path diverged'

reset_fixture
python3 - "$FIX/scripts/network/allow-domain.sh" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace(r'line="(^|\\.)${esc}\$"', 'line="${esc}"', 1)   # drop the anchoring entirely
open(p, 'w').write(s)
PY
expect_rc 1 'a hot-add path that stops anchoring its generated pattern is reported'

# --- the recorded verdicts must match what the builders and engines actually do -------------------
reset_fixture
sed -i.bak 's/^com | refuse |/com | admit |/' "$FIX/docs/allowlist-decisions.md"
expect_rc 1 'a bare TLD recorded as admitted is reported, because the builders refuse it'

reset_fixture
sed -i.bak 's/^8\.8\.8\.8 | refuse |/8.8.8.8 | admit |/' "$FIX/docs/allowlist-decisions.md"
expect_rc 1 'an IP literal recorded as admitted is reported, because the builders refuse it'

reset_fixture
sed -i.bak 's/^evil-anthropic\.com | refuse | refuse |/evil-anthropic.com | refuse | admit |/' "$FIX/docs/allowlist-decisions.md"
expect_rc 1 'a changed engine verdict is reported: the addon refuses the suffix near-miss'

reset_fixture
sed -i.bak 's/^anthropic\.com\. | refuse | admit | undecided |/anthropic.com. | refuse | refuse | undecided |/' "$FIX/docs/allowlist-decisions.md"
expect_rc 1 'the undecided row is asserted too: flipping either recorded verdict fails'

# --- fail closed on a malformed or missing inventory ----------------------------------------------
reset_fixture
python3 - "$FIX/docs/allowlist-decisions.md" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace('```allowlist-runtime', '```allowlist-runtime-renamed', 1)
open(p, 'w').write(s)
PY
expect_rc 2 'a missing case block exits 2 rather than passing with nothing to check'

reset_fixture
rm -f "$FIX/docs/allowlist-decisions.md"
expect_rc 2 'a missing inventory exits 2'

# --- and once against the real engines, when the image is here ------------------------------------
reset_fixture
if docker image inspect coding-agent-sandbox:latest >/dev/null 2>&1; then
    expect_rc 0 'the shipped tree passes with tinyproxy actually executed' coding-agent-sandbox:latest
    grep -q 'on both real engines' "$TMP_DIR/out" \
        || fail 'the summary does not report that both engines were executed'
    grep -q 'UNEVALUATED' "$TMP_DIR/out" \
        && fail 'an engine was reported UNEVALUATED even though the image is present'
    ok 'with the image present both engines are executed and the summary says so'
else
    printf 'SKIP: coding-agent-sandbox:latest absent — the real-engine case needs a built image\n'
fi

printf '\n%d passed, 0 failed\n' "$PASSED"
