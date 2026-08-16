#!/usr/bin/env bash
# Deterministic coverage for issue #68's provider-contract drift check.
# Drives the check against fixture inventories and fixture trees; never installs, launches, or
# contacts anything, and never needs a credential.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHECK="$ROOT/scripts/check-provider-contracts.sh"
DOC="$ROOT/docs/provider-contracts.md"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

PASSED=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { PASSED=$((PASSED + 1)); printf 'ok  %s\n' "$*"; }

[[ -x "$CHECK" ]] || fail "check is missing or not executable"
[[ -f "$DOC" ]] || fail "provider contract inventory is missing"
ok "check and inventory are present"

# The check must stay credential-free and offline: it is the thing that has to remain runnable in
# ordinary verification, and a drift check that needs a credential becomes a reason to keep one.
if grep -nE '\b(curl|wget|nc|openssl s_client|ssh|python3? -c .*urllib)\b' "$CHECK" >/dev/null 2>&1; then
    fail "check references a network command"
fi
ok "check contains no network command"

if grep -nE '\.env\b|credentials\.json|api-key["'\'' ]*\)|\bTOKEN\b' "$CHECK" >/dev/null 2>&1; then
    fail "check reads a credential location"
fi
ok "check reads no credential location"

# --- fixture helpers -------------------------------------------------------
read_block() { # doc -> the machine-readable records, comments stripped
    awk '
        /^```contract-pins$/ { inblock = 1; next }
        inblock && /^```/    { inblock = 0; next }
        inblock              { print }
    ' "$1" | grep -vE '^\s*(#|$)' || true
}

make_tree() { # dir
    mkdir -p "$1"
    printf 'alpha marker PINNED-ALPHA here\n' >"$1/a.txt"
    printf 'beta marker PINNED-BETA here\n' >"$1/b.txt"
}

make_doc() { # path record...
    local path=$1; shift
    {
        printf '# fixture inventory\n\n```contract-pins\n'
        printf '# id | provider | surface | files | pin | live | observed\n'
        local r
        for r in "$@"; do printf '%s\n' "$r"; done
        printf '```\n'
    } >"$path"
}

run_check() { # doc root [--json] -> sets STATUS and OUT
    set +e
    OUT=$(PROVIDER_CONTRACTS_DOC="$1" PROVIDER_CONTRACTS_ROOT="$2" "$CHECK" ${3:-} 2>&1)
    STATUS=$?
    set -e
}

status_of() { # id, from $OUT
    awk -v id="$1" '$2 == id { print $1; found = 1 } END { if (!found) print "ABSENT" }' <<<"$OUT"
}

FIX_ROOT="$TMP_DIR/tree"
make_tree "$FIX_ROOT"

# --- the real inventory ----------------------------------------------------
# This is the regression guard that keeps the inventory honest: if a pinned literal is edited out of
# the source without updating docs/provider-contracts.md, the check reports it and this test fails.
run_check "$DOC" "$ROOT"
[[ $STATUS -eq 1 ]] || fail "real inventory should exit 1 while a recorded contract is drifted (got $STATUS)"
ok "real inventory exits 1 while a recorded contract is drifted"

[[ "$(status_of claude.oauth-client-id)" == DRIFTED ]] \
    || fail "the known-drifted Claude client registration must be reported DRIFTED"
ok "known-drifted Claude client registration is reported DRIFTED"

drifted_ids=$(awk '$1 == "DRIFTED" { print $2 }' <<<"$OUT")
[[ "$drifted_ids" == "claude.oauth-client-id" ]] \
    || fail "unexpected drift in the real tree: $(tr '\n' ' ' <<<"$drifted_ids")"
ok "every other recorded pin still agrees with the source"

grep -q '^PASS ' <<<"$OUT" || fail "real inventory reports no PASS at all"
grep -q '^UNEVALUATED ' <<<"$OUT" || fail "real inventory reports no UNEVALUATED at all"
ok "real inventory reports both evaluable and unevaluable dependencies"

# Every recorded dependency must appear exactly once, with one of exactly three statuses.
while IFS= read -r record; do
    id=$(awk -F'|' '{ gsub(/^[ \t]+|[ \t]+$/, "", $1); print $1 }' <<<"$record")
    hits=$(awk -v id="$id" '$2 == id { c++ } END { print c + 0 }' <<<"$OUT")
    [[ "$hits" -eq 1 ]] || fail "dependency '$id' produced $hits rows, expected exactly 1"
    st=$(status_of "$id")
    case "$st" in
        PASS|DRIFTED|UNEVALUATED) ;;
        *) fail "dependency '$id' produced an unexpected status '$st'" ;;
    esac
