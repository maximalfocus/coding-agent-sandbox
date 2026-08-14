#!/usr/bin/env bash
# Deterministic coverage for issue #63's upstream-proxy compatibility probe.
# Drives the probe against fixture `sbx` binaries; never installs, launches, or contacts anything.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PROBE="$ROOT/scripts/probe-sbx-upstream-proxy.sh"
DOC="$ROOT/docs/sbx-upstream-proxy-feasibility.md"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

PASSED=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { PASSED=$((PASSED + 1)); printf 'ok  %s\n' "$*"; }

[[ -x "$PROBE" ]] || fail "probe is missing or not executable"
[[ -f "$DOC" ]] || fail "feasibility verdict doc is missing"
ok "probe and verdict document are present"

# The probe must never reach the network or create a sandbox.
if grep -nE '\b(curl|wget|nc|sbx (run|create|login|exec))\b' "$PROBE" >/dev/null 2>&1; then
    fail "probe references a network or sandbox-creating command"
fi
ok "probe contains no network or sandbox-creating command"

# --- fixture builder -------------------------------------------------------
# $1 fixture path, $2 settings JSON, $3 kit validate output
make_fixture() {
    local path=$1 settings=$2 kit_out=$3
    cat >"$path" <<FIXTURE
#!/usr/bin/env bash
case "\${1:-}" in
  version) echo 'sbx version: v0.38.0 fixture' ;;
  settings) cat <<'SETTINGS'
$settings
SETTINGS
    ;;
  kit) printf '%s\n' '$kit_out' ;;
  *) exit 1 ;;
esac
FIXTURE
    chmod +x "$path"
}

GOOD_SETTINGS='[
 {"key":"proxy","description":"Upstream proxy for both sandbox and daemon egress (URL, PAC source, \"system\", or \"direct\"; empty = automatic: HTTP(S)_PROXY if set, otherwise the host OS proxy)."},
 {"key":"proxy.sandbox","description":"Upstream proxy for sandbox egress only."},
 {"key":"proxy.daemon","description":"Upstream proxy for the daemon only."},
 {"key":"no_proxy.sandbox","description":"No-proxy exceptions for sandbox egress."},
 {"key":"tls.allowNegativeSerial","description":"Accept server certificates with a negative serial number."}
]'

run_probe() { # fixture -> sets STATUS and OUT
    set +e
    OUT=$(SBX_BIN="$1" "$PROBE" 2>&1)
    STATUS=$?
    set -e
}

# --- happy path ------------------------------------------------------------
make_fixture "$TMP_DIR/good" "$GOOD_SETTINGS" "VALID: fixture"
run_probe "$TMP_DIR/good"
[[ $STATUS -eq 0 ]] || fail "healthy surface should exit 0 (got $STATUS)"
grep -q 'no relied-on sbx surface was contradicted' <<<"$OUT" \
    || fail "healthy surface should report no contradiction"
grep -q 'PASS *upstream-proxy-keys' <<<"$OUT" || fail "expected upstream-proxy-keys PASS"
grep -q 'PASS *http-proxy-accepted' <<<"$OUT" || fail "expected http-proxy-accepted PASS"
grep -q 'PASS *kit-mixin-schema' <<<"$OUT" || fail "expected kit-mixin-schema PASS"
ok "healthy sbx surface passes every relied-on check"

# --- fail closed: missing sbx must not be reported as success --------------
run_probe "$TMP_DIR/does-not-exist"
[[ $STATUS -eq 0 ]] || fail "absent sbx should not be a hard failure (got $STATUS)"
grep -q 'UNVERIFIED *sbx-present' <<<"$OUT" || fail "absent sbx should report UNVERIFIED"
grep -q 'PASS' <<<"$OUT" && fail "absent sbx must not synthesize any PASS"
ok "absent sbx reports UNVERIFIED and synthesizes no PASS"

# --- relied-on key disappears ---------------------------------------------
make_fixture "$TMP_DIR/no-scope" \
    "$(python3 -c '
import json,sys
rows=json.loads(sys.argv[1])
print(json.dumps([r for r in rows if r["key"]!="proxy.sandbox"]))' "$GOOD_SETTINGS")" \
    "VALID: fixture"
run_probe "$TMP_DIR/no-scope"
[[ $STATUS -eq 1 ]] || fail "missing proxy.sandbox should exit 1 (got $STATUS)"
grep -q 'CHANGED *upstream-proxy-keys' <<<"$OUT" || fail "expected upstream-proxy-keys CHANGED"
ok "removal of proxy.sandbox is detected and fails closed"

# --- HTTP proxy form withdrawn --------------------------------------------
make_fixture "$TMP_DIR/socks-only" \
    "$(python3 -c '
import json,sys
rows=json.loads(sys.argv[1])
for r in rows:
    if r["key"]=="proxy": r["description"]="Upstream proxy (socks5:// only)."
print(json.dumps(rows))' "$GOOD_SETTINGS")" \
    "VALID: fixture"
run_probe "$TMP_DIR/socks-only"
[[ $STATUS -eq 1 ]] || fail "withdrawn HTTP proxy form should exit 1 (got $STATUS)"
grep -q 'CHANGED *http-proxy-accepted' <<<"$OUT" || fail "expected http-proxy-accepted CHANGED"
ok "withdrawal of the HTTP proxy form is detected"

# --- a custom CA setting appears: the documented limitation may be retired --
make_fixture "$TMP_DIR/with-ca" \
    "$(python3 -c '
import json,sys
rows=json.loads(sys.argv[1])
rows.append({"key":"tls.customCaBundle","description":"Extra trust anchors for the sandbox proxy."})
print(json.dumps(rows))' "$GOOD_SETTINGS")" \
    "VALID: fixture"
run_probe "$TMP_DIR/with-ca"
[[ $STATUS -eq 1 ]] || fail "new CA-trust setting should exit 1 (got $STATUS)"
grep -q 'CHANGED *no-custom-ca-setting' <<<"$OUT" || fail "expected no-custom-ca-setting CHANGED"
ok "appearance of a custom-CA setting is surfaced for reevaluation"

# --- kit schema drift ------------------------------------------------------
make_fixture "$TMP_DIR/kit-drift" "$GOOD_SETTINGS" \
    "INVALID: manifest: field setup.startup not found"
run_probe "$TMP_DIR/kit-drift"
[[ $STATUS -eq 1 ]] || fail "kit schema drift should exit 1 (got $STATUS)"
grep -q 'CHANGED *kit-mixin-schema' <<<"$OUT" || fail "expected kit-mixin-schema CHANGED"
ok "kit mixin schema drift is detected"

# --- JSON mode -------------------------------------------------------------
set +e
JSON_OUT=$(SBX_BIN="$TMP_DIR/good" "$PROBE" --json 2>&1)
JSON_STATUS=$?
set -e
[[ $JSON_STATUS -eq 0 ]] || fail "--json should exit 0 on a healthy surface"
python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["relianceContradicted"] is False, "healthy surface must not report contradiction"
assert d["checks"], "checks must not be empty"
assert all(c["status"] in ("PASS", "CHANGED", "UNVERIFIED") for c in d["checks"]), "bad status"
' <<<"$JSON_OUT" || fail "--json did not emit valid, well-formed JSON"
ok "--json emits valid machine-readable output"

printf '\nAll %d checks passed.\n' "$PASSED"