done < <(read_block "$DOC")
ok "every recorded dependency reports exactly one of the three outcomes"

# An unevaluated dependency must never also be claimed as verified.
if grep -E '^UNEVALUATED' <<<"$OUT" | grep -qiE '\bverified\b|\bconfirmed\b|\bagrees\b'; then
    fail "an UNEVALUATED row claims verification"
fi
ok "no UNEVALUATED row claims verification"

# --- healthy fixture -------------------------------------------------------
HEALTHY="$TMP_DIR/healthy.md"
make_doc "$HEALTHY" \
    'fix.alpha | Fixture | pinned CLI | a.txt | PINNED-ALPHA | na | -' \
    'fix.beta | Fixture | local secret path | b.txt | PINNED-BETA | na | -'
run_check "$HEALTHY" "$FIX_ROOT"
[[ $STATUS -eq 0 ]] || fail "healthy fixture should exit 0 (got $STATUS)"
[[ "$(status_of fix.alpha)" == PASS && "$(status_of fix.beta)" == PASS ]] \
    || fail "healthy fixture should report PASS for both pins"
ok "healthy fixture reports PASS and exits 0"

# --- negative case per dependency class ------------------------------------
# The classes are derived from the real inventory, so a newly recorded class inherits its own
# negative case instead of being trusted by default.
classes=$(read_block "$DOC" | awk -F'|' '{ gsub(/^[ \t]+|[ \t]+$/, "", $3); print $3 }' | sort -u)
[[ -n "$classes" ]] || fail "could not derive dependency classes from the real inventory"
class_count=0
while IFS= read -r class; do
    [[ -n "$class" ]] || continue
    class_count=$((class_count + 1))
    BROKEN="$TMP_DIR/broken-$class_count.md"
    make_doc "$BROKEN" "fix.gone | Fixture | $class | a.txt | VALUE-THAT-IS-NOT-THERE | na | -"
    run_check "$BROKEN" "$FIX_ROOT"
    [[ $STATUS -eq 1 ]] || fail "class '$class': an absent pin must exit 1 (got $STATUS)"
    [[ "$(status_of fix.gone)" == DRIFTED ]] \
        || fail "class '$class': an absent pin must be reported DRIFTED"
done <<<"$classes"
ok "an absent pin fails closed for each of the $class_count recorded dependency classes"

# A recorded file that has disappeared entirely is drift, not a silent skip.
MISSING="$TMP_DIR/missing-file.md"
make_doc "$MISSING" 'fix.nofile | Fixture | endpoint | nowhere.txt | PINNED-ALPHA | na | -'
run_check "$MISSING" "$FIX_ROOT"
[[ $STATUS -eq 1 && "$(status_of fix.nofile)" == DRIFTED ]] \
    || fail "a missing recorded file must be reported DRIFTED with exit 1"
ok "a missing recorded file is reported DRIFTED"

# A pin present in one recorded file but absent from another is still drift.
PARTIAL="$TMP_DIR/partial.md"
make_doc "$PARTIAL" 'fix.partial | Fixture | endpoint | a.txt,b.txt | PINNED-ALPHA | na | -'
run_check "$PARTIAL" "$FIX_ROOT"
[[ $STATUS -eq 1 && "$(status_of fix.partial)" == DRIFTED ]] \
    || fail "a pin absent from one of several recorded files must be DRIFTED"
grep -q 'b.txt' <<<"$OUT" || fail "the drift detail must name the file that lost the pin"
ok "a pin absent from one of several recorded files is DRIFTED and names the file"

# --- the unevaluable case --------------------------------------------------
UNEVAL="$TMP_DIR/uneval.md"
make_doc "$UNEVAL" \
    'fix.live | Fixture | endpoint | a.txt | PINNED-ALPHA | required | -' \
    'fix.asserted | Fixture | asserted credential schema | - | ~/somewhere/auth.json | required | -'
run_check "$UNEVAL" "$FIX_ROOT"
[[ $STATUS -eq 0 ]] || fail "unevaluable dependencies alone should not fail the run (got $STATUS)"
[[ "$(status_of fix.live)" == UNEVALUATED ]] \
    || fail "a live-only dependency must be UNEVALUATED, not PASS"
[[ "$(status_of fix.asserted)" == UNEVALUATED ]] \
    || fail "an asserted contract with no in-tree literal must be UNEVALUATED, not skipped"
if grep -q '^PASS ' <<<"$OUT"; then
    fail "no row should be PASS when nothing was evaluable offline"
fi
ok "live-only and asserted dependencies are UNEVALUATED, never PASS"

# Drift observed against the provider is reported even though the source is untouched.
OBSERVED="$TMP_DIR/observed.md"
make_doc "$OBSERVED" 'fix.rotated | Fixture | identifier | a.txt | PINNED-ALPHA | required | drifted:2026-08-14'
run_check "$OBSERVED" "$FIX_ROOT"
[[ $STATUS -eq 1 && "$(status_of fix.rotated)" == DRIFTED ]] \
    || fail "a recorded provider-side drift must be DRIFTED with exit 1"
grep -q '2026-08-14' <<<"$OUT" || fail "the drift detail must name the date it was observed"
ok "a recorded provider-side drift is DRIFTED and names its date"

# --- malformed inventories fail closed -------------------------------------
run_check "$TMP_DIR/does-not-exist.md" "$FIX_ROOT"
[[ $STATUS -eq 2 ]] || fail "a missing inventory must exit 2 (got $STATUS)"

printf '# no block here\n' >"$TMP_DIR/noblock.md"
run_check "$TMP_DIR/noblock.md" "$FIX_ROOT"
[[ $STATUS -eq 2 ]] || fail "an inventory with no contract-pins block must exit 2 (got $STATUS)"

make_doc "$TMP_DIR/empty.md"
run_check "$TMP_DIR/empty.md" "$FIX_ROOT"
[[ $STATUS -eq 2 ]] || fail "an inventory recording no dependencies must exit 2 (got $STATUS)"

make_doc "$TMP_DIR/short.md" 'fix.short | Fixture | endpoint | a.txt | PINNED-ALPHA'
run_check "$TMP_DIR/short.md" "$FIX_ROOT"
[[ $STATUS -eq 2 ]] || fail "a record with too few fields must exit 2 (got $STATUS)"

make_doc "$TMP_DIR/badlive.md" 'fix.bad | Fixture | endpoint | a.txt | PINNED-ALPHA | maybe | -'
run_check "$TMP_DIR/badlive.md" "$FIX_ROOT"
[[ $STATUS -eq 2 ]] || fail "an invalid live value must exit 2 (got $STATUS)"

make_doc "$TMP_DIR/badobs.md" 'fix.bad | Fixture | endpoint | a.txt | PINNED-ALPHA | required | drifted:soon'
run_check "$TMP_DIR/badobs.md" "$FIX_ROOT"
[[ $STATUS -eq 2 ]] || fail "an invalid observed value must exit 2 (got $STATUS)"

make_doc "$TMP_DIR/dupe.md" \
    'fix.same | Fixture | endpoint | a.txt | PINNED-ALPHA | na | -' \
    'fix.same | Fixture | endpoint | b.txt | PINNED-BETA | na | -'
run_check "$TMP_DIR/dupe.md" "$FIX_ROOT"
[[ $STATUS -eq 2 ]] || fail "a duplicate dependency id must exit 2 (got $STATUS)"

# The combination that would let an unevaluable dependency be reported as verified.
make_doc "$TMP_DIR/unverifiable.md" 'fix.ghost | Fixture | endpoint | - | something | na | -'
run_check "$TMP_DIR/unverifiable.md" "$FIX_ROOT"
[[ $STATUS -eq 2 ]] || fail "a record with no files claiming live=na must exit 2 (got $STATUS)"
ok "malformed inventories fail closed with exit 2 (8 cases)"

# --- JSON output -----------------------------------------------------------
run_check "$DOC" "$ROOT" --json
python3 -c 'import json,sys; json.load(sys.stdin)' <<<"$OUT" \
    || fail "--json output is not valid JSON"
python3 - "$OUT" <<'PY' || fail "--json payload does not describe the drift correctly"
import json, sys
d = json.loads(sys.argv[1])
assert d["contractDrift"] is True, "contractDrift should be true while a pin is drifted"
assert d["drifted"] >= 1, "drifted count should be at least 1"
assert d["unevaluated"] >= 1, "unevaluated count should be at least 1"
ids = {c["dependency"]: c["status"] for c in d["checks"]}
assert ids["claude.oauth-client-id"] == "DRIFTED", "client id must be DRIFTED in JSON too"
assert set(ids.values()) <= {"PASS", "DRIFTED", "UNEVALUATED"}, "unexpected status in JSON"
PY
ok "--json emits valid JSON that matches the human report"

run_check "$HEALTHY" "$FIX_ROOT" --json
python3 - "$OUT" <<'PY' || fail "--json should report no drift for a healthy inventory"
import json, sys
d = json.loads(sys.argv[1])
assert d["contractDrift"] is False and d["drifted"] == 0
PY
ok "--json reports no drift for a healthy inventory"

printf '\nAll %d checks passed.\n' "$PASSED"
